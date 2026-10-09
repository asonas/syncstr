pub const ALPN: &[u8] = b"syncstr/music/1";

#[derive(clap::ValueEnum, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Direct,
    Auto,
    RelayOnly,
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct Message {
    #[serde(default = "version")]
    pub version: u8,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub library: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry: Option<crate::model::Entry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub track: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub organization: Option<crate::organization::Organization>,
}

fn version() -> u8 {
    2
}

impl crate::peer::Message {
    pub fn new(kind: &str) -> Self {
        Self {
            version: 2,
            kind: kind.to_owned(),
            ..Self::default()
        }
    }
}

pub async fn send(
    stream: &mut iroh::endpoint::SendStream,
    message: &crate::peer::Message,
) -> anyhow::Result<()> {
    let body = serde_json::to_vec(message)?;
    anyhow::ensure!(body.len() <= 2 * 1024 * 1024, "message too large");
    stream.write_all(&(body.len() as u32).to_be_bytes()).await?;
    stream.write_all(&body).await?;
    Ok(())
}

pub async fn receive(
    stream: &mut iroh::endpoint::RecvStream,
) -> anyhow::Result<crate::peer::Message> {
    let mut header = [0; 4];
    tokio::time::timeout(
        std::time::Duration::from_secs(120),
        stream.read_exact(&mut header),
    )
    .await??;
    let length = u32::from_be_bytes(header) as usize;
    anyhow::ensure!(
        length > 0 && length <= 2 * 1024 * 1024,
        "invalid message length"
    );
    let mut body = vec![0; length];
    tokio::time::timeout(
        std::time::Duration::from_secs(120),
        stream.read_exact(&mut body),
    )
    .await??;
    let message: crate::peer::Message = serde_json::from_slice(&body)?;
    anyhow::ensure!(
        message.version == 2,
        "update Syncstr: organization protocol version 2 required"
    );
    Ok(message)
}

async fn receive_organization(
    stream: &mut iroh::endpoint::RecvStream,
    header: &crate::peer::Message,
) -> anyhow::Result<Option<crate::organization::Organization>> {
    use base64::Engine as _;
    if let Some(organization) = &header.organization {
        organization.validate()?;
        return Ok(Some(organization.clone()));
    }
    if header.track.as_deref() != Some("organization") {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    loop {
        let message = crate::peer::receive(stream).await?;
        if message.kind == "organization-end" {
            break;
        }
        anyhow::ensure!(
            message.kind == "organization",
            "expected organization chunk"
        );
        let chunk = base64::engine::general_purpose::STANDARD.decode(
            message
                .bytes
                .ok_or_else(|| anyhow::anyhow!("missing organization bytes"))?,
        )?;
        anyhow::ensure!(
            !chunk.is_empty()
                && chunk.len() <= 65536
                && bytes.len() + chunk.len() <= 64 * 1024 * 1024,
            "invalid organization size"
        );
        bytes.extend(chunk);
    }
    let organization: crate::organization::Organization = serde_json::from_slice(&bytes)?;
    organization.validate()?;
    Ok(Some(organization))
}

async fn send_organized(
    stream: &mut iroh::endpoint::SendStream,
    mut header: crate::peer::Message,
    organization: crate::organization::Organization,
) -> anyhow::Result<()> {
    use base64::Engine as _;
    let bytes = serde_json::to_vec(&organization)?;
    anyhow::ensure!(bytes.len() <= 64 * 1024 * 1024, "organization too large");
    if bytes.len() <= 1024 * 1024 {
        header.organization = Some(organization);
        crate::peer::send(stream, &header).await?;
    } else {
        header.track = Some("organization".to_owned());
        crate::peer::send(stream, &header).await?;
        for chunk in bytes.chunks(65536) {
            let mut message = crate::peer::Message::new("organization");
            message.bytes = Some(base64::engine::general_purpose::STANDARD.encode(chunk));
            crate::peer::send(stream, &message).await?;
        }
        crate::peer::send(stream, &crate::peer::Message::new("organization-end")).await?;
    }
    Ok(())
}

pub async fn serve(
    identity: std::sync::Arc<crate::peer::Identity>,
    endpoint: iroh::Endpoint,
    store: crate::store::Store,
) {
    let slots = std::sync::Arc::new(tokio::sync::Semaphore::new(4));
    let mut tasks = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break };
                let Ok(permit) = slots.clone().try_acquire_owned() else { incoming.refuse(); continue };
                let identity = identity.clone();
                let store = store.clone();
                tasks.spawn(async move {
                    let _permit = permit;
                    let result = tokio::time::timeout(std::time::Duration::from_secs(7200), async {
                        let connection = tokio::time::timeout(std::time::Duration::from_secs(20), incoming).await??;
                        if !identity.is_paired(connection.remote_id()) {
                            connection.close(1u32.into(), b"peer not paired");
                            anyhow::bail!("peer not paired");
                        }
                        crate::peer::serve_connection(&identity, connection, store).await
                    }).await;
                    if !matches!(result, Ok(Ok(()))) { eprintln!("P2P connection ended: {result:?}"); }
                });
            },
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
}

async fn serve_connection(
    identity: &crate::peer::Identity,
    connection: iroh::endpoint::Connection,
    store: crate::store::Store,
) -> anyhow::Result<()> {
    use base64::Engine as _;
    use sha2::Digest as _;
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let (mut output, mut input) = connection.accept_bi().await?;
    let hello = crate::peer::receive(&mut input).await?;
    anyhow::ensure!(hello.kind == "hello", "expected hello");
    if let Some(organization) = crate::peer::receive_organization(&mut input, &hello).await? {
        store.merge_organization(organization).await?;
    }
    let catalog = store.catalog().await?;
    let mut header = crate::peer::Message::new("catalog");
    header.library = Some(catalog.id);
    header.name = Some(catalog.name);
    crate::peer::send_organized(&mut output, header, catalog.organization).await?;
    for entry in catalog.entries {
        let mut message = crate::peer::Message::new("entry");
        message.entry = Some(entry);
        crate::peer::send(&mut output, &message).await?;
    }
    crate::peer::send(&mut output, &crate::peer::Message::new("ready")).await?;
    loop {
        let request = crate::peer::receive(&mut input).await?;
        anyhow::ensure!(identity.is_paired(connection.remote_id()), "peer revoked");
        match request.kind.as_str() {
            "get" => {
                let id = request
                    .track
                    .ok_or_else(|| anyhow::anyhow!("missing track"))?;
                let entry = store
                    .get(id.clone())
                    .await?
                    .ok_or_else(|| anyhow::anyhow!("unknown track"))?;
                let mut file = tokio::fs::File::open(store.path(&entry)).await?;
                anyhow::ensure!(
                    file.metadata().await?.len() == entry.track.size,
                    "audio changed"
                );
                let mut buffer = vec![0; 65536];
                loop {
                    let count = file.read(&mut buffer).await?;
                    if count == 0 {
                        break;
                    }
                    anyhow::ensure!(identity.is_paired(connection.remote_id()), "peer revoked");
                    let mut chunk = crate::peer::Message::new("data");
                    chunk.bytes =
                        Some(base64::engine::general_purpose::STANDARD.encode(&buffer[..count]));
                    crate::peer::send(&mut output, &chunk).await?;
                }
                let mut end = crate::peer::Message::new("end");
                end.track = Some(id);
                crate::peer::send(&mut output, &end).await?;
            }
            "put" => {
                let incoming_organization =
                    crate::peer::receive_organization(&mut input, &request).await?;
                let entry = request
                    .entry
                    .ok_or_else(|| anyhow::anyhow!("missing entry"))?;
                entry.validate()?;
                anyhow::ensure!(
                    serde_json::to_vec(&entry)?.len() <= crate::model::MAX_METADATA,
                    "entry too large"
                );
                let temporary = store.stage().await?;
                let mut file = tokio::fs::File::from_std(temporary.reopen()?);
                let mut count = 0u64;
                let mut hash = sha2::Sha256::new();
                crate::peer::send(&mut output, &crate::peer::Message::new("accept")).await?;
                loop {
                    let chunk = crate::peer::receive(&mut input).await?;
                    anyhow::ensure!(identity.is_paired(connection.remote_id()), "peer revoked");
                    if chunk.kind == "end" {
                        break;
                    }
                    anyhow::ensure!(chunk.kind == "data", "expected audio chunk");
                    let bytes = base64::engine::general_purpose::STANDARD.decode(
                        chunk
                            .bytes
                            .ok_or_else(|| anyhow::anyhow!("missing bytes"))?,
                    )?;
                    anyhow::ensure!(
                        !bytes.is_empty()
                            && bytes.len() <= 65536
                            && count + bytes.len() as u64 <= entry.track.size,
                        "invalid audio chunk"
                    );
                    count += bytes.len() as u64;
                    hash.update(&bytes);
                    file.write_all(&bytes).await?;
                }
                anyhow::ensure!(
                    count == entry.track.size && hex::encode(hash.finalize()) == entry.sha256,
                    "audio integrity mismatch"
                );
                file.flush().await?;
                file.sync_all().await?;
                drop(file);
                let saved = store
                    .commit_organized(entry, temporary, true, incoming_organization)
                    .await?;
                let mut response = crate::peer::Message::new("saved");
                response.entry = Some(saved);
                crate::peer::send(&mut output, &response).await?;
            }
            "bye" => {
                output.finish()?;
                output.stopped().await?;
                return Ok(());
            }
            _ => anyhow::bail!("unsupported request"),
        }
    }
}

pub struct Identity {
    root: std::path::PathBuf,
    key: iroh::SecretKey,
}

impl crate::peer::Identity {
    pub fn sign(&self, bytes: &[u8]) -> Vec<u8> {
        self.key.sign(bytes).to_bytes().to_vec()
    }

    pub fn allowed_peers(&self) -> anyhow::Result<Vec<iroh::EndpointId>> {
        std::fs::read_dir(self.root.join("peers"))?
            .map(|entry| Ok(entry?.file_name().to_string_lossy().parse()?))
            .collect()
    }

    pub fn initialize(root: &std::path::Path) -> anyhow::Result<iroh::EndpointId> {
        use std::io::Write as _;
        use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root)?;
        let key = iroh::SecretKey::generate();
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(root.join("device.key"))?;
        file.write_all(&key.to_bytes())?;
        file.sync_all()?;
        std::fs::File::open(root)?.sync_all()?;
        Ok(key.public())
    }

    pub fn open(root: &std::path::Path) -> anyhow::Result<Self> {
        let bytes: [u8; 32] = std::fs::read(root.join("device.key"))?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid device key"))?;
        Ok(Self {
            root: root.to_owned(),
            key: iroh::SecretKey::from_bytes(&bytes),
        })
    }

    pub fn id(&self) -> iroh::EndpointId {
        self.key.public()
    }

    pub fn pair(&self, peer: iroh::EndpointId) -> anyhow::Result<()> {
        use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
        anyhow::ensure!(peer != self.id(), "cannot pair with this device");
        std::fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(self.root.join("peers"))?;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(self.root.join("peers").join(peer.to_string()))?;
        file.sync_all()?;
        std::fs::File::open(self.root.join("peers"))?.sync_all()?;
        Ok(())
    }

    pub fn unpair(&self, peer: iroh::EndpointId) -> anyhow::Result<()> {
        std::fs::remove_file(self.root.join("peers").join(peer.to_string()))?;
        std::fs::File::open(self.root.join("peers"))?.sync_all()?;
        Ok(())
    }

    pub fn is_paired(&self, peer: iroh::EndpointId) -> bool {
        self.root.join("peers").join(peer.to_string()).is_file()
    }

    pub async fn endpoint(
        &self,
        mode: crate::peer::Mode,
        listen: &[std::net::SocketAddr],
    ) -> anyhow::Result<(iroh::Endpoint, std::fs::File)> {
        use std::os::unix::fs::OpenOptionsExt as _;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(self.root.join("device.lock"))?;
        fs2::FileExt::try_lock_exclusive(&lock)?;
        let builder = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
            .secret_key(self.key.clone())
            .alpns(vec![crate::peer::ALPN.to_vec()])
            .relay_mode(if mode != crate::peer::Mode::Direct {
                iroh::RelayMode::Default
            } else {
                iroh::RelayMode::Disabled
            });
        anyhow::ensure!(
            listen.is_empty() || mode != crate::peer::Mode::RelayOnly,
            "A P2P listen address cannot be used in relay-only mode"
        );
        let mut builder = builder;
        if !listen.is_empty() {
            builder = builder.clear_ip_transports();
            for address in listen {
                builder = builder.bind_addr(*address)?;
            }
        }
        let endpoint = if mode == crate::peer::Mode::RelayOnly {
            builder.clear_ip_transports()
        } else {
            builder
        }
        .bind()
        .await?;
        if mode != crate::peer::Mode::Direct {
            tokio::time::timeout(std::time::Duration::from_secs(20), endpoint.online()).await?;
        }
        Ok((endpoint, lock))
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Address {
    pub version: u8,
    pub id: iroh::EndpointId,
    pub addresses: Vec<std::net::SocketAddr>,
    pub relay: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
}

impl crate::peer::Address {
    pub fn read(path: &std::path::Path, expected: iroh::EndpointId) -> anyhow::Result<Self> {
        use std::io::Read as _;
        let mut bytes = Vec::new();
        std::fs::File::open(path)?
            .take(16 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        anyhow::ensure!(bytes.len() <= 16 * 1024, "address file too large");
        let address: Self = serde_json::from_slice(&bytes)?;
        anyhow::ensure!(address.version == 1, "unsupported address version");
        anyhow::ensure!(
            address.id == expected,
            "address does not match approved peer"
        );
        Ok(address)
    }

    pub fn write(endpoint: &iroh::Endpoint, path: &std::path::Path) -> anyhow::Result<()> {
        use std::io::Write as _;
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(std::path::Path::new("."));
        let mut file = tempfile::NamedTempFile::new_in(parent)?;
        serde_json::to_writer(
            &mut file,
            &Self {
                version: 1,
                directory: None,
                id: endpoint.id(),
                addresses: endpoint
                    .addr()
                    .addrs
                    .iter()
                    .filter_map(|addr| match addr {
                        iroh::TransportAddr::Ip(ip) => Some(*ip),
                        _ => None,
                    })
                    .collect(),
                relay: endpoint.addr().addrs.iter().find_map(|addr| match addr {
                    iroh::TransportAddr::Relay(url) => Some(url.to_string()),
                    _ => None,
                }),
            },
        )?;
        file.write_all(b"\n")?;
        file.as_file().sync_all()?;
        if path.exists() {
            Self::read(path, endpoint.id())?;
            file.persist(path)?;
        } else {
            file.persist_noclobber(path)?;
        }
        std::fs::File::open(parent)?.sync_all()?;
        Ok(())
    }
}

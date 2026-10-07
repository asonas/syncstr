pub const ALPN: &[u8] = b"syncstr/connectivity-probe/1";
pub const MAX_BYTES: usize = 64 * 1024;

#[derive(clap::ValueEnum, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Direct,
    Auto,
    RelayOnly,
}

pub struct Identity {
    root: std::path::PathBuf,
    key: iroh::SecretKey,
}

impl crate::Identity {
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
        mode: crate::Mode,
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
            .alpns(vec![crate::ALPN.to_vec()])
            .relay_mode(if mode != crate::Mode::Direct {
                iroh::RelayMode::Default
            } else {
                iroh::RelayMode::Disabled
            });
        let endpoint = if mode == crate::Mode::RelayOnly {
            builder.clear_ip_transports()
        } else {
            builder
        }
        .bind()
        .await?;
        if mode != crate::Mode::Direct {
            tokio::time::timeout(std::time::Duration::from_secs(20), endpoint.online()).await?;
        }
        Ok((endpoint, lock))
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Address {
    pub version: u8,
    pub endpoint: iroh::EndpointAddr,
}

impl crate::Address {
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
            address.endpoint.id == expected,
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
                endpoint: endpoint.addr(),
            },
        )?;
        file.write_all(b"\n")?;
        file.as_file().sync_all()?;
        file.persist_noclobber(path)?;
        std::fs::File::open(parent)?.sync_all()?;
        Ok(())
    }
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
pub struct Path {
    pub kind: String,
    pub selected: bool,
}

pub fn paths(connection: &iroh::endpoint::Connection) -> Vec<crate::Path> {
    connection
        .paths()
        .iter()
        .map(|path| crate::Path {
            kind: match path.remote_addr() {
                iroh::TransportAddr::Ip(_) => "direct",
                iroh::TransportAddr::Relay(_) => "relay",
                _ => "other",
            }
            .to_owned(),
            selected: path.is_selected(),
        })
        .collect()
}

pub async fn serve_connection(
    identity: &crate::Identity,
    connection: iroh::endpoint::Connection,
) -> anyhow::Result<()> {
    use sha2::Digest as _;
    if !identity.is_paired(connection.remote_id()) {
        connection.close(1u32.into(), b"peer not paired");
        anyhow::bail!("peer not paired");
    }
    let (mut send, mut receive) = connection.accept_bi().await?;
    let bytes = receive.read_to_end(crate::MAX_BYTES).await?;
    anyhow::ensure!(
        bytes.len() == crate::MAX_BYTES,
        "invalid probe payload length"
    );
    send.write_all(&sha2::Sha256::digest(&bytes)).await?;
    send.finish()?;
    send.stopped().await?;
    Ok(())
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
pub struct Report {
    pub peer_id: String,
    pub bytes: usize,
    pub sha256: String,
    pub paths_before: Vec<crate::Path>,
    pub paths_after: Vec<crate::Path>,
    pub elapsed_ms: u128,
}

pub async fn probe(
    identity: &crate::Identity,
    endpoint: &iroh::Endpoint,
    address: crate::Address,
    require_direct: bool,
) -> anyhow::Result<crate::Report> {
    use sha2::Digest as _;
    anyhow::ensure!(
        identity.is_paired(address.endpoint.id),
        "peer not paired locally"
    );
    let connection = endpoint.connect(address.endpoint, crate::ALPN).await?;
    if require_direct {
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            while !crate::paths(&connection)
                .iter()
                .any(|path| path.selected && path.kind == "direct")
            {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        })
        .await?;
    }
    let before = crate::paths(&connection);
    let nonce = iroh::SecretKey::generate().to_bytes();
    let payload: Vec<u8> = nonce.into_iter().cycle().take(crate::MAX_BYTES).collect();
    let digest = sha2::Sha256::digest(&payload);
    let started = std::time::Instant::now();
    let (mut send, mut receive) = connection.open_bi().await?;
    send.write_all(&payload).await?;
    send.finish()?;
    let received = receive.read_to_end(32).await?;
    anyhow::ensure!(
        received.as_slice() == digest.as_slice(),
        "probe digest mismatch"
    );
    let report = crate::Report {
        peer_id: connection.remote_id().to_string(),
        bytes: payload.len(),
        sha256: hex::encode(digest),
        paths_before: before,
        paths_after: crate::paths(&connection),
        elapsed_ms: started.elapsed().as_millis(),
    };
    if require_direct {
        anyhow::ensure!(
            report
                .paths_after
                .iter()
                .any(|path| path.selected && path.kind == "direct"),
            "direct path was lost"
        );
    }
    connection.close(0u32.into(), b"probe complete");
    Ok(report)
}

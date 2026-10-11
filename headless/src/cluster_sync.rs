pub const ALPN: &[u8] = b"syncstr/cluster/3";

pub async fn run_lan(
    identity: std::sync::Arc<crate::peer::Identity>,
    endpoint: iroh::Endpoint,
    store: crate::store::Store,
    discovery: crate::cluster_discovery::Discovery,
) -> anyhow::Result<()> {
    store.local_cluster_grant(&identity).await?;
    let catalog = store.catalog().await?;
    let mut known: std::collections::HashSet<_> = store
        .cluster_changes()
        .await?
        .into_iter()
        .map(|state| state.object)
        .collect();
    for entry in catalog.entries {
        if known.insert(entry.sha256.clone()) {
            store
                .import_cluster_file(
                    &identity,
                    entry.clone(),
                    Some(catalog.organization.clone()),
                    &store.path(&entry),
                    false,
                )
                .await?;
        }
    }
    let mut peers = std::collections::BTreeMap::new();
    let relay = store.cluster_relay().await?.map(|url| crate::cluster_remote::validate_url(&url)).transpose()?;
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(3));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            found = discovery.next() => {
                let mut address = found?;
                if let Some(relay) = &relay { address = address.with_relay_url(relay.clone()); }
                if address.id != identity.id() && (peers.len() < 256 || peers.contains_key(&address.id)) { peers.insert(address.id, address); }
            }
            _ = interval.tick() => {
                let proof = store.cluster_membership_proof().await?;
                if let Some(relay) = &relay {
                    for grant in &proof.grants {
                        if grant.host && proof.verify(&grant.id).is_ok() {
                            let id: iroh::EndpointId = grant.member.parse()?;
                            if id != identity.id() { peers.entry(id).or_insert_with(|| iroh::EndpointAddr::new(id).with_relay_url(relay.clone())); }
                        }
                    }
                }
                for (peer, address) in &peers {
                    if !proof.grants.iter().any(|grant| grant.member == peer.to_string() && grant.host && proof.verify(&grant.id).is_ok()) { continue; }
                    let result = async {
                        let session = crate::cluster_sync::Session::connect(&endpoint, address.clone(), &store).await?;
                        session.reconcile(&store).await?;
                        store.reconcile_cluster_organization(&identity).await?;
                        for state in store.cluster_object_states().await? {
                            if state.conflicted() { continue; }
                            if let Err(error) = store.project_cluster_metadata(state.object.clone()).await {
                                eprintln!("Cluster metadata requires attention: {error}");
                                continue;
                            }
                            if store.cluster_selected_change(&state.object).await?.is_none() { continue; }
                            if !store.has_cluster_replica(&state.object).await?
                                && let Err(error) = session.download(&identity, &store, &state.object).await { eprintln!("Cluster replica unavailable: {error}"); }
                        }
                        anyhow::Ok(())
                    }.await;
                    if let Err(error) = result { eprintln!("Cluster reconciliation deferred: {error}"); }
                }
            }
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    capabilities: crate::cluster::Capabilities,
    proof: crate::enrollment::Proof,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "operation", rename_all = "kebab-case", deny_unknown_fields)]
enum Request {
    Evidence { object: String },
    Changes { after: i64 },
    Audio { object: String },
    Upload { entry: Box<crate::model::Entry>, organization: Box<crate::organization::Organization>, parents: Vec<String>, #[serde(default)] restore: bool },
    Resolve { object: String, selected: String, parents: Vec<String> },
    AlbumTitle { album: String, title: String, heads: std::collections::BTreeMap<String, String> },
    Metadata { entry: Box<crate::model::Entry>, organization: Box<crate::organization::Organization>, parents: Vec<String> },
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case", deny_unknown_fields)]
enum Response {
    Page {
        next: i64,
        change: Option<Box<crate::cluster_changes::Change>>,
        signing_payload: Option<String>,
    },
    Audio {
        entry: Box<crate::model::Entry>,
    },
    Unavailable,
    Stored { object: String },
    NeedsAttention { object: String },
    Resolved { object: String },
    Edited { object: String, revision: String },
}

async fn authorized(store: &crate::store::Store, member: &str, host: bool) -> anyhow::Result<()> {
    let proof = store.cluster_membership_proof().await?;
    anyhow::ensure!(
        proof.grants.iter().any(|grant| grant.member == member
            && (!host || grant.host)
            && proof.verify(&grant.id).is_ok()),
        "unauthorized cluster member"
    );
    Ok(())
}

async fn hello(store: &crate::store::Store) -> anyhow::Result<crate::cluster_sync::Hello> {
    Ok(crate::cluster_sync::Hello {
        capabilities: crate::cluster::Capabilities {
            version: 1,
            membership: true,
            deletions: true,
            conflicts: true,
        },
        proof: store.cluster_membership_proof().await?,
    })
}

pub(crate) async fn serve_connection(
    identity: &crate::peer::Identity,
    store: &crate::store::Store,
    connection: iroh::endpoint::Connection,
) -> anyhow::Result<()> {
    let peer = connection.remote_id().to_string();
    let (mut output, mut input) = connection.accept_bi().await?;
    let hello: crate::cluster_sync::Hello =
        crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
    anyhow::ensure!(
        hello.capabilities.allows_automatic_writer(),
        "cluster upgrade required"
    );
    store
        .authenticate_cluster_peer(peer.clone(), hello.proof)
        .await?;
    crate::cluster_sync::authorized(store, &identity.id().to_string(), true).await?;
    crate::cluster_net::send(&mut output, &crate::cluster_sync::hello(store).await?).await?;
    output.finish()?;
    while let Ok((mut output, mut input)) = connection.accept_bi().await {
        crate::cluster_sync::authorized(store, &peer, false).await?;
        crate::cluster_sync::authorized(store, &identity.id().to_string(), true).await?;
        let request: crate::cluster_sync::Request =
            crate::cluster_net::receive(&mut input, crate::cluster_changes::MAX_CHANGE).await?;
        match request {
            crate::cluster_sync::Request::Metadata { entry, organization, parents } => {
                let object = entry.sha256.clone();
                let response = match store.receive_cluster_metadata(identity, *entry, *organization, parents).await {
                    Ok(revision) => crate::cluster_sync::Response::Edited { object, revision },
                    Err(error) => {
                        eprintln!("Cluster metadata requires attention: {error:#}");
                        crate::cluster_sync::Response::NeedsAttention { object }
                    }
                };
                crate::cluster_net::send(&mut output, &response).await?;
            }
            crate::cluster_sync::Request::AlbumTitle { album, title, heads } => {
                store.resolve_cluster_album_title(identity, &album, &title, heads).await?;
                crate::cluster_net::send(&mut output, &crate::cluster_sync::Response::Resolved { object: album }).await?;
            }
            crate::cluster_sync::Request::Resolve { object, selected, parents } => {
                let records = store.cluster_active_changes().await?;
                let heads = crate::cluster_changes::object_heads(&records, &object);
                let mut choice = records.iter().find(|record| record.id == selected && record.object == object)
                    .ok_or_else(|| anyhow::anyhow!("unknown conflict choice"))?;
                for _ in 0..records.len() {
                    let crate::cluster_changes::Action::Resolve { selected } = &choice.action else { break; };
                    choice = records.iter().find(|record| record.id == *selected && record.object == object)
                        .ok_or_else(|| anyhow::anyhow!("unknown conflict history"))?;
                }
                if matches!(choice.action, crate::cluster_changes::Action::Delete) {
                    crate::cluster_sync::authorized(store, &peer, true).await?;
                }
                let repeated = heads.len() == 1 && matches!(&heads[0].action, crate::cluster_changes::Action::Resolve { selected: previous } if previous == &selected) && heads[0].parents == parents;
                if !repeated {
                    let current: std::collections::BTreeSet<_> = heads.iter().map(|record| &record.id).collect();
                    anyhow::ensure!(parents.len() <= 64 && current.len() == parents.len() && current == parents.iter().collect() && parents.contains(&selected), "conflict changed; refresh before resolving");
                    store.publish_observed_cluster_change(identity, object.clone(), crate::cluster_changes::Action::Resolve { selected }, parents).await?;
                }
                crate::cluster_net::send(&mut output, &crate::cluster_sync::Response::Resolved { object }).await?;
            }
            crate::cluster_sync::Request::Upload { entry, organization, parents, restore } => {
                use tokio::io::AsyncWriteExt as _;
                entry.validate()?;
                organization.validate()?;
                anyhow::ensure!(parents.len() <= 64, "too many import parents");
                let temporary = store.stage().await?;
                let mut file = tokio::fs::File::from_std(temporary.reopen()?);
                let mut remaining = entry.track.size;
                let mut buffer = [0; 65536];
                while remaining > 0 {
                    crate::cluster_sync::authorized(store, &peer, false).await?;
                    let size = remaining.min(buffer.len() as u64) as usize;
                    input.read_exact(&mut buffer[..size]).await?;
                    file.write_all(&buffer[..size]).await?;
                    remaining -= size as u64;
                }
                anyhow::ensure!(input.read_to_end(1).await?.is_empty(), "trailing upload bytes");
                file.sync_all().await?;
                drop(file);
                crate::cluster_sync::authorized(store, &peer, false).await?;
                let object = entry.sha256.clone();
                let response = match store.receive_cluster_import(identity, *entry, *organization, parents, restore, temporary).await {
                    Ok(()) => crate::cluster_sync::Response::Stored { object },
                    Err(error) => {
                        eprintln!("Cluster import requires attention: {error}");
                        crate::cluster_sync::Response::NeedsAttention { object }
                    }
                };
                crate::cluster_net::send(&mut output, &response).await?;
            }
            crate::cluster_sync::Request::Evidence { object } => {
                let recovered = store.recover_cluster_evidence(identity, &object).await?;
                crate::cluster_net::send(&mut output, &if recovered {
                    crate::cluster_sync::Response::Stored { object }
                } else { crate::cluster_sync::Response::Unavailable }).await?;
            }
            crate::cluster_sync::Request::Changes { after } => {
                store.reconcile_cluster_organization(identity).await?;
                let page = store.cluster_change_page(after).await?;
                let (next, change) = page.map_or((after, None), |(next, change)| {
                    (next, Some(Box::new(change)))
                });
                let signing_payload = change.as_ref().map(|change| Ok::<_, anyhow::Error>(String::from_utf8(change.signing_bytes()?)?)).transpose()?;
                crate::cluster_net::send(
                    &mut output,
                    &crate::cluster_sync::Response::Page { next, change, signing_payload },
                )
                .await?;
            }
            crate::cluster_sync::Request::Audio { object } => {
                anyhow::ensure!(object.len() == 64, "invalid audio identity");
                let file = store.cluster_local_file(&object).await;
                if let Ok(Some(entry)) = file {
                    use tokio::io::AsyncReadExt as _;
                    let mut file = tokio::fs::File::open(store.path(&entry)).await?;
                    crate::cluster_net::send(
                        &mut output,
                        &crate::cluster_sync::Response::Audio {
                            entry: Box::new(entry.clone()),
                        },
                    )
                    .await?;
                    let mut buffer = [0; 65536];
                    let mut remaining = entry.track.size;
                    while remaining > 0 {
                        let limit = remaining.min(buffer.len() as u64) as usize;
                        let size = file.read(&mut buffer[..limit]).await?;
                        anyhow::ensure!(size > 0, "stored audio truncated");
                        crate::cluster_sync::authorized(store, &peer, false).await?;
                        output.write_all(&buffer[..size]).await?;
                        remaining -= size as u64;
                    }
                } else {
                    crate::cluster_net::send(
                        &mut output,
                        &crate::cluster_sync::Response::Unavailable,
                    )
                    .await?;
                }
            }
        }
        output.finish()?;
        output.stopped().await?;
    }
    Ok(())
}

pub struct Session {
    connection: iroh::endpoint::Connection,
}

impl Drop for crate::cluster_sync::Session {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"done");
    }
}

impl crate::cluster_sync::Session {
    pub fn selected_path(&self) -> Option<&'static str> {
        self.connection.paths().iter().find(|path| path.is_selected()).and_then(|path| match path.remote_addr() {
            iroh::TransportAddr::Ip(_) => Some("direct"),
            iroh::TransportAddr::Relay(_) => Some("relay"),
            _ => None,
        })
    }
    pub async fn connect(
        endpoint: &iroh::Endpoint,
        address: iroh::EndpointAddr,
        store: &crate::store::Store,
    ) -> anyhow::Result<Self> {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let session = Self {
                connection: endpoint.connect(address, crate::cluster_sync::ALPN).await?,
            };
            let (mut output, mut input) = session.connection.open_bi().await?;
            crate::cluster_net::send(&mut output, &crate::cluster_sync::hello(store).await?)
                .await?;
            output.finish()?;
            let hello: crate::cluster_sync::Hello =
                crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
            anyhow::ensure!(
                hello.capabilities.allows_automatic_writer(),
                "cluster upgrade required"
            );
            store
                .authenticate_cluster_peer(session.connection.remote_id().to_string(), hello.proof)
                .await?;
            crate::cluster_sync::authorized(
                store,
                &session.connection.remote_id().to_string(),
                true,
            )
            .await?;
            Ok(session)
        })
        .await?
    }

    pub async fn reconcile(&self, store: &crate::store::Store) -> anyhow::Result<()> {
        let peer = self.connection.remote_id().to_string();
        let peer_query = peer.clone();
        let mut after = store
            .run(move |connection, _| {
                use rusqlite::OptionalExtension as _;
                Ok(connection
                    .query_row(
                        "SELECT sequence FROM cluster_cursors WHERE peer = ?",
                        [peer_query],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?
                    .unwrap_or(0))
            })
            .await?;
        // A reconnect resumes from durable pages; a pending record is not a library change.
        for _ in 0..1024 {
            let (mut output, mut input) = self.connection.open_bi().await?;
            crate::cluster_net::send(
                &mut output,
                &crate::cluster_sync::Request::Changes { after },
            )
            .await?;
            output.finish()?;
            let response: crate::cluster_sync::Response =
                crate::cluster_net::receive(&mut input, crate::cluster_net::MAX_FRAME).await?;
            let crate::cluster_sync::Response::Page { next, change, signing_payload } = response else {
                anyhow::bail!("invalid change response");
            };
            let Some(change) = change else {
                break;
            };
            anyhow::ensure!(signing_payload.as_deref().map(str::as_bytes) == Some(change.signing_bytes()?.as_slice()), "signed payload mismatch");
            anyhow::ensure!(next > after, "non-progressing history cursor");
            store
                .receive_cluster_changes(peer.clone(), vec![*change])
                .await?;
            let peer_update = peer.clone();
            store.run(move |connection, _| {
                connection.execute("INSERT INTO cluster_cursors VALUES (?, ?) ON CONFLICT(peer) DO UPDATE SET sequence = excluded.sequence", rusqlite::params![peer_update, next])?;
                Ok(())
            }).await?;
            after = next;
        }
        store.receive_cluster_changes(peer, Vec::new()).await?;
        Ok(())
    }

    pub async fn recover_evidence(&self, object: String) -> anyhow::Result<bool> {
        let (mut output, mut input) = self.connection.open_bi().await?;
        crate::cluster_net::send(&mut output, &crate::cluster_sync::Request::Evidence { object: object.clone() }).await?;
        output.finish()?;
        match crate::cluster_net::receive::<crate::cluster_sync::Response>(&mut input, crate::model::MAX_METADATA).await? {
            crate::cluster_sync::Response::Stored { object: received } if received == object => Ok(true),
            crate::cluster_sync::Response::Unavailable => Ok(false),
            _ => anyhow::bail!("invalid evidence response"),
        }
    }

    pub async fn download(
        &self,
        identity: &crate::peer::Identity,
        store: &crate::store::Store,
        object: &str,
    ) -> anyhow::Result<()> {
        let change = store
            .cluster_selected_change(object)
            .await?
            .ok_or_else(|| anyhow::anyhow!("object unavailable or deleted"))?;
        let entry = match &change.action {
            crate::cluster_changes::Action::Import { entry, .. }
            | crate::cluster_changes::Action::Restore { entry, .. }
            | crate::cluster_changes::Action::Edit { entry, .. } => entry.as_ref().clone(),
            _ => anyhow::bail!("no selected audio"),
        };
        let job = store
            .prepare_cluster_download(
                self.connection.remote_id().to_string(),
                identity.id().to_string(),
                entry.clone(),
            )
            .await?;
        let result = tokio::time::timeout(std::time::Duration::from_secs(240), async {
            use tokio::io::AsyncWriteExt as _;
            let (mut output, mut input) = self.connection.open_bi().await?;
            crate::cluster_net::send(
                &mut output,
                &crate::cluster_sync::Request::Audio {
                    object: object.to_owned(),
                },
            )
            .await?;
            output.finish()?;
            let response: crate::cluster_sync::Response =
                crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
            let crate::cluster_sync::Response::Audio { entry: remote } = response else {
                anyhow::bail!("source has no verified replica");
            };
            anyhow::ensure!(
                remote.sha256 == entry.sha256 && remote.track.size == entry.track.size,
                "unexpected replica identity"
            );
            let temporary = store.stage().await?;
            let mut file = tokio::fs::File::from_std(temporary.reopen()?);
            let mut remaining = entry.track.size;
            // Android JNI threads have a smaller stack than desktop worker threads.
            let mut buffer = vec![0; 65536];
            while remaining > 0 {
                let limit = remaining.min(buffer.len() as u64) as usize;
                let size = input
                    .read(&mut buffer[..limit])
                    .await?
                    .ok_or_else(|| anyhow::anyhow!("incomplete replica"))?;
                anyhow::ensure!(size > 0, "incomplete replica");
                file.write_all(&buffer[..size]).await?;
                remaining -= size as u64;
            }
            anyhow::ensure!(
                input.read(&mut buffer[..1]).await?.is_none(),
                "oversized replica"
            );
            file.flush().await?;
            file.sync_all().await?;
            drop(file);
            crate::cluster_sync::authorized(store, &self.connection.remote_id().to_string(), true)
                .await?;
            store
                .commit_cluster_replica(identity, change, temporary, Some(job.clone()))
                .await
        })
        .await;
        let result = match result {
            Ok(result) => result,
            Err(error) => Err(error.into()),
        };
        if result.is_err() {
            store.retry_cluster_download(job).await?;
        }
        result
    }
}

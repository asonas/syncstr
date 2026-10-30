pub const ALPN: &[u8] = b"syncstr/cluster/5";

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Hello {
    pub version: u8,
    pub proof: crate::enrollment::Proof,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "operation", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Request {
    Catalog,
    Records {
        after: i64,
    },
    PlaylistRecords {
        after: i64,
    },
    Receive {
        records: Vec<crate::shared_audio::Signed>,
    },
    Audio {
        track: String,
        hash: String,
    },
}

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Snapshot {
    pub catalog: crate::shared_audio::Catalog,
    pub playlists: Vec<crate::playlists::Snapshot>,
    pub playlist_history: Vec<crate::playlists::Signed>,
}

pub fn authorize(proof: &crate::enrollment::Proof, member: &str, host: bool) -> anyhow::Result<()> {
    anyhow::ensure!(
        proof
            .grants
            .iter()
            .any(|g| g.member == member && (!host || g.host) && proof.verify(&g.id).is_ok()),
        "unauthorized v5 member"
    );
    Ok(())
}

impl crate::shared_audio::Store {
    pub fn revoke_member(
        &self,
        signer: &crate::peer::Identity,
        member: &str,
    ) -> anyhow::Result<crate::enrollment::Revocation> {
        use sha2::Digest as _;
        let mut proof = self.membership()?;
        let authority = proof
            .grants
            .iter()
            .find(|g| g.member == signer.id().to_string() && g.host && proof.verify(&g.id).is_ok())
            .ok_or_else(|| anyhow::anyhow!("unauthorized host"))?;
        anyhow::ensure!(
            proof.grants.iter().any(|g| g.member == member),
            "unknown member"
        );
        let mut observed: Vec<_> = proof
            .grants
            .iter()
            .filter(|g| g.issuer == member)
            .map(|g| g.id.clone())
            .chain(
                proof
                    .revocations
                    .iter()
                    .filter(|r| r.issuer == member)
                    .map(|r| r.id.clone()),
            )
            .collect();
        observed.sort();
        let mut record = crate::enrollment::Revocation {
            version: 1,
            id: String::new(),
            cluster: authority.cluster.clone(),
            issuer: signer.id().to_string(),
            member: member.into(),
            authority: authority.id.clone(),
            observed,
            change_heads: vec![],
            signature: String::new(),
        };
        record.id = hex::encode(sha2::Sha256::digest(record.signing_bytes()?));
        record.signature = hex::encode(signer.sign(&record.signing_bytes()?));
        proof.revocations.push(record.clone());
        self.merge_membership(proof)?;
        Ok(record)
    }
    pub fn membership(&self) -> anyhow::Result<crate::enrollment::Proof> {
        self.run(|connection, _| crate::enrollment::read_proof(connection))
    }

    pub fn merge_membership(&self, incoming: crate::enrollment::Proof) -> anyhow::Result<()> {
        self.run(|connection, _| {
            let transaction = connection.transaction()?;
            let mut combined = crate::enrollment::read_proof(&transaction)?;
            anyhow::ensure!(combined.root == incoming.root, "cluster root mismatch");
            let cluster: String = transaction.query_row(
                "SELECT id FROM cluster_identity WHERE singleton=1",
                [],
                |r| r.get(0),
            )?;
            for grant in incoming.grants {
                anyhow::ensure!(grant.cluster == cluster, "cross-cluster grant");
                if let Some(previous) = combined.grants.iter().find(|g| g.id == grant.id) {
                    anyhow::ensure!(previous == &grant, "inconsistent grant replay");
                } else {
                    transaction.execute(
                        "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
                        rusqlite::params![grant.id, serde_json::to_vec(&grant)?],
                    )?;
                    combined.grants.push(grant);
                }
            }
            for revocation in incoming.revocations {
                anyhow::ensure!(revocation.cluster == cluster, "cross-cluster revocation");
                if let Some(previous) = combined.revocations.iter().find(|r| r.id == revocation.id)
                {
                    anyhow::ensure!(previous == &revocation, "inconsistent revocation replay");
                } else {
                    transaction.execute(
                        "INSERT INTO cluster_revocations VALUES (?, ?)",
                        rusqlite::params![revocation.id, serde_json::to_vec(&revocation)?],
                    )?;
                    combined.revocations.push(revocation);
                }
            }
            for grant in &combined.grants {
                combined.chain(&grant.id)?;
            }
            combined.revocation_state()?;
            transaction.commit()?;
            Ok(())
        })
    }
}

pub async fn serve(
    endpoint: iroh::Endpoint,
    store: crate::shared_audio::Store,
    own: String,
) -> anyhow::Result<()> {
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break; };
                if connections.len() >= 64 { incoming.refuse(); continue; }
                let store = store.clone(); let own = own.clone();
                connections.spawn(async move {
                    let connection = incoming.await?;
                    anyhow::ensure!(connection.alpn() == crate::shared_audio_net::ALPN, "v5 upgrade required");
                    tokio::time::timeout(std::time::Duration::from_secs(7200), crate::shared_audio_net::serve_connection(connection, store, own)).await?
                });
            }
            result = connections.join_next(), if !connections.is_empty() => {
                if let Some(Ok(Err(error))) = result { eprintln!("Shared connection ended: {error}"); }
            }
        }
    }
    Ok(())
}

async fn serve_connection(
    connection: iroh::endpoint::Connection,
    store: crate::shared_audio::Store,
    own: String,
) -> anyhow::Result<()> {
    let peer = connection.remote_id().to_string();
    let (mut output, mut input) = connection.accept_bi().await?;
    let hello: crate::shared_audio_net::Hello =
        crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
    anyhow::ensure!(hello.version == 5, "v5 capability required");
    let check = store.clone();
    let presenter = peer.clone();
    let own_check = own.clone();
    let proof = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
        check.merge_membership(hello.proof)?;
        let proof = check.membership()?;
        crate::shared_audio_net::authorize(&proof, &presenter, false)?;
        crate::shared_audio_net::authorize(&proof, &own_check, true)?;
        Ok(proof)
    })
    .await??;
    crate::cluster_net::send(
        &mut output,
        &crate::shared_audio_net::Hello { version: 5, proof },
    )
    .await?;
    output.finish()?;
    while let Ok((mut output, mut input)) = connection.accept_bi().await {
        let request: crate::shared_audio_net::Request =
            crate::cluster_net::receive(&mut input, 64 * 1024 * 1024).await?;
        let proof = store.membership()?;
        crate::shared_audio_net::authorize(&proof, &peer, false)?;
        crate::shared_audio_net::authorize(&proof, &own, true)?;
        match request {
            crate::shared_audio_net::Request::Catalog => {
                let store = store.clone();
                let snapshot = tokio::task::spawn_blocking(move || store.snapshot()).await??;
                crate::cluster_net::send(&mut output, &snapshot).await?;
            }
            crate::shared_audio_net::Request::Records { after } => {
                crate::cluster_net::send(&mut output, &store.page(after)?).await?
            }
            crate::shared_audio_net::Request::PlaylistRecords { after } => {
                crate::cluster_net::send(&mut output, &store.playlist_page(after)?).await?
            }
            crate::shared_audio_net::Request::Receive { records } => {
                crate::shared_audio_net::authorize(&proof, &peer, true)?;
                store.receive(records)?;
                crate::cluster_net::send(&mut output, &true).await?;
            }
            crate::shared_audio_net::Request::Audio { track, hash } => {
                let selected = store.clone();
                let file =
                    tokio::task::spawn_blocking(move || selected.audio(&track, &hash)).await??;
                let size = file.metadata()?.len();
                crate::cluster_net::send(&mut output, &size).await?;
                let mut file = tokio::fs::File::from_std(file);
                use tokio::io::AsyncReadExt as _;
                let mut buffer = vec![0; 65536];
                loop {
                    let count = file.read(&mut buffer).await?;
                    if count == 0 {
                        break;
                    }
                    let proof = store.membership()?;
                    crate::shared_audio_net::authorize(&proof, &peer, false)?;
                    crate::shared_audio_net::authorize(&proof, &own, true)?;
                    output.write_all(&buffer[..count]).await?;
                }
            }
        }
        output.finish()?;
    }
    Ok(())
}

pub struct Session {
    connection: iroh::endpoint::Connection,
    pub proof: crate::enrollment::Proof,
}

impl crate::shared_audio_net::Session {
    pub async fn reconcile(
        &self,
        store: &crate::shared_audio::Store,
        peer: &str,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            peer == self.connection.remote_id().to_string(),
            "cursor peer mismatch"
        );
        store.merge_membership(self.proof.clone())?;
        let remote: crate::shared_audio_net::Snapshot = self
            .request(crate::shared_audio_net::Request::Catalog)
            .await?;
        let local = store.catalog()?;
        anyhow::ensure!(
            local.cluster == remote.catalog.cluster && local.baseline == remote.catalog.baseline,
            "activation baseline mismatch"
        );
        loop {
            let after = store.cursor(peer)?;
            let page: Vec<(i64, crate::shared_audio::Signed)> = self
                .request(crate::shared_audio_net::Request::Records { after })
                .await?;
            if page.is_empty() {
                break;
            }
            store.receive_page(peer, after, page)?;
        }
        let playlist_peer = format!("{peer}/playlists");
        loop {
            let after = store.cursor(&playlist_peer)?;
            let page: Vec<(i64, crate::playlists::Signed)> = self
                .request(crate::shared_audio_net::Request::PlaylistRecords { after })
                .await?;
            if page.is_empty() {
                break;
            }
            store.receive_playlist_page(&playlist_peer, after, page)?;
        }
        let catalog = store.catalog()?;
        for (track, hashes) in &catalog.pins {
            for hash in hashes {
                if store.audio(track, hash).is_ok() {
                    continue;
                }
                let temporary = store.stage()?.into_temp_path();
                match self.download(track, hash, &temporary).await {
                    Ok(()) => store.put_audio(hash, &mut std::fs::File::open(&temporary)?)?,
                    Err(error) => eprintln!("Shared replica unavailable: {error}"),
                }
            }
        }
        Ok(())
    }

    pub async fn connect(
        endpoint: &iroh::Endpoint,
        address: iroh::EndpointAddr,
        proof: crate::enrollment::Proof,
    ) -> anyhow::Result<Self> {
        let peer = address.id.to_string();
        let connection = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            endpoint.connect(address, crate::shared_audio_net::ALPN),
        )
        .await??;
        let (mut output, mut input) = connection.open_bi().await?;
        crate::cluster_net::send(
            &mut output,
            &crate::shared_audio_net::Hello {
                version: 5,
                proof: proof.clone(),
            },
        )
        .await?;
        output.finish()?;
        let hello: crate::shared_audio_net::Hello = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            crate::cluster_net::receive(&mut input, 4 * 1024 * 1024),
        )
        .await??;
        anyhow::ensure!(
            hello.version == 5 && hello.proof.root == proof.root,
            "v5 trust mismatch"
        );
        let clusters: std::collections::BTreeSet<_> =
            proof.grants.iter().map(|g| &g.cluster).collect();
        anyhow::ensure!(
            clusters.len() == 1
                && hello
                    .proof
                    .grants
                    .iter()
                    .all(|g| clusters.contains(&g.cluster)),
            "cross-cluster handshake"
        );
        let mut combined = hello.proof;
        for grant in proof.grants {
            if let Some(existing) = combined.grants.iter().find(|g| g.id == grant.id) {
                anyhow::ensure!(existing == &grant, "inconsistent grant replay");
            } else {
                combined.grants.push(grant);
            }
        }
        for revocation in proof.revocations {
            if let Some(existing) = combined.revocations.iter().find(|r| r.id == revocation.id) {
                anyhow::ensure!(existing == &revocation, "inconsistent revocation replay");
            } else {
                combined.revocations.push(revocation);
            }
        }
        for grant in &combined.grants {
            combined.chain(&grant.id)?;
        }
        combined.revocation_state()?;
        crate::shared_audio_net::authorize(&combined, &peer, true)?;
        crate::shared_audio_net::authorize(&combined, &endpoint.id().to_string(), false)?;
        Ok(Self {
            connection,
            proof: combined,
        })
    }

    pub async fn request<T: serde::de::DeserializeOwned>(
        &self,
        request: crate::shared_audio_net::Request,
    ) -> anyhow::Result<T> {
        let (mut output, mut input) = self.connection.open_bi().await?;
        crate::cluster_net::send(&mut output, &request).await?;
        output.finish()?;
        tokio::time::timeout(
            std::time::Duration::from_secs(120),
            crate::cluster_net::receive(&mut input, 64 * 1024 * 1024),
        )
        .await?
    }

    pub async fn download(
        &self,
        track: &str,
        hash: &str,
        destination: &std::path::Path,
    ) -> anyhow::Result<()> {
        use sha2::Digest as _;
        use tokio::io::AsyncWriteExt as _;
        let (mut output, mut input) = self.connection.open_bi().await?;
        crate::cluster_net::send(
            &mut output,
            &crate::shared_audio_net::Request::Audio {
                track: track.into(),
                hash: hash.into(),
            },
        )
        .await?;
        output.finish()?;
        let expected: u64 = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            crate::cluster_net::receive(&mut input, 128),
        )
        .await??;
        anyhow::ensure!(
            expected > 0 && expected <= crate::model::MAX_AUDIO,
            "invalid audio size"
        );
        let parent = destination
            .parent()
            .ok_or_else(|| anyhow::anyhow!("missing audio directory"))?;
        let staged = tempfile::NamedTempFile::new_in(parent)?;
        let mut file = tokio::fs::File::from_std(staged.reopen()?);
        let mut digest = sha2::Sha256::new();
        let mut received = 0u64;
        let mut buffer = vec![0; 65536];
        while let Some(count) =
            tokio::time::timeout(std::time::Duration::from_secs(30), input.read(&mut buffer))
                .await??
        {
            received += count as u64;
            anyhow::ensure!(received <= expected, "audio too large");
            digest.update(&buffer[..count]);
            file.write_all(&buffer[..count]).await?;
        }
        anyhow::ensure!(
            received == expected && hex::encode(digest.finalize()) == hash,
            "audio integrity failure"
        );
        file.sync_all().await?;
        drop(file);
        crate::platform_fs::persist_replace(staged, destination)?;
        crate::platform_fs::sync_directory(parent)?;
        Ok(())
    }
}

pub async fn synchronize(
    endpoint: iroh::Endpoint,
    store: crate::shared_audio::Store,
    mut discovered: tokio::sync::mpsc::Receiver<iroh::EndpointAddr>,
) -> anyhow::Result<()> {
    let mut peers = std::collections::BTreeMap::new();
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(3));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            found = discovered.recv() => {
                let Some(address) = found else { anyhow::bail!("discovery stopped"); };
                if address.id != endpoint.id() && (peers.len() < 256 || peers.contains_key(&address.id)) { peers.insert(address.id, address); }
            }
            _ = interval.tick() => {
                let proof = store.membership()?;
                for (peer, address) in &peers {
                    if crate::shared_audio_net::authorize(&proof, &peer.to_string(), true).is_err() { continue; }
                    let result = tokio::time::timeout(std::time::Duration::from_secs(120), async {
                        let session = crate::shared_audio_net::Session::connect(&endpoint, address.clone(), proof.clone()).await?;
                        session.reconcile(&store, &peer.to_string()).await
                    }).await;
                    match result {
                        Ok(Ok(())) => {},
                        Ok(Err(error)) => eprintln!("Shared synchronization deferred: {error}"),
                        Err(_) => eprintln!("Shared synchronization timed out"),
                    }
                }
            }
        }
    }
}

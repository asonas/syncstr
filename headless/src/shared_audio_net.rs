pub const ALPN: &[u8] = b"syncstr/cluster/5";

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Hello {
    pub version: u8,
    pub proof: crate::enrollment::Proof,
    #[serde(default)]
    pub supported_operations: Vec<String>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case", deny_unknown_fields)]
pub enum HelloRefusal {
    Rejected {
        version: u8,
        reason: crate::shared_audio_net::MutationRejection,
        member: String,
        evidence: crate::enrollment::Proof,
    },
}

impl std::fmt::Display for crate::shared_audio_net::HelloRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("revoked v5 member")
    }
}

impl std::error::Error for crate::shared_audio_net::HelloRefusal {}

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
    Mutation {
        mutation: crate::shared_audio_net::MutationRequest,
    },
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MutationRequest {
    pub request: String,
    pub cluster: String,
    pub baseline: String,
    pub operation: String,
    pub expected: std::collections::BTreeMap<String, Vec<String>>,
    pub payload: serde_json::Value,
    pub confirmed: Vec<serde_json::Value>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditTrack {
    pub track: String,
    pub metadata: std::collections::BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AlbumVisibility {
    pub album: String,
    pub hidden: bool,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolveTrack {
    pub track: String,
    pub select: String,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdatePlaylists {
    pub documents: Vec<crate::playlists::Document>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PutObject {
    pub hash: String,
    pub bytes: u64,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegisterTrack {
    pub source: crate::shared_audio::Source,
    pub metadata: std::collections::BTreeMap<String, serde_json::Value>,
    pub hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MutationRejection {
    Invalid,
    Unauthorized,
    Revoked,
    ClusterMismatch,
    BaselineMismatch,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case", deny_unknown_fields)]
pub enum MutationReply {
    ObjectStored {
        request: String,
        hash: String,
        bytes: u64,
        host: String,
    },
    Accepted {
        request: String,
        record: String,
        host: String,
        heads: std::collections::BTreeMap<String, Vec<String>>,
    },
    NeedsReview {
        request: String,
        current: std::collections::BTreeMap<String, Vec<String>>,
    },
    Rejected {
        request: String,
        reason: crate::shared_audio_net::MutationRejection,
    },
    Deferred {
        request: String,
        reason: String,
    },
    Unsupported {
        request: String,
        operation: String,
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

fn revoked_hello(
    combined: &crate::enrollment::Proof,
    known_grants: usize,
    known_revocations: usize,
    peer: &str,
    own: &str,
) -> anyhow::Result<Option<crate::shared_audio_net::HelloRefusal>> {
    if !combined.grants.iter().any(|g| g.member == peer) {
        return Ok(None);
    }
    let mut evidence = crate::enrollment::Proof {
        root: combined.root.clone(),
        grants: combined.grants[..known_grants].to_vec(),
        revocations: combined.revocations[..known_revocations].to_vec(),
    };
    crate::shared_audio_net::authorize(&evidence, own, true)?;
    // Only the peer's verified grant chains may supplement the retained evidence.
    for grant in combined.grants.iter().filter(|g| g.member == peer) {
        for record in combined.chain(&grant.id)? {
            if !evidence.grants.iter().any(|g| g.id == record.id) {
                evidence.grants.push(record.clone());
            }
        }
    }
    let (active, disputed) = evidence.revocation_state()?;
    if disputed.contains(peer) {
        return Ok(None);
    }
    for grant in evidence.grants.iter().filter(|g| g.member == peer) {
        let chain = evidence.chain(&grant.id)?;
        if chain.iter().any(|g| disputed.contains(&g.issuer)) {
            return Ok(None);
        }
        let revoked = active.iter().any(|index| {
            let revocation = &evidence.revocations[*index];
            revocation.member == peer
                || chain
                    .iter()
                    .any(|g| g.issuer == revocation.member && !revocation.observed.contains(&g.id))
        });
        if !revoked {
            return Ok(None);
        }
    }
    Ok(Some(crate::shared_audio_net::HelloRefusal::Rejected {
        version: 5,
        reason: crate::shared_audio_net::MutationRejection::Revoked,
        member: peer.into(),
        evidence,
    }))
}

impl crate::shared_audio::Store {
    fn prepare_mutation(
        &self,
        peer: &str,
        signer: &crate::peer::Identity,
        request: String,
        incoming: &[u8],
    ) -> Result<
        (
            crate::shared_audio_net::MutationRequest,
            crate::enrollment::Proof,
        ),
        crate::shared_audio_net::MutationReply,
    > {
        use crate::shared_audio_net::{MutationRejection, MutationReply, Request};
        let proof = match self.membership() {
            Ok(proof) => proof,
            Err(_) => {
                return Err(MutationReply::Deferred {
                    request,
                    reason: "store-unavailable".into(),
                });
            }
        };
        if crate::shared_audio_net::authorize(&proof, peer, false).is_err() {
            return Err(MutationReply::Rejected {
                request,
                reason: if proof.grants.iter().any(|g| g.member == peer) {
                    MutationRejection::Revoked
                } else {
                    MutationRejection::Unauthorized
                },
            });
        }
        if crate::shared_audio_net::authorize(&proof, &signer.id().to_string(), true).is_err() {
            return Err(MutationReply::Rejected {
                request,
                reason: MutationRejection::Unauthorized,
            });
        }
        let Ok(Request::Mutation { mutation }) = serde_json::from_slice(incoming) else {
            return Err(MutationReply::Rejected {
                request,
                reason: MutationRejection::Invalid,
            });
        };
        // Read the activation identity without projecting possibly incomplete history.
        let identity = self.run(|connection, _| {
            Ok(connection.query_row(
                "SELECT id, fingerprint FROM cluster_identity CROSS JOIN shared_baseline WHERE cluster_identity.singleton=1 AND shared_baseline.singleton=1",
                [],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )?)
        });
        match identity {
            Err(_) => Err(MutationReply::Deferred {
                request,
                reason: "store-unavailable".into(),
            }),
            Ok((cluster, _)) if mutation.cluster != cluster => Err(MutationReply::Rejected {
                request,
                reason: MutationRejection::ClusterMismatch,
            }),
            Ok((_, baseline)) if mutation.baseline != baseline => Err(MutationReply::Rejected {
                request,
                reason: MutationRejection::BaselineMismatch,
            }),
            Ok(_) => Ok((mutation, proof)),
        }
    }

    fn mutation_reply(
        &self,
        peer: &str,
        signer: &crate::peer::Identity,
        mutation: crate::shared_audio_net::MutationRequest,
        proof: &crate::enrollment::Proof,
    ) -> crate::shared_audio_net::MutationReply {
        use crate::shared_audio_net::MutationReply;
        match mutation.operation.as_str() {
            "set-album-visibility" | "resolve-album-visibility" => {
                self.album_visibility_member(signer, peer, mutation, proof)
            }
            "edit-track" => self.edit_track_member(signer, peer, mutation, proof),
            "resolve-track" => self.resolve_track_member(signer, peer, mutation, proof),
            "update-playlists" => self.update_playlists_member(signer, peer, mutation, proof),
            "register-track" => self.register_track_member(signer, peer, mutation, proof),
            "assign-source" => self.assign_source_member(signer, peer, mutation, proof),
            _ => MutationReply::Unsupported {
                request: mutation.request,
                operation: mutation.operation,
            },
        }
    }

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
        self.merge_membership_from(incoming, None).map(|_| ())
    }

    fn merge_membership_from(
        &self,
        incoming: crate::enrollment::Proof,
        presenter: Option<(&str, &str)>,
    ) -> anyhow::Result<crate::enrollment::Proof> {
        self.run(|connection, _| {
            let transaction = connection.transaction()?;
            let mut combined = crate::enrollment::read_proof(&transaction)?;
            let known_grants = combined.grants.len();
            let known_revocations = combined.revocations.len();
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
                    combined.grants.push(grant);
                }
            }
            let refusal = if let Some((peer, own)) = presenter {
                // New members may present an unknown grant chain, but cannot replace retained revocations.
                match crate::shared_audio_net::authorize(&combined, peer, false) {
                    Ok(()) => None,
                    Err(error) => {
                        let refusal = crate::shared_audio_net::revoked_hello(
                            &combined,
                            known_grants,
                            known_revocations,
                            peer,
                            own,
                        )?;
                        if refusal.is_none() {
                            return Err(error);
                        }
                        refusal
                    }
                }
            } else {
                None
            };
            for revocation in incoming.revocations {
                anyhow::ensure!(revocation.cluster == cluster, "cross-cluster revocation");
                if let Some(previous) = combined.revocations.iter().find(|r| r.id == revocation.id)
                {
                    anyhow::ensure!(previous == &revocation, "inconsistent revocation replay");
                } else {
                    combined.revocations.push(revocation);
                }
            }
            for grant in &combined.grants {
                combined.chain(&grant.id)?;
            }
            combined.revocation_state()?;
            if let Some(refusal) = refusal {
                return Err(refusal.into());
            }
            if let Some((peer, own)) = presenter {
                crate::shared_audio_net::authorize(&combined, peer, false)?;
                crate::shared_audio_net::authorize(&combined, own, true)?;
            }
            for grant in &combined.grants[known_grants..] {
                transaction.execute(
                    "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
                    rusqlite::params![grant.id, serde_json::to_vec(grant)?],
                )?;
            }
            for revocation in &combined.revocations[known_revocations..] {
                transaction.execute(
                    "INSERT INTO cluster_revocations VALUES (?, ?)",
                    rusqlite::params![revocation.id, serde_json::to_vec(revocation)?],
                )?;
            }
            transaction.commit()?;
            Ok(combined)
        })
    }
}

pub async fn serve(
    endpoint: iroh::Endpoint,
    store: crate::shared_audio::Store,
    signer: std::sync::Arc<crate::peer::Identity>,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        endpoint.id() == signer.id(),
        "host signer identity mismatch"
    );
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break; };
                if connections.len() >= 64 { incoming.refuse(); continue; }
                let store = store.clone(); let signer = signer.clone();
                connections.spawn(async move {
                    let connection = incoming.await?;
                    anyhow::ensure!(connection.alpn() == crate::shared_audio_net::ALPN, "v5 upgrade required");
                    tokio::time::timeout(std::time::Duration::from_secs(7200), crate::shared_audio_net::serve_connection(connection, store, signer)).await?
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
    signer: std::sync::Arc<crate::peer::Identity>,
) -> anyhow::Result<()> {
    let own = signer.id().to_string();
    let peer = connection.remote_id().to_string();
    let (mut output, mut input) = connection.accept_bi().await?;
    let hello: crate::shared_audio_net::Hello =
        crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
    anyhow::ensure!(hello.version == 5, "v5 capability required");
    let check = store.clone();
    let presenter = peer.clone();
    let own_check = own.clone();
    let proof = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
        check.merge_membership_from(hello.proof, Some((&presenter, &own_check)))
    })
    .await?;
    let proof = match proof {
        Ok(proof) => proof,
        Err(error) => {
            if let Some(refusal) = error.downcast_ref::<crate::shared_audio_net::HelloRefusal>() {
                let payload = serde_json::to_vec(refusal)?;
                // Oversized evidence is an ordinary connection failure, never a trusted revocation reply.
                anyhow::ensure!(payload.len() <= 4 * 1024 * 1024, "Hello refusal too large");
                let _ = tokio::time::timeout(std::time::Duration::from_secs(5), async {
                    output
                        .write_all(&(payload.len() as u32).to_be_bytes())
                        .await?;
                    output.write_all(&payload).await?;
                    output.finish()?;
                    output.stopped().await?;
                    anyhow::Ok(())
                })
                .await;
                connection.close(0u32.into(), b"revoked v5 member");
                return Ok(());
            }
            return Err(error);
        }
    };
    crate::cluster_net::send(
        &mut output,
        &crate::shared_audio_net::Hello {
            version: 5,
            proof,
            supported_operations: vec![
                "set-album-visibility".into(),
                "resolve-album-visibility".into(),
                "edit-track".into(),
                "resolve-track".into(),
                "update-playlists".into(),
                "put-object".into(),
                "register-track".into(),
                "assign-source".into(),
            ],
        },
    )
    .await?;
    output.finish()?;
    while let Ok((mut output, mut input)) = connection.accept_bi().await {
        // Keep the original JSON so strict decoding still rejects duplicate request fields.
        let mut size = [0; 4];
        input.read_exact(&mut size).await?;
        let size = u32::from_be_bytes(size) as usize;
        anyhow::ensure!(
            size > 0 && size <= crate::cluster_net::MAX_FRAME,
            "invalid cluster frame length"
        );
        let mut payload = vec![0; size];
        input.read_exact(&mut payload).await?;
        let incoming: serde_json::Value = serde_json::from_slice(&payload)?;
        if incoming.get("operation").and_then(|v| v.as_str()) == Some("mutation") {
            let request = incoming
                .get("mutation")
                .and_then(|m| m.get("request"))
                .and_then(|r| r.as_str())
                .unwrap_or_default()
                .to_owned();
            let check = store.clone();
            let presenter = peer.clone();
            let signing = signer.clone();
            let prepared = tokio::task::spawn_blocking(move || {
                check.prepare_mutation(&presenter, &signing, request, &payload)
            })
            .await?;
            let reply = match prepared {
                Err(reply) => reply,
                Ok((mutation, _)) if mutation.operation == "put-object" => {
                    crate::shared_audio_net::receive_object(
                        &store,
                        signer.clone(),
                        &peer,
                        mutation,
                        &mut input,
                    )
                    .await
                }
                Ok((mutation, proof)) => {
                    let check = store.clone();
                    let presenter = peer.clone();
                    let signing = signer.clone();
                    tokio::task::spawn_blocking(move || {
                        check.mutation_reply(&presenter, &signing, mutation, &proof)
                    })
                    .await?
                }
            };
            // Rejections must not wait for an unauthenticated or oversized body.
            let _ = input.stop(0u32.into());
            let unauthorized = matches!(
                &reply,
                crate::shared_audio_net::MutationReply::Rejected {
                    reason: crate::shared_audio_net::MutationRejection::Unauthorized
                        | crate::shared_audio_net::MutationRejection::Revoked,
                    ..
                }
            );
            crate::cluster_net::send(&mut output, &reply).await?;
            output.finish()?;
            if unauthorized {
                output.stopped().await?;
                connection.close(0u32.into(), b"unauthorized v5 member");
                return Ok(());
            }
            continue;
        }
        let request: crate::shared_audio_net::Request = serde_json::from_slice(&payload)?;
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
            crate::shared_audio_net::Request::Mutation { .. } => unreachable!(),
        }
        output.finish()?;
    }
    Ok(())
}

async fn receive_object(
    store: &crate::shared_audio::Store,
    signer: std::sync::Arc<crate::peer::Identity>,
    peer: &str,
    mutation: crate::shared_audio_net::MutationRequest,
    input: &mut iroh::endpoint::RecvStream,
) -> crate::shared_audio_net::MutationReply {
    let request = mutation.request.clone();
    let result = async {
        let check = store.clone();
        let presenter = peer.to_owned();
        let intent = mutation.clone();
        let (put, staged) = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
            let put = check.prepare_put_object(&presenter, &intent)?;
            Ok((put, check.stage()?))
        })
        .await??;
        use sha2::Digest as _;
        use tokio::io::AsyncWriteExt as _;
        let mut file = tokio::fs::File::from_std(staged.reopen()?);
        let mut sha = sha2::Sha256::new();
        let mut received = 0u64;
        let mut buffer = vec![0; 65536];
        loop {
            let count =
                tokio::time::timeout(std::time::Duration::from_secs(30), input.read(&mut buffer))
                    .await??;
            let Some(count) = count else {
                break;
            };
            received += count as u64;
            anyhow::ensure!(received <= put.bytes, "excess upload bytes");
            sha.update(&buffer[..count]);
            file.write_all(&buffer[..count]).await?;
        }
        anyhow::ensure!(
            received == put.bytes && hex::encode(sha.finalize()) == put.hash,
            "audio size or hash mismatch"
        );
        file.flush().await?;
        drop(file);
        let check = store.clone();
        let presenter = peer.to_owned();
        Ok(tokio::task::spawn_blocking(move || {
            check.finish_put_object(&signer, &presenter, mutation, staged)
        })
        .await?)
    }
    .await;
    crate::shared_audio::mutation_result(request, result)
}

pub struct Session {
    connection: iroh::endpoint::Connection,
    pub proof: crate::enrollment::Proof,
    pub supported_operations: Vec<String>,
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
                supported_operations: vec![],
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
            supported_operations: hello.supported_operations,
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

    pub async fn edit_track(
        &self,
        mutation: crate::shared_audio_net::MutationRequest,
    ) -> anyhow::Result<crate::shared_audio_net::MutationReply> {
        anyhow::ensure!(
            mutation.operation == "edit-track",
            "expected edit-track operation"
        );
        if !self
            .supported_operations
            .iter()
            .any(|op| op == "edit-track")
        {
            return Ok(crate::shared_audio_net::MutationReply::Unsupported {
                request: mutation.request,
                operation: mutation.operation,
            });
        }
        self.request(crate::shared_audio_net::Request::Mutation { mutation })
            .await
    }

    pub async fn resolve_track(
        &self,
        mutation: crate::shared_audio_net::MutationRequest,
    ) -> anyhow::Result<crate::shared_audio_net::MutationReply> {
        anyhow::ensure!(
            mutation.operation == "resolve-track",
            "expected resolve-track operation"
        );
        if !self
            .supported_operations
            .iter()
            .any(|op| op == "resolve-track")
        {
            return Ok(crate::shared_audio_net::MutationReply::Unsupported {
                request: mutation.request,
                operation: mutation.operation,
            });
        }
        self.request(crate::shared_audio_net::Request::Mutation { mutation })
            .await
    }

    pub async fn update_playlists(
        &self,
        mutation: crate::shared_audio_net::MutationRequest,
    ) -> anyhow::Result<crate::shared_audio_net::MutationReply> {
        anyhow::ensure!(
            mutation.operation == "update-playlists",
            "expected update-playlists operation"
        );
        if !self
            .supported_operations
            .iter()
            .any(|op| op == "update-playlists")
        {
            return Ok(crate::shared_audio_net::MutationReply::Unsupported {
                request: mutation.request,
                operation: mutation.operation,
            });
        }
        self.request(crate::shared_audio_net::Request::Mutation { mutation })
            .await
    }

    pub async fn register_track(
        &self,
        mutation: crate::shared_audio_net::MutationRequest,
    ) -> anyhow::Result<crate::shared_audio_net::MutationReply> {
        anyhow::ensure!(
            mutation.operation == "register-track",
            "expected register-track operation"
        );
        if !self
            .supported_operations
            .iter()
            .any(|op| op == "register-track")
        {
            return Ok(crate::shared_audio_net::MutationReply::Unsupported {
                request: mutation.request,
                operation: mutation.operation,
            });
        }
        self.request(crate::shared_audio_net::Request::Mutation { mutation })
            .await
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

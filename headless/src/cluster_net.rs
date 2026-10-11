pub const ENROLLMENT_ALPN: &[u8] = b"syncstr/enrollment/1";

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct EnrollmentRequest {
    version: u8,
    secret: String,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case", deny_unknown_fields)]
enum EnrollmentResponse {
    Enrolled {
        grant: String,
        proof: crate::enrollment::Proof,
    },
    Rejected,
}

pub(crate) async fn send<T: serde::Serialize>(
    stream: &mut iroh::endpoint::SendStream,
    message: &T,
) -> anyhow::Result<()> {
    let payload = serde_json::to_vec(message)?;
    anyhow::ensure!(payload.len() <= 4 * 1024 * 1024, "cluster frame too large");
    stream
        .write_all(&(payload.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&payload).await?;
    Ok(())
}

pub(crate) async fn receive<T: serde::de::DeserializeOwned>(
    stream: &mut iroh::endpoint::RecvStream,
    limit: usize,
) -> anyhow::Result<T> {
    let mut size = [0; 4];
    stream.read_exact(&mut size).await?;
    let size = u32::from_be_bytes(size) as usize;
    anyhow::ensure!(size > 0 && size <= limit, "invalid cluster frame length");
    let mut payload = vec![0; size];
    stream.read_exact(&mut payload).await?;
    Ok(serde_json::from_slice(&payload)?)
}

fn local_address(address: iroh::endpoint::IncomingAddr) -> bool {
    match address {
        iroh::endpoint::IncomingAddr::Ip(address) => match address.ip() {
            std::net::IpAddr::V4(ip) => ip.is_private() || ip.is_link_local() || ip.is_loopback(),
            std::net::IpAddr::V6(ip) => {
                ip.is_unique_local() || ip.is_unicast_link_local() || ip.is_loopback()
            }
        },
        _ => false,
    }
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
                let Some(incoming) = incoming else { break; };
                if !crate::cluster_net::local_address(incoming.remote_addr()) {
                    eprintln!("Cluster connection refused: non-LAN source {:?}", incoming.remote_addr());
                    incoming.refuse(); continue;
                }
                let Ok(permit) = slots.clone().try_acquire_owned() else {
                    eprintln!("Cluster connection refused: connection limit");
                    incoming.refuse(); continue;
                };
                let identity = identity.clone();
                let store = store.clone();
                tasks.spawn(async move {
                    let _permit = permit;
                    let result = tokio::time::timeout(std::time::Duration::from_secs(300), async {
                        let connection = incoming.await?;
                        if connection.alpn() == crate::cluster_sync::ALPN {
                            return crate::cluster_sync::serve_connection(&identity, &store, connection).await;
                        }
                        anyhow::ensure!(connection.alpn() == crate::cluster_net::ENROLLMENT_ALPN, "unsupported cluster protocol");
                        let (mut output, mut input) = connection.accept_bi().await?;
                        let request: crate::cluster_net::EnrollmentRequest = crate::cluster_net::receive(&mut input, 4096).await?;
                        let result = if request.version == 1 {
                            store.redeem_cluster_invitation(&identity, &request.secret, connection.remote_id().to_string(), crate::rendezvous::now()? / 1000).await
                        } else { Err(anyhow::anyhow!("unsupported enrollment version")) };
                        let response = match result {
                            Ok(grant) => crate::cluster_net::EnrollmentResponse::Enrolled { grant: grant.id, proof: store.cluster_membership_proof().await? },
                            Err(_) => crate::cluster_net::EnrollmentResponse::Rejected,
                        };
                        crate::cluster_net::send(&mut output, &response).await?;
                        output.finish()?;
                        output.stopped().await?;
                        anyhow::Ok(())
                    }).await;
                    match result {
                        Ok(Err(error)) => eprintln!("Cluster connection failed: {error:#}"),
                        Err(_) => eprintln!("Cluster connection timed out"),
                        Ok(Ok(())) => {}
                    }
                });
            }
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
}

pub async fn enroll(
    identity: &crate::peer::Identity,
    endpoint: &iroh::Endpoint,
    address: iroh::EndpointAddr,
    invitation: &crate::enrollment::Invitation,
    store: &crate::store::Store,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        invitation.version == 1 && invitation.host == address.id.to_string(),
        "invitation host mismatch"
    );
    tokio::time::timeout(std::time::Duration::from_secs(30), async {
        let connection = endpoint
            .connect(address, crate::cluster_net::ENROLLMENT_ALPN)
            .await?;
        let result = async {
            let (mut output, mut input) = connection.open_bi().await?;
            crate::cluster_net::send(
                &mut output,
                &crate::cluster_net::EnrollmentRequest {
                    version: 1,
                    secret: invitation.secret.clone(),
                },
            )
            .await?;
            output.finish()?;
            let response: crate::cluster_net::EnrollmentResponse =
                crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
            match response {
                crate::cluster_net::EnrollmentResponse::Enrolled { grant, proof } => {
                    anyhow::ensure!(
                        proof.verify(&grant)?.cluster == invitation.cluster,
                        "invitation cluster mismatch"
                    );
                    store
                        .join_cluster(identity, connection.remote_id(), grant, proof)
                        .await
                }
                crate::cluster_net::EnrollmentResponse::Rejected => {
                    anyhow::bail!("invitation expired, invalid, or already used")
                }
            }
        }
        .await;
        connection.close(0u32.into(), b"done");
        result
    })
    .await?
}

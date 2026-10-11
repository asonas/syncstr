#[tokio::test]
async fn private_tls_relay_verifies_certificates_and_rejects_unknown_keys() -> anyhow::Result<()> {
    let allowed = iroh::SecretKey::generate();
    let stranger = iroh::SecretKey::generate();
    let fixture = crate::TlsRelay::new(vec![allowed.public()])?;
    let server = fixture.start(([127, 0, 0, 1], 0).into()).await?;
    let url: iroh::RelayUrl = format!("https://{}", server.https_addr().unwrap()).parse()?;
    let trusted = fixture.trust();
    assert!(
        crate::connect(url.clone(), allowed.clone(), &trusted)
            .await
            .is_ok()
    );
    let denied = crate::connect(url.clone(), stranger, &trusted)
        .await
        .unwrap_err();
    assert!(
        format!("{denied:#}").contains("endpoint not permitted"),
        "{denied:#}"
    );
    let other = crate::TlsRelay::new(Vec::new())?;
    let untrusted = crate::connect(url, allowed, &other.trust())
        .await
        .unwrap_err();
    assert!(
        format!("{untrusted:#}").contains("invalid peer certificate"),
        "{untrusted:#}"
    );
    server.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn paired_endpoints_resume_verified_tls_relay_transfer_after_restart() -> anyhow::Result<()> {
    let roots = [tempfile::tempdir()?, tempfile::tempdir()?];
    for root in &roots {
        syncstr_connectivity_probe::Identity::initialize(root.path())?;
    }
    let server_identity = syncstr_connectivity_probe::Identity::open(roots[0].path())?;
    let client_identity = syncstr_connectivity_probe::Identity::open(roots[1].path())?;
    server_identity.pair(client_identity.id())?;
    client_identity.pair(server_identity.id())?;
    let fixture = crate::TlsRelay::new(vec![server_identity.id(), client_identity.id()])?;
    let mut relay = fixture.start(([127, 0, 0, 1], 0).into()).await?;
    let address = relay.https_addr().unwrap();
    let url: iroh::RelayUrl = format!("https://{address}").parse()?;
    let server = crate::endpoint(roots[0].path(), url.clone(), fixture.trust()).await?;
    let client = crate::endpoint(roots[1].path(), url.clone(), fixture.trust()).await?;
    let receiver = server.clone();
    let serving = tokio::spawn(async move {
        for _ in 0..2 {
            let connection = receiver.accept().await.unwrap().await?;
            syncstr_connectivity_probe::serve_connection(&server_identity, connection).await?;
        }
        anyhow::Ok(())
    });
    for round in 0..2 {
        let report = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            syncstr_connectivity_probe::probe(
                &client_identity,
                &client,
                syncstr_connectivity_probe::Address {
                    version: 1,
                    endpoint: iroh::EndpointAddr::new(server.id()).with_relay_url(url.clone()),
                },
                false,
            ),
        )
        .await??;
        assert_eq!(report.bytes, 65536);
        assert_eq!(report.peer_id, server.id().to_string());
        assert!(
            report
                .paths_after
                .iter()
                .any(|p| p.kind == "relay" && p.selected)
        );
        assert!(report.paths_after.iter().all(|p| p.kind != "direct"));
        if round == 0 {
            relay.shutdown().await?;
            let bytes: [u8; 32] = std::fs::read(roots[1].path().join("device.key"))?
                .try_into()
                .unwrap();
            assert!(
                crate::connect(
                    url.clone(),
                    iroh::SecretKey::from_bytes(&bytes),
                    &fixture.trust()
                )
                .await
                .is_err()
            );
            relay = fixture.start(address).await?;
        }
    }
    serving.await??;
    client.close().await;
    server.close().await;
    relay.shutdown().await?;
    Ok(())
}

struct TlsRelay {
    certificate: rustls::pki_types::CertificateDer<'static>,
    tls: rustls::ServerConfig,
    allowed: Vec<iroh::EndpointId>,
}

async fn endpoint(
    root: &std::path::Path,
    relay: iroh::RelayUrl,
    trust: iroh_relay::tls::CaTlsConfig,
) -> anyhow::Result<iroh::Endpoint> {
    let key: [u8; 32] = std::fs::read(root.join("device.key"))?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid fixture key"))?;
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .secret_key(iroh::SecretKey::from_bytes(&key))
        .alpns(vec![syncstr_connectivity_probe::ALPN.to_vec()])
        .portmapper_config(iroh::endpoint::PortmapperConfig::Disabled)
        .clear_ip_transports()
        .relay_mode(iroh::RelayMode::Custom(iroh::RelayMap::from_iter([relay])))
        .ca_tls_config(trust)
        .bind()
        .await?;
    tokio::time::timeout(std::time::Duration::from_secs(10), endpoint.online()).await?;
    Ok(endpoint)
}

impl crate::TlsRelay {
    fn new(allowed: Vec<iroh::EndpointId>) -> anyhow::Result<Self> {
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()])?;
        let tls = rustls::ServerConfig::builder_with_provider(iroh_relay::tls::default_provider())
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(
                    certificate.signing_key.serialize_der(),
                )
                .into(),
            )?;
        Ok(Self {
            certificate: certificate.cert.der().clone(),
            tls,
            allowed,
        })
    }

    fn trust(&self) -> iroh_relay::tls::CaTlsConfig {
        iroh_relay::tls::CaTlsConfig::custom_roots([self.certificate.clone()])
    }

    async fn start(
        &self,
        address: std::net::SocketAddr,
    ) -> anyhow::Result<iroh_relay::server::Server> {
        let mut relay = iroh_relay::server::RelayConfig::new(([127, 0, 0, 1], 0));
        relay.tls = Some(iroh_relay::server::TlsConfig::new(
            address,
            iroh_relay::server::CertConfig::Manual {
                server_config: self.tls.clone(),
            },
        ));
        relay.access = std::sync::Arc::new(crate::Allowed(self.allowed.clone()));
        let mut config = iroh_relay::server::ServerConfig::default();
        config.relay = Some(relay);
        Ok(iroh_relay::server::Server::spawn(config).await?)
    }
}

#[derive(Debug)]
struct Allowed(Vec<iroh::EndpointId>);

impl iroh_relay::server::AccessControl for crate::Allowed {
    async fn on_connect(
        &self,
        request: &iroh_relay::server::ClientRequest,
    ) -> iroh_relay::server::Access {
        if self.0.contains(&request.endpoint_id()) {
            iroh_relay::server::Access::Allow
        } else {
            iroh_relay::server::Access::Deny {
                reason: Some("endpoint not permitted".into()),
            }
        }
    }
}

async fn connect(
    url: iroh::RelayUrl,
    key: iroh::SecretKey,
    trust: &iroh_relay::tls::CaTlsConfig,
) -> anyhow::Result<iroh_relay::client::Client> {
    let builder =
        iroh_relay::client::ClientBuilder::new(url, key, iroh_dns::dns::DnsResolver::new())
            .tls_client_config(trust.client_config(iroh_relay::tls::default_provider())?);
    Ok(tokio::time::timeout(std::time::Duration::from_secs(5), builder.connect()).await??)
}

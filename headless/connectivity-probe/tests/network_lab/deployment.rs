#[tokio::test]
#[ignore = "Requires nginx and the private_relay example in the disposable Linux lab"]
async fn tls_proxy_enforces_admission_and_recovers_after_relay_process_restart()
-> anyhow::Result<()> {
    anyhow::ensure!(
        std::env::var("SYNCSTR_ISOLATED_NETWORK_LAB").as_deref() == Ok("1"),
        "run only in the disposable network lab"
    );
    let root = tempfile::tempdir()?;
    let server_key = iroh::SecretKey::generate();
    let client_key = iroh::SecretKey::generate();
    let stranger = iroh::SecretKey::generate();
    let backend = crate::deployment::unused_address()?;
    let frontend = crate::deployment::unused_address()?;
    let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()])?;
    std::fs::write(root.path().join("cert.pem"), certificate.cert.pem())?;
    std::fs::write(
        root.path().join("key.pem"),
        certificate.signing_key.serialize_pem(),
    )?;
    let config = format!(
        "daemon off; master_process off; pid {root}/nginx.pid; error_log stderr info; events {{}} http {{ access_log off; server {{ listen {frontend} ssl; ssl_certificate {root}/cert.pem; ssl_certificate_key {root}/key.pem; location / {{ proxy_pass http://{backend}; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection upgrade; proxy_buffering off; proxy_read_timeout 120s; }} }} }}",
        root = root.path().display()
    );
    let config_path = root.path().join("nginx.conf");
    std::fs::write(&config_path, config)?;
    let mut relay =
        crate::deployment::start_relay(backend, &[server_key.public(), client_key.public()])?;
    let mut proxy = tokio::process::Command::new("nginx")
        .arg("-c")
        .arg(&config_path)
        .kill_on_drop(true)
        .spawn()?;
    let trust = iroh_relay::tls::CaTlsConfig::custom_roots([certificate.cert.der().clone()]);
    let url: iroh::RelayUrl = format!("https://{frontend}").parse()?;
    let http = reqwest::Client::builder()
        .tls_backend_preconfigured(trust.client_config(iroh_relay::tls::default_provider())?)
        .no_proxy()
        .timeout(std::time::Duration::from_secs(2))
        .build()?;
    crate::deployment::wait_healthy(&http, &url).await?;
    let denied = crate::deployment::connect(url.clone(), stranger.clone(), &trust)
        .await
        .unwrap_err();
    anyhow::ensure!(
        format!("{denied:#}").contains("endpoint not permitted"),
        "{denied:#}"
    );
    let other_cert = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()])?;
    let other_trust = iroh_relay::tls::CaTlsConfig::custom_roots([other_cert.cert.der().clone()]);
    let untrusted = crate::deployment::connect(url.clone(), client_key.clone(), &other_trust)
        .await
        .unwrap_err();
    anyhow::ensure!(
        format!("{untrusted:#}").contains("invalid peer certificate"),
        "{untrusted:#}"
    );
    let server = crate::deployment::endpoint(server_key, url.clone(), trust.clone()).await?;
    let client = crate::deployment::endpoint(client_key, url.clone(), trust.clone()).await?;
    let receiver = server.clone();
    let client_id = client.id();
    let serving = tokio::spawn(async move {
        use sha2::Digest as _;
        for _ in 0..2 {
            let connection = receiver.accept().await.unwrap().await?;
            anyhow::ensure!(connection.remote_id() == client_id, "unexpected peer");
            let (mut send, mut receive) = connection.accept_bi().await?;
            let payload = receive.read_to_end(65536).await?;
            anyhow::ensure!(payload.len() == 65536, "incomplete payload");
            send.write_all(&sha2::Sha256::digest(payload)).await?;
            send.finish()?;
            send.stopped().await?;
        }
        anyhow::Ok(())
    });
    for round in 0..2 {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let connection = client.connect(iroh::EndpointAddr::new(server.id()).with_relay_url(url.clone()), syncstr_connectivity_probe::ALPN).await?;
            let (mut send, mut receive) = connection.open_bi().await?;
            let payload: Vec<u8> = (0..65536).map(|i| (i % 251) as u8).collect();
            send.write_all(&payload).await?;
            send.finish()?;
            let digest = receive.read_to_end(32).await?;
            anyhow::ensure!(hex::encode(&digest) == "4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2", "fixture mismatch");
            let paths = syncstr_connectivity_probe::paths(&connection);
            anyhow::ensure!(paths.iter().any(|path| path.selected && path.kind == "relay"), "missing relay path");
            println!("{}", serde_json::json!({"proxy_round":round,"bytes":payload.len(),"sha256":hex::encode(digest),"paths":paths}));
            connection.close(0u32.into(), b"complete");
            anyhow::Ok(())
        }).await??;
        if round == 0 {
            relay.kill().await?;
            let response = http.get(format!("{url}healthz")).send().await?;
            assert_eq!(response.status(), reqwest::StatusCode::BAD_GATEWAY);
            relay = crate::deployment::start_relay(backend, &[server.id(), client.id()])?;
            crate::deployment::wait_healthy(&http, &url).await?;
            let denied = crate::deployment::connect(url.clone(), stranger.clone(), &trust)
                .await
                .unwrap_err();
            anyhow::ensure!(
                format!("{denied:#}").contains("endpoint not permitted"),
                "{denied:#}"
            );
        }
    }
    serving.await??;
    client.close().await;
    server.close().await;
    relay.kill().await?;
    proxy.kill().await?;
    Ok(())
}

fn unused_address() -> anyhow::Result<std::net::SocketAddr> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?.local_addr()?)
}

fn start_relay(
    address: std::net::SocketAddr,
    allowed: &[iroh::EndpointId],
) -> anyhow::Result<tokio::process::Child> {
    Ok(
        tokio::process::Command::new("target/debug/examples/private_relay")
            .arg(address.to_string())
            .args(allowed.iter().map(ToString::to_string))
            .kill_on_drop(true)
            .spawn()?,
    )
}

async fn wait_healthy(client: &reqwest::Client, url: &iroh::RelayUrl) -> anyhow::Result<()> {
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            if let Ok(response) = client.get(format!("{url}healthz")).send().await
                && response.status().is_success()
            {
                let body: serde_json::Value = response.json().await?;
                anyhow::ensure!(
                    body["status"] == "ok" && body["version"] == "1.3.0",
                    "unexpected health response: {body}"
                );
                return anyhow::Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    })
    .await??;
    Ok(())
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

async fn endpoint(
    key: iroh::SecretKey,
    url: iroh::RelayUrl,
    trust: iroh_relay::tls::CaTlsConfig,
) -> anyhow::Result<iroh::Endpoint> {
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .secret_key(key)
        .alpns(vec![syncstr_connectivity_probe::ALPN.to_vec()])
        .portmapper_config(iroh::endpoint::PortmapperConfig::Disabled)
        .clear_ip_transports()
        .relay_mode(iroh::RelayMode::Custom(iroh::RelayMap::from_iter([url])))
        .ca_tls_config(trust)
        .bind()
        .await?;
    tokio::time::timeout(std::time::Duration::from_secs(10), endpoint.online()).await?;
    Ok(endpoint)
}

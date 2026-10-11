#![cfg(feature = "p2p")]

struct Process(std::process::Child);

impl Drop for crate::Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(arguments: &[&std::ffi::OsStr]) -> anyhow::Result<crate::Process> {
    use std::io::BufRead as _;
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
        .args(arguments)
        .stdout(std::process::Stdio::piped())
        .spawn()?;
    let stdout = child.stdout.take().unwrap();
    let process = crate::Process(child);
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = std::io::BufReader::new(stdout).read_line(&mut line);
        let _ = sender.send(line);
    });
    anyhow::ensure!(
        !receiver
            .recv_timeout(std::time::Duration::from_secs(10))?
            .is_empty(),
        "server did not start"
    );
    Ok(process)
}

#[tokio::test]
async fn enrolled_host_downloads_through_private_relay_without_peer_ips() -> anyhow::Result<()> {
    use sha2::Digest as _;
    let root = tempfile::tempdir()?;
    let host_root = root.path().join("host");
    let client_root = root.path().join("client");
    let host_key = host_root.join("identity");
    let client_key = client_root.join("identity");
    let host_data = host_root.join("data");
    let client_data = client_root.join("data");
    let host_id = syncstr_headless::peer::Identity::initialize(&host_key)?;
    let client_id = syncstr_headless::peer::Identity::initialize(&client_key)?;
    let host = syncstr_headless::peer::Identity::open(&host_key)?;
    let client = syncstr_headless::peer::Identity::open(&client_key)?;
    let store = syncstr_headless::store::Store::open(&host_data)?;
    let received = syncstr_headless::store::Store::open(&client_data)?;
    store.create_cluster(host_id.to_string()).await?;
    let invitation = store
        .create_cluster_invitation(&host, true, 1000, 600)
        .await?;
    let grant = store
        .redeem_cluster_invitation(&host, &invitation.secret, client_id.to_string(), 1100)
        .await?;
    received
        .join_cluster(
            &client,
            host_id,
            grant.id,
            store.cluster_membership_proof().await?,
        )
        .await?;
    let bytes = b"verified relay audio fixture";
    let file = root.path().join("audio.mp3");
    std::fs::write(&file, bytes)?;
    let mut entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    entry.sha256 = hex::encode(sha2::Sha256::digest(bytes));
    entry.track.size = bytes.len() as u64;
    store
        .import_cluster_file(&host, entry.clone(), None, &file, false)
        .await?;
    let socket = std::net::TcpListener::bind("127.0.0.1:0")?;
    let bind = socket.local_addr()?.to_string();
    drop(socket);
    let relay_url: iroh::RelayUrl = format!("http://{bind}/").parse()?;
    store.set_cluster_relay(Some(relay_url.to_string())).await?;
    drop(store);
    let admission = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
        .args(["cluster-relay-ids", "--data"])
        .arg(&host_data)
        .output()?;
    assert!(
        admission.status.success(),
        "{}",
        String::from_utf8_lossy(&admission.stderr)
    );
    let mut members: Vec<String> = serde_json::from_slice(&admission.stdout)?;
    members.sort();
    let mut expected = vec![host_id.to_string(), client_id.to_string()];
    expected.sort();
    assert_eq!(members, expected);
    let allowed = root.path().join("allowed.json");
    std::fs::write(&allowed, admission.stdout)?;
    let relay = crate::start(&[
        "relay-serve".as_ref(),
        "--listen".as_ref(),
        bind.as_ref(),
        "--allowed-ids".as_ref(),
        allowed.as_os_str(),
    ])?;
    let health = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
        .args(["relay-health", "--url", relay_url.as_str()])
        .output()?;
    assert!(
        health.status.success(),
        "{}",
        String::from_utf8_lossy(&health.stderr)
    );
    let health: serde_json::Value = serde_json::from_slice(&health.stdout)?;
    assert_eq!(health["status"], "ok");
    assert_eq!(health["version"], "1.3.0");
    let server = crate::start(&[
        "cluster-serve".as_ref(),
        "--data".as_ref(),
        host_data.as_os_str(),
        "--peer-state".as_ref(),
        host_key.as_os_str(),
        "--relay-only".as_ref(),
    ])?;
    let key: [u8; 32] = std::fs::read(client_key.join("device.key"))?
        .try_into()
        .unwrap();
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .secret_key(iroh::SecretKey::from_bytes(&key))
        .alpns(vec![syncstr_headless::cluster_sync::ALPN.to_vec()])
        .portmapper_config(iroh::endpoint::PortmapperConfig::Disabled)
        .clear_ip_transports()
        .relay_mode(iroh::RelayMode::Custom(iroh::RelayMap::from_iter([
            relay_url.clone(),
        ])))
        .bind()
        .await?;
    tokio::time::timeout(std::time::Duration::from_secs(10), endpoint.online()).await?;
    let address = iroh::EndpointAddr::new(host_id).with_relay_url(relay_url.clone());
    let session =
        syncstr_headless::cluster_sync::Session::connect(&endpoint, address, &received).await?;
    session.reconcile(&received).await?;
    session.download(&client, &received, &entry.sha256).await?;
    assert_eq!(session.selected_path(), Some("relay"));
    assert_eq!(received.cluster_receipts().await?.len(), 1);
    assert_eq!(std::fs::read(received.path(&entry))?, bytes);
    let stranger = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .clear_ip_transports()
        .portmapper_config(iroh::endpoint::PortmapperConfig::Disabled)
        .relay_mode(iroh::RelayMode::Custom(iroh::RelayMap::from_iter([
            relay_url.clone(),
        ])))
        .bind()
        .await?;
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(3), stranger.online())
            .await
            .is_err()
    );
    stranger.close().await;
    endpoint.close().await;
    drop(server);
    drop(relay);
    assert!(
        !std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
            .args(["relay-health", "--url", relay_url.as_str()])
            .status()?
            .success()
    );
    assert_eq!(std::fs::read(file)?, bytes);
    Ok(())
}

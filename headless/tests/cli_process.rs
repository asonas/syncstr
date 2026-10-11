struct Server(std::process::Child);

impl Drop for crate::Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn command() -> std::process::Command {
    std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
}

#[cfg(feature = "p2p")]
fn start_cluster(root: &std::path::Path) -> crate::Server {
    use std::io::BufRead as _;
    let mut child = crate::command().arg("cluster-serve").arg("--data").arg(root.join("data")).arg("--peer-state").arg(root.join("identity")).stdout(std::process::Stdio::piped()).spawn().unwrap();
    let stdout = child.stdout.take().unwrap();
    let server = crate::Server(child);
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || { let mut line = String::new(); let _ = std::io::BufReader::new(stdout).read_line(&mut line); let _ = sender.send(line); });
    assert!(receiver.recv_timeout(std::time::Duration::from_secs(10)).unwrap().starts_with("Cluster LAN endpoint "));
    server
}

#[cfg(feature = "p2p")]
fn wait_for_replica(root: &std::path::Path, hash: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(45);
    loop {
        let connection = rusqlite::Connection::open_with_flags(root.join("data/node.sqlite"), rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        connection.busy_timeout(std::time::Duration::from_secs(1)).unwrap();
        let found: bool = connection.query_row("SELECT EXISTS(SELECT 1 FROM cluster_receipts WHERE object = ?)", [hash], |row| row.get(0)).unwrap();
        if found { return; }
        assert!(std::time::Instant::now() < deadline, "replica did not arrive");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

#[cfg(feature = "p2p")]
#[test]
fn separate_lan_hosts_catch_up_after_offline_import_and_restart() {
    let root = tempfile::tempdir().unwrap();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let a_root = root.path().join("a");
    let b_root = root.path().join("b");
    let first = runtime.block_on(async {
        use sha2::Digest as _;
        let mut nodes = Vec::new();
        for path in [&a_root, &b_root] {
            syncstr_headless::peer::Identity::initialize(&path.join("identity")).unwrap();
            nodes.push((syncstr_headless::peer::Identity::open(&path.join("identity")).unwrap(), syncstr_headless::store::Store::open(&path.join("data")).unwrap()));
        }
        let (a, a_store) = &nodes[0];
        let (b, b_store) = &nodes[1];
        a_store.create_cluster(a.id().to_string()).await.unwrap();
        let invite = a_store.create_cluster_invitation(a, true, 1000, 600).await.unwrap();
        let grant = a_store.redeem_cluster_invitation(a, &invite.secret, b.id().to_string(), 1100).await.unwrap();
        b_store.join_cluster(b, a.id(), grant.id, a_store.cluster_membership_proof().await.unwrap()).await.unwrap();
        let bytes = b"first process fixture";
        let source = root.path().join("first.mp3");
        std::fs::write(&source, bytes).unwrap();
        let mut entry: syncstr_headless::model::Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
        entry.sha256 = hex::encode(sha2::Sha256::digest(bytes));
        entry.track.size = bytes.len() as u64;
        a_store.import_cluster_file(a, entry.clone(), None, &source, false).await.unwrap();
        entry.sha256
    });
    let mut a = crate::start_cluster(&a_root);
    let mut b = crate::start_cluster(&b_root);
    crate::wait_for_replica(&b_root, &first);
    crate::stop(&mut a);
    crate::stop(&mut b);
    let second = runtime.block_on(async {
        use sha2::Digest as _;
        let identity = syncstr_headless::peer::Identity::open(&b_root.join("identity")).unwrap();
        let store = syncstr_headless::store::Store::open(&b_root.join("data")).unwrap();
        let bytes = b"import while other host is offline";
        let source = root.path().join("second.mp3");
        std::fs::write(&source, bytes).unwrap();
        let mut entry: syncstr_headless::model::Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
        entry.track.id = uuid::Uuid::new_v4().to_string();
        entry.sha256 = hex::encode(sha2::Sha256::digest(bytes));
        entry.track.size = bytes.len() as u64;
        store.import_cluster_file(&identity, entry.clone(), None, &source, false).await.unwrap();
        assert_eq!(store.cluster_changes().await.unwrap().len(), 2);
        entry.sha256
    });
    let mut b = crate::start_cluster(&b_root);
    let mut a = crate::start_cluster(&a_root);
    crate::wait_for_replica(&a_root, &second);
    crate::wait_for_replica(&a_root, &first);
    crate::stop(&mut a);
    crate::stop(&mut b);
    runtime.block_on(async {
        for path in [&a_root, &b_root] {
            let store = syncstr_headless::store::Store::open(&path.join("data")).unwrap();
            assert_eq!(store.catalog().await.unwrap().entries.len(), 2);
            assert_eq!(store.cluster_changes().await.unwrap().len(), 2);
            assert_eq!(store.cluster_receipts().await.unwrap().len(), 2);
            assert!(store.cluster_jobs().await.unwrap().iter().all(|job| job.state == syncstr_headless::cluster::JobState::Complete));
        }
    });
}

#[cfg(feature = "p2p")]
#[test]
fn cli_enrollment_discovers_the_pinned_host_without_an_ip_address() {
    use std::io::BufRead as _;
    use std::os::unix::fs::PermissionsExt as _;
    let root = tempfile::tempdir().unwrap();
    let host_state = root.path().join("host-state");
    let client_state = root.path().join("client-state");
    let data = root.path().join("host-data");
    let client_data = root.path().join("client-data");
    let invite = root.path().join("invitation.json");
    for state in [&host_state, &client_state] {
        let result = crate::command()
            .arg("peer-init")
            .arg("--state")
            .arg(state)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
    let result = crate::command()
        .arg("cluster-init")
        .arg("--data")
        .arg(&data)
        .arg("--peer-state")
        .arg(&host_state)
        .output()
        .unwrap();
    assert!(result.status.success());
    let result = crate::command()
        .arg("cluster-invite")
        .arg("--data")
        .arg(&data)
        .arg("--peer-state")
        .arg(&host_state)
        .arg("--library-host")
        .arg("--output")
        .arg(&invite)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(
        std::fs::metadata(&invite).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let invitation: syncstr_headless::enrollment::Invitation =
        serde_json::from_slice(&std::fs::read(&invite).unwrap()).unwrap();
    assert!(!String::from_utf8_lossy(&result.stdout).contains(&invitation.secret));
    let mut child = crate::command()
        .arg("cluster-serve")
        .arg("--data")
        .arg(&data)
        .arg("--peer-state")
        .arg(&host_state)
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut server = crate::Server(child);
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = std::io::BufReader::new(stdout).read_line(&mut line);
        let _ = sender.send(line);
    });
    assert!(
        receiver
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .starts_with("Cluster LAN endpoint ")
    );
    let result = crate::command()
        .arg("cluster-join")
        .arg("--data")
        .arg(&client_data)
        .arg("--peer-state")
        .arg(&client_state)
        .arg("--invitation")
        .arg(&invite)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    crate::stop(&mut server);
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let store = syncstr_headless::store::Store::open(&client_data).unwrap();
        assert_eq!(
            store.cluster_inventory().await.unwrap().cluster.unwrap().id,
            invitation.cluster
        );
        assert_eq!(
            store.cluster_membership_proof().await.unwrap().root,
            invitation.host
        );
    });
}

#[cfg(feature = "p2p")]
#[test]
fn explicit_cluster_creation_preserves_transport_identity_and_pairings() {
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join("peer");
    let data = root.path().join("data");
    let member = syncstr_headless::peer::Identity::initialize(&state).unwrap();
    let identity = syncstr_headless::peer::Identity::open(&state).unwrap();
    let paired = iroh::SecretKey::generate().public();
    identity.pair(paired).unwrap();
    let key = std::fs::read(state.join("device.key")).unwrap();
    let mut previous = None;
    for _ in 0..2 {
        let output = crate::command()
            .arg("cluster-init")
            .arg("--data")
            .arg(&data)
            .arg("--peer-state")
            .arg(&state)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let cluster: syncstr_headless::cluster::ClusterIdentity =
            serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(cluster.member_id, member.to_string());
        if let Some(previous) = &previous {
            assert_eq!(&cluster, previous);
        }
        previous = Some(cluster);
    }
    let output = crate::command()
        .arg("cluster-info")
        .arg("--data")
        .arg(&data)
        .output()
        .unwrap();
    assert!(output.status.success());
    let inventory: syncstr_headless::cluster::Inventory =
        serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(inventory.cluster, previous);
    assert_eq!(std::fs::read(state.join("device.key")).unwrap(), key);
    assert!(
        syncstr_headless::peer::Identity::open(&state)
            .unwrap()
            .is_paired(paired)
    );
}

fn start(root: &std::path::Path) -> (crate::Server, String) {
    use std::io::BufRead as _;
    let mut child = crate::command()
        .args(["serve", "--data"])
        .arg(root.join("data"))
        .arg("--identity")
        .arg(root.join("identity"))
        .args(["--listen", "127.0.0.1:0"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        std::io::BufReader::new(stdout)
            .read_line(&mut line)
            .unwrap();
        let _ = sender.send(line);
    });
    let server = crate::Server(child);
    let line = receiver
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    let endpoint = line
        .trim()
        .strip_prefix("Listening on ")
        .unwrap()
        .to_owned();
    (server, endpoint)
}

fn stop(server: &mut crate::Server) {
    assert!(
        std::process::Command::new("/bin/kill")
            .args(["-TERM", &server.0.id().to_string()])
            .status()
            .unwrap()
            .success()
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(status) = server.0.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(std::time::Instant::now() < deadline, "server did not stop");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn client(root: &std::path::Path, endpoint: &str, operation: &str) -> std::process::Command {
    let mut command = crate::command();
    command
        .args([operation, "--url", endpoint, "--cert"])
        .arg(root.join("identity/tls.crt"))
        .arg("--token-file")
        .arg(root.join("identity/token"));
    command
}

#[test]
fn cli_processes_initialize_upload_restart_download_and_shutdown() {
    let root = tempfile::tempdir().unwrap();
    let initialized = crate::command()
        .args(["init", "--host", "127.0.0.1", "--identity"])
        .arg(root.path().join("identity"))
        .output()
        .unwrap();
    assert!(
        initialized.status.success(),
        "{}",
        String::from_utf8_lossy(&initialized.stderr)
    );
    let (mut server, endpoint) = crate::start(root.path());
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../apps/macos/Tests/Fixtures/untagged.mp3");
    let upload = crate::client(root.path(), &endpoint, "upload")
        .arg("--file")
        .arg(&fixture)
        .args(["--title", "CLI fixture"])
        .output()
        .unwrap();
    assert!(
        upload.status.success(),
        "{}",
        String::from_utf8_lossy(&upload.stderr)
    );
    let saved: syncstr_headless::model::Entry = serde_json::from_slice(&upload.stdout).unwrap();
    crate::stop(&mut server);
    let (mut server, endpoint) = crate::start(root.path());
    let catalog = crate::client(root.path(), &endpoint, "catalog")
        .output()
        .unwrap();
    assert!(catalog.status.success());
    assert_eq!(
        serde_json::from_slice::<syncstr_headless::model::Catalog>(&catalog.stdout)
            .unwrap()
            .entries,
        vec![saved.clone()]
    );
    let output = root.path().join("received.mp3");
    let download = crate::client(root.path(), &endpoint, "download")
        .args(["--id", &saved.track.id, "--output"])
        .arg(&output)
        .output()
        .unwrap();
    assert!(
        download.status.success(),
        "{}",
        String::from_utf8_lossy(&download.stderr)
    );
    assert_eq!(
        std::fs::read(&output).unwrap(),
        std::fs::read(fixture).unwrap()
    );
    let overwrite = crate::client(root.path(), &endpoint, "download")
        .args(["--id", &saved.track.id, "--output"])
        .arg(&output)
        .output()
        .unwrap();
    assert!(!overwrite.status.success());
    crate::stop(&mut server);
}

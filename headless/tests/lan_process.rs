#![cfg(feature = "p2p")]

struct Server {
    child: std::process::Child,
    stdout: tempfile::NamedTempFile,
    stderr: tempfile::NamedTempFile,
}

impl Drop for crate::Server {
    fn drop(&mut self) {
        let status = self.child.try_wait();
        let _ = self.child.kill();
        let _ = self.child.wait();
        if std::thread::panicking() {
            eprintln!("cluster-serve process status before cleanup: {status:?}");
            for (name, file) in [("stdout", &self.stdout), ("stderr", &self.stderr)] {
                let bytes = std::fs::read(file.path()).unwrap_or_default();
                let tail = &bytes[bytes.len().saturating_sub(16384)..];
                eprintln!(
                    "cluster-serve {name} (last 16 KiB):\n{}",
                    String::from_utf8_lossy(tail)
                );
            }
        }
    }
}

fn command() -> std::process::Command {
    std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
}

fn start_cluster(root: &std::path::Path) -> crate::Server {
    crate::start_cluster_at(&root.join("data"), &root.join("identity"))
}

fn start_cluster_at(data: &std::path::Path, state: &std::path::Path) -> crate::Server {
    let stdout = tempfile::NamedTempFile::new().unwrap();
    let stderr = tempfile::NamedTempFile::new().unwrap();
    let child = crate::command()
        .arg("cluster-serve")
        .arg("--data")
        .arg(data)
        .arg("--peer-state")
        .arg(state)
        .stdout(stdout.reopen().unwrap())
        .stderr(stderr.reopen().unwrap())
        .spawn()
        .unwrap();
    let mut server = crate::Server {
        child,
        stdout,
        stderr,
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let output = std::fs::read_to_string(server.stdout.path()).unwrap();
        if output
            .lines()
            .any(|line| line.starts_with("Cluster LAN endpoint "))
        {
            return server;
        }
        assert!(
            server.child.try_wait().unwrap().is_none(),
            "cluster-serve exited before announcing readiness"
        );
        assert!(
            std::time::Instant::now() < deadline,
            "waiting for cluster-serve readiness exceeded 10 seconds"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

#[cfg(feature = "p2p")]
fn wait_for_replica(root: &std::path::Path, hash: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(45);
    loop {
        let connection = rusqlite::Connection::open_with_flags(
            root.join("data/node.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        connection
            .busy_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        let found: bool = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM cluster_receipts WHERE object = ?)",
                [hash],
                |row| row.get(0),
            )
            .unwrap();
        if found {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "waiting for replica {hash} in {} exceeded 45 seconds",
            root.display()
        );
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
            nodes.push((
                syncstr_headless::peer::Identity::open(&path.join("identity")).unwrap(),
                syncstr_headless::store::Store::open(&path.join("data")).unwrap(),
            ));
        }
        let (a, a_store) = &nodes[0];
        let (b, b_store) = &nodes[1];
        a_store.create_cluster(a.id().to_string()).await.unwrap();
        let invite = a_store
            .create_cluster_invitation(a, true, 1000, 600)
            .await
            .unwrap();
        let grant = a_store
            .redeem_cluster_invitation(a, &invite.secret, b.id().to_string(), 1100)
            .await
            .unwrap();
        b_store
            .join_cluster(
                b,
                a.id(),
                grant.id,
                a_store.cluster_membership_proof().await.unwrap(),
            )
            .await
            .unwrap();
        let bytes = b"first process fixture";
        let source = root.path().join("first.mp3");
        std::fs::write(&source, bytes).unwrap();
        let mut entry: syncstr_headless::model::Entry =
            serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
        entry.sha256 = hex::encode(sha2::Sha256::digest(bytes));
        entry.track.size = bytes.len() as u64;
        a_store
            .import_cluster_file(a, entry.clone(), None, &source, false)
            .await
            .unwrap();
        entry.sha256
    });
    let mut a = crate::start_cluster(&a_root);
    let mut b = crate::start_cluster(&b_root);
    crate::wait_for_replica(&b_root, &first);
    crate::stop(&mut a);
    crate::stop(&mut b);
    let interrupted = rusqlite::Connection::open(b_root.join("data/node.sqlite")).unwrap();
    interrupted
        .execute("DELETE FROM cluster_receipts WHERE object = ?", [&first])
        .unwrap();
    interrupted
        .execute(
            "UPDATE cluster_jobs SET state = 'running' WHERE sha256 = ?",
            [&first],
        )
        .unwrap();
    drop(interrupted);
    let second = runtime.block_on(async {
        use sha2::Digest as _;
        let identity = syncstr_headless::peer::Identity::open(&b_root.join("identity")).unwrap();
        let store = syncstr_headless::store::Store::open(&b_root.join("data")).unwrap();
        let bytes = b"import while other host is offline";
        let source = root.path().join("second.mp3");
        std::fs::write(&source, bytes).unwrap();
        let mut entry: syncstr_headless::model::Entry =
            serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
        entry.track.id = uuid::Uuid::new_v4().to_string();
        entry.sha256 = hex::encode(sha2::Sha256::digest(bytes));
        entry.track.size = bytes.len() as u64;
        store
            .import_cluster_file(&identity, entry.clone(), None, &source, false)
            .await
            .unwrap();
        assert_eq!(store.cluster_changes().await.unwrap().len(), 2);
        entry.sha256
    });
    let mut b = crate::start_cluster(&b_root);
    let mut a = crate::start_cluster(&a_root);
    crate::wait_for_replica(&a_root, &second);
    crate::wait_for_replica(&a_root, &first);
    crate::wait_for_replica(&b_root, &first);
    crate::stop(&mut a);
    crate::stop(&mut b);
    runtime.block_on(async {
        for path in [&a_root, &b_root] {
            let store = syncstr_headless::store::Store::open(&path.join("data")).unwrap();
            assert_eq!(store.catalog().await.unwrap().entries.len(), 2);
            assert_eq!(store.cluster_changes().await.unwrap().len(), 2);
            assert_eq!(store.cluster_receipts().await.unwrap().len(), 2);
            assert!(
                store
                    .cluster_jobs()
                    .await
                    .unwrap()
                    .iter()
                    .all(|job| job.state == syncstr_headless::cluster::JobState::Complete)
            );
        }
    });
}

#[cfg(feature = "p2p")]
#[test]
fn cli_enrollment_discovers_the_pinned_host_without_an_ip_address() {
    #[cfg(unix)]
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
    #[cfg(unix)]
    assert_eq!(
        std::fs::metadata(&invite).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let invitation: syncstr_headless::enrollment::Invitation =
        serde_json::from_slice(&std::fs::read(&invite).unwrap()).unwrap();
    assert!(!String::from_utf8_lossy(&result.stdout).contains(&invitation.secret));
    let mut server = crate::start_cluster_at(&data, &host_state);
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

fn stop(server: &mut crate::Server) {
    assert!(
        std::process::Command::new("/bin/kill")
            .args(["-TERM", &server.child.id().to_string()])
            .status()
            .unwrap()
            .success()
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(status) = server.child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(std::time::Instant::now() < deadline, "server did not stop");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

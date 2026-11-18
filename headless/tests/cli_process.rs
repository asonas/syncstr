struct Server(std::process::Child);

#[cfg(feature = "p2p")]
#[test]
fn relay_configuration_survives_restart_and_is_carried_by_invitations() {
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join("identity");
    let data = root.path().join("data");
    let identity = syncstr_headless::peer::Identity::initialize(&state).unwrap();
    let initialized = crate::command()
        .args(["cluster-init", "--data"])
        .arg(&data)
        .arg("--peer-state")
        .arg(&state)
        .output()
        .unwrap();
    assert!(initialized.status.success());
    let configured = crate::command()
        .args(["cluster-relay", "--data"])
        .arg(&data)
        .args(["--url", "https://relay.example.net/"])
        .output()
        .unwrap();
    assert!(
        configured.status.success(),
        "{}",
        String::from_utf8_lossy(&configured.stderr)
    );
    for (index, invalid) in [
        "https://listener:password@relay.example.net/",
        "http://relay.example.net/",
        "https://relay.example.net/?secret=example",
    ]
    .iter()
    .enumerate()
    {
        let rejected = crate::command()
            .args(["cluster-relay", "--data"])
            .arg(&data)
            .args(["--url", invalid])
            .output()
            .unwrap();
        assert!(!rejected.status.success());
        let invitation = root.path().join(format!("invite-{index}.json"));
        let invited = crate::command()
            .args(["cluster-invite", "--data"])
            .arg(&data)
            .arg("--peer-state")
            .arg(&state)
            .arg("--output")
            .arg(&invitation)
            .output()
            .unwrap();
        assert!(invited.status.success());
        let payload: serde_json::Value =
            serde_json::from_slice(&std::fs::read(invitation).unwrap()).unwrap();
        assert_eq!(payload["relay"], "https://relay.example.net/");
        assert_eq!(payload["host"], identity.to_string());
    }
    let disabled = crate::command()
        .args(["cluster-relay", "--data"])
        .arg(&data)
        .arg("--disable")
        .output()
        .unwrap();
    assert!(disabled.status.success());
    let invitation = root.path().join("lan.json");
    assert!(
        crate::command()
            .args(["cluster-invite", "--data"])
            .arg(&data)
            .arg("--peer-state")
            .arg(&state)
            .arg("--output")
            .arg(&invitation)
            .status()
            .unwrap()
            .success()
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&std::fs::read(invitation).unwrap()).unwrap();
    assert!(payload.get("relay").is_none());
}

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

fn start(root: &std::path::Path) -> (crate::Server, String, String) {
    use std::io::BufRead as _;
    let mut child = crate::command()
        .args(["serve", "--data"])
        .arg(root.join("data"))
        .arg("--identity")
        .arg(root.join("identity"))
        .args([
            "--listen",
            "127.0.0.1:0",
            "--api-listen",
            "127.0.0.1:0",
            "--api-address",
            "https://music.example.test",
        ])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout).lines().take(2) {
            sender.send(line.unwrap()).unwrap();
        }
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
    let line = receiver
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    let api = line
        .strip_prefix("Host API listening on ")
        .unwrap()
        .to_owned();
    (server, endpoint, api)
}

#[tokio::main(flavor = "current_thread")]
async fn library_info(api: &str) -> serde_json::Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .no_proxy()
        .build()
        .unwrap()
        .get(format!("{api}/api/v1/library"))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap()
}

#[test]
fn host_api_refuses_non_loopback_listeners_and_invalid_origins() {
    for (flag, value, error) in [
        ("--api-listen", "127.0.0.1:0", "--api-address"),
        ("--api-listen", "0.0.0.0:0", "loopback"),
        ("--api-listen", "[::]:8441", "loopback"),
        ("--api-address", "http://music.example.test", "HTTPS origin"),
        (
            "--api-address",
            "https://music.example.test/path",
            "HTTPS origin",
        ),
        (
            "--api-address",
            "https://music.example.test?param",
            "HTTPS origin",
        ),
        (
            "--api-address",
            "https://music.example.test#fragment",
            "HTTPS origin",
        ),
        (
            "--api-address",
            "https://user@music.example.test",
            "HTTPS origin",
        ),
    ] {
        let output = command().args(["serve", flag, value]).output().unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains(error));
    }
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
    let (mut server, endpoint, api) = crate::start(root.path());
    let first = library_info(&api);
    assert_eq!(first["host"]["address"], "https://music.example.test");
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
    let (mut server, endpoint, api) = crate::start(root.path());
    let restarted = library_info(&api);
    assert_eq!(first["host"], restarted["host"]);
    assert_ne!(first["marker"], restarted["marker"]);
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

#![cfg(feature = "p2p")]

#[test]
fn standalone_directory_lookup_reports_network_failure_without_panicking() {
    let root = tempfile::tempdir().unwrap();
    let id = syncstr_headless::peer::Identity::initialize(root.path()).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
        .args(["peer-resolve", "--state"])
        .arg(root.path())
        .args([
            "--directory",
            "https://127.0.0.1:1",
            "--peer",
            &id.to_string(),
        ])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("panicked"));
}

#[test]
fn exports_current_identity_and_selected_ip_without_private_keys() {
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join("peer");
    let id = syncstr_headless::peer::Identity::initialize(&state).unwrap();
    let record = root.path().join("address.json");
    std::fs::write(
        &record,
        serde_json::to_vec(&syncstr_headless::peer::Address {
            version: 1,
            id,
            addresses: vec![
                "192.0.2.10:40000".parse().unwrap(),
                "172.18.0.1:40000".parse().unwrap(),
            ],
            relay: None,
            directory: None,
        })
        .unwrap(),
    )
    .unwrap();
    let run = |extra: &[&str]| {
        std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
            .args(["peer-info", "--state"])
            .arg(&state)
            .arg("--address")
            .arg(&record)
            .args(extra)
            .output()
            .unwrap()
    };
    let output = run(&["--ip", "192.0.2.10"]);
    assert!(output.status.success());
    let parsed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        parsed,
        serde_json::json!({"version":1,"id":id.to_string(),"addresses":["192.0.2.10:40000"],"relay":null})
    );
    let qr = run(&["--ip", "192.0.2.10", "--qr"]);
    assert!(qr.status.success());
    let text = String::from_utf8(qr.stdout).unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(text.lines().last().unwrap()).unwrap(),
        parsed
    );
    assert!(text.lines().count() > 10);
    assert!(!run(&["--ip", "192.0.2.99"]).status.success());
    let directory = run(&["--directory", "https://directory.example.com"]);
    assert!(directory.status.success());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&directory.stdout).unwrap(),
        serde_json::json!({"version":1,"id":id.to_string(),"addresses":[],"relay":null,"directory":"https://directory.example.com/"})
    );
    assert!(
        !run(&["--directory", "http://directory.example.com"])
            .status
            .success()
    );
    assert!(
        !run(&[
            "--directory",
            "https://directory.example.com",
            "--ip",
            "192.0.2.10"
        ])
        .status
        .success()
    );
    let wrong_state = root.path().join("other");
    syncstr_headless::peer::Identity::initialize(&wrong_state).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
        .args(["peer-info", "--state"])
        .arg(wrong_state)
        .arg("--address")
        .arg(record)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
}

struct Listener(std::process::Child);
impl Drop for crate::Listener {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn command(state: &std::path::Path) -> std::process::Command {
    let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-connectivity-probe"));
    command.arg("--state").arg(state);
    command
}

fn output(mut command: std::process::Command) -> anyhow::Result<String> {
    let output = command.output()?;
    anyhow::ensure!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

#[test]
fn relay_configuration_is_explicit_and_address_files_cannot_override_it() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let mut init = crate::command(root.path());
    init.arg("init");
    crate::output(init)?;
    let peer = iroh::SecretKey::generate().public();
    let address = root.path().join("address.json");
    std::fs::write(
        &address,
        serde_json::to_vec(&syncstr_connectivity_probe::Address {
            version: 1,
            endpoint: iroh::EndpointAddr::new(peer)
                .with_relay_url("https://unconfigured.invalid".parse()?),
        })?,
    )?;
    let mut probe = crate::command(root.path());
    probe
        .args(["probe", "--peer", &peer.to_string(), "--address"])
        .arg(&address);
    let result = probe.output()?;
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("unconfigured relay"));
    for mode in ["auto", "relay-only"] {
        let mut listen = crate::command(root.path());
        listen
            .args(["listen", "--mode", mode, "--address-out"])
            .arg(root.path().join("out.json"));
        let result = listen.output()?;
        assert!(!result.status.success());
        assert!(String::from_utf8_lossy(&result.stderr).contains("--relay-url is required"));
    }
    Ok(())
}

#[test]
fn real_cli_pairs_probes_rejects_revocation_and_exits_on_sigterm() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let server = root.path().join("server");
    let client = root.path().join("client");
    let mut init_server = crate::command(&server);
    init_server.arg("init");
    let mut init_client = crate::command(&client);
    init_client.arg("init");
    let server_id = crate::output(init_server)?;
    let client_id = crate::output(init_client)?;
    for (state, peer) in [(&server, &client_id), (&client, &server_id)] {
        let mut pair = crate::command(state);
        pair.args(["pair", "--peer", peer]);
        crate::output(pair)?;
    }
    let address = root.path().join("address.json");
    let mut start = crate::command(&server);
    start.arg("listen").arg("--address-out").arg(&address);
    start
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let mut listener = crate::Listener(start.spawn()?);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !address.exists() {
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "listener did not start"
        );
        anyhow::ensure!(listener.0.try_wait()?.is_none(), "listener exited");
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    let mut probe = crate::command(&client);
    probe
        .args(["probe", "--peer", &server_id, "--require-direct"])
        .arg("--address")
        .arg(&address);
    let report: syncstr_connectivity_probe::Report = serde_json::from_str(&crate::output(probe)?)?;
    assert_eq!(report.bytes, 65536);
    assert!(
        report
            .paths_after
            .iter()
            .any(|p| p.selected && p.kind == "direct")
    );
    let mut unpair = crate::command(&server);
    unpair.args(["unpair", "--peer", &client_id]);
    crate::output(unpair)?;
    let mut probe = crate::command(&client);
    probe
        .args(["probe", "--peer", &server_id])
        .arg("--address")
        .arg(&address);
    assert!(!probe.output()?.status.success());
    let status = std::process::Command::new("kill")
        .args(["-TERM", &listener.0.id().to_string()])
        .status()?;
    assert!(status.success());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(status) = listener.0.try_wait()? {
            assert!(status.success());
            break;
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "listener did not stop"
        );
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    Ok(())
}

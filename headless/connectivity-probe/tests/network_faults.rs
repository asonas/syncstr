#![cfg(target_os = "linux")]

#[path = "network_lab/deployment.rs"]
mod deployment;

#[tokio::test]
#[ignore = "Requires the two WAN-isolated network namespaces created by network-lab/run.sh"]
async fn lan_discovery_and_transfer_work_between_nodes_without_wan_routes() -> anyhow::Result<()> {
    anyhow::ensure!(
        std::env::var("SYNCSTR_ISOLATED_NETWORK_LAB").as_deref() == Ok("1"),
        "run only in the disposable network lab"
    );
    let roots = [tempfile::tempdir()?, tempfile::tempdir()?];
    let mut ids = Vec::new();
    for root in &roots {
        ids.push(syncstr_connectivity_probe::Identity::initialize(
            root.path(),
        )?);
    }
    for index in 0..2 {
        syncstr_connectivity_probe::Identity::open(roots[index].path())?.pair(ids[1 - index])?;
    }
    let mut server = tokio::process::Command::new("ip")
        .args([
            "netns",
            "exec",
            "syncstr-lab-a",
            "target/debug/examples/lan_node",
            "serve",
        ])
        .arg(roots[0].path())
        .arg(ids[1].to_string())
        .kill_on_drop(true)
        .spawn()?;
    let client = tokio::time::timeout(
        std::time::Duration::from_secs(40),
        tokio::process::Command::new("ip")
            .args([
                "netns",
                "exec",
                "syncstr-lab-b",
                "target/debug/examples/lan_node",
                "discover",
            ])
            .arg(roots[1].path())
            .arg(ids[0].to_string())
            .kill_on_drop(true)
            .output(),
    )
    .await??;
    anyhow::ensure!(
        client.status.success(),
        "{}",
        String::from_utf8_lossy(&client.stderr)
    );
    let report: serde_json::Value = serde_json::from_slice(&client.stdout)?;
    assert_eq!(report["bytes"], 65536);
    assert_eq!(report["peer_id"], ids[0].to_string());
    println!("WAN-isolated LAN: {report}");
    anyhow::ensure!(
        tokio::time::timeout(std::time::Duration::from_secs(5), server.wait())
            .await??
            .success(),
        "LAN server failed"
    );
    Ok(())
}

#[tokio::test]
#[ignore = "Requires an isolated Linux network namespace with CAP_NET_ADMIN and iptables"]
async fn blocked_udp_falls_back_and_restored_udp_upgrades_the_same_connection() -> anyhow::Result<()>
{
    anyhow::ensure!(
        std::env::var("SYNCSTR_ISOLATED_NETWORK_LAB").as_deref() == Ok("1"),
        "run only in the disposable network lab"
    );
    let roots = [tempfile::tempdir()?, tempfile::tempdir()?];
    for root in &roots {
        syncstr_connectivity_probe::Identity::initialize(root.path())?;
    }
    let server = syncstr_connectivity_probe::Identity::open(roots[0].path())?;
    let client = syncstr_connectivity_probe::Identity::open(roots[1].path())?;
    server.pair(client.id())?;
    client.pair(server.id())?;
    let mut config = iroh_relay::server::ServerConfig::default();
    let mut relay_config = iroh_relay::server::RelayConfig::new(([127, 0, 0, 1], 0));
    relay_config.access = std::sync::Arc::new(crate::Allowed([server.id(), client.id()]));
    config.relay = Some(relay_config);
    let relay = iroh_relay::server::Server::spawn(config).await?;
    let url: iroh::RelayUrl = format!("http://{}", relay.http_addr().unwrap()).parse()?;
    let (acceptor, _server_lock) = server
        .endpoint(syncstr_connectivity_probe::Mode::Auto, Some(url.clone()))
        .await?;
    let (initiator, _client_lock) = client
        .endpoint(syncstr_connectivity_probe::Mode::Auto, Some(url.clone()))
        .await?;
    let receiver = acceptor.clone();
    let serving: tokio::task::JoinHandle<anyhow::Result<()>> = tokio::spawn(async move {
        let connection = receiver.accept().await.unwrap().await?;
        loop {
            syncstr_connectivity_probe::serve_connection(&server, connection.clone()).await?;
        }
    });
    let connection = initiator
        .connect(
            iroh::EndpointAddr::new(acceptor.id()).with_relay_url(url),
            syncstr_connectivity_probe::ALPN,
        )
        .await?;
    crate::wait_for_path(&connection, "direct").await?;
    let mut block = crate::UdpBlock::install()?;
    crate::wait_for_path(&connection, "relay").await?;
    block.verify_dropped_packets()?;
    block.restore()?;
    crate::wait_for_path(&connection, "direct").await?;
    connection.close(0u32.into(), b"complete");
    serving.abort();
    initiator.close().await;
    acceptor.close().await;
    relay.shutdown().await?;
    Ok(())
}

async fn wait_for_path(
    connection: &iroh::endpoint::Connection,
    expected: &str,
) -> anyhow::Result<()> {
    use sha2::Digest as _;
    tokio::time::timeout(std::time::Duration::from_secs(90), async {
        loop {
            let payload: Vec<u8> = (0..65536).map(|i| (i % 251) as u8).collect();
            let (mut send, mut receive) = connection.open_bi().await?;
            send.write_all(&payload).await?;
            send.finish()?;
            let digest = receive.read_to_end(32).await?;
            anyhow::ensure!(hex::encode(&digest) == "4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2", "fixture hash mismatch");
            assert_eq!(digest, sha2::Sha256::digest(&payload).as_slice());
            let paths = syncstr_connectivity_probe::paths(connection);
            if paths.iter().any(|path| path.selected && path.kind == expected) {
                println!("{}", serde_json::json!({"phase":expected,"bytes":payload.len(),"sha256":hex::encode(digest),"paths":paths}));
                return anyhow::Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
    }).await??;
    Ok(())
}

struct UdpBlock(Vec<&'static str>);

impl crate::UdpBlock {
    fn verify_dropped_packets(&self) -> anyhow::Result<()> {
        let mut dropped = 0u64;
        for program in &self.0 {
            let output = std::process::Command::new(program)
                .args(["-w", "-L", "OUTPUT", "-v", "-n", "-x"])
                .output()?;
            anyhow::ensure!(output.status.success(), "could not read lab UDP counters");
            let text = String::from_utf8(output.stdout)?;
            let line = text
                .lines()
                .find(|line| line.contains("syncstr-probe-udp-fault"))
                .ok_or_else(|| anyhow::anyhow!("missing lab UDP rule"))?;
            dropped += line.split_whitespace().next().unwrap().parse::<u64>()?;
        }
        anyhow::ensure!(dropped > 0, "UDP fault did not drop packets");
        println!("UDP packets dropped: {dropped}");
        Ok(())
    }

    fn install() -> anyhow::Result<Self> {
        let mut guard = Self(Vec::new());
        for program in ["iptables", "ip6tables"] {
            crate::firewall(program, "-I")?;
            guard.0.push(program);
        }
        Ok(guard)
    }

    fn restore(&mut self) -> anyhow::Result<()> {
        while let Some(program) = self.0.last() {
            crate::firewall(program, "-D")?;
            self.0.pop();
        }
        Ok(())
    }
}

impl Drop for crate::UdpBlock {
    fn drop(&mut self) {
        if let Err(error) = self.restore() {
            eprintln!("failed to remove lab UDP rule: {error:#}");
        }
    }
}

fn firewall(program: &str, operation: &str) -> anyhow::Result<()> {
    let output = std::process::Command::new(program)
        .args([
            "-w",
            operation,
            "OUTPUT",
            "-p",
            "udp",
            "-m",
            "comment",
            "--comment",
            "syncstr-probe-udp-fault",
            "-j",
            "DROP",
        ])
        .output()?;
    anyhow::ensure!(
        output.status.success(),
        "{program}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

#[derive(Debug)]
struct Allowed([iroh::EndpointId; 2]);

impl iroh_relay::server::AccessControl for crate::Allowed {
    async fn on_connect(
        &self,
        request: &iroh_relay::server::ClientRequest,
    ) -> iroh_relay::server::Access {
        if self.0.contains(&request.endpoint_id()) {
            iroh_relay::server::Access::Allow
        } else {
            iroh_relay::server::Access::Deny { reason: None }
        }
    }
}

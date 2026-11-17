#![cfg(feature = "p2p")]

#[tokio::test]
#[ignore = "Requires a LAN interface and multicast permission; run on the Windows validation host"]
async fn advertised_host_resolves_without_an_explicit_address() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    syncstr_headless::peer::Identity::initialize(root.path())?;
    let identity = syncstr_headless::peer::Identity::open(root.path())?;
    let mut host = HostProcess(
        std::process::Command::new(std::env::current_exe()?)
            .args([
                "--ignored",
                "--exact",
                "advertising_host_process",
                "--nocapture",
            ])
            .env("SYNCSTR_DISCOVERY_TEST_ROOT", root.path())
            .spawn()?,
    );
    let start = std::time::Instant::now();
    while !root.path().join("ready").exists() {
        anyhow::ensure!(
            host.0.try_wait()?.is_none(),
            "Advertising subprocess exited before readiness"
        );
        anyhow::ensure!(
            start.elapsed() < std::time::Duration::from_secs(10),
            "Advertising subprocess did not become ready"
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let browser = syncstr_headless::cluster_discovery::Discovery::browse()?;
    let result = tokio::time::timeout(std::time::Duration::from_secs(6), async {
        loop {
            let address = browser.next().await?;
            if address.id == identity.id() {
                anyhow::ensure!(
                    address.ip_addrs().next().is_some(),
                    "Discovered host has no socket address"
                );
                return anyhow::Ok(());
            }
        }
    })
    .await;
    drop(browser);
    drop(host);
    result.map_err(|_| {
        anyhow::anyhow!("LAN discovery did not resolve the advertised host in six seconds")
    })??;
    Ok(())
}

struct HostProcess(std::process::Child);
impl Drop for HostProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
#[ignore = "Subprocess entry point for the real LAN discovery test"]
async fn advertising_host_process() -> anyhow::Result<()> {
    let Some(root) = std::env::var_os("SYNCSTR_DISCOVERY_TEST_ROOT") else {
        return Ok(());
    };
    let root = std::path::PathBuf::from(root);
    let identity = syncstr_headless::peer::Identity::open(&root)?;
    let (endpoint, _lock) = identity.cluster_endpoint(&["0.0.0.0:0".parse()?]).await?;
    let _advertiser = syncstr_headless::cluster_discovery::Discovery::start(&endpoint)?;
    std::fs::write(root.join("ready"), b"ready")?;
    std::future::pending::<()>().await;
    Ok(())
}

#[derive(clap::Parser)]
#[command(about = "Experimental Syncstr device pairing and QUIC connectivity probe")]
struct Cli {
    #[arg(long)]
    state: std::path::PathBuf,
    #[command(subcommand)]
    command: crate::Command,
}

#[derive(clap::Subcommand)]
enum Command {
    Init,
    Id,
    Pair {
        #[arg(long)]
        peer: iroh::EndpointId,
    },
    Unpair {
        #[arg(long)]
        peer: iroh::EndpointId,
    },
    Listen {
        #[arg(long)]
        address_out: std::path::PathBuf,
        #[arg(long, value_enum, default_value = "direct")]
        mode: syncstr_connectivity_probe::Mode,
        #[arg(long)]
        relay_url: Option<iroh::RelayUrl>,
    },
    Probe {
        #[arg(long)]
        address: Option<std::path::PathBuf>,
        #[arg(long)]
        peer: iroh::EndpointId,
        #[arg(long, value_enum, default_value = "direct")]
        mode: syncstr_connectivity_probe::Mode,
        #[arg(long)]
        relay_url: Option<iroh::RelayUrl>,
        #[arg(long)]
        require_direct: bool,
    },
}

#[tokio::main]
async fn main() {
    use clap::Parser as _;
    if let Err(error) = crate::run(crate::Cli::parse()).await {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

async fn run(cli: crate::Cli) -> anyhow::Result<()> {
    if matches!(cli.command, crate::Command::Init) {
        println!(
            "{}",
            syncstr_connectivity_probe::Identity::initialize(&cli.state)?
        );
        return Ok(());
    }
    let identity = syncstr_connectivity_probe::Identity::open(&cli.state)?;
    match cli.command {
        crate::Command::Init => unreachable!(),
        crate::Command::Id => println!("{}", identity.id()),
        crate::Command::Pair { peer } => identity.pair(peer)?,
        crate::Command::Unpair { peer } => identity.unpair(peer)?,
        crate::Command::Listen {
            address_out,
            mode,
            relay_url,
        } => {
            let (endpoint, _lock) = identity.endpoint(mode, relay_url).await?;
            syncstr_connectivity_probe::Address::write(&endpoint, &address_out)?;
            eprintln!("Listening as {}", endpoint.id());
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
            loop {
                let incoming = tokio::select! {
                    value = endpoint.accept() => value,
                    _ = tokio::signal::ctrl_c() => break,
                    _ = terminate.recv() => break,
                };
                let Some(incoming) = incoming else { break };
                let result = tokio::time::timeout(std::time::Duration::from_secs(20), async {
                    let connection = incoming.await?;
                    syncstr_connectivity_probe::serve_connection(&identity, connection).await
                })
                .await;
                if !matches!(result, Ok(Ok(()))) {
                    eprintln!("Probe rejected or failed: {result:?}");
                }
            }
            endpoint.close().await;
        }
        crate::Command::Probe {
            address,
            peer,
            mode,
            relay_url,
            require_direct,
        } => {
            let address = match address {
                Some(path) => syncstr_connectivity_probe::Address::read(&path, peer)?,
                None => syncstr_connectivity_probe::Address {
                    version: 1,
                    endpoint: iroh::EndpointAddr::new(peer).with_relay_url(
                        relay_url.clone().ok_or_else(|| {
                            anyhow::anyhow!("--address or --relay-url is required")
                        })?,
                    ),
                },
            };
            anyhow::ensure!(
                address
                    .endpoint
                    .relay_urls()
                    .all(|url| Some(url) == relay_url.as_ref()),
                "address contains an unconfigured relay"
            );
            anyhow::ensure!(
                !(mode == syncstr_connectivity_probe::Mode::RelayOnly && require_direct),
                "relay-only conflicts with --require-direct"
            );
            let (endpoint, _lock) = identity.endpoint(mode, relay_url).await?;
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(45),
                syncstr_connectivity_probe::probe(&identity, &endpoint, address, require_direct),
            )
            .await;
            endpoint.close().await;
            println!("{}", serde_json::to_string(&result??)?);
        }
    }
    Ok(())
}

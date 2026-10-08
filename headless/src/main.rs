#[derive(clap::Parser)]
#[command(version, about = "Headless Syncstr node and HTTPS client")]
struct Cli {
    #[command(subcommand)]
    command: crate::Command,
}

#[derive(clap::Subcommand)]
enum Command {
    Init {
        #[arg(long, default_value = "identity")]
        identity: std::path::PathBuf,
        #[arg(long, default_value = "localhost")]
        host: String,
    },
    Serve {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long, default_value = "identity")]
        identity: std::path::PathBuf,
        #[arg(long, default_value = "127.0.0.1:8443")]
        listen: std::net::SocketAddr,
        #[cfg(feature = "p2p")]
        #[arg(long, requires = "peer_address_out")]
        peer_state: Option<std::path::PathBuf>,
        #[cfg(feature = "p2p")]
        #[arg(long, requires = "peer_state")]
        peer_address_out: Option<std::path::PathBuf>,
        #[cfg(feature = "p2p")]
        #[arg(long, value_enum, default_value = "direct")]
        peer_mode: syncstr_headless::peer::Mode,
    },
    Catalog {
        #[command(flatten)]
        connection: crate::Connection,
    },
    Upload {
        #[command(flatten)]
        connection: crate::Connection,
        #[arg(long)]
        file: std::path::PathBuf,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        artist: Option<String>,
        #[arg(long)]
        album: Option<String>,
    },
    Download {
        #[command(flatten)]
        connection: crate::Connection,
        #[arg(long)]
        id: String,
        #[arg(long)]
        output: std::path::PathBuf,
    },
    #[cfg(feature = "p2p")]
    PeerInit {
        #[arg(long)]
        state: std::path::PathBuf,
    },
    #[cfg(feature = "p2p")]
    PeerInfo {
        #[arg(long)]
        state: std::path::PathBuf,
        #[arg(long)]
        address: std::path::PathBuf,
        #[arg(long)]
        ip: Option<std::net::IpAddr>,
        #[arg(long)]
        qr: bool,
    },
    #[cfg(feature = "p2p")]
    PeerPair {
        #[arg(long)]
        state: std::path::PathBuf,
        #[arg(long)]
        peer: iroh::EndpointId,
        #[arg(long)]
        revoke: bool,
    },
}

#[derive(clap::Args)]
struct Connection {
    #[arg(long, default_value = "https://localhost:8443")]
    url: String,
    #[arg(long, default_value = "identity/tls.crt")]
    cert: std::path::PathBuf,
    #[arg(long, default_value = "identity/token")]
    token_file: std::path::PathBuf,
}

impl crate::Connection {
    fn client(&self) -> anyhow::Result<syncstr_headless::client::Client> {
        syncstr_headless::client::Client::new(&self.url, &self.cert, &self.token_file)
    }
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
    match cli.command {
        crate::Command::Init { identity, host } => {
            syncstr_headless::identity::initialize(&identity, &host)?;
            println!(
                "Created tls.crt, tls.key, and token in {}",
                identity.display()
            );
        }
        crate::Command::Serve {
            data,
            identity,
            listen,
            #[cfg(feature = "p2p")]
            peer_state,
            #[cfg(feature = "p2p")]
            peer_address_out,
            #[cfg(feature = "p2p")]
            peer_mode,
        } => {
            let token = syncstr_headless::identity::token(&identity.join("token"))?;
            let tls = syncstr_headless::identity::tls(&identity).await?;
            let store = syncstr_headless::store::Store::open(&data)?;
            #[cfg(feature = "p2p")]
            let peer = if let Some(state) = peer_state {
                let identity = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&state)?);
                let (endpoint, lock) = identity.endpoint(peer_mode).await?;
                syncstr_headless::peer::Address::write(&endpoint, &peer_address_out.unwrap())?;
                let task = tokio::spawn(syncstr_headless::peer::serve(
                    identity,
                    endpoint.clone(),
                    store.clone(),
                ));
                Some((endpoint, lock, task))
            } else {
                None
            };
            let listener = std::net::TcpListener::bind(listen)?;
            listener.set_nonblocking(true)?;
            println!("Listening on https://{}", listener.local_addr()?);
            let handle = axum_server::Handle::new();
            let shutdown = handle.clone();
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
            tokio::spawn(async move {
                tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
                shutdown.graceful_shutdown(Some(std::time::Duration::from_secs(30)));
            });
            let mut server = axum_server::from_tcp_rustls(listener, tls)?.handle(handle);
            server
                .http_builder()
                .http1()
                .timer(hyper_util::rt::TokioTimer::new())
                .header_read_timeout(std::time::Duration::from_secs(10))
                .max_buf_size(16384);
            server
                .serve(syncstr_headless::api::router(store, &token).into_make_service())
                .await?;
            #[cfg(feature = "p2p")]
            if let Some((endpoint, _lock, task)) = peer {
                endpoint.close().await;
                task.await?;
            }
        }
        crate::Command::Catalog { connection } => {
            println!(
                "{}",
                serde_json::to_string(&connection.client()?.catalog().await?)?
            );
        }
        crate::Command::Upload {
            connection,
            file,
            title,
            artist,
            album,
        } => {
            println!(
                "{}",
                serde_json::to_string(
                    &connection
                        .client()?
                        .upload(&file, title, artist, album)
                        .await?
                )?
            );
        }
        crate::Command::Download {
            connection,
            id,
            output,
        } => {
            connection.client()?.download(&id, &output).await?;
        }
        #[cfg(feature = "p2p")]
        crate::Command::PeerInit { state } => {
            println!("{}", syncstr_headless::peer::Identity::initialize(&state)?);
        }
        #[cfg(feature = "p2p")]
        crate::Command::PeerInfo {
            state,
            address,
            ip,
            qr,
        } => {
            let identity = syncstr_headless::peer::Identity::open(&state)?;
            let mut address = syncstr_headless::peer::Address::read(&address, identity.id())?;
            if let Some(ip) = ip {
                address.addresses.retain(|value| value.ip() == ip);
                anyhow::ensure!(
                    !address.addresses.is_empty(),
                    "IP is not in the node's address record"
                );
            }
            anyhow::ensure!(
                address.addresses.len() <= 32,
                "too many addresses; select a reachable IP with --ip"
            );
            anyhow::ensure!(
                !address.addresses.is_empty() || address.relay.is_some(),
                "no reachable address"
            );
            let text = serde_json::to_string(&address)?;
            if qr {
                let code = qrcode::QrCode::new(text.as_bytes())?;
                println!(
                    "{}",
                    code.render::<qrcode::render::unicode::Dense1x2>()
                        .dark_color(qrcode::render::unicode::Dense1x2::Light)
                        .light_color(qrcode::render::unicode::Dense1x2::Dark)
                        .build()
                );
            }
            println!("{text}");
        }
        #[cfg(feature = "p2p")]
        crate::Command::PeerPair {
            state,
            peer,
            revoke,
        } => {
            let identity = syncstr_headless::peer::Identity::open(&state)?;
            if revoke {
                identity.unpair(peer)?;
            } else {
                identity.pair(peer)?;
            }
        }
    }
    Ok(())
}

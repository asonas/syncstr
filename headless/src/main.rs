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
        } => {
            let token = syncstr_headless::identity::token(&identity.join("token"))?;
            let tls = syncstr_headless::identity::tls(&identity).await?;
            let store = syncstr_headless::store::Store::open(&data)?;
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
    }
    Ok(())
}

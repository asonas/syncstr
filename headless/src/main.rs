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
        #[cfg(feature = "p2p")]
        #[arg(
            long,
            requires = "peer_state",
            help = "Fixed UDP listen address for P2P; repeat for IPv4 and IPv6"
        )]
        peer_listen: Vec<std::net::SocketAddr>,
        #[cfg(feature = "p2p")]
        #[arg(long, requires = "peer_state")]
        peer_directory: Option<String>,
        #[cfg(feature = "p2p")]
        #[arg(long, requires = "peer_directory")]
        peer_public_address: Option<std::net::SocketAddr>,
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
    ClusterInit {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
    },
    #[cfg(feature = "p2p")]
    ClusterInvite {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
        #[arg(long)]
        library_host: bool,
        #[arg(long, default_value = "600")]
        expires: u64,
        #[arg(long)]
        output: std::path::PathBuf,
        #[arg(long)]
        qr: bool,
    },
    #[cfg(feature = "p2p")]
    ClusterServe {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
    },
    #[cfg(feature = "p2p")]
    ClusterImport {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
        #[arg(long)]
        entry: std::path::PathBuf,
        #[arg(long)]
        organization: Option<std::path::PathBuf>,
        #[arg(long)]
        file: std::path::PathBuf,
        #[arg(long)]
        restore: bool,
    },
    #[cfg(feature = "p2p")]
    ClusterDelete {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
        #[arg(long)]
        object: String,
    },
    #[cfg(feature = "p2p")]
    ClusterResolve {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
        #[arg(long)]
        object: String,
        #[arg(long)]
        selected: String,
    },
    #[cfg(feature = "p2p")]
    ClusterStatus {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
    },
    #[cfg(feature = "p2p")]
    ClusterJoin {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
        #[arg(long)]
        invitation: std::path::PathBuf,
    },
    #[cfg(feature = "p2p")]
    ClusterRevoke {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
        #[arg(long)]
        peer_state: std::path::PathBuf,
        #[arg(long)]
        member: String,
    },
    ClusterInfo {
        #[arg(long, default_value = "data")]
        data: std::path::PathBuf,
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
        #[arg(long, conflicts_with = "ip")]
        directory: Option<String>,
    },
    #[cfg(feature = "p2p")]
    PeerResolve {
        #[arg(long)]
        state: std::path::PathBuf,
        #[arg(long)]
        directory: String,
        #[arg(long)]
        peer: iroh::EndpointId,
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
            #[cfg(feature = "p2p")]
            peer_listen,
            #[cfg(feature = "p2p")]
            peer_directory,
            #[cfg(feature = "p2p")]
            peer_public_address,
        } => {
            let token = syncstr_headless::identity::token(&identity.join("token"))?;
            let tls = syncstr_headless::identity::tls(&identity).await?;
            let store = syncstr_headless::store::Store::open(&data)?;
            #[cfg(feature = "p2p")]
            let peer = if let Some(state) = peer_state {
                let identity = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&state)?);
                if state.join("peers").is_dir() {
                    let known = store.cluster_inventory().await?.peers;
                    for peer in identity.allowed_peers()? {
                        if known.iter().any(|saved| saved.id == peer.to_string()) {
                            continue;
                        }
                        store
                            .remember_cluster_peer(syncstr_headless::cluster::KnownPeer {
                                id: peer.to_string(),
                                name: "Legacy peer".into(),
                                address: None,
                            })
                            .await?;
                    }
                }
                let (endpoint, lock) = identity.endpoint(peer_mode, &peer_listen).await?;
                let publisher = if let Some(directory) = peer_directory {
                    anyhow::ensure!(
                        peer_mode == syncstr_headless::peer::Mode::Direct,
                        "Directory currently supports direct-only nodes"
                    );
                    let origin = syncstr_headless::rendezvous::service(&directory)?;
                    if syncstr_headless::rendezvous::publish(
                        &identity,
                        &endpoint,
                        &origin,
                        &peer_listen,
                        peer_public_address,
                    )
                    .await
                    .is_err()
                    {
                        eprintln!("Directory announcement failed; direct P2P remains available");
                    }
                    let identity = identity.clone();
                    let endpoint = endpoint.clone();
                    Some(tokio::spawn(async move {
                        let mut interval =
                            tokio::time::interval(std::time::Duration::from_secs(60));
                        interval.tick().await;
                        loop {
                            interval.tick().await;
                            if syncstr_headless::rendezvous::publish(
                                &identity,
                                &endpoint,
                                &origin,
                                &peer_listen,
                                peer_public_address,
                            )
                            .await
                            .is_err()
                            {
                                eprintln!(
                                    "Directory announcement failed; direct P2P remains available"
                                );
                            }
                        }
                    }))
                } else {
                    None
                };
                syncstr_headless::peer::Address::write(&endpoint, &peer_address_out.unwrap())?;
                let task = tokio::spawn(syncstr_headless::peer::serve(
                    identity,
                    endpoint.clone(),
                    store.clone(),
                ));
                Some((endpoint, lock, task, publisher))
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
            if let Some((endpoint, _lock, task, publisher)) = peer {
                if let Some(publisher) = publisher {
                    publisher.abort();
                }
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
        crate::Command::ClusterInit { data, peer_state } => {
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            println!(
                "{}",
                serde_json::to_string(&store.create_cluster(identity.id().to_string()).await?)?
            );
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterInvite {
            data,
            peer_state,
            library_host,
            expires,
            output,
            qr,
        } => {
            use std::io::Write as _;
            use std::os::unix::fs::OpenOptionsExt as _;
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            let invite = store
                .create_cluster_invitation(
                    &identity,
                    library_host,
                    syncstr_headless::rendezvous::now()? / 1000,
                    expires,
                )
                .await?;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&output)?;
            file.write_all(&serde_json::to_vec(&invite)?)?;
            file.sync_all()?;
            std::fs::File::open(
                output
                    .parent()
                    .filter(|parent| !parent.as_os_str().is_empty())
                    .unwrap_or(std::path::Path::new(".")),
            )?
            .sync_all()?;
            println!("Invitation written to {}", output.display());
            if qr {
                let code = qrcode::QrCode::new(serde_json::to_vec(&invite)?)?;
                println!("{}", code.render::<qrcode::render::unicode::Dense1x2>()
                    .dark_color(qrcode::render::unicode::Dense1x2::Light)
                    .light_color(qrcode::render::unicode::Dense1x2::Dark)
                    .build());
            }
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterServe { data, peer_state } => {
            let identity =
                std::sync::Arc::new(syncstr_headless::peer::Identity::open(&peer_state)?);
            let store = syncstr_headless::store::Store::open(&data)?;
            let (endpoint, _lock) = identity.cluster_endpoint(&[]).await?;
            let discovery = syncstr_headless::cluster_discovery::Discovery::start(&endpoint)?;
            println!("Cluster LAN endpoint {}", identity.id());
            let task = tokio::spawn(syncstr_headless::cluster_net::serve(
                identity.clone(),
                endpoint.clone(),
                store.clone(),
            ));
            let mut replication = tokio::spawn(syncstr_headless::cluster_sync::run_lan(identity, endpoint.clone(), store, discovery));
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
            tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {}, result = &mut replication => { result??; } }
            replication.abort();
            endpoint.close().await;
            task.await?;
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterImport { data, peer_state, entry, organization, file, restore } => {
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            let entry = serde_json::from_slice(&std::fs::read(entry)?)?;
            let organization = organization.map(std::fs::read).transpose()?.map(|bytes| serde_json::from_slice(&bytes)).transpose()?;
            store.import_cluster_file(&identity, entry, organization, &file, restore).await?;
            println!("Audio verified and stored");
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterDelete { data, peer_state, object } => {
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            let record = store.publish_cluster_change(&identity, object, syncstr_headless::cluster_changes::Action::Delete).await?;
            store.project_cluster_metadata(record.object.clone()).await?;
            println!("{}", serde_json::to_string_pretty(&record)?);
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterResolve { data, peer_state, object, selected } => {
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            let record = store.publish_cluster_change(&identity, object, syncstr_headless::cluster_changes::Action::Resolve { selected }).await?;
            println!("{}", serde_json::to_string_pretty(&record)?);
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterStatus { data } => {
            let store = syncstr_headless::store::Store::open(&data)?;
            println!("{}", serde_json::to_string_pretty(&serde_json::json!({ "objects": store.cluster_object_states().await?, "receipts": store.cluster_receipts().await?, "jobs": store.cluster_jobs().await?, "membershipConflicts": store.cluster_membership_proof().await?.membership_conflicts()? }))?);
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterJoin {
            data,
            peer_state,
            invitation,
        } => {
            use std::io::Read as _;
            let mut bytes = Vec::new();
            std::fs::File::open(invitation)?
                .take(16385)
                .read_to_end(&mut bytes)?;
            anyhow::ensure!(bytes.len() <= 16384, "invitation too large");
            let invite: syncstr_headless::enrollment::Invitation = serde_json::from_slice(&bytes)?;
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            let (endpoint, _lock) = identity.cluster_endpoint(&[]).await?;
            let discovery = syncstr_headless::cluster_discovery::Discovery::start(&endpoint)?;
            let result = tokio::time::timeout(std::time::Duration::from_secs(30), async {
                loop {
                    let address = discovery.next().await?;
                    if address.id.to_string() != invite.host {
                        continue;
                    }
                    break syncstr_headless::cluster_net::enroll(
                        &identity, &endpoint, address, &invite, &store,
                    )
                    .await;
                }
            })
            .await;
            endpoint.close().await;
            result??;
            println!("Joined cluster {}", invite.cluster);
        }
        #[cfg(feature = "p2p")]
        crate::Command::ClusterRevoke {
            data,
            peer_state,
            member,
        } => {
            let identity = syncstr_headless::peer::Identity::open(&peer_state)?;
            let store = syncstr_headless::store::Store::open(&data)?;
            println!(
                "{}",
                serde_json::to_string(&store.revoke_cluster_member(&identity, member).await?)?
            );
        }
        crate::Command::ClusterInfo { data } => {
            let store = syncstr_headless::store::Store::open(&data)?;
            println!(
                "{}",
                serde_json::to_string(&store.cluster_inventory().await?)?
            );
        }
        #[cfg(feature = "p2p")]
        crate::Command::PeerInfo {
            state,
            address,
            ip,
            qr,
            directory,
        } => {
            let identity = syncstr_headless::peer::Identity::open(&state)?;
            let mut address = syncstr_headless::peer::Address::read(&address, identity.id())?;
            if let Some(directory) = directory {
                address.directory =
                    Some(syncstr_headless::rendezvous::service(&directory)?.to_string());
                address.addresses.clear();
                address.relay = None;
            }
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
                !address.addresses.is_empty()
                    || address.relay.is_some()
                    || address.directory.is_some(),
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
        crate::Command::PeerResolve {
            state,
            directory,
            peer,
        } => {
            let identity = syncstr_headless::peer::Identity::open(&state)?;
            let origin = syncstr_headless::rendezvous::service(&directory)?;
            println!(
                "{}",
                serde_json::to_string(
                    &syncstr_headless::rendezvous::resolve(&identity, &origin, peer).await?
                )?
            );
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

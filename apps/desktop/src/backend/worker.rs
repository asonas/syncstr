pub fn run(
    config: super::configuration::Config,
    commands: std::sync::mpsc::Receiver<super::Command>,
    events: std::sync::mpsc::Sender<super::Event>,
    active: super::Active,
    audio: std::sync::mpsc::Sender<super::audio::Command>,
    generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
) -> anyhow::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    if let Some(source) = &config.copy_from {
        runtime.block_on(crate::profile::copy_win32(source, &config.root))?;
    }
    std::fs::create_dir_all(&config.root)?;
    let mut client = if config.root.join("node.sqlite").exists() {
        Some(syncstr_headless::catalog_client::Client::open(
            &config.root,
        )?)
    } else {
        None
    };
    let mut hosts: Vec<super::Host> = config.host.into_iter().collect();
    let mut selected = hosts.first().map(|h| h.member.clone());
    let _ = events.send(super::Event::Hosts(hosts.clone(), selected.clone()));
    if let Some(client) = &client {
        snapshot(client, &events)?;
    } else {
        let _ = events.send(super::Event::Message(
            "Discover and select a host, then enroll using an invitation copied to the clipboard."
                .into(),
        ));
    }
    for command in commands {
        if matches!(command, super::Command::Shutdown) {
            break;
        }
        let operation = syncstr_headless::catalog_client::Operation::default();
        *active.lock().expect("active operation") = Some(operation.clone());
        let _ = events.send(super::Event::Busy(true));
        let result: anyhow::Result<()> = runtime.block_on(async {
            match command {
                super::Command::Discover => {
                    let discovery = syncstr_headless::cluster_discovery::Discovery::browse()?;
                    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
                    while let Ok(Ok(address)) =
                        tokio::time::timeout_at(deadline, discovery.next()).await
                    {
                        if let Some(socket) = address.ip_addrs().next() {
                            let member = address.id.to_string();
                            hosts.retain(|h| h.member != member);
                            hosts.push(super::Host {
                                member,
                                socket: *socket,
                            });
                        }
                    }
                    let _ = events.send(super::Event::Hosts(hosts.clone(), selected.clone()));
                    let _ = events.send(super::Event::Message(format!(
                        "{} host(s) discovered. Select the intended host before connecting.",
                        hosts.len()
                    )));
                }
                super::Command::SelectHost(member) => {
                    anyhow::ensure!(hosts.iter().any(|h| h.member == member), "Unknown host");
                    selected = Some(member);
                    let _ = events.send(super::Event::Hosts(hosts.clone(), selected.clone()));
                }
                super::Command::Enroll(invitation) => {
                    anyhow::ensure!(client.is_none(), "This profile is already enrolled");
                    let host = selected_host(&hosts, &selected)?;
                    let parsed: syncstr_headless::enrollment::Invitation =
                        serde_json::from_str(&invitation)?;
                    anyhow::ensure!(
                        parsed.host == host.member,
                        "The invitation does not match the selected host"
                    );
                    let secret = crate::windows_identity::load(&config.root, true)?;
                    let legacy = syncstr_headless::cluster_client::PlaybackClient::open(
                        &config.root,
                        secret,
                    )?;
                    legacy.enroll(&invitation, host.socket).await?;
                    drop(legacy);
                    client = Some(syncstr_headless::catalog_client::Client::open(
                        &config.root,
                    )?);
                    let core = client.as_mut().expect("enrolled client");
                    core.refresh(&host.core(), secret, &operation).await?;
                }
                super::Command::Refresh => {
                    let core = client
                        .as_mut()
                        .ok_or_else(|| anyhow::anyhow!("Enroll this profile first"))?;
                    let host = selected_host(&hosts, &selected)?;
                    core.refresh(
                        &host.core(),
                        crate::windows_identity::load(&config.root, false)?,
                        &operation,
                    )
                    .await?;
                    let pending = crate::profile::restore_saves(&config.root, core)?;
                    if pending > 0 {
                        let _ = events.send(super::Event::Message(format!(
                            "{pending} original save(s) await their exact catalog records."
                        )));
                    }
                    core.policy()
                        .update(syncstr_headless::catalog_client::TransferPolicy {
                            online: true,
                            ..Default::default()
                        });
                    for job in core.save_jobs()? {
                        if matches!(
                            job.state,
                            syncstr_headless::catalog_client::SaveState::Waiting
                                | syncstr_headless::catalog_client::SaveState::Partial
                        ) {
                            core.run_save(
                                &job.id,
                                &[host.core()],
                                crate::windows_identity::load(&config.root, false).ok(),
                                &operation,
                            )
                            .await?;
                        }
                    }
                }
                super::Command::Play(track, request) => {
                    if request != generation.load(std::sync::atomic::Ordering::Acquire) {
                        return Ok(());
                    }
                    let core = client
                        .as_mut()
                        .ok_or_else(|| anyhow::anyhow!("Enroll this profile first"))?;
                    core.policy()
                        .update(syncstr_headless::catalog_client::TransferPolicy {
                            online: true,
                            ..Default::default()
                        });
                    let sources: Vec<_> = hosts
                        .iter()
                        .filter(|h| Some(&h.member) == selected.as_ref())
                        .map(super::Host::core)
                        .collect();
                    let asset = core
                        .prepare_playback(
                            &track.logical_id,
                            track.hash.as_deref(),
                            &sources,
                            crate::windows_identity::load(&config.root, false).ok(),
                            &operation,
                        )
                        .await?;
                    audio.send(super::audio::Command::Play {
                        track,
                        asset,
                        generation: request,
                    })?;
                }
                super::Command::Save(track) => {
                    let core = client
                        .as_mut()
                        .ok_or_else(|| anyhow::anyhow!("Enroll this profile first"))?;
                    let pin = pin(&track)?;
                    let job = core.save_tracks(&[pin])?;
                    let sources: Vec<_> = hosts
                        .iter()
                        .filter(|h| Some(&h.member) == selected.as_ref())
                        .map(super::Host::core)
                        .collect();
                    core.policy()
                        .update(syncstr_headless::catalog_client::TransferPolicy {
                            online: true,
                            ..Default::default()
                        });
                    let job = core
                        .run_save(
                            &job.id,
                            &sources,
                            crate::windows_identity::load(&config.root, false).ok(),
                            &operation,
                        )
                        .await?;
                    anyhow::ensure!(
                        job.state == syncstr_headless::catalog_client::SaveState::Complete,
                        "Save is {:?}; Refresh retries pending items",
                        job.state
                    );
                }
                super::Command::Remove(track) => {
                    client
                        .as_mut()
                        .ok_or_else(|| anyhow::anyhow!("Enroll this profile first"))?
                        .remove_save(&pin(&track)?)?;
                }
                super::Command::Shutdown => unreachable!(),
            }
            Ok(())
        });
        *active.lock().expect("active operation") = None;
        if let Some(core) = &client
            && let Err(error) = snapshot(core, &events)
        {
            let _ = events.send(super::Event::Message(error.to_string()));
        }
        if let Err(error) = result {
            let _ = events.send(super::Event::Message(error.to_string()));
        }
        let _ = events.send(super::Event::Busy(false));
    }
    let (stopped, acknowledge) = std::sync::mpsc::channel();
    if audio
        .send(super::audio::Command::Stop(Some(stopped)))
        .is_ok()
    {
        let _ = acknowledge.recv();
    }
    if let Some(mut core) = client {
        runtime.block_on(core.shutdown())?;
    }
    Ok(())
}

fn selected_host<'a>(
    hosts: &'a [super::Host],
    selected: &Option<String>,
) -> anyhow::Result<&'a super::Host> {
    hosts
        .iter()
        .find(|h| Some(&h.member) == selected.as_ref())
        .ok_or_else(|| anyhow::anyhow!("Select a host first"))
}
fn pin(
    track: &crate::model::Track,
) -> anyhow::Result<syncstr_headless::catalog_client::ExactTrack> {
    Ok(syncstr_headless::catalog_client::ExactTrack {
        track_id: track.logical_id.clone(),
        sha256: track
            .hash
            .clone()
            .ok_or_else(|| anyhow::anyhow!("This entry has no available exact audio version"))?,
    })
}
fn snapshot(
    client: &syncstr_headless::catalog_client::Client,
    events: &std::sync::mpsc::Sender<super::Event>,
) -> anyhow::Result<()> {
    let view = client.catalog()?;
    let saved = client.saved_tracks()?;
    let tracks = super::rows(&view, &saved);
    let playlists = view
        .playlists
        .values()
        .map(|playlist| {
            let rows = playlist
                .items
                .iter()
                .map(|item| {
                    let resolved = item.pin.as_ref().and_then(|pin| view.exact_track(pin));
                    crate::model::Track {
                        id: format!("{}:{}", playlist.id, item.id),
                        logical_id: item
                            .pin
                            .as_ref()
                            .map(|p| p.track_id.clone())
                            .unwrap_or_else(|| item.source_track.clone()),
                        hash: item.pin.as_ref().map(|p| p.sha256.clone()),
                        title: item.title.clone(),
                        artist: item
                            .artist
                            .clone()
                            .or_else(|| resolved.and_then(|track| track.artist.clone()))
                            .unwrap_or_default(),
                        album: item
                            .album
                            .clone()
                            .or_else(|| resolved.map(|track| track.album.clone()))
                            .unwrap_or_default(),
                        available: item
                            .pin
                            .as_ref()
                            .and_then(|p| view.audio_bytes(p))
                            .is_some(),
                        saved: item.pin.as_ref().is_some_and(|p| {
                            saved.iter().any(|saved| {
                                saved.sha256 == p.sha256
                                    && saved.track_id
                                        == *view.aliases.get(&p.track_id).unwrap_or(&p.track_id)
                            })
                        }),
                    }
                })
                .collect();
            (playlist.id.clone(), playlist.name.clone(), rows)
        })
        .collect();
    let pending = client
        .save_jobs()?
        .iter()
        .filter(|j| {
            matches!(
                j.state,
                syncstr_headless::catalog_client::SaveState::Waiting
                    | syncstr_headless::catalog_client::SaveState::Partial
            )
        })
        .count();
    let message = format!(
        "{} tracks · {} saved versions · {pending} pending saves (Refresh to retry) · {} incomplete records",
        tracks.len(),
        saved.len(),
        view.incomplete_records.len()
    );
    let _ = events.send(super::Event::Library {
        tracks,
        playlists,
        message,
    });
    Ok(())
}

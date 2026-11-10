pub enum Command {
    Play {
        track: crate::model::Track,
        asset: syncstr_headless::catalog_client::VerifiedAudio,
        generation: u64,
    },
    Pause,
    Resume,
    Stop(Option<std::sync::mpsc::Sender<()>>),
    Shutdown,
}

pub fn start(
    events: std::sync::mpsc::Sender<super::Event>,
    generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    muted: bool,
) -> (
    std::sync::mpsc::Sender<Command>,
    std::thread::JoinHandle<()>,
) {
    let (send, receive) = std::sync::mpsc::channel();
    let join = std::thread::spawn(move || {
        let result = run(receive, events.clone(), generation, muted);
        if let Err(error) = result {
            let _ = events.send(super::Event::Message(format!("Windows audio: {error}")));
        }
    });
    (send, join)
}

fn run(
    receive: std::sync::mpsc::Receiver<Command>,
    events: std::sync::mpsc::Sender<super::Event>,
    generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    muted: bool,
) -> anyhow::Result<()> {
    let mut player = crate::windows_player::Player::new(muted)?;
    let mut current: Option<crate::model::Track> = None;
    loop {
        match receive.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(Command::Play {
                track,
                asset,
                generation: request,
            }) => {
                if request != generation.load(std::sync::atomic::Ordering::Acquire) {
                    continue;
                }
                match player.play(asset) {
                    Ok(()) => current = Some(track),
                    Err(error) => {
                        let _ =
                            events.send(super::Event::Message(format!("Playback failed: {error}")));
                    }
                }
            }
            Ok(Command::Pause) => player.pause()?,
            Ok(Command::Resume) => player.resume()?,
            Ok(Command::Stop(ack)) => {
                player.stop()?;
                current = None;
                if let Some(ack) = ack {
                    let _ = ack.send(());
                }
                let _ = events.send(super::Event::Playback {
                    key: String::new(),
                    title: String::new(),
                    playing: false,
                    seconds: 0.,
                    duration: 0.,
                });
            }
            Ok(Command::Shutdown) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
        if let Some(track) = &current {
            if let Some(error) = player.failure() {
                player.stop()?;
                current = None;
                let _ = events.send(super::Event::Message(format!("Playback failed: {error}")));
                let _ = events.send(super::Event::Playback {
                    key: String::new(),
                    title: String::new(),
                    playing: false,
                    seconds: 0.,
                    duration: 0.,
                });
                continue;
            }
            let (playing, seconds, duration) = player.state()?;
            let _ = events.send(super::Event::Playback {
                key: track.id.clone(),
                title: format!("{} — {}", track.title, track.artist),
                playing,
                seconds,
                duration,
            });
            if player.ended() {
                player.stop()?;
                current = None;
                let _ = events.send(super::Event::Playback {
                    key: String::new(),
                    title: String::new(),
                    playing: false,
                    seconds: duration,
                    duration,
                });
            }
        }
    }
    player.stop()?;
    Ok(())
}

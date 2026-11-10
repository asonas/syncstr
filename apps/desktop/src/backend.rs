mod audio;
pub mod configuration;
mod worker;

#[derive(Clone)]
pub struct Host {
    pub member: String,
    pub socket: std::net::SocketAddr,
}
impl Host {
    pub fn core(&self) -> syncstr_headless::catalog_client::Host {
        syncstr_headless::catalog_client::Host {
            member: self.member.clone(),
            socket: self.socket,
        }
    }
}

pub enum Command {
    Discover,
    SelectHost(String),
    Enroll(String),
    Refresh,
    Play(crate::model::Track, u64),
    Save(crate::model::Track),
    Remove(crate::model::Track),
    Shutdown,
}

pub enum Event {
    Library {
        tracks: Vec<crate::model::Track>,
        playlists: Vec<(String, String, Vec<crate::model::Track>)>,
        message: String,
    },
    Hosts(Vec<Host>, Option<String>),
    Busy(bool),
    Message(String),
    Playback {
        key: String,
        title: String,
        playing: bool,
        seconds: f64,
        duration: f64,
    },
}

type Active = std::sync::Arc<std::sync::Mutex<Option<syncstr_headless::catalog_client::Operation>>>;
struct Running {
    commands: std::sync::mpsc::Sender<Command>,
    active: Active,
    audio: std::sync::mpsc::Sender<audio::Command>,
    join: std::thread::JoinHandle<()>,
}
static RUNNING: std::sync::Mutex<Vec<Running>> = std::sync::Mutex::new(Vec::new());

pub struct Service {
    commands: std::sync::mpsc::Sender<Command>,
    pub events: std::sync::mpsc::Receiver<Event>,
    active: Active,
    generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    audio: std::sync::mpsc::Sender<audio::Command>,
}

impl Service {
    pub fn start(config: configuration::Config) -> Self {
        let (commands, receive) = std::sync::mpsc::channel();
        let (events, responses) = std::sync::mpsc::channel();
        let active: Active = Default::default();
        let generation = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
        let (audio, audio_join) = audio::start(events.clone(), generation.clone(), config.muted);
        let (shared, audio_sender, worker_generation) =
            (active.clone(), audio.clone(), generation.clone());
        let join = std::thread::spawn(move || {
            let result = worker::run(
                config,
                receive,
                events.clone(),
                shared,
                audio_sender.clone(),
                worker_generation,
            );
            if let Err(error) = result {
                let _ = events.send(Event::Message(error.to_string()));
            }
            let _ = audio_sender.send(audio::Command::Shutdown);
            let _ = audio_join.join();
        });
        RUNNING.lock().expect("worker registry").push(Running {
            commands: commands.clone(),
            active: active.clone(),
            audio: audio.clone(),
            join,
        });
        Self {
            commands,
            events: responses,
            active,
            generation,
            audio,
        }
    }
    pub fn send(&self, command: Command) {
        let _ = self.commands.send(command);
    }
    pub fn cancel(&self) {
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        if let Some(operation) = self.active.lock().expect("active operation").as_ref() {
            operation.cancel();
        }
    }
    pub fn play(&self, track: crate::model::Track) {
        self.cancel();
        self.stop();
        self.send(Command::Play(
            track,
            self.generation.load(std::sync::atomic::Ordering::Acquire),
        ));
    }
    pub fn pause(&self) {
        let _ = self.audio.send(audio::Command::Pause);
    }
    pub fn resume(&self) {
        let _ = self.audio.send(audio::Command::Resume);
    }
    pub fn stop(&self) {
        let _ = self.audio.send(audio::Command::Stop(None));
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        self.cancel();
        self.stop();
        self.send(Command::Shutdown);
    }
}

pub fn shutdown_all() {
    if let Ok(running) = RUNNING.lock() {
        for worker in running.iter() {
            if let Some(operation) = worker.active.lock().expect("active operation").as_ref() {
                operation.cancel();
            }
            let _ = worker.audio.send(audio::Command::Stop(None));
            let _ = worker.commands.send(Command::Shutdown);
        }
    }
}
pub fn drain_workers() {
    shutdown_all();
    for worker in RUNNING.lock().expect("worker registry").drain(..) {
        let _ = worker.join.join();
    }
}

pub fn rows(
    view: &syncstr_headless::catalog_client::CatalogView,
    saved: &[syncstr_headless::catalog_client::ExactTrack],
) -> Vec<crate::model::Track> {
    let saved: std::collections::BTreeSet<_> = saved
        .iter()
        .map(|pin| (&pin.track_id, &pin.sha256))
        .collect();
    let mut tracks: Vec<_> = view
        .tracks
        .values()
        .map(|track| crate::model::Track {
            id: track.id.clone(),
            logical_id: track.id.clone(),
            hash: track.preferred.as_ref().map(|pin| pin.sha256.clone()),
            title: track.title.clone(),
            artist: track.artist.clone().unwrap_or_default(),
            album: track.album.clone(),
            available: track
                .preferred
                .as_ref()
                .and_then(|pin| view.audio_bytes(pin))
                .is_some(),
            saved: track
                .preferred
                .as_ref()
                .is_some_and(|pin| saved.contains(&(&pin.track_id, &pin.sha256))),
        })
        .collect();
    tracks.sort_by(|a, b| a.title.cmp(&b.title).then(a.id.cmp(&b.id)));
    tracks
}

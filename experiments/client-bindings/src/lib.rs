uniffi::setup_scaffolding!();

static RUNTIME: std::sync::LazyLock<tokio::runtime::Runtime> =
    std::sync::LazyLock::new(|| tokio::runtime::Runtime::new().expect("probe runtime"));

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PinnedTrack {
    pub track_id: String,
    pub audio_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatalogView {
    pub revision: u64,
    pub tracks: Vec<PinnedTrack>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ProbeError {
    #[error("profile unavailable")]
    ProfileUnavailable,
    #[error("invalid pin")]
    InvalidPin,
    #[error("operation cancelled")]
    Cancelled,
    #[error("client closed")]
    Closed,
    #[error("worker failed")]
    WorkerFailed,
}

#[derive(uniffi::Object)]
pub struct Client {
    lock: std::sync::Mutex<Option<std::fs::File>>,
}

#[uniffi::export]
impl Client {
    pub fn catalog(&self) -> Result<CatalogView, ProbeError> {
        if self.lock.lock().expect("profile lock").is_none() {
            return Err(ProbeError::Closed);
        }
        Ok(CatalogView {
            revision: 7,
            tracks: vec![
                PinnedTrack {
                    track_id: "logical-track-a".into(),
                    audio_hash: "shared-audio".into(),
                },
                PinnedTrack {
                    track_id: "logical-track-b".into(),
                    audio_hash: "shared-audio".into(),
                },
            ],
        })
    }

    #[uniffi::constructor]
    pub fn open(profile_path: String) -> Result<std::sync::Arc<Self>, ProbeError> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(profile_path)
            .map_err(|_| ProbeError::ProfileUnavailable)?;
        fs2::FileExt::try_lock_exclusive(&file).map_err(|_| ProbeError::ProfileUnavailable)?;
        Ok(std::sync::Arc::new(Self {
            lock: std::sync::Mutex::new(Some(file)),
        }))
    }

    pub fn prepare(
        self: std::sync::Arc<Self>,
        pin: PinnedTrack,
    ) -> Result<std::sync::Arc<Operation>, ProbeError> {
        if self.lock.lock().expect("profile lock").is_none() {
            return Err(ProbeError::Closed);
        }
        if pin.track_id.is_empty() || pin.audio_hash.is_empty() {
            return Err(ProbeError::InvalidPin);
        }
        Ok(std::sync::Arc::new(Operation {
            client: self,
            pin,
            cancelled: std::sync::atomic::AtomicBool::new(false),
            started: std::sync::atomic::AtomicBool::new(false),
        }))
    }

    pub fn shutdown(&self) {
        self.lock.lock().expect("profile lock").take();
    }
}

#[derive(uniffi::Object)]
pub struct Operation {
    client: std::sync::Arc<Client>,
    pin: PinnedTrack,
    cancelled: std::sync::atomic::AtomicBool,
    started: std::sync::atomic::AtomicBool,
}

#[uniffi::export]
impl Operation {
    pub fn has_started(&self) -> bool {
        self.started.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn cancel(&self) {
        self.cancelled
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    pub async fn complete(self: std::sync::Arc<Self>) -> Result<PinnedTrack, ProbeError> {
        self.started
            .store(true, std::sync::atomic::Ordering::SeqCst);
        // Simulate work finishing after the caller has cancelled its request.
        RUNTIME
            .spawn(async { tokio::time::sleep(std::time::Duration::from_millis(80)).await })
            .await
            .map_err(|_| ProbeError::WorkerFailed)?;
        if self.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(ProbeError::Cancelled);
        }
        if self.client.lock.lock().expect("profile lock").is_none() {
            return Err(ProbeError::Closed);
        }
        Ok(self.pin.clone())
    }
}

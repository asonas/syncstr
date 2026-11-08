pub(super) struct Storage {
    pub root: std::path::PathBuf,
    pub policy: crate::catalog_client::Policy,
    state: std::sync::Mutex<State>,
}

#[derive(Default)]
struct State {
    objects: std::collections::BTreeMap<String, Object>,
    protected: std::collections::BTreeSet<String>,
    leases: std::collections::BTreeMap<String, usize>,
    transfers: std::collections::BTreeMap<String, crate::catalog_client::Operation>,
}

pub(super) struct Transfer {
    storage: std::sync::Arc<Storage>,
    id: String,
    _lock: std::sync::Arc<crate::node_lock::NodeLock>,
}
impl Drop for Transfer {
    fn drop(&mut self) {
        if let Ok(mut state) = self.storage.state.lock() {
            state.transfers.remove(&self.id);
        }
    }
}

struct Object {
    bytes: u64,
    used: i64,
    remove: bool,
}

impl Storage {
    pub fn open(
        root: &std::path::Path,
        connection: &rusqlite::Connection,
    ) -> Result<Self, crate::catalog_client::Error> {
        connection.execute_batch("PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS client_audio (hash TEXT PRIMARY KEY, bytes INTEGER NOT NULL, used INTEGER NOT NULL, remove_when_unused INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS client_saves (track TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(track, hash));").map_err(|_| crate::catalog_client::Error::Storage)?;
        let root = root.join("catalog-audio");
        crate::platform_fs::create_private_dir(&root).map_err(io_error)?;
        let mut state = State::default();
        let mut statement = connection
            .prepare("SELECT hash, bytes, used, remove_when_unused FROM client_audio")
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get(2)?,
                    row.get(3)?,
                ))
            })
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        for row in rows {
            let (hash, bytes, used, remove) =
                row.map_err(|_| crate::catalog_client::Error::Storage)?;
            if !crate::catalog_client::projection::hash(&hash)
                || bytes <= 0
                || bytes as u64 > crate::model::MAX_AUDIO
            {
                return Err(crate::catalog_client::Error::Integrity);
            }
            state.objects.insert(
                hash,
                Object {
                    bytes: bytes as u64,
                    used,
                    remove,
                },
            );
        }
        let mut statement = connection
            .prepare("SELECT hash FROM client_saves")
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        for row in statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|_| crate::catalog_client::Error::Storage)?
        {
            state
                .protected
                .insert(row.map_err(|_| crate::catalog_client::Error::Storage)?);
        }
        reconcile_files(&root, connection, &mut state)?;
        let storage = Self {
            root,
            state: std::sync::Mutex::new(state),
            policy: Default::default(),
        };
        {
            let mut state = storage
                .state
                .lock()
                .map_err(|_| crate::catalog_client::Error::Storage)?;
            storage.trim_state(&mut state, u64::MAX)?;
        }
        Ok(storage)
    }

    pub fn path(&self, hash: &str) -> std::path::PathBuf {
        self.root.join(format!("{hash}.audio"))
    }

    pub fn publish(
        self: &std::sync::Arc<Self>,
        connection: &rusqlite::Connection,
        source: tempfile::TempPath,
        pin: crate::catalog_client::ExactTrack,
        bytes: u64,
        lock: std::sync::Arc<crate::node_lock::NodeLock>,
    ) -> Result<crate::catalog_client::VerifiedAudio, crate::catalog_client::Error> {
        let hash = &pin.sha256;
        let mut state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        if state.leases.get(hash).copied().unwrap_or(0) != 0 {
            return Err(crate::catalog_client::Error::Integrity);
        }
        crate::platform_fs::persist_path_replace(source, &self.path(hash))
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        crate::platform_fs::sync_directory(&self.root).map_err(io_error)?;
        let used = crate::model::addition_time();
        connection
            .execute(
                "INSERT OR REPLACE INTO client_audio VALUES (?, ?, ?, 0)",
                rusqlite::params![hash, bytes as i64, used],
            )
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        state.objects.insert(
            hash.into(),
            Object {
                bytes,
                used,
                remove: false,
            },
        );
        Ok(self.make_asset(&mut state, pin, bytes, lock))
    }

    pub fn protect(&self, hash: &str) -> Result<(), crate::catalog_client::Error> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        state.protected.insert(hash.into());
        if let Some(object) = state.objects.get_mut(hash) {
            object.remove = false;
        }
        Ok(())
    }

    pub fn remove_save(
        &self,
        connection: &rusqlite::Connection,
        pin: &crate::catalog_client::ExactTrack,
    ) -> Result<(), crate::catalog_client::Error> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let remaining: bool = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM client_saves WHERE hash=?)",
                [&pin.sha256],
                |row| row.get(0),
            )
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        if !remaining {
            connection
                .execute(
                    "UPDATE client_audio SET remove_when_unused=1 WHERE hash=?",
                    [&pin.sha256],
                )
                .map_err(|_| crate::catalog_client::Error::Storage)?;
            state.protected.remove(&pin.sha256);
            if let Some(object) = state.objects.get_mut(&pin.sha256) {
                object.remove = true;
            }
        }
        self.trim_state(&mut state, self.policy.current().cache_limit_bytes)
    }

    pub fn lease(
        self: &std::sync::Arc<Self>,
        pin: crate::catalog_client::ExactTrack,
        bytes: u64,
        lock: std::sync::Arc<crate::node_lock::NodeLock>,
    ) -> Result<crate::catalog_client::VerifiedAudio, crate::catalog_client::Error> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        if !self.path(&pin.sha256).exists() {
            return Err(crate::catalog_client::Error::UnavailableSource);
        }
        verify_file(&self.path(&pin.sha256), &pin.sha256, bytes)?;
        if let Some(object) = state.objects.get_mut(&pin.sha256) {
            object.used = crate::model::addition_time();
        }
        Ok(self.make_asset(&mut state, pin, bytes, lock))
    }

    fn make_asset(
        self: &std::sync::Arc<Self>,
        state: &mut State,
        pin: crate::catalog_client::ExactTrack,
        bytes: u64,
        lock: std::sync::Arc<crate::node_lock::NodeLock>,
    ) -> crate::catalog_client::VerifiedAudio {
        *state.leases.entry(pin.sha256.clone()).or_default() += 1;
        crate::catalog_client::VerifiedAudio(std::sync::Arc::new(
            crate::catalog_client::audio::Lease {
                path: self.path(&pin.sha256),
                pin,
                bytes,
                storage: self.clone(),
                _lock: lock,
            },
        ))
    }

    pub fn release(&self, hash: &str) {
        if let Ok(mut state) = self.state.lock() {
            if let Some(count) = state.leases.get_mut(hash) {
                *count -= 1;
                if *count == 0 {
                    state.leases.remove(hash);
                }
            }
            let _ = self.trim_state(&mut state, self.policy.current().cache_limit_bytes);
        }
    }

    pub fn active(&self) -> Result<bool, crate::catalog_client::Error> {
        let state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        Ok(!state.leases.is_empty() || !state.transfers.is_empty())
    }

    pub fn begin_transfer(
        self: &std::sync::Arc<Self>,
        operation: crate::catalog_client::Operation,
        lock: std::sync::Arc<crate::node_lock::NodeLock>,
    ) -> Result<Transfer, crate::catalog_client::Error> {
        let id = uuid::Uuid::new_v4().to_string();
        self.state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?
            .transfers
            .insert(id.clone(), operation);
        Ok(Transfer {
            storage: self.clone(),
            id,
            _lock: lock,
        })
    }

    pub fn cancel_transfers(&self) -> Result<(), crate::catalog_client::Error> {
        let state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        for operation in state.transfers.values() {
            operation.cancel();
        }
        Ok(())
    }
    pub fn trim(&self) -> Result<(), crate::catalog_client::Error> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        self.trim_state(&mut state, self.policy.current().cache_limit_bytes)
    }

    fn trim_state(
        &self,
        state: &mut State,
        limit: u64,
    ) -> Result<(), crate::catalog_client::Error> {
        let mut cache: Vec<_> = state
            .objects
            .iter()
            .filter(|(hash, _)| !state.protected.contains(*hash))
            .map(|(hash, object)| (hash.clone(), object.bytes, object.used, object.remove))
            .collect();
        cache.sort_by_key(|(_, _, used, _)| *used);
        let mut total: u64 = cache
            .iter()
            .filter(|(hash, _, _, _)| self.path(hash).is_file())
            .map(|(_, bytes, _, _)| *bytes)
            .sum();
        for (hash, bytes, _, remove) in cache {
            if state.leases.contains_key(&hash) || (!remove && total <= limit) {
                continue;
            }
            match std::fs::remove_file(self.path(&hash)) {
                Ok(()) => {
                    total = total.saturating_sub(bytes);
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(io_error(error)),
            }
            state.objects.remove(&hash);
        }
        Ok(())
    }
}

fn reconcile_files(
    root: &std::path::Path,
    connection: &rusqlite::Connection,
    state: &mut State,
) -> Result<(), crate::catalog_client::Error> {
    for entry in std::fs::read_dir(root).map_err(io_error)? {
        let entry = entry.map_err(io_error)?;
        if !entry.file_type().map_err(io_error)?.is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if name.starts_with(".acquiring-") || name.starts_with(".tmp") {
            std::fs::remove_file(entry.path()).map_err(io_error)?;
            continue;
        }
        let Some(hash) = name
            .strip_suffix(".audio")
            .filter(|hash| crate::catalog_client::projection::hash(hash))
        else {
            continue;
        };
        if state.objects.contains_key(hash) {
            continue;
        }
        let bytes = entry.metadata().map_err(io_error)?.len();
        if bytes == 0 || bytes > crate::model::MAX_AUDIO {
            std::fs::remove_file(entry.path()).map_err(io_error)?;
            continue;
        }
        let verified = verify_file(&entry.path(), hash, bytes);
        if let Err(error) = &verified
            && *error != crate::catalog_client::Error::Integrity
        {
            return Err(*error);
        }
        if verified.is_err() {
            std::fs::remove_file(entry.path()).map_err(io_error)?;
            continue;
        }
        // A crash can publish verified bytes before the database records them.
        let used = crate::model::addition_time();
        connection
            .execute(
                "INSERT INTO client_audio VALUES (?, ?, ?, 0)",
                rusqlite::params![hash, bytes as i64, used],
            )
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        state.objects.insert(
            hash.into(),
            Object {
                bytes,
                used,
                remove: false,
            },
        );
    }
    Ok(())
}

pub(super) fn verify_file(
    path: &std::path::Path,
    hash: &str,
    expected: u64,
) -> Result<(), crate::catalog_client::Error> {
    use sha2::Digest as _;
    use std::io::Read as _;
    let mut file = std::fs::File::open(path).map_err(io_error)?;
    if !std::fs::symlink_metadata(path)
        .map_err(io_error)?
        .file_type()
        .is_file()
    {
        return Err(crate::catalog_client::Error::Integrity);
    }
    if file.metadata().map_err(io_error)?.len() != expected {
        return Err(crate::catalog_client::Error::Integrity);
    }
    let mut digest = sha2::Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer).map_err(io_error)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    if hex::encode(digest.finalize()) != hash {
        return Err(crate::catalog_client::Error::Integrity);
    }
    Ok(())
}

pub(super) fn io_error(error: std::io::Error) -> crate::catalog_client::Error {
    if error.kind() == std::io::ErrorKind::StorageFull {
        crate::catalog_client::Error::InsufficientStorage
    } else {
        crate::catalog_client::Error::Storage
    }
}

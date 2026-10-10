struct Inner {
    connection: std::sync::Mutex<rusqlite::Connection>,
    root: std::path::PathBuf,
    _lock: std::fs::File,
}

#[derive(Clone)]
pub struct Store(std::sync::Arc<crate::store::Inner>);

impl crate::store::Store {
    pub fn open(root: &std::path::Path) -> anyhow::Result<Self> {
        use fs2::FileExt as _;
        use std::os::unix::fs::DirBuilderExt as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root)?;
        let root = root.canonicalize()?;
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(root.join("node.lock"))?;
        lock.try_lock_exclusive()
            .map_err(|error| anyhow::anyhow!("data directory is already in use: {error}"))?;
        for name in ["objects", "staging"] {
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(name))
                .or_else(|error| {
                    if error.kind() == std::io::ErrorKind::AlreadyExists {
                        Ok(())
                    } else {
                        Err(error)
                    }
                })?;
        }
        let mut connection = rusqlite::Connection::open(root.join("node.sqlite"))?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        anyhow::ensure!(
            version == 0 || version == 1 || version == 2,
            "unsupported catalog schema {version}"
        );
        let transaction = connection.transaction()?;
        transaction.execute_batch("CREATE TABLE IF NOT EXISTS library (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS tracks (id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, suffix TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(sha256, suffix));
            CREATE TABLE IF NOT EXISTS organization (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload BLOB NOT NULL);
            PRAGMA user_version = 2;")?;
        let stored: Option<Vec<u8>> = {
            use rusqlite::OptionalExtension as _;
            transaction
                .query_row(
                    "SELECT payload FROM organization WHERE singleton = 1",
                    [],
                    |row| row.get(0),
                )
                .optional()?
        };
        if stored.is_none() {
            let mut organization = crate::organization::Organization::default();
            let mut statement = transaction.prepare("SELECT payload FROM tracks ORDER BY id")?;
            let rows = statement.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
            for row in rows {
                organization.import(&serde_json::from_slice::<crate::model::Entry>(&row?)?);
            }
            transaction.execute(
                "INSERT INTO organization VALUES (1, ?)",
                [serde_json::to_vec(&organization)?],
            )?;
        }
        transaction.execute(
            "INSERT OR IGNORE INTO library VALUES (1, ?)",
            [uuid::Uuid::new_v4().to_string()],
        )?;
        transaction.commit()?;
        // The exclusive directory lock excludes uploads while abandoned staging files are removed.
        for file in std::fs::read_dir(root.join("staging"))? {
            let file = file?;
            if file.file_type()?.is_file()
                && file.file_name().to_string_lossy().starts_with("upload-")
            {
                std::fs::remove_file(file.path())?;
            }
        }
        Ok(Self(std::sync::Arc::new(crate::store::Inner {
            connection: std::sync::Mutex::new(connection),
            root,
            _lock: lock,
        })))
    }

    async fn run<T: Send + 'static>(
        &self,
        action: impl FnOnce(&mut rusqlite::Connection, &std::path::Path) -> anyhow::Result<T>
        + Send
        + 'static,
    ) -> anyhow::Result<T> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            let mut connection = store
                .0
                .connection
                .lock()
                .map_err(|_| anyhow::anyhow!("catalog lock poisoned"))?;
            action(&mut connection, &store.0.root)
        })
        .await?
    }

    pub async fn stage(&self) -> anyhow::Result<tempfile::NamedTempFile> {
        self.run(|_, root| {
            Ok(tempfile::Builder::new()
                .prefix("upload-")
                .tempfile_in(root.join("staging"))?)
        })
        .await
    }

    pub async fn catalog(&self) -> anyhow::Result<crate::model::Catalog> {
        self.run(|connection, _| {
            let id =
                connection.query_row("SELECT id FROM library WHERE singleton = 1", [], |row| {
                    row.get(0)
                })?;
            let mut statement = connection.prepare("SELECT payload FROM tracks ORDER BY id")?;
            let rows = statement.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
            let entries = rows
                .map(|data| Ok(serde_json::from_slice(&data?)?))
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok(crate::model::Catalog {
                id,
                name: "Syncstr".to_owned(),
                entries,
                organization: crate::store::read_organization(connection)?,
            })
        })
        .await
    }

    pub async fn get(&self, id: String) -> anyhow::Result<Option<crate::model::Entry>> {
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            let data: Option<Vec<u8>> = connection
                .query_row("SELECT payload FROM tracks WHERE id = ?", [id], |row| {
                    row.get(0)
                })
                .optional()?;
            data.map(|bytes| Ok(serde_json::from_slice(&bytes)?))
                .transpose()
        })
        .await
    }

    pub fn path(&self, entry: &crate::model::Entry) -> std::path::PathBuf {
        self.0
            .root
            .join("objects")
            .join(format!("{}.{}", entry.sha256, entry.track.suffix))
    }

    pub async fn commit(
        &self,
        entry: crate::model::Entry,
        temporary: tempfile::NamedTempFile,
        update_metadata: bool,
    ) -> anyhow::Result<crate::model::Entry> {
        self.commit_organized(entry, temporary, update_metadata, None)
            .await
    }

    pub async fn merge_organization(
        &self,
        incoming: crate::organization::Organization,
    ) -> anyhow::Result<()> {
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let mut organization = crate::store::read_organization(&transaction)?;
            organization.merge(&incoming)?;
            transaction.execute(
                "UPDATE organization SET payload = ? WHERE singleton = 1",
                [serde_json::to_vec(&organization)?],
            )?;
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub async fn commit_organized(
        &self,
        mut entry: crate::model::Entry,
        temporary: tempfile::NamedTempFile,
        update_metadata: bool,
        incoming: Option<crate::organization::Organization>,
    ) -> anyhow::Result<crate::model::Entry> {
        self.run(move |connection, root| {
            use rusqlite::OptionalExtension as _;
            let transaction = connection.transaction()?;
            let mut organization = crate::store::read_organization(&transaction)?;
            let original_id = entry.track.id.clone();
            if let Some(incoming) = incoming { organization.merge(&incoming)?; }
            let previous: Option<Vec<u8>> = transaction
                .query_row(
                    "SELECT payload FROM tracks WHERE sha256 = ? AND suffix = ?",
                    [&entry.sha256, &entry.track.suffix],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(previous) = previous {
                let previous: crate::model::Entry = serde_json::from_slice(&previous)?;
                if update_metadata {
                    entry.track.id = previous.track.id;
                    entry.track.cover_art = entry.artwork.as_ref().map(|_| entry.track.id.clone());
                } else {
                    entry = previous;
                }
            } else {
                entry.track.id = uuid::Uuid::new_v4().to_string();
                entry.track.cover_art = entry.artwork.as_ref().map(|_| entry.track.id.clone());
            }
            if original_id != entry.track.id && organization.tracks.iter().any(|t| t.id == original_id) {
                organization.track_aliases.get_or_insert_with(Default::default).insert(entry.track.id.clone(), original_id);
            } else { organization.import(&entry); }
            organization.validate()?;
            transaction.execute("UPDATE organization SET payload = ? WHERE singleton = 1", [serde_json::to_vec(&organization)?])?;
            let destination = root
                .join("objects")
                .join(format!("{}.{}", entry.sha256, entry.track.suffix));
            temporary.persist(destination)?;
            std::fs::File::open(root.join("objects"))?.sync_all()?;
            transaction.execute(
                "INSERT INTO tracks VALUES (?, ?, ?, ?) ON CONFLICT(sha256, suffix) DO UPDATE SET payload = excluded.payload",
                rusqlite::params![
                    entry.track.id,
                    entry.sha256,
                    entry.track.suffix,
                    serde_json::to_vec(&entry)?
                ],
            )?;
            transaction.commit()?;
            Ok(entry)
        })
        .await
    }
}

fn read_organization(
    connection: &rusqlite::Connection,
) -> anyhow::Result<crate::organization::Organization> {
    let payload: Vec<u8> = connection.query_row(
        "SELECT payload FROM organization WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let organization: crate::organization::Organization = serde_json::from_slice(&payload)?;
    organization.validate()?;
    Ok(organization)
}

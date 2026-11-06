//! Versioned logical identities. Legacy tables and signed payloads remain untouched.

const DOMAIN: &str = "syncstr-shared-audio-v1\n";

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub library: String,
    pub track: String,
}

impl crate::shared_audio::Source {
    pub fn subject(&self) -> String {
        format!(
            "source:{}",
            serde_json::to_string(self).expect("string serialization")
        )
    }
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Track {
    pub id: String,
    pub metadata: std::collections::BTreeMap<String, serde_json::Value>,
    pub album_id: Option<String>,
    pub added_at: Option<i64>,
    pub retired: bool,
    pub audio: Vec<String>,
    pub preferred: Option<String>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Evidence {
    pub snapshot: String,
    pub catalog: String,
    pub reason: String,
    pub audio_eligible: bool,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Value {
    Track {
        track: crate::shared_audio::Track,
        evidence: crate::shared_audio::Evidence,
    },
    Correspondence {
        source: crate::shared_audio::Source,
        target: Option<String>,
        evidence: crate::shared_audio::Evidence,
    },
}

impl crate::shared_audio::Value {
    pub fn subject(&self) -> String {
        match self {
            Self::Track { track, .. } => format!("track:{}", track.id),
            Self::Correspondence { source, .. } => source.subject(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Edit {
    pub parents: Vec<String>,
    pub value: crate::shared_audio::Value,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Body {
    pub cluster: String,
    pub baseline: String,
    pub author: String,
    pub grant: String,
    pub request: String,
    pub request_digest: String,
    pub edits: Vec<crate::shared_audio::Edit>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Signed {
    pub id: String,
    pub payload: String,
    pub signature: String,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(tag = "action", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Action {
    Register {
        source: crate::shared_audio::Source,
        track: crate::shared_audio::Track,
        evidence: crate::shared_audio::Evidence,
    },
    Assign {
        source: crate::shared_audio::Source,
        target: Option<String>,
        evidence: crate::shared_audio::Evidence,
    },
    EditTrack {
        track: crate::shared_audio::Track,
        evidence: crate::shared_audio::Evidence,
    },
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub id: String,
    pub expected: std::collections::BTreeMap<String, Vec<String>>,
    pub action: crate::shared_audio::Action,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlaylistUpdate {
    pub documents: Vec<crate::playlists::Document>,
    pub expected: std::collections::BTreeMap<String, Vec<String>>,
    pub confirmed_replacements: bool,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Object {
    pub sha256: String,
    pub bytes: Option<u64>,
    pub locators: Vec<String>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Baseline {
    pub cluster: String,
    pub library: String,
    pub legacy_organization: serde_json::Value,
    pub tracks: std::collections::BTreeMap<String, crate::shared_audio::Track>,
    pub addresses: std::collections::BTreeMap<String, String>,
    pub objects: std::collections::BTreeMap<String, crate::shared_audio::Object>,
    pub pins: std::collections::BTreeMap<String, std::collections::BTreeSet<String>>,
    pub legacy_fingerprint: String,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Catalog {
    pub version: u8,
    pub cluster: String,
    pub library: String,
    pub legacy_organization: serde_json::Value,
    pub baseline: String,
    pub tracks: std::collections::BTreeMap<String, crate::shared_audio::Track>,
    pub addresses: std::collections::BTreeMap<String, String>,
    pub objects: std::collections::BTreeMap<String, crate::shared_audio::Object>,
    pub pins: std::collections::BTreeMap<String, std::collections::BTreeSet<String>>,
    pub correspondences: std::collections::BTreeMap<String, String>,
    pub heads: std::collections::BTreeMap<String, Vec<String>>,
    pub conflicts: std::collections::BTreeSet<String>,
    pub incomplete: Vec<String>,
}

fn hash(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    hex::encode(sha2::Sha256::digest(bytes))
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn identity(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
}

fn rows(connection: &rusqlite::Connection, table: &str) -> anyhow::Result<Vec<Vec<u8>>> {
    let exists: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
        [table],
        |r| r.get(0),
    )?;
    if !exists {
        return Ok(vec![]);
    }
    let mut statement = connection.prepare(&format!("SELECT payload FROM {table} ORDER BY id"))?;
    Ok(statement
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?)
}

fn legacy(connection: &rusqlite::Connection) -> anyhow::Result<crate::shared_audio::Baseline> {
    let organization = crate::store::read_organization(connection)?;
    let organization_raw: Vec<u8> = connection.query_row(
        "SELECT payload FROM organization WHERE singleton=1",
        [],
        |r| r.get(0),
    )?;
    let mut baseline = crate::shared_audio::Baseline {
        cluster: connection.query_row(
            "SELECT id FROM cluster_identity WHERE singleton=1",
            [],
            |r| r.get(0),
        )?,
        library: connection
            .query_row("SELECT id FROM library WHERE singleton=1", [], |r| r.get(0))?,
        legacy_organization: serde_json::from_slice(&organization_raw)?,
        tracks: Default::default(),
        addresses: Default::default(),
        objects: Default::default(),
        pins: Default::default(),
        legacy_fingerprint: String::new(),
    };
    for track in &organization.tracks {
        let canonical = organization.canonical_track(&track.id);
        baseline
            .addresses
            .insert(track.id.clone(), canonical.clone());
        if canonical == track.id {
            baseline.tracks.insert(
                track.id.clone(),
                crate::shared_audio::Track {
                    id: track.id.clone(),
                    metadata: std::collections::BTreeMap::from([(
                        "organization".into(),
                        serde_json::to_value(track)?,
                    )]),
                    album_id: organization.album_id_for_track(&track.id)?,
                    added_at: None,
                    retired: false,
                    audio: vec![track.sha256.clone()],
                    preferred: Some(track.sha256.clone()),
                },
            );
            baseline
                .pins
                .entry(canonical)
                .or_default()
                .insert(track.sha256.clone());
        }
    }
    for alias in organization
        .track_aliases
        .as_ref()
        .into_iter()
        .flat_map(|a| a.keys())
    {
        baseline
            .addresses
            .insert(alias.clone(), organization.canonical_track(alias));
    }
    let entries = crate::shared_audio::rows(connection, "tracks")?;
    for raw in &entries {
        let entry: crate::model::Entry = serde_json::from_slice(raw)?;
        entry.validate()?;
        let canonical = organization.canonical_track(&entry.track.id);
        baseline
            .addresses
            .insert(entry.track.id.clone(), canonical.clone());
        let track = baseline.tracks.entry(canonical.clone()).or_insert_with(|| {
            crate::shared_audio::Track {
                id: canonical.clone(),
                metadata: Default::default(),
                album_id: entry.track.album_id.clone(),
                added_at: entry.track.added_at,
                retired: false,
                audio: vec![],
                preferred: Some(entry.sha256.clone()),
            }
        });
        track
            .metadata
            .insert("legacyEntry".into(), serde_json::to_value(&entry.track)?);
        track.added_at = track.added_at.or(entry.track.added_at);
        if !track.audio.contains(&entry.sha256) {
            track.audio.push(entry.sha256.clone());
        }
        baseline
            .pins
            .entry(canonical)
            .or_default()
            .insert(entry.sha256.clone());
        let object =
            baseline
                .objects
                .entry(entry.sha256.clone())
                .or_insert(crate::shared_audio::Object {
                    sha256: entry.sha256.clone(),
                    bytes: Some(entry.track.size),
                    locators: vec![],
                });
        anyhow::ensure!(
            object.bytes == Some(entry.track.size),
            "competing object sizes"
        );
        object
            .locators
            .push(format!("{}.{}", entry.sha256, entry.track.suffix));
    }
    let playlists = crate::shared_audio::rows(connection, "playlist_records")?;
    let proof = crate::enrollment::read_proof(connection)?;
    for raw in &playlists {
        let signed: crate::playlists::Signed = serde_json::from_slice(raw)?;
        let body = signed.decode(&proof)?;
        for item in body.document.items {
            if let (Some(id), Some(hash)) = (item.track_id, item.sha256) {
                let canonical = baseline
                    .addresses
                    .get(&id)
                    .ok_or_else(|| anyhow::anyhow!("dangling playlist track address"))?;
                baseline
                    .pins
                    .entry(canonical.clone())
                    .or_default()
                    .insert(hash);
            }
        }
    }
    for (id, target) in &baseline.addresses {
        anyhow::ensure!(
            baseline.tracks.contains_key(target),
            "dangling track address: {id}"
        );
    }
    for hash in baseline.pins.values().flatten() {
        anyhow::ensure!(crate::shared_audio::valid_hash(hash), "invalid legacy hash");
        baseline
            .objects
            .entry(hash.clone())
            .or_insert(crate::shared_audio::Object {
                sha256: hash.clone(),
                bytes: None,
                locators: vec![],
            });
    }
    baseline.legacy_fingerprint = crate::shared_audio::hash(&serde_json::to_vec(&(
        entries,
        organization_raw,
        playlists,
        crate::shared_audio::rows(connection, "cluster_changes")?,
    ))?);
    Ok(baseline)
}

struct Inner {
    connection: std::sync::Mutex<rusqlite::Connection>,
    root: std::path::PathBuf,
    _lock: std::fs::File,
}

#[derive(Clone)]
pub struct Store(std::sync::Arc<crate::shared_audio::Inner>);

impl crate::shared_audio::Store {
    fn locked(
        root: &std::path::Path,
    ) -> anyhow::Result<(rusqlite::Connection, std::fs::File, std::path::PathBuf)> {
        let root = crate::platform_fs::absolute_directory(root)?;
        let lock = crate::platform_fs::private_file_options()
            .read(true)
            .write(true)
            .open(root.join("node.lock"))?;
        fs2::FileExt::try_lock_exclusive(&lock)?;
        let connection = rusqlite::Connection::open_with_flags(
            root.join("node.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
        )?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok((connection, lock, root))
    }

    pub fn inspect(root: &std::path::Path) -> anyhow::Result<String> {
        let (mut connection, _lock, _) = Self::locked(root)?;
        let transaction = connection.transaction()?;
        let baseline = crate::shared_audio::legacy(&transaction)?;
        Ok(crate::shared_audio::hash(&serde_json::to_vec(&baseline)?))
    }

    pub fn activate(root: &std::path::Path, expected: &str) -> anyhow::Result<Self> {
        let (mut connection, lock, root) = Self::locked(root)?;
        let transaction = connection.transaction()?;
        let version: i64 = transaction.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        anyhow::ensure!(version == 4 || version == 5, "unsupported migration source");
        let baseline = crate::shared_audio::legacy(&transaction)?;
        let payload = serde_json::to_vec(&baseline)?;
        let fingerprint = crate::shared_audio::hash(&payload);
        anyhow::ensure!(fingerprint == expected, "stale migration baseline");
        transaction.execute_batch("CREATE TABLE IF NOT EXISTS shared_baseline (singleton INTEGER PRIMARY KEY CHECK(singleton=1), fingerprint TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_records (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_requests (id TEXT PRIMARY KEY, digest TEXT NOT NULL, record TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_cursors (peer TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_playlists (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_objects (sha256 TEXT PRIMARY KEY, bytes INTEGER NOT NULL, locator TEXT NOT NULL);")?;
        if version == 4 {
            transaction.execute(
                "INSERT INTO shared_baseline VALUES (1, ?, ?)",
                rusqlite::params![fingerprint, payload],
            )?;
            transaction.execute_batch("PRAGMA user_version=5;")?;
        } else {
            let existing: String =
                transaction
                    .query_row("SELECT fingerprint FROM shared_baseline", [], |r| r.get(0))?;
            anyhow::ensure!(existing == fingerprint, "migration baseline changed");
        }
        transaction.commit()?;
        Ok(Self(std::sync::Arc::new(crate::shared_audio::Inner {
            connection: std::sync::Mutex::new(connection),
            root,
            _lock: lock,
        })))
    }

    pub fn open(root: &std::path::Path) -> anyhow::Result<Self> {
        let (connection, lock, root) = Self::locked(root)?;
        let version: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        anyhow::ensure!(version == 5, "shared audio is not activated");
        Ok(Self(std::sync::Arc::new(crate::shared_audio::Inner {
            connection: std::sync::Mutex::new(connection),
            root,
            _lock: lock,
        })))
    }

    pub(crate) fn run<T>(
        &self,
        action: impl FnOnce(&mut rusqlite::Connection, &std::path::Path) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let mut connection = self
            .0
            .connection
            .lock()
            .map_err(|_| anyhow::anyhow!("catalog lock poisoned"))?;
        action(&mut connection, &self.0.root)
    }

    pub fn catalog(&self) -> anyhow::Result<crate::shared_audio::Catalog> {
        self.run(|connection, _| crate::shared_audio::catalog(connection))
    }

    pub fn snapshot(&self) -> anyhow::Result<crate::shared_audio_net::Snapshot> {
        self.run(|connection, _| {
            Ok(crate::shared_audio_net::Snapshot {
                playlist_history: crate::shared_audio::playlist_records(connection)?,
                catalog: crate::shared_audio::catalog(connection)?,
                playlists: crate::playlists::project(
                    &crate::shared_audio::playlist_records(connection)?,
                    &crate::enrollment::read_proof(connection)?,
                )?
                .into_values()
                .collect(),
            })
        })
    }

    pub fn records(&self) -> anyhow::Result<Vec<crate::shared_audio::Signed>> {
        self.run(|connection, _| {
            crate::shared_audio::rows(connection, "shared_records")?
                .iter()
                .map(|raw| Ok(serde_json::from_slice(raw)?))
                .collect()
        })
    }

    pub fn page(&self, after: i64) -> anyhow::Result<Vec<(i64, crate::shared_audio::Signed)>> {
        anyhow::ensure!(after >= 0, "invalid cursor");
        self.run(|connection, _| {
            let mut query = connection.prepare(
                "SELECT rowid, payload FROM shared_records WHERE rowid>? ORDER BY rowid LIMIT 64",
            )?;
            query
                .query_map([after], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
                })?
                .map(|row| {
                    let (cursor, raw) = row?;
                    Ok((cursor, serde_json::from_slice(&raw)?))
                })
                .collect()
        })
    }

    pub fn stage(&self) -> anyhow::Result<tempfile::NamedTempFile> {
        Ok(tempfile::Builder::new()
            .prefix("shared-")
            .tempfile_in(self.0.root.join("staging"))?)
    }

    pub fn playlists(&self) -> anyhow::Result<Vec<crate::playlists::Snapshot>> {
        self.run(|connection, _| {
            Ok(crate::playlists::project(
                &crate::shared_audio::playlist_records(connection)?,
                &crate::enrollment::read_proof(connection)?,
            )?
            .into_values()
            .collect())
        })
    }

    pub fn playlist_page(
        &self,
        after: i64,
    ) -> anyhow::Result<Vec<(i64, crate::playlists::Signed)>> {
        anyhow::ensure!(after >= 0, "invalid cursor");
        self.run(|connection, _| {
            let mut query = connection.prepare(
                "SELECT rowid, payload FROM shared_playlists WHERE rowid>? ORDER BY rowid LIMIT 4",
            )?;
            query
                .query_map([after], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
                })?
                .map(|row| {
                    let (cursor, raw) = row?;
                    Ok((cursor, serde_json::from_slice(&raw)?))
                })
                .collect()
        })
    }

    pub fn update_playlists(
        &self,
        signer: &crate::peer::Identity,
        request: crate::shared_audio::PlaylistUpdate,
    ) -> anyhow::Result<Vec<crate::playlists::Signed>> {
        self.run(|connection, _| {
            anyhow::ensure!(
                !request.documents.is_empty() && request.documents.len() <= 64,
                "invalid playlist selection"
            );
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let grant = proof
                .grants
                .iter()
                .find(|g| {
                    g.member == signer.id().to_string() && g.host && proof.verify(&g.id).is_ok()
                })
                .ok_or_else(|| anyhow::anyhow!("unauthorized playlist author"))?;
            let mut records = crate::shared_audio::playlist_records(&transaction)?;
            let before = crate::playlists::project(&records, &proof)?;
            let catalog = crate::shared_audio::catalog(&transaction)?;
            let mut result = vec![];
            let mut seen = std::collections::BTreeSet::new();
            for document in request.documents {
                document.validate()?;
                anyhow::ensure!(
                    seen.insert(document.id.clone()),
                    "duplicate playlist selection"
                );
                let parents = request
                    .expected
                    .get(&document.id)
                    .cloned()
                    .unwrap_or_default();
                let body = crate::playlists::Body {
                    version: if parents.is_empty() { 1 } else { 2 },
                    cluster: catalog.cluster.clone(),
                    author: signer.id().to_string(),
                    grant: grant.id.clone(),
                    document,
                    parents,
                };
                let payload = format!("syncstr-playlist-v1\n{}", serde_json::to_string(&body)?);
                let signed = crate::playlists::Signed {
                    id: crate::shared_audio::hash(payload.as_bytes()),
                    signature: hex::encode(signer.sign(payload.as_bytes())),
                    payload,
                };
                signed.decode(&proof)?;
                if records.iter().any(|r| r.id == signed.id) {
                    result.push(signed);
                    continue;
                }
                let previous = before.get(&body.document.id);
                anyhow::ensure!(
                    previous.map(|p| &p.revisions).cloned().unwrap_or_default() == body.parents,
                    "stale playlist preview"
                );
                if let Some(previous) = previous {
                    anyhow::ensure!(
                        crate::playlists::reconciled(&body.document, &previous.document)?
                            == body.document,
                        "playlist structure changed"
                    );
                    for (old, new) in previous.document.items.iter().zip(&body.document.items) {
                        if old.track_id.is_some()
                            && (old.track_id != new.track_id || old.sha256 != new.sha256)
                        {
                            anyhow::ensure!(
                                request.confirmed_replacements,
                                "replacement confirmation required"
                            );
                        }
                    }
                }
                for item in &body.document.items {
                    if let (Some(address), Some(hash)) = (&item.track_id, &item.sha256) {
                        let id = catalog.addresses.get(address).unwrap_or(address);
                        anyhow::ensure!(
                            catalog.pins.get(id).is_some_and(|p| p.contains(hash)),
                            "unknown playlist binding"
                        );
                    }
                }
                transaction.execute(
                    "INSERT INTO shared_playlists VALUES (?, ?)",
                    rusqlite::params![signed.id, serde_json::to_vec(&signed)?],
                )?;
                records.push(signed.clone());
                result.push(signed);
            }
            anyhow::ensure!(
                request.expected.keys().all(|id| seen.contains(id)),
                "unexpected playlist head"
            );
            let snapshots = crate::playlists::project(&records, &proof)?;
            for snapshot in snapshots.values() {
                let mut parent = snapshot.document.parent.as_ref();
                let mut ancestors = std::collections::BTreeSet::from([&snapshot.document.id]);
                while let Some(id) = parent {
                    anyhow::ensure!(ancestors.insert(id), "playlist folder cycle");
                    let folder = snapshots
                        .get(id)
                        .ok_or_else(|| anyhow::anyhow!("missing playlist folder"))?;
                    anyhow::ensure!(folder.document.kind == "folder", "parent is not a folder");
                    parent = folder.document.parent.as_ref();
                }
            }
            transaction.commit()?;
            Ok(result)
        })
    }

    pub fn receive_playlist_page(
        &self,
        peer: &str,
        after: i64,
        page: Vec<(i64, crate::playlists::Signed)>,
    ) -> anyhow::Result<()> {
        self.run(|connection, _| {
            use rusqlite::OptionalExtension as _;
            anyhow::ensure!(page.len() <= 4, "playlist page too large");
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let catalog = crate::shared_audio::catalog(&transaction)?;
            let current: i64 = transaction.query_row("SELECT sequence FROM shared_cursors WHERE peer=?", [peer], |r| r.get(0)).optional()?.unwrap_or(0);
            anyhow::ensure!(current == after, "playlist cursor changed");
            let mut next = after;
            for (sequence, signed) in page {
                anyhow::ensure!(sequence > next, "nonmonotonic playlist page");
                let body = signed.decode(&proof)?;
                anyhow::ensure!(body.cluster == catalog.cluster, "cross-cluster playlist");
                let known: bool = transaction.query_row("SELECT EXISTS(SELECT 1 FROM shared_playlists WHERE id=?)", [&signed.id], |r| r.get(0))?;
                if !known { proof.verify(&body.grant)?; }
                transaction.execute("INSERT OR IGNORE INTO shared_playlists VALUES (?, ?)", rusqlite::params![signed.id, serde_json::to_vec(&signed)?])?;
                next = sequence;
            }
            // Signed conflicts are retained; projection reports them without choosing a winner.
            transaction.execute("INSERT INTO shared_cursors VALUES (?, ?) ON CONFLICT(peer) DO UPDATE SET sequence=excluded.sequence", rusqlite::params![peer, next])?;
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn commit(
        &self,
        signer: &crate::peer::Identity,
        request: crate::shared_audio::Request,
    ) -> anyhow::Result<crate::shared_audio::Signed> {
        self.run(|connection, _| {
            use rusqlite::OptionalExtension as _;
            anyhow::ensure!(
                crate::shared_audio::identity(&request.id),
                "invalid request ID"
            );
            let digest = crate::shared_audio::hash(&serde_json::to_vec(&request)?);
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let grant = proof
                .grants
                .iter()
                .find(|g| {
                    g.member == signer.id().to_string() && g.host && proof.verify(&g.id).is_ok()
                })
                .ok_or_else(|| anyhow::anyhow!("signer is not an authorized host"))?;
            let prior: Option<(String, String)> = transaction
                .query_row(
                    "SELECT digest, record FROM shared_requests WHERE id=?",
                    [&request.id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if let Some((previous, record)) = prior {
                anyhow::ensure!(
                    previous == digest,
                    "idempotency key reused with different content"
                );
                let matching = crate::shared_audio::rows(&transaction, "shared_records")?
                    .into_iter()
                    .map(|raw| -> anyhow::Result<bool> {
                        let signed: crate::shared_audio::Signed = serde_json::from_slice(&raw)?;
                        Ok(crate::shared_audio::decode(&signed, &proof)?.request == request.id)
                    })
                    .collect::<anyhow::Result<Vec<_>>>()?;
                anyhow::ensure!(
                    matching.into_iter().filter(|matches| *matches).count() == 1,
                    "request has competing host results"
                );
                let raw: Vec<u8> = transaction.query_row(
                    "SELECT payload FROM shared_records WHERE id=?",
                    [record],
                    |r| r.get(0),
                )?;
                return Ok(serde_json::from_slice(&raw)?);
            }
            let catalog = crate::shared_audio::catalog(&transaction)?;
            anyhow::ensure!(
                grant.cluster == catalog.cluster,
                "host belongs to another cluster"
            );
            anyhow::ensure!(catalog.incomplete.is_empty(), "incomplete shared history");
            let values = match request.action {
                crate::shared_audio::Action::Register {
                    source,
                    mut track,
                    evidence,
                } => {
                    anyhow::ensure!(
                        !catalog.heads.contains_key(&source.subject()),
                        "source already registered; review its correspondence"
                    );
                    anyhow::ensure!(track.id.is_empty(), "server allocates new track IDs");
                    anyhow::ensure!(
                        track.audio.is_empty() || evidence.audio_eligible,
                        "audio eligibility requires approval"
                    );
                    track.id = uuid::Uuid::new_v4().to_string();
                    track.added_at = Some(crate::model::addition_time());
                    vec![
                        crate::shared_audio::Value::Correspondence {
                            source,
                            target: Some(track.id.clone()),
                            evidence: evidence.clone(),
                        },
                        crate::shared_audio::Value::Track { track, evidence },
                    ]
                }
                crate::shared_audio::Action::Assign {
                    source,
                    target,
                    evidence,
                } => {
                    if let Some(id) = &target {
                        let track = catalog
                            .tracks
                            .get(id)
                            .ok_or_else(|| anyhow::anyhow!("unknown target track"))?;
                        anyhow::ensure!(
                            !track.retired && !catalog.conflicts.contains(&format!("track:{id}")),
                            "target track is unavailable"
                        );
                        anyhow::ensure!(
                            track.audio.is_empty() || evidence.audio_eligible,
                            "audio eligibility requires approval"
                        );
                    }
                    vec![crate::shared_audio::Value::Correspondence {
                        source,
                        target,
                        evidence,
                    }]
                }
                crate::shared_audio::Action::EditTrack { track, evidence } => {
                    let previous = catalog
                        .tracks
                        .get(&track.id)
                        .ok_or_else(|| anyhow::anyhow!("unknown track"))?;
                    anyhow::ensure!(
                        track.added_at == previous.added_at,
                        "addition time is immutable"
                    );
                    anyhow::ensure!(
                        track.audio.iter().all(|h| previous.audio.contains(h))
                            || evidence.audio_eligible,
                        "audio eligibility requires approval"
                    );
                    vec![crate::shared_audio::Value::Track { track, evidence }]
                }
            };
            let mut edits = vec![];
            let mut allowed = std::collections::BTreeSet::new();
            for value in values {
                let subject = value.subject();
                let current = catalog.heads.get(&subject).cloned().unwrap_or_default();
                anyhow::ensure!(
                    request.expected.get(&subject).cloned().unwrap_or_default() == current,
                    "stale preview"
                );
                if let crate::shared_audio::Value::Correspondence {
                    target: Some(target),
                    source,
                    evidence,
                } = &value
                {
                    anyhow::ensure!(
                        evidence.catalog
                            == crate::shared_audio::hash(&serde_json::to_vec(&catalog)?),
                        "stale catalog evidence"
                    );
                    anyhow::ensure!(
                        !catalog
                            .correspondences
                            .iter()
                            .any(|(key, existing)| key != &source.subject() && existing == target),
                        "target already belongs to another source"
                    );
                }
                if let crate::shared_audio::Value::Track { track, evidence } = &value {
                    anyhow::ensure!(
                        evidence.catalog
                            == crate::shared_audio::hash(&serde_json::to_vec(&catalog)?),
                        "stale catalog evidence"
                    );
                    anyhow::ensure!(
                        track
                            .audio
                            .iter()
                            .all(|h| catalog.objects.get(h).is_some_and(|o| o.bytes.is_some())),
                        "audio object has not been verified"
                    );
                }
                allowed.insert(subject);
                edits.push(crate::shared_audio::Edit {
                    parents: current,
                    value,
                });
            }
            anyhow::ensure!(
                request.expected.keys().all(|k| allowed.contains(k)),
                "unexpected revision subject"
            );
            let body = crate::shared_audio::Body {
                cluster: grant.cluster.clone(),
                baseline: catalog.baseline,
                author: signer.id().to_string(),
                grant: grant.id.clone(),
                request: request.id.clone(),
                request_digest: digest.clone(),
                edits,
            };
            let payload = format!(
                "{}{}",
                crate::shared_audio::DOMAIN,
                serde_json::to_string(&body)?
            );
            let signed = crate::shared_audio::Signed {
                id: crate::shared_audio::hash(payload.as_bytes()),
                signature: hex::encode(signer.sign(payload.as_bytes())),
                payload,
            };
            crate::shared_audio::decode(&signed, &proof)?;
            transaction.execute(
                "INSERT INTO shared_records VALUES (?, ?)",
                rusqlite::params![signed.id, serde_json::to_vec(&signed)?],
            )?;
            let projected = crate::shared_audio::catalog(&transaction)?;
            anyhow::ensure!(projected.incomplete.is_empty(), "incomplete transaction");
            for edit in &body.edits {
                anyhow::ensure!(
                    !projected.conflicts.contains(&edit.value.subject()),
                    "correspondence conflict requires resolution"
                );
            }
            transaction.execute(
                "INSERT INTO shared_requests VALUES (?, ?, ?)",
                rusqlite::params![request.id, digest, signed.id],
            )?;
            transaction.commit()?;
            Ok(signed)
        })
    }

    pub fn receive(&self, records: Vec<crate::shared_audio::Signed>) -> anyhow::Result<()> {
        self.ingest(records, None)
    }

    pub fn cursor(&self, peer: &str) -> anyhow::Result<i64> {
        self.run(|connection, _| {
            use rusqlite::OptionalExtension as _;
            Ok(connection
                .query_row(
                    "SELECT sequence FROM shared_cursors WHERE peer=?",
                    [peer],
                    |r| r.get(0),
                )
                .optional()?
                .unwrap_or(0))
        })
    }

    pub fn receive_page(
        &self,
        peer: &str,
        after: i64,
        page: Vec<(i64, crate::shared_audio::Signed)>,
    ) -> anyhow::Result<()> {
        let mut next = after;
        for (sequence, _) in &page {
            anyhow::ensure!(*sequence > next, "nonmonotonic replication page");
            next = *sequence;
        }
        self.ingest(
            page.into_iter().map(|(_, record)| record).collect(),
            Some((peer, after, next)),
        )
    }

    fn ingest(
        &self,
        records: Vec<crate::shared_audio::Signed>,
        cursor: Option<(&str, i64, i64)>,
    ) -> anyhow::Result<()> {
        self.run(|connection, _| {
            anyhow::ensure!(records.len() <= 256, "replication page too large");
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let catalog = crate::shared_audio::catalog(&transaction)?;
            if let Some((peer, expected, _)) = cursor {
                use rusqlite::OptionalExtension as _;
                let current: i64 = transaction.query_row("SELECT sequence FROM shared_cursors WHERE peer=?", [peer], |r| r.get(0)).optional()?.unwrap_or(0);
                anyhow::ensure!(current == expected, "replication cursor changed");
            }
            for record in records {
                let body = crate::shared_audio::decode(&record, &proof)?;
                anyhow::ensure!(body.baseline == catalog.baseline, "different migration baseline");
                let known: bool = transaction.query_row("SELECT EXISTS(SELECT 1 FROM shared_records WHERE id=?)", [&record.id], |r| r.get(0))?;
                if !known { proof.verify(&body.grant)?; }
                transaction.execute("INSERT OR IGNORE INTO shared_records VALUES (?, ?)", rusqlite::params![record.id, serde_json::to_vec(&record)?])?;
                transaction.execute("INSERT OR IGNORE INTO shared_requests VALUES (?, ?, ?)", rusqlite::params![body.request, body.request_digest, record.id])?;
            }
            crate::shared_audio::catalog(&transaction)?;
            if let Some((peer, _, next)) = cursor {
                transaction.execute("INSERT INTO shared_cursors VALUES (?, ?) ON CONFLICT(peer) DO UPDATE SET sequence=excluded.sequence", rusqlite::params![peer, next])?;
            }
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn put_audio(&self, expected: &str, input: &mut impl std::io::Read) -> anyhow::Result<()> {
        anyhow::ensure!(
            crate::shared_audio::valid_hash(expected),
            "invalid audio hash"
        );
        self.run(|connection, root| {
            use std::io::Write as _;
            use sha2::Digest as _;
            let mut staged = tempfile::Builder::new().prefix("shared-").tempfile_in(root.join("staging"))?;
            let mut bytes = 0u64;
            let mut sha = sha2::Sha256::new();
            let mut buffer = vec![0; 1024 * 1024];
            loop {
                let count = input.read(&mut buffer)?;
                if count == 0 { break; }
                bytes += count as u64;
                anyhow::ensure!(bytes <= crate::model::MAX_AUDIO, "audio too large");
                sha.update(&buffer[..count]);
                staged.write_all(&buffer[..count])?;
            }
            anyhow::ensure!(bytes > 0 && hex::encode(sha.finalize()) == expected, "audio hash mismatch");
            let catalog = crate::shared_audio::catalog(connection)?;
            if let Some(object) = catalog.objects.get(expected) {
                anyhow::ensure!(object.bytes.is_none_or(|size| size == bytes), "audio size mismatch");
                for locator in &object.locators {
                    if let Ok(mut existing) = std::fs::File::open(root.join("objects").join(locator)) {
                        let mut existing_hash = sha2::Sha256::new();
                        loop {
                            let count = std::io::Read::read(&mut existing, &mut buffer)?;
                            if count == 0 { break; }
                            existing_hash.update(&buffer[..count]);
                        }
                        if hex::encode(existing_hash.finalize()) == expected { return Ok(()); }
                    }
                }
            }
            staged.as_file().sync_all()?;
            let locator = format!("{expected}.audio");
            crate::platform_fs::persist_replace(staged, &root.join("objects").join(&locator))?;
            crate::platform_fs::sync_directory(&root.join("objects"))?;
            connection.execute("INSERT INTO shared_objects VALUES (?, ?, ?) ON CONFLICT(sha256) DO UPDATE SET bytes=excluded.bytes, locator=excluded.locator", rusqlite::params![expected, bytes as i64, locator])?;
            Ok(())
        })
    }

    pub fn audio(&self, address: &str, hash: &str) -> anyhow::Result<std::fs::File> {
        self.run(|connection, root| {
            let catalog = crate::shared_audio::catalog(connection)?;
            let id = catalog
                .addresses
                .get(address)
                .map(String::as_str)
                .unwrap_or(address);
            anyhow::ensure!(
                catalog.pins.get(id).is_some_and(|p| p.contains(hash)),
                "unknown track/audio binding"
            );
            let object = catalog
                .objects
                .get(hash)
                .ok_or_else(|| anyhow::anyhow!("audio unavailable"))?;
            for locator in &object.locators {
                match std::fs::File::open(root.join("objects").join(locator)) {
                    Ok(file) if object.bytes == Some(file.metadata()?.len()) => return Ok(file),
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
            }
            anyhow::bail!("audio unavailable")
        })
    }
}

fn decode(
    record: &crate::shared_audio::Signed,
    proof: &crate::enrollment::Proof,
) -> anyhow::Result<crate::shared_audio::Body> {
    anyhow::ensure!(
        record.payload.len() <= 1024 * 1024
            && record.id == crate::shared_audio::hash(record.payload.as_bytes()),
        "invalid record identity or size"
    );
    let body: crate::shared_audio::Body = serde_json::from_str(
        record
            .payload
            .strip_prefix(crate::shared_audio::DOMAIN)
            .ok_or_else(|| anyhow::anyhow!("unsupported record version"))?,
    )?;
    let chain = proof.chain(&body.grant)?;
    let grant = chain[0];
    anyhow::ensure!(
        grant.cluster == body.cluster && grant.member == body.author && grant.host,
        "unauthorized record author"
    );
    let signature: [u8; 64] = hex::decode(&record.signature)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid signature"))?;
    body.author.parse::<iroh::EndpointId>()?.verify(
        record.payload.as_bytes(),
        &iroh::Signature::from_bytes(&signature),
    )?;
    anyhow::ensure!(
        crate::shared_audio::valid_hash(&body.baseline)
            && crate::shared_audio::valid_hash(&body.request_digest)
            && crate::shared_audio::identity(&body.request),
        "invalid record evidence"
    );
    anyhow::ensure!(
        !body.edits.is_empty() && body.edits.len() <= 2,
        "invalid edit count"
    );
    let mut subjects = std::collections::BTreeSet::new();
    for edit in &body.edits {
        anyhow::ensure!(
            subjects.insert(edit.value.subject()),
            "duplicate edit subject"
        );
        anyhow::ensure!(
            edit.parents.len() <= 64
                && edit
                    .parents
                    .iter()
                    .all(|p| p != &record.id && crate::shared_audio::valid_hash(p))
                && edit
                    .parents
                    .iter()
                    .collect::<std::collections::BTreeSet<_>>()
                    .len()
                    == edit.parents.len(),
            "invalid revision parents"
        );
        match &edit.value {
            crate::shared_audio::Value::Track { track, evidence } => {
                crate::shared_audio::validate_evidence(evidence)?;
                anyhow::ensure!(
                    crate::shared_audio::identity(&track.id)
                        && track.audio.len() <= 32
                        && track
                            .audio
                            .iter()
                            .all(|h| crate::shared_audio::valid_hash(h)),
                    "invalid track"
                );
                anyhow::ensure!(
                    track
                        .preferred
                        .as_ref()
                        .is_none_or(|h| track.audio.contains(h))
                        && track.added_at.is_none_or(|t| t >= 0),
                    "invalid preferred audio or addition time"
                );
            }
            crate::shared_audio::Value::Correspondence {
                source,
                target,
                evidence,
            } => {
                anyhow::ensure!(
                    crate::shared_audio::identity(&source.library)
                        && crate::shared_audio::identity(&source.track)
                        && target
                            .as_ref()
                            .is_none_or(|t| crate::shared_audio::identity(t)),
                    "invalid source identity"
                );
                crate::shared_audio::validate_evidence(evidence)?;
            }
        }
    }
    Ok(body)
}

fn catalog(connection: &rusqlite::Connection) -> anyhow::Result<crate::shared_audio::Catalog> {
    let (fingerprint, raw): (String, Vec<u8>) = connection.query_row(
        "SELECT fingerprint, payload FROM shared_baseline",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let baseline: crate::shared_audio::Baseline = serde_json::from_slice(&raw)?;
    let mut catalog = crate::shared_audio::Catalog {
        version: 1,
        cluster: baseline.cluster,
        library: baseline.library,
        legacy_organization: baseline.legacy_organization,
        baseline: fingerprint.clone(),
        tracks: baseline.tracks,
        addresses: baseline.addresses,
        objects: baseline.objects,
        pins: baseline.pins,
        correspondences: Default::default(),
        heads: Default::default(),
        conflicts: Default::default(),
        incomplete: vec![],
    };
    let mut statement =
        connection.prepare("SELECT sha256, bytes, locator FROM shared_objects ORDER BY sha256")?;
    for row in statement.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, String>(2)?,
        ))
    })? {
        let (hash, bytes, locator) = row?;
        let bytes = u64::try_from(bytes)?;
        let object = catalog
            .objects
            .entry(hash.clone())
            .or_insert(crate::shared_audio::Object {
                sha256: hash,
                bytes: Some(bytes),
                locators: vec![],
            });
        object.bytes = Some(bytes);
        if !object.locators.contains(&locator) {
            object.locators.insert(0, locator);
        }
    }
    let proof = crate::enrollment::read_proof(connection)?;
    let mut bodies = std::collections::BTreeMap::new();
    for raw in crate::shared_audio::rows(connection, "shared_records")? {
        let record: crate::shared_audio::Signed = serde_json::from_slice(&raw)?;
        let body = crate::shared_audio::decode(&record, &proof)?;
        anyhow::ensure!(body.baseline == fingerprint, "different migration baseline");
        anyhow::ensure!(body.cluster == catalog.cluster, "cross-cluster record");
        bodies.insert(record.id, body);
    }
    let mut complete = std::collections::BTreeSet::new();
    loop {
        let before = complete.len();
        for (id, body) in &bodies {
            if complete.contains(id) {
                continue;
            }
            let mut ready = true;
            for edit in &body.edits {
                for parent in &edit.parents {
                    if let Some(previous) = bodies.get(parent) {
                        anyhow::ensure!(
                            previous
                                .edits
                                .iter()
                                .any(|e| e.value.subject() == edit.value.subject()),
                            "wrong revision parent"
                        );
                    }
                    ready &= complete.contains(parent);
                }
                if let crate::shared_audio::Value::Correspondence {
                    target: Some(target),
                    ..
                } = &edit.value
                {
                    ready &= catalog.tracks.contains_key(target) || body.edits.iter().any(|e| matches!(&e.value, crate::shared_audio::Value::Track { track, .. } if &track.id == target));
                }
            }
            if ready {
                complete.insert(id.clone());
                for edit in &body.edits {
                    if let crate::shared_audio::Value::Track { track, .. } = &edit.value {
                        anyhow::ensure!(
                            catalog
                                .addresses
                                .get(&track.id)
                                .is_none_or(|target| target == &track.id),
                            "legacy alias cannot become a different track"
                        );
                        anyhow::ensure!(
                            catalog
                                .tracks
                                .get(&track.id)
                                .is_none_or(|previous| previous.added_at == track.added_at),
                            "addition time is immutable"
                        );
                        catalog
                            .tracks
                            .entry(track.id.clone())
                            .or_insert(track.clone());
                        catalog
                            .pins
                            .entry(track.id.clone())
                            .or_default()
                            .extend(track.audio.iter().cloned());
                    }
                }
            }
        }
        if complete.len() == before {
            break;
        }
    }
    let mut versions: std::collections::BTreeMap<
        String,
        std::collections::BTreeMap<String, crate::shared_audio::Value>,
    > = Default::default();
    let mut superseded: std::collections::BTreeMap<String, std::collections::BTreeSet<String>> =
        Default::default();
    for (id, body) in &bodies {
        if !complete.contains(id) {
            catalog.incomplete.push(id.clone());
            continue;
        }
        for edit in &body.edits {
            let subject = edit.value.subject();
            versions
                .entry(subject.clone())
                .or_default()
                .insert(id.clone(), edit.value.clone());
            superseded
                .entry(subject)
                .or_default()
                .extend(edit.parents.iter().cloned());
        }
    }
    for (subject, values) in versions {
        let heads: Vec<_> = values
            .keys()
            .filter(|id| !superseded[&subject].contains(*id))
            .cloned()
            .collect();
        if heads.len() == 1 {
            match &values[&heads[0]] {
                crate::shared_audio::Value::Track { track, .. } => {
                    catalog.tracks.insert(track.id.clone(), track.clone());
                }
                crate::shared_audio::Value::Correspondence {
                    target: Some(target),
                    ..
                } => {
                    catalog
                        .correspondences
                        .insert(subject.clone(), target.clone());
                }
                _ => {}
            }
        } else {
            catalog.conflicts.insert(subject.clone());
        }
        catalog.heads.insert(subject, heads);
    }
    let mut targets: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for (source, target) in &catalog.correspondences {
        targets
            .entry(target.clone())
            .or_default()
            .push(source.clone());
    }
    for (target, sources) in targets {
        if sources.len() > 1 || catalog.conflicts.contains(&format!("track:{target}")) {
            catalog.conflicts.extend(sources);
        }
    }
    catalog
        .correspondences
        .retain(|source, _| !catalog.conflicts.contains(source));
    for hash in catalog.pins.values().flatten() {
        catalog
            .objects
            .entry(hash.clone())
            .or_insert(crate::shared_audio::Object {
                sha256: hash.clone(),
                bytes: None,
                locators: vec![],
            });
    }
    Ok(catalog)
}

fn validate_evidence(evidence: &crate::shared_audio::Evidence) -> anyhow::Result<()> {
    anyhow::ensure!(
        crate::shared_audio::valid_hash(&evidence.snapshot)
            && crate::shared_audio::valid_hash(&evidence.catalog)
            && !evidence.reason.trim().is_empty()
            && evidence.reason.len() <= 4096,
        "invalid approval evidence"
    );
    Ok(())
}

fn playlist_records(
    connection: &rusqlite::Connection,
) -> anyhow::Result<Vec<crate::playlists::Signed>> {
    crate::shared_audio::rows(connection, "playlist_records")?
        .into_iter()
        .chain(crate::shared_audio::rows(connection, "shared_playlists")?)
        .map(|raw| Ok(serde_json::from_slice(&raw)?))
        .collect()
}

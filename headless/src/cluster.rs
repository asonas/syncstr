#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ClusterIdentity {
    pub id: String,
    pub member_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct KnownPeer {
    pub id: String,
    pub name: String,
    pub address: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Location {
    pub library_id: String,
    pub track_id: String,
    pub member_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Object {
    pub sha256: String,
    pub bytes: i64,
    pub locations: Vec<crate::cluster::Location>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Inventory {
    pub cluster: Option<crate::cluster::ClusterIdentity>,
    pub peers: Vec<crate::cluster::KnownPeer>,
    pub objects: Vec<crate::cluster::Object>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct PendingChange {
    pub id: String,
    pub author: String,
    pub parents: Vec<String>,
    pub operation: String,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JobState {
    Queued,
    Running,
    Complete,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TransferJob {
    pub id: String,
    pub sha256: String,
    pub source: String,
    pub destination: String,
    pub state: crate::cluster::JobState,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Capabilities {
    pub version: u8,
    pub membership: bool,
    pub deletions: bool,
    pub conflicts: bool,
}

impl crate::cluster::Capabilities {
    pub fn allows_automatic_writer(&self) -> bool {
        self.version == 1 && self.membership && self.deletions && self.conflicts
    }
}

pub(crate) fn migrate(connection: &rusqlite::Connection) -> anyhow::Result<()> {
    connection.execute_batch("CREATE TABLE IF NOT EXISTS cluster_schema (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL);")?;
    let inserted = connection.execute("INSERT OR IGNORE INTO cluster_schema VALUES (1, 1)", [])?;
    let version: i64 = connection.query_row(
        "SELECT version FROM cluster_schema WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    anyhow::ensure!(version == 1, "unsupported cluster schema {version}");
    if inserted == 0 {
        connection.execute(
            "UPDATE cluster_jobs SET state = 'queued' WHERE state = 'running'",
            [],
        )?;
        return Ok(());
    }
    connection.execute_batch("CREATE TABLE IF NOT EXISTS cluster_identity (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL, member_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS cluster_peers (id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT);
        CREATE TABLE IF NOT EXISTS cluster_objects (sha256 TEXT PRIMARY KEY, bytes INTEGER NOT NULL CHECK(bytes > 0));
        CREATE TABLE IF NOT EXISTS cluster_locations (library_id TEXT NOT NULL, track_id TEXT NOT NULL, member_id TEXT NOT NULL, sha256 TEXT NOT NULL, PRIMARY KEY(library_id, track_id, member_id));
        CREATE TABLE IF NOT EXISTS cluster_pending_changes (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS cluster_jobs (id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, source TEXT NOT NULL, destination TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('queued', 'running', 'complete')));
        UPDATE cluster_jobs SET state = 'queued' WHERE state = 'running';")?;
    let library: String =
        connection.query_row("SELECT id FROM library WHERE singleton = 1", [], |row| {
            row.get(0)
        })?;
    let mut statement = connection.prepare("SELECT payload FROM tracks ORDER BY id")?;
    let entries = statement.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
    for entry in entries {
        crate::cluster::index_entry(
            connection,
            &library,
            None,
            &serde_json::from_slice(&entry?)?,
        )?;
    }
    Ok(())
}

pub(crate) fn index_entry(
    connection: &rusqlite::Connection,
    library: &str,
    member: Option<&str>,
    entry: &crate::model::Entry,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        entry.sha256.len() == 64
            && entry
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "invalid content hash"
    );
    anyhow::ensure!(
        entry.track.size > 0 && entry.track.size <= crate::model::MAX_AUDIO,
        "invalid object size"
    );
    anyhow::ensure!(
        !library.is_empty() && !entry.track.id.is_empty(),
        "missing source identity"
    );
    connection.execute(
        "INSERT OR IGNORE INTO cluster_objects VALUES (?, ?)",
        rusqlite::params![entry.sha256, entry.track.size as i64],
    )?;
    let bytes: i64 = connection.query_row(
        "SELECT bytes FROM cluster_objects WHERE sha256 = ?",
        [&entry.sha256],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        bytes == entry.track.size as i64,
        "inconsistent object length"
    );
    connection.execute("INSERT INTO cluster_locations VALUES (?, ?, ?, ?) ON CONFLICT(library_id, track_id, member_id) DO UPDATE SET sha256 = excluded.sha256",
        rusqlite::params![library, entry.track.id, member.unwrap_or(""), entry.sha256])?;
    Ok(())
}

fn validate_member(id: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        id.len() == 64
            && id
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "invalid member public key"
    );
    Ok(())
}

impl crate::store::Store {
    pub async fn save_pending_cluster_change(
        &self,
        change: crate::cluster::PendingChange,
    ) -> anyhow::Result<()> {
        uuid::Uuid::parse_str(&change.id)?;
        crate::cluster::validate_member(&change.author)?;
        anyhow::ensure!(
            change.parents.len() <= 64 && !change.parents.contains(&change.id),
            "invalid causal parents"
        );
        let mut unique = std::collections::HashSet::new();
        for parent in &change.parents {
            uuid::Uuid::parse_str(parent)?;
            anyhow::ensure!(unique.insert(parent), "duplicate causal parent");
        }
        anyhow::ensure!(
            change.operation.len() <= crate::model::MAX_METADATA,
            "change too large"
        );
        let operation: serde_json::Value = serde_json::from_str(&change.operation)?;
        anyhow::ensure!(operation.is_object(), "operation must be an object");
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let payload = serde_json::to_vec(&change)?;
            transaction.execute(
                "INSERT OR IGNORE INTO cluster_pending_changes VALUES (?, ?)",
                rusqlite::params![change.id, payload],
            )?;
            let stored: Vec<u8> = transaction.query_row(
                "SELECT payload FROM cluster_pending_changes WHERE id = ?",
                [&change.id],
                |row| row.get(0),
            )?;
            anyhow::ensure!(stored == payload, "inconsistent change replay");
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub async fn pending_cluster_changes(
        &self,
    ) -> anyhow::Result<Vec<crate::cluster::PendingChange>> {
        self.run(|connection, _| {
            let mut statement =
                connection.prepare("SELECT payload FROM cluster_pending_changes ORDER BY rowid")?;
            statement
                .query_map([], |row| row.get::<_, Vec<u8>>(0))?
                .map(|row| Ok(serde_json::from_slice(&row?)?))
                .collect()
        })
        .await
    }

    pub async fn enqueue_cluster_job(
        &self,
        job: crate::cluster::TransferJob,
    ) -> anyhow::Result<()> {
        uuid::Uuid::parse_str(&job.id)?;
        crate::cluster::validate_member(&job.source)?;
        crate::cluster::validate_member(&job.destination)?;
        anyhow::ensure!(
            job.source != job.destination && job.state == crate::cluster::JobState::Queued,
            "invalid new transfer job"
        );
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let exists: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM cluster_objects WHERE sha256 = ?)",
                [&job.sha256],
                |row| row.get(0),
            )?;
            anyhow::ensure!(exists, "unknown object");
            transaction.execute(
                "INSERT OR IGNORE INTO cluster_jobs VALUES (?, ?, ?, ?, 'queued')",
                rusqlite::params![job.id, job.sha256, job.source, job.destination],
            )?;
            let stored: (String, String, String) = transaction.query_row(
                "SELECT sha256, source, destination FROM cluster_jobs WHERE id = ?",
                [&job.id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
            anyhow::ensure!(
                stored == (job.sha256, job.source, job.destination),
                "inconsistent job replay"
            );
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub async fn begin_cluster_job(&self, id: String) -> anyhow::Result<()> {
        self.run(move |connection, _| {
            let changed = connection.execute(
                "UPDATE cluster_jobs SET state = 'running' WHERE id = ? AND state = 'queued'",
                [id],
            )?;
            anyhow::ensure!(changed == 1, "job is not queued");
            Ok(())
        })
        .await
    }

    pub async fn cluster_jobs(&self) -> anyhow::Result<Vec<crate::cluster::TransferJob>> {
        self.run(|connection, _| {
            let mut statement = connection.prepare(
                "SELECT id, sha256, source, destination, state FROM cluster_jobs ORDER BY rowid",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })?;
            rows.map(|row| {
                let (id, sha256, source, destination, state) = row?;
                let state = match state.as_str() {
                    "queued" => crate::cluster::JobState::Queued,
                    "running" => crate::cluster::JobState::Running,
                    "complete" => crate::cluster::JobState::Complete,
                    _ => anyhow::bail!("invalid job state"),
                };
                Ok(crate::cluster::TransferJob {
                    id,
                    sha256,
                    source,
                    destination,
                    state,
                })
            })
            .collect()
        })
        .await
    }
    pub async fn create_cluster(
        &self,
        member_id: String,
    ) -> anyhow::Result<crate::cluster::ClusterIdentity> {
        crate::cluster::validate_member(&member_id)?;
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            transaction.execute(
                "INSERT OR IGNORE INTO cluster_identity VALUES (1, ?, ?)",
                rusqlite::params![uuid::Uuid::new_v4().to_string(), member_id],
            )?;
            let identity = transaction.query_row(
                "SELECT id, member_id FROM cluster_identity WHERE singleton = 1",
                [],
                |row| {
                    Ok(crate::cluster::ClusterIdentity {
                        id: row.get(0)?,
                        member_id: row.get(1)?,
                    })
                },
            )?;
            anyhow::ensure!(
                identity.member_id == member_id,
                "cluster belongs to a different local key"
            );
            transaction.commit()?;
            Ok(identity)
        })
        .await
    }

    pub async fn remember_cluster_peer(
        &self,
        peer: crate::cluster::KnownPeer,
    ) -> anyhow::Result<()> {
        crate::cluster::validate_member(&peer.id)?;
        anyhow::ensure!(
            peer.name.len() <= 2048
                && peer
                    .address
                    .as_ref()
                    .is_none_or(|value| value.len() <= 16384),
            "peer record too large"
        );
        if let Some(address) = &peer.address {
            let value: serde_json::Value = serde_json::from_str(address)?;
            anyhow::ensure!(
                value["id"].as_str() == Some(&peer.id),
                "peer address identity mismatch"
            );
        }
        self.run(move |connection, _| {
            connection.execute("INSERT INTO cluster_peers VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, address = excluded.address", rusqlite::params![peer.id, peer.name, peer.address])?;
            Ok(())
        }).await
    }

    pub async fn observe_cluster_catalog(
        &self,
        catalog: crate::model::Catalog,
        member: Option<String>,
    ) -> anyhow::Result<()> {
        if let Some(member) = &member {
            crate::cluster::validate_member(member)?;
        }
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            for entry in catalog.entries {
                crate::cluster::index_entry(&transaction, &catalog.id, member.as_deref(), &entry)?;
            }
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub async fn cluster_inventory(&self) -> anyhow::Result<crate::cluster::Inventory> {
        self.run(|connection, _| {
            use rusqlite::OptionalExtension as _;
            let cluster = connection.query_row("SELECT id, member_id FROM cluster_identity WHERE singleton = 1", [], |row| Ok(crate::cluster::ClusterIdentity { id:row.get(0)?, member_id:row.get(1)? })).optional()?;
            let mut statement = connection.prepare("SELECT id, name, address FROM cluster_peers ORDER BY id")?;
            let peers = statement.query_map([], |row| Ok(crate::cluster::KnownPeer { id:row.get(0)?, name:row.get(1)?, address:row.get(2)? }))?.collect::<Result<Vec<_>, _>>()?;
            let mut statement = connection.prepare("SELECT sha256, bytes FROM cluster_objects ORDER BY sha256")?;
            let mut objects = statement.query_map([], |row| Ok(crate::cluster::Object { sha256:row.get(0)?, bytes:row.get(1)?, locations:Vec::new() }))?.collect::<Result<Vec<_>, _>>()?;
            for object in &mut objects {
                let mut statement = connection.prepare("SELECT library_id, track_id, NULLIF(member_id, '') FROM cluster_locations WHERE sha256 = ? ORDER BY library_id, track_id, member_id")?;
                object.locations = statement.query_map([&object.sha256], |row| Ok(crate::cluster::Location { library_id:row.get(0)?, track_id:row.get(1)?, member_id:row.get(2)? }))?.collect::<Result<Vec<_>, _>>()?;
            }
            Ok(crate::cluster::Inventory { cluster, peers, objects })
        }).await
    }
}

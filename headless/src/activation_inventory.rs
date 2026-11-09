//! Offline evidence only. No store constructors, migrations, transport or writers.
use anyhow::Context as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

const VERSION: u8 = 1;
const MAX_JSON: u64 = 32 * 1024 * 1024;

#[derive(clap::Subcommand)]
pub enum Command {
    /// Inspect one stopped host without opening a writable store.
    Host {
        #[arg(long)]
        input: PathBuf,
    },
    /// Compare collected host reports and device intent exports offline.
    Compare {
        #[arg(long)]
        input: PathBuf,
    },
}

pub fn run(command: Command) -> anyhow::Result<()> {
    let value = match command {
        Command::Host { input } => serde_json::to_value(host(read_json(&input)?)?)?,
        Command::Compare { input } => serde_json::to_value(compare(read_json(&input)?)?)?,
    };
    println!("{}", canonical(&value)?);
    Ok(())
}

/// Paths are input-only. Evidence does not embed machine-specific paths.
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostInput {
    version: u8,
    host: String,
    cluster: String,
    data: PathBuf,
    build: String,
    profiles: BTreeSet<String>,
    /// Stable labels mapped to files/directories outside the data directory.
    evidence: BTreeMap<String, PathBuf>,
    /// An operator assertion, not an inference from the lock file.
    stopped_and_fenced: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileEvidence {
    bytes: u64,
    sha256: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostReport {
    version: u8,
    host: String,
    cluster: String,
    schema: i64,
    build: String,
    profiles: BTreeSet<String>,
    stopped_and_fenced: bool,
    baseline: String,
    proof: crate::enrollment::Proof,
    /// Public semantic evidence; private request/configuration bytes are hashed only.
    categories: BTreeMap<String, Value>,
    files: BTreeMap<String, FileEvidence>,
    findings: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Collection {
    version: u8,
    cluster: String,
    expected_hosts: BTreeSet<String>,
    expected_members: BTreeSet<String>,
    hosts: Vec<PathBuf>,
    clients: Vec<PathBuf>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientExport {
    version: u8,
    cluster: String,
    member: String,
    baseline: String,
    build: String,
    /// Digest of the privately retained complete queue/receipt snapshot.
    queue: FileEvidence,
    queue_path: String,
    requests: Vec<ClientRequest>,
    staging: BTreeMap<String, FileEvidence>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientRequest {
    operation: String,
    id: String,
    digest: String,
    target_host: String,
    state: IntentState,
    /// Only evidence identifiers/digests, never raw envelopes or secrets.
    eligibility: Option<String>,
    receipts: BTreeSet<String>,
    staging: BTreeSet<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum IntentState {
    NeverSent,
    OutcomeUnknown,
    Accepted,
}

#[derive(Serialize)]
pub struct Comparison {
    version: u8,
    cluster: String,
    /// This never grants activation readiness, even when empty.
    blocking: BTreeSet<String>,
    differences: BTreeMap<String, BTreeMap<String, String>>,
    availability_differences: BTreeMap<String, BTreeMap<String, String>>,
    availability: BTreeMap<String, Value>,
    hosts: BTreeSet<String>,
    clients: BTreeMap<String, ClientExport>,
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> anyhow::Result<T> {
    use std::io::Read as _;
    let file = std::fs::File::open(path)?;
    anyhow::ensure!(file.metadata()?.len() <= MAX_JSON, "JSON input too large");
    let mut bytes = Vec::new();
    file.take(MAX_JSON + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= MAX_JSON, "JSON input grew too large");
    Ok(serde_json::from_slice(&bytes)?)
}

fn canonical(value: &Value) -> anyhow::Result<String> {
    fn sorted(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let ordered: BTreeMap<_, _> =
                    map.iter().map(|(k, v)| (k.clone(), sorted(v))).collect();
                Value::Object(ordered.into_iter().collect())
            }
            Value::Array(values) => Value::Array(values.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    Ok(serde_json::to_string(&sorted(value))?)
}

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn semantic_digest(value: &Value) -> anyhow::Result<String> {
    Ok(digest(canonical(value)?.as_bytes()))
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn label(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control),
        "empty, oversized or control-containing identifier"
    );
    Ok(())
}

fn relative(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && !value.contains('\\')
            && !value.contains(':')
            && !value.chars().any(char::is_control)
            && !value
                .split('/')
                .any(|c| c.is_empty() || c == "." || c == "..")
            && Path::new(value)
                .components()
                .all(|c| matches!(c, Component::Normal(_))),
        "unsafe relative path"
    );
    Ok(())
}

#[derive(PartialEq, Eq)]
struct ObservedFile {
    evidence: FileEvidence,
    modified: std::time::SystemTime,
}

fn snapshot(path: &Path) -> anyhow::Result<BTreeMap<String, ObservedFile>> {
    fn visit(
        path: &Path,
        name: &str,
        out: &mut BTreeMap<String, ObservedFile>,
    ) -> anyhow::Result<()> {
        let metadata = std::fs::symlink_metadata(path)?;
        anyhow::ensure!(!metadata.file_type().is_symlink(), "symlink source refused");
        if metadata.is_dir() {
            // Include directory entries so empty-directory changes also invalidate the cut.
            out.insert(
                format!("{name}/"),
                ObservedFile {
                    evidence: FileEvidence {
                        bytes: 0,
                        sha256: digest(b"directory"),
                    },
                    modified: metadata.modified()?,
                },
            );
            for entry in std::fs::read_dir(path)? {
                let entry = entry?;
                let filename = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("non-UTF-8 source path"))?;
                relative(&filename)?;
                visit(&entry.path(), &format!("{name}/{filename}"), out)?;
            }
        } else {
            anyhow::ensure!(metadata.is_file(), "nonregular source refused");
            let mut file = std::fs::File::open(path)?;
            let mut hasher = Sha256::new();
            let bytes = std::io::copy(&mut file, &mut hasher)?;
            anyhow::ensure!(bytes == metadata.len(), "source changed during hashing");
            out.insert(
                name.into(),
                ObservedFile {
                    evidence: FileEvidence {
                        bytes,
                        sha256: hex::encode(hasher.finalize()),
                    },
                    modified: metadata.modified()?,
                },
            );
        }
        Ok(())
    }
    let mut out = BTreeMap::new();
    visit(path, "root", &mut out)?;
    Ok(out)
}

fn observe(input: &HostInput) -> anyhow::Result<BTreeMap<String, ObservedFile>> {
    let mut files = BTreeMap::new();
    for (name, file) in snapshot(&input.data)? {
        files.insert(format!("data/{name}"), file);
    }
    for (name, path) in &input.evidence {
        relative(name)?;
        for (entry, file) in snapshot(path)? {
            anyhow::ensure!(
                files
                    .insert(format!("evidence/{name}/{entry}"), file)
                    .is_none(),
                "duplicate evidence path"
            );
        }
    }
    Ok(files)
}

fn readonly(root: &Path) -> anyhow::Result<rusqlite::Connection> {
    // Immutable SQLite avoids even read-only WAL opening creating a shm file.
    // Only a stopped, sidecar-free database is eligible for this path.
    for suffix in ["-wal", "-shm", "-journal"] {
        anyhow::ensure!(
            !root.join(format!("node.sqlite{suffix}")).try_exists()?,
            "SQLite sidecars require a separately prepared consistent stopped snapshot"
        );
    }
    let path = root.join("node.sqlite").canonicalize()?;
    let mut uri =
        reqwest::Url::from_file_path(path).map_err(|_| anyhow::anyhow!("invalid database path"))?;
    uri.set_query(Some("mode=ro&immutable=1"));
    let connection = rusqlite::Connection::open_with_flags(
        uri.as_str(),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )?;
    connection.execute_batch("PRAGMA query_only=ON; BEGIN;")?;
    Ok(connection)
}

pub fn host(input: HostInput) -> anyhow::Result<HostReport> {
    anyhow::ensure!(
        input.version == VERSION && input.stopped_and_fenced,
        "version 1 and explicit stopped/fenced assertion required"
    );
    label(&input.host)?;
    label(&input.build)?;
    let before = observe(&input)?;
    let lock_file = std::fs::File::open(input.data.join("node.lock"))?;
    let _lock = crate::node_lock::NodeLock::acquire(lock_file)
        .context("host is busy or read-only locking unsupported")?;
    let connection = readonly(&input.data)?;
    let schema: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    anyhow::ensure!(matches!(schema, 4 | 5), "unsupported inventory schema");
    let (cluster, member): (String, String) = connection.query_row(
        "SELECT id, member_id FROM cluster_identity WHERE singleton=1",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    anyhow::ensure!(
        cluster == input.cluster && member == input.host,
        "host/cluster descriptor mismatch"
    );
    let mut proof = crate::enrollment::read_proof(&connection)?;
    proof.grants.sort_by(|a, b| a.id.cmp(&b.id));
    proof.revocations.sort_by(|a, b| a.id.cmp(&b.id));
    let mut findings = BTreeSet::new();
    validate_proof(&proof, &cluster, &mut findings);
    if !proof
        .grants
        .iter()
        .any(|g| g.member == member && g.host && proof.verify(&g.id).is_ok())
    {
        findings.insert("local-host-not-authorized".into());
    }
    let mut categories = BTreeMap::new();
    let baseline;
    let mut objects = BTreeMap::new();
    if schema == 5 {
        baseline = connection.query_row(
            "SELECT fingerprint FROM shared_baseline WHERE singleton=1",
            [],
            |r| r.get::<_, String>(0),
        )?;
        let payload: Vec<u8> = connection.query_row(
            "SELECT payload FROM shared_baseline WHERE singleton=1",
            [],
            |r| r.get(0),
        )?;
        if digest(&payload) != baseline {
            findings.insert("baseline-payload-digest-mismatch".into());
        }
        match crate::shared_audio::catalog(&connection) {
            Ok(catalog) => {
                anyhow::ensure!(catalog.cluster == cluster, "cross-cluster catalog");
                if !catalog.conflicts.is_empty() {
                    findings.insert("music-conflicts".into());
                }
                if !catalog.incomplete.is_empty() {
                    findings.insert("incomplete-music-parents".into());
                }
                objects = catalog.objects.clone();
                let value = serde_json::to_value(catalog)?;
                for key in [
                    "tracks",
                    "addresses",
                    "legacy_organization",
                    "pins",
                    "correspondences",
                    "heads",
                    "candidates",
                    "conflicts",
                    "incomplete",
                    "album_visibility",
                ] {
                    categories.insert(key.into(), value.get(key).cloned().unwrap_or(Value::Null));
                }
            }
            Err(_) => {
                // Keep history/file evidence available even when the projection is invalid.
                findings.insert("invalid-music-projection-or-signatures".into());
            }
        }
    } else {
        let legacy = crate::shared_audio::legacy(&connection)?;
        baseline = digest(&serde_json::to_vec(&legacy)?);
        objects = legacy.objects.clone();
        let value = serde_json::to_value(legacy)?;
        for key in ["tracks", "addresses", "legacy_organization", "pins"] {
            categories.insert(key.into(), value[key].clone());
        }
    }
    anyhow::ensure!(valid_digest(&baseline), "invalid baseline fingerprint");
    validate_aliases(&categories, &mut findings);
    for table in [
        "shared_records",
        "shared_playlists",
        "playlist_records",
        "cluster_changes",
        "shared_requests",
        "shared_member_requests",
        "shared_member_playlist_requests",
        "shared_member_object_requests",
        "shared_object_requests",
        "shared_playlist_requests",
        "shared_cursors",
        "playlist_cursors",
        "shared_request_index_positions",
        "cluster_pending_changes",
        "cluster_jobs",
    ] {
        categories.insert(table.into(), table_evidence(&connection, table)?);
    }
    categories.insert(
        "music_history".into(),
        music_evidence(&connection, &proof, &cluster, &baseline, &mut findings)?,
    );
    let playlists = playlist_evidence(&connection, &proof, &cluster, &mut findings)?;
    categories.insert(
        "playlist_pins".into(),
        playlist_pins(&playlists, &categories, &mut findings)?,
    );
    categories.insert("playlists".into(), playlists);
    // Retain legacy locator evidence even if projection construction failed.
    let mut statement = connection.prepare("SELECT sha256, suffix FROM tracks ORDER BY id")?;
    for row in statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (sha256, suffix) = row?;
        let object = objects
            .entry(sha256.clone())
            .or_insert(crate::shared_audio::Object {
                sha256: sha256.clone(),
                bytes: None,
                locators: vec![],
            });
        let locator = format!("{sha256}.{suffix}");
        if !object.locators.contains(&locator) {
            object.locators.push(locator);
        }
    }
    drop(statement);
    categories.insert(
        "availability".into(),
        audio_evidence(&input.data, &objects, &mut findings)?,
    );
    let raw: Vec<u8> = connection.query_row(
        "SELECT payload FROM organization WHERE singleton=1",
        [],
        |r| r.get(0),
    )?;
    let organization: crate::organization::Organization = serde_json::from_slice(&raw)?;
    let mut artwork = BTreeMap::new();
    let mut statement = connection.prepare("SELECT id, payload FROM artwork_assets ORDER BY id")?;
    for row in statement.query_map([], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
    })? {
        let (id, bytes) = row?;
        let actual = digest(&bytes);
        if actual != id {
            findings.insert(format!("corrupt-artwork:{id}"));
        }
        artwork.insert(id, json!({"bytes": bytes.len(), "sha256": actual}));
    }
    drop(statement);
    if let Some(art) = &organization.artwork {
        for (id, bytes) in &art.assets {
            if bytes.is_empty() {
                continue;
            }
            let actual = digest(bytes);
            if actual != *id {
                findings.insert(format!("corrupt-artwork:{id}"));
            }
            artwork.insert(id.clone(), json!({"bytes": bytes.len(), "sha256": actual}));
        }
        for candidate in &art.candidates {
            if !artwork.contains_key(&candidate.asset) {
                findings.insert(format!("missing-artwork:{}", candidate.asset));
            }
        }
    }
    categories.insert("artwork".into(), serde_json::to_value(artwork)?);
    let referenced: BTreeSet<_> = objects
        .values()
        .flat_map(|o| o.locators.iter().cloned())
        .collect();
    let unreferenced: BTreeSet<_> = before
        .keys()
        .filter_map(|p| p.strip_prefix("data/root/objects/"))
        .filter(|p| !p.ends_with('/') && !referenced.contains(*p))
        .collect();
    let staging: BTreeMap<_, _> = before
        .iter()
        .filter_map(|(p, f)| {
            p.strip_prefix("data/root/staging/")
                .filter(|p| !p.ends_with('/'))
                .map(|p| (p, &f.evidence))
        })
        .collect();
    categories.insert("unreferenced_objects".into(), json!(unreferenced));
    categories.insert("staging".into(), json!(staging));
    drop(connection);
    anyhow::ensure!(
        before == observe(&input)?,
        "source changed during inventory"
    );
    let files = before
        .into_iter()
        .filter(|(p, _)| !p.ends_with('/'))
        .map(|(p, f)| (p, f.evidence))
        .collect();
    Ok(HostReport {
        version: VERSION,
        host: member,
        cluster,
        schema,
        build: input.build,
        profiles: input.profiles,
        stopped_and_fenced: true,
        baseline,
        proof,
        categories,
        files,
        findings,
    })
}

fn validate_proof(
    proof: &crate::enrollment::Proof,
    cluster: &str,
    findings: &mut BTreeSet<String>,
) {
    if proof.grants.is_empty() {
        findings.insert("missing-membership-proof".into());
    }
    for grant in &proof.grants {
        if grant.cluster != cluster || proof.chain(&grant.id).is_err() {
            findings.insert(format!("invalid-membership-proof:{}", grant.id));
        }
    }
    match proof.membership_conflicts() {
        Ok(conflicts) => {
            for member in conflicts {
                findings.insert(format!("disputed-membership:{member}"));
            }
        }
        Err(_) => {
            findings.insert("invalid-revocation-history".into());
        }
    }
    if proof.revocations.iter().any(|r| r.cluster != cluster) {
        findings.insert("cross-cluster-revocation".into());
    }
    // verify evaluates revocations and disputed decisions, not just grant signatures.
    if !proof
        .grants
        .iter()
        .any(|g| g.host && proof.verify(&g.id).is_ok())
    {
        findings.insert("no-verifiable-host-authority".into());
    }
}

fn validate_aliases(categories: &BTreeMap<String, Value>, findings: &mut BTreeSet<String>) {
    let Some(addresses) = categories.get("addresses").and_then(Value::as_object) else {
        return;
    };
    let tracks = categories.get("tracks").and_then(Value::as_object);
    for source in addresses.keys() {
        let mut current = source.as_str();
        let mut seen = BTreeSet::new();
        loop {
            if !seen.insert(current) {
                findings.insert(format!("alias-cycle:{source}"));
                break;
            }
            match addresses.get(current).and_then(Value::as_str) {
                Some(next) if next != current => current = next,
                _ => {
                    if tracks.is_none_or(|t| !t.contains_key(current)) {
                        findings.insert(format!("dangling-alias:{source}"));
                    }
                    break;
                }
            }
        }
    }
}

fn exists(connection: &rusqlite::Connection, table: &str) -> anyhow::Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
        [table],
        |r| r.get(0),
    )?)
}

/// Sorted typed row hashes retain exact SQLite payload bytes without exposing receipts.
fn table_evidence(connection: &rusqlite::Connection, table: &str) -> anyhow::Result<Value> {
    if !exists(connection, table)? {
        return Ok(json!({"present": false}));
    }
    // Table identifiers come only from the constant allowlist above.
    let mut statement = connection.prepare(&format!("SELECT * FROM \"{table}\""))?;
    let columns = statement.column_count();
    let rows = statement.query_map([], |row| {
        let mut cells = Vec::new();
        for index in 0..columns {
            use rusqlite::types::ValueRef;
            cells.push(match row.get_ref(index)? {
                ValueRef::Null => json!(["null"]),
                ValueRef::Integer(v) => json!(["integer", v]),
                ValueRef::Real(v) => json!(["real-bits", v.to_bits()]),
                ValueRef::Text(v) => json!(["text", hex::encode(v)]),
                ValueRef::Blob(v) => json!(["blob", hex::encode(v)]),
            });
        }
        Ok(digest(
            &serde_json::to_vec(&cells).expect("JSON cells serialize"),
        ))
    })?;
    let mut hashes = rows.collect::<Result<Vec<_>, _>>()?;
    hashes.sort();
    Ok(json!({"present": true, "count": hashes.len(), "rows": hashes}))
}

fn music_evidence(
    connection: &rusqlite::Connection,
    proof: &crate::enrollment::Proof,
    cluster: &str,
    baseline: &str,
    findings: &mut BTreeSet<String>,
) -> anyhow::Result<Value> {
    let mut records = BTreeMap::new();
    let mut parents: BTreeMap<String, Vec<String>> = BTreeMap::new();
    if exists(connection, "shared_records")? {
        let mut statement = connection.prepare("SELECT payload FROM shared_records ORDER BY id")?;
        for raw in statement.query_map([], |r| r.get::<_, Vec<u8>>(0))? {
            let raw = raw?;
            if let Ok(record) = serde_json::from_slice::<crate::shared_audio::Signed>(&raw)
                && let Ok(body) = crate::shared_audio::decode(&record, proof)
                && body.cluster == cluster
                && body.baseline == baseline
            {
                parents.insert(
                    record.id.clone(),
                    body.edits.iter().flat_map(|e| e.parents.clone()).collect(),
                );
                records.insert(record.id, json!({"payload_digest": digest(record.payload.as_bytes()), "member": body.origin.as_ref().map(|o| &o.member).unwrap_or(&body.author), "request": body.request, "digest": body.request_digest}));
            } else {
                findings.insert(format!("invalid-music-record:{}", digest(&raw)));
            }
        }
    }
    let mut legacy = Vec::new();
    if exists(connection, "cluster_changes")? {
        let mut statement =
            connection.prepare("SELECT payload FROM cluster_changes ORDER BY id")?;
        for raw in statement.query_map([], |r| r.get::<_, Vec<u8>>(0))? {
            let raw = raw?;
            if let Ok(record) = serde_json::from_slice::<crate::cluster_changes::Change>(&raw)
                && record.cluster == cluster
                && record.validate(proof).is_ok()
            {
                let refs = record
                    .parents
                    .iter()
                    .chain(&record.previous)
                    .cloned()
                    .collect();
                parents.insert(record.id.clone(), refs);
                records.insert(record.id.clone(), json!({"signed_digest": digest(&raw)}));
                legacy.push(record);
            } else {
                findings.insert(format!("invalid-legacy-music-record:{}", digest(&raw)));
            }
        }
    }
    for (id, refs) in &parents {
        if refs.iter().any(|p| !records.contains_key(p)) {
            findings.insert(format!("incomplete-music-parents:{id}"));
        }
    }
    let superseded: BTreeSet<_> = legacy.iter().flat_map(|r| &r.parents).collect();
    let explicit: BTreeSet<_> = legacy
        .iter()
        .filter(|r| !matches!(r.action, crate::cluster_changes::Action::Import { .. }))
        .map(|r| &r.object)
        .collect();
    let mut heads = BTreeMap::new();
    for record in &legacy {
        if !superseded.contains(&record.id)
            && !(explicit.contains(&record.object)
                && matches!(record.action, crate::cluster_changes::Action::Import { .. }))
        {
            *heads.entry(&record.object).or_insert(0usize) += 1;
        }
    }
    for (object, count) in heads {
        if count > 1 {
            findings.insert(format!("legacy-music-conflict:{object}"));
        }
    }
    Ok(serde_json::to_value(records)?)
}

fn playlist_evidence(
    connection: &rusqlite::Connection,
    proof: &crate::enrollment::Proof,
    cluster: &str,
    findings: &mut BTreeSet<String>,
) -> anyhow::Result<Value> {
    let mut records = BTreeMap::new();
    let mut parents = BTreeMap::new();
    let mut signed = Vec::new();
    for table in ["shared_playlists", "playlist_records"] {
        if !exists(connection, table)? {
            continue;
        }
        let mut statement =
            connection.prepare(&format!("SELECT payload FROM {table} ORDER BY id"))?;
        for raw in statement.query_map([], |r| r.get::<_, Vec<u8>>(0))? {
            let raw = raw?;
            let result = serde_json::from_slice::<crate::playlists::Signed>(&raw);
            match result {
                Ok(record) => match record.decode(proof) {
                    Ok(body) if body.cluster == cluster => {
                        signed.push(record.clone());
                        parents.insert(record.id.clone(), body.parents.clone());
                        records.insert(record.id, json!({"payload_digest": digest(record.payload.as_bytes()), "document": body.document, "parents": body.parents}));
                    }
                    _ => {
                        findings.insert(format!("invalid-playlist-signature:{}", digest(&raw)));
                    }
                },
                Err(_) => {
                    findings.insert(format!("invalid-playlist-record:{}", digest(&raw)));
                }
            }
        }
    }
    for (id, refs) in &parents {
        if refs.iter().any(|p| !records.contains_key(p)) {
            findings.insert(format!("incomplete-playlist-parents:{id}"));
        }
    }
    match crate::playlists::project(&signed, proof) {
        Ok(projected) => {
            for (id, snapshot) in projected {
                if snapshot.conflicted {
                    findings.insert(format!("playlist-conflict:{id}"));
                }
            }
        }
        Err(_) => {
            findings.insert("invalid-or-incomplete-playlist-projection".into());
        }
    }
    Ok(serde_json::to_value(records)?)
}

fn playlist_pins(
    playlists: &Value,
    categories: &BTreeMap<String, Value>,
    findings: &mut BTreeSet<String>,
) -> anyhow::Result<Value> {
    let mut result = BTreeMap::new();
    if let Some(records) = playlists.as_object() {
        for (record, value) in records {
            let document: crate::playlists::Document =
                serde_json::from_value(value["document"].clone())?;
            let mut occurrences = Vec::new();
            for item in document.items {
                if let (Some(id), Some(hash)) = (&item.track_id, &item.sha256) {
                    let target = categories
                        .get("addresses")
                        .and_then(|v| v.get(id))
                        .and_then(Value::as_str);
                    let pinned = target
                        .and_then(|t| categories.get("pins").and_then(|v| v.get(t)))
                        .and_then(Value::as_array)
                        .is_some_and(|pins| pins.iter().any(|p| p.as_str() == Some(hash.as_str())));
                    if !pinned {
                        findings.insert(format!("unresolved-playlist-pin:{record}:{}", item.id));
                    }
                    occurrences.push(json!({"occurrence": item.id, "track": id, "sha256": hash, "target": target, "pinned": pinned}));
                } else {
                    occurrences.push(json!({"occurrence": item.id, "track": null, "sha256": null, "target": null, "pinned": false}));
                }
            }
            result.insert(record.clone(), occurrences);
        }
    }
    Ok(serde_json::to_value(result)?)
}

fn audio_evidence(
    root: &Path,
    objects: &BTreeMap<String, crate::shared_audio::Object>,
    findings: &mut BTreeSet<String>,
) -> anyhow::Result<Value> {
    let mut result = BTreeMap::new();
    for (id, object) in objects {
        let mut locators = BTreeMap::new();
        for locator in &object.locators {
            relative(locator)?;
            let path = root.join("objects").join(locator);
            match snapshot(&path) {
                Ok(files) => {
                    let evidence = &files
                        .get("root")
                        .ok_or_else(|| anyhow::anyhow!("audio locator is not a file"))?
                        .evidence;
                    if evidence.sha256 != *id || object.bytes.is_some_and(|b| b != evidence.bytes) {
                        findings.insert(format!("corrupt-audio:{id}:{locator}"));
                    }
                    locators.insert(locator.clone(), serde_json::to_value(evidence)?);
                }
                Err(_) => {
                    locators.insert(locator.clone(), json!({"unavailable": true}));
                }
            }
        }
        if locators.is_empty() || locators.values().all(|v| v.get("unavailable").is_some()) {
            findings.insert(format!("missing-audio:{id}"));
        }
        result.insert(
            id.clone(),
            json!({"expected_bytes": object.bytes, "locators": locators}),
        );
    }
    Ok(serde_json::to_value(result)?)
}

fn validate_client(client: &mut ClientExport, cluster: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        client.version == VERSION && client.cluster == cluster,
        "client export version/cluster mismatch"
    );
    label(&client.member)?;
    label(&client.build)?;
    relative(&client.queue_path)?;
    anyhow::ensure!(
        valid_digest(&client.baseline) && valid_digest(&client.queue.sha256),
        "invalid client snapshot digest"
    );
    let mut ids = BTreeSet::new();
    for (path, file) in &client.staging {
        relative(path)?;
        anyhow::ensure!(valid_digest(&file.sha256), "invalid staging digest");
    }
    for request in &client.requests {
        label(&request.id)?;
        label(&request.operation)?;
        label(&request.target_host)?;
        anyhow::ensure!(
            ids.insert(&request.id) && valid_digest(&request.digest),
            "duplicate request or invalid digest"
        );
        anyhow::ensure!(
            request.eligibility.as_deref().is_none_or(valid_digest)
                && request.receipts.iter().all(|v| valid_digest(v)),
            "invalid client evidence digest"
        );
        anyhow::ensure!(
            request
                .staging
                .iter()
                .all(|p| client.staging.contains_key(p)),
            "request staging missing from export"
        );
    }
    client.requests.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(())
}

fn client_files(client: &ClientExport, root: &Path, blocking: &mut BTreeSet<String>) {
    for (path, expected) in
        std::iter::once((&client.queue_path, &client.queue)).chain(client.staging.iter())
    {
        // Reject links in any ancestor, including paths not represented in the export.
        let mut full = root.to_path_buf();
        let mut safe = true;
        for component in Path::new(path).components() {
            full.push(component);
            safe &= std::fs::symlink_metadata(&full).is_ok_and(|m| !m.file_type().is_symlink());
        }
        let matches = safe
            && snapshot(&full).is_ok_and(|files| {
                files.get("root").is_some_and(|f| f.evidence == *expected)
                    && snapshot(&full).is_ok_and(|again| files == again)
            });
        if !matches {
            blocking.insert(format!(
                "missing-or-corrupt-client-file:{}:{path}",
                client.member
            ));
        }
    }
}

pub fn compare(input: Collection) -> anyhow::Result<Comparison> {
    anyhow::ensure!(
        input.version == VERSION && !input.expected_hosts.is_empty(),
        "version 1 and explicit host roster required"
    );
    let mut reports = BTreeMap::new();
    let mut clients = BTreeMap::new();
    let mut blocking = BTreeSet::new();
    let mut expected_hosts = input.expected_hosts;
    let mut expected_members = input.expected_members;
    let mut union = crate::enrollment::Proof {
        root: String::new(),
        grants: vec![],
        revocations: vec![],
    };
    let mut roots = BTreeSet::new();
    let mut grants = BTreeMap::new();
    let mut revocations = BTreeMap::new();
    for path in &input.hosts {
        let mut report: HostReport = read_json(path)?;
        report.proof.grants.sort_by(|a, b| a.id.cmp(&b.id));
        report.proof.revocations.sort_by(|a, b| a.id.cmp(&b.id));
        anyhow::ensure!(
            report.version == VERSION
                && report.cluster == input.cluster
                && matches!(report.schema, 4 | 5)
                && valid_digest(&report.baseline),
            "invalid host report bindings"
        );
        anyhow::ensure!(
            report.stopped_and_fenced,
            "host report lacks stopped/fenced assertion"
        );
        for finding in &report.findings {
            blocking.insert(format!("host:{}:{finding}", report.host));
        }
        validate_proof(&report.proof, &input.cluster, &mut blocking);
        roots.insert(report.proof.root.clone());
        for grant in &report.proof.grants {
            if let Some(previous) = grants.insert(grant.id.clone(), grant.clone()) {
                anyhow::ensure!(previous == *grant, "grant content divergence");
            }
        }
        for revocation in &report.proof.revocations {
            let value = serde_json::to_value(revocation)?;
            if let Some(previous) = revocations.insert(revocation.id.clone(), value.clone()) {
                anyhow::ensure!(previous == value, "revocation content divergence");
            }
        }
        let id = report.host.clone();
        anyhow::ensure!(
            reports.insert(id, report).is_none(),
            "duplicate host report"
        );
    }
    if roots.len() > 1 {
        blocking.insert("membership-root-divergence".into());
    }
    union.root = roots.into_iter().next().unwrap_or_default();
    union.grants = grants.into_values().collect();
    union.revocations = revocations
        .into_values()
        .map(serde_json::from_value)
        .collect::<Result<_, _>>()?;
    validate_proof(&union, &input.cluster, &mut blocking);
    for grant in &union.grants {
        // Retain even revoked/disputed members in the evidence roster: exclusion is explicit.
        expected_members.insert(grant.member.clone());
        if grant.host && union.verify(&grant.id).is_ok() {
            expected_hosts.insert(grant.member.clone());
        }
    }
    for id in &expected_hosts {
        if !reports.contains_key(id) {
            blocking.insert(format!("missing-host:{id}"));
        }
    }
    for report in reports.values() {
        if !expected_hosts.contains(&report.host) {
            blocking.insert(format!("unexpected-host:{}", report.host));
        }
        if !union
            .grants
            .iter()
            .any(|g| g.member == report.host && g.host && union.verify(&g.id).is_ok())
        {
            blocking.insert(format!("unauthorized-host:{}", report.host));
        }
        expected_members.insert(report.host.clone());
    }
    for path in &input.clients {
        let mut client: ClientExport = read_json(path)?;
        validate_client(&mut client, &input.cluster)?;
        client_files(
            &client,
            path.parent().unwrap_or(Path::new(".")),
            &mut blocking,
        );
        if !expected_members.contains(&client.member) {
            blocking.insert(format!("unexpected-client:{}", client.member));
        }
        if reports.values().any(|r| r.baseline != client.baseline) {
            blocking.insert(format!("client-baseline-divergence:{}", client.member));
        }
        for request in &client.requests {
            if request.state != IntentState::NeverSent {
                blocking.insert(format!(
                    "unresolved-client-request:{}:{}",
                    client.member, request.id
                ));
            }
        }
        anyhow::ensure!(
            clients.insert(client.member.clone(), client).is_none(),
            "duplicate client export"
        );
    }
    for id in &expected_members {
        if !clients.contains_key(id) {
            blocking.insert(format!("missing-client-intent:{id}"));
        }
    }
    let mut differences = BTreeMap::new();
    let mut availability = BTreeMap::new();
    let mut availability_differences: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut compared: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for report in reports.values() {
        let mut categories = report.categories.clone();
        for key in ["availability", "artwork"] {
            availability_differences
                .entry(key.into())
                .or_default()
                .insert(
                    report.host.clone(),
                    semantic_digest(categories.get(key).unwrap_or(&Value::Null))?,
                );
        }
        categories.insert("baseline".into(), json!(report.baseline));
        categories.insert("schema".into(), json!(report.schema));
        categories.insert("membership".into(), serde_json::to_value(&report.proof)?);
        let mut local = BTreeMap::new();
        for key in [
            "availability",
            "artwork",
            "unreferenced_objects",
            "staging",
            "shared_requests",
            "shared_member_requests",
            "shared_member_playlist_requests",
            "shared_member_object_requests",
            "shared_object_requests",
            "shared_playlist_requests",
            "shared_cursors",
            "playlist_cursors",
            "shared_request_index_positions",
            "cluster_pending_changes",
            "cluster_jobs",
        ] {
            local.insert(key, categories.remove(key));
        }
        availability.insert(report.host.clone(), json!({"local": local, "files": report.files, "build": report.build, "profiles": report.profiles}));
        for (category, value) in categories {
            compared
                .entry(category)
                .or_default()
                .insert(report.host.clone(), semantic_digest(&value)?);
        }
    }
    availability_differences.retain(|_, hosts| hosts.values().collect::<BTreeSet<_>>().len() > 1);
    for (category, values) in compared {
        if values.len() != reports.len() || values.values().collect::<BTreeSet<_>>().len() > 1 {
            blocking.insert(format!("divergence:{category}"));
            differences.insert(category, values);
        }
    }
    Ok(Comparison {
        version: VERSION,
        cluster: input.cluster,
        blocking,
        differences,
        availability_differences,
        availability,
        hosts: reports.into_keys().collect(),
        clients,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLUSTER: &str = "00000000-0000-4000-8000-000000000001";

    fn fixture(root: &Path) -> anyhow::Result<HostInput> {
        let data = root.join("data");
        drop(crate::store::Store::open(&data)?);
        let secret = iroh::SecretKey::from_bytes(&[7; 32]);
        let member = secret.public().to_string();
        let bytes = format!(
            "syncstr-enrollment-grant-v1\n{}",
            serde_json::to_string(&(1u8, CLUSTER, &member, &member, true, Option::<String>::None))?
        );
        let grant = crate::enrollment::Grant {
            version: 1,
            id: digest(bytes.as_bytes()),
            cluster: CLUSTER.into(),
            issuer: member.clone(),
            member: member.clone(),
            host: true,
            authority: None,
            signature: hex::encode(secret.sign(bytes.as_bytes()).to_bytes()),
        };
        let connection = rusqlite::Connection::open(data.join("node.sqlite"))?;
        connection.execute("UPDATE library SET id=?", [CLUSTER])?;
        connection.execute(
            "INSERT INTO cluster_identity VALUES (1, ?, ?)",
            rusqlite::params![CLUSTER, member],
        )?;
        connection.execute(
            "INSERT INTO cluster_trust VALUES (1, ?, ?)",
            rusqlite::params![member, grant.id],
        )?;
        connection.execute(
            "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
            rusqlite::params![grant.id, serde_json::to_vec(&grant)?],
        )?;
        drop(connection);
        std::fs::write(data.join("staging/upload-retained"), b"unfinished")?;
        let identity = root.join("private.key");
        std::fs::write(&identity, b"fictional-secret-do-not-print")?;
        Ok(HostInput {
            version: 1,
            host: member,
            cluster: CLUSTER.into(),
            data,
            build: "fixture-build".into(),
            profiles: BTreeSet::new(),
            evidence: BTreeMap::from([("identity".into(), identity)]),
            stopped_and_fenced: true,
        })
    }

    fn report_path(root: &Path, report: &HostReport, name: &str) -> anyhow::Result<PathBuf> {
        let path = root.join(name);
        std::fs::write(&path, canonical(&serde_json::to_value(report)?)?)?;
        Ok(path)
    }

    fn collection(paths: Vec<PathBuf>, member: &str) -> Collection {
        Collection {
            version: 1,
            cluster: CLUSTER.into(),
            expected_hosts: BTreeSet::from([member.into()]),
            expected_members: BTreeSet::from([member.into()]),
            hosts: paths,
            clients: vec![],
        }
    }

    fn client(member: &str, baseline: &str) -> ClientExport {
        ClientExport {
            version: 1,
            cluster: CLUSTER.into(),
            member: member.into(),
            baseline: baseline.into(),
            build: "fixture-reader".into(),
            queue: FileEvidence {
                bytes: 2,
                sha256: digest(b"[]"),
            },
            queue_path: "queue.json".into(),
            requests: vec![],
            staging: BTreeMap::new(),
        }
    }

    #[test]
    fn inventory_preserves_source_bytes_mtimes_and_entries() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let input = fixture(root.path())?;
        let connection = rusqlite::Connection::open(input.data.join("node.sqlite"))?;
        connection.execute_batch("CREATE TABLE shared_requests (id TEXT, digest TEXT, record TEXT); INSERT INTO shared_requests VALUES ('request', 'private-request-payload', 'private-receipt');")?;
        drop(connection);
        let before = observe(&input)?;
        let data = input.data.clone();
        let report = host(input)?;
        assert!(report.findings.is_empty());
        let after_input = HostInput {
            version: 1,
            host: report.host.clone(),
            cluster: CLUSTER.into(),
            data,
            build: "fixture-build".into(),
            profiles: BTreeSet::new(),
            evidence: BTreeMap::from([("identity".into(), root.path().join("private.key"))]),
            stopped_and_fenced: true,
        };
        assert!(before == observe(&after_input)?);
        assert_eq!(report.schema, 4);
        assert!(
            report
                .files
                .contains_key("data/root/staging/upload-retained")
        );
        let output = canonical(&serde_json::to_value(report)?)?;
        assert!(!output.contains("fictional-secret"));
        assert!(!output.contains("private-request-payload"));
        assert!(!output.contains("private-receipt"));
        Ok(())
    }

    #[test]
    fn inventory_canonical_across_roots_and_input_order() -> anyhow::Result<()> {
        let first = tempfile::tempdir()?;
        let second = tempfile::tempdir()?;
        let first_input = fixture(first.path())?;
        let second_input = fixture(second.path())?;
        // Identical source bytes, including SQLite's physical layout, at different roots.
        std::fs::copy(
            first_input.data.join("node.sqlite"),
            second_input.data.join("node.sqlite"),
        )?;
        let one = host(first_input)?;
        let two = host(second_input)?;
        assert_eq!(
            canonical(&serde_json::to_value(&one)?)?,
            canonical(&serde_json::to_value(two)?)?
        );
        let repeated = host(HostInput {
            version: 1,
            host: one.host.clone(),
            cluster: CLUSTER.into(),
            data: first.path().join("data"),
            build: "fixture-build".into(),
            profiles: BTreeSet::new(),
            evidence: BTreeMap::from([("identity".into(), first.path().join("private.key"))]),
            stopped_and_fenced: true,
        })?;
        assert_eq!(
            canonical(&serde_json::to_value(one)?)?,
            canonical(&serde_json::to_value(repeated)?)?
        );
        assert_eq!(
            canonical(&json!({"z": {"b": 2, "a": 1}, "a": [2,1]}))?,
            "{\"a\":[2,1],\"z\":{\"a\":1,\"b\":2}}"
        );
        Ok(())
    }

    #[test]
    fn inventory_rejects_busy_sidecar_and_unfenced_sources() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let mut input = fixture(root.path())?;
        let guard = crate::node_lock::NodeLock::acquire(std::fs::File::open(
            input.data.join("node.lock"),
        )?)?;
        assert!(host(input.clone()).is_err());
        assert!(
            crate::node_lock::NodeLock::acquire(std::fs::File::open(input.data.join("node.lock"))?)
                .is_err()
        );
        drop(guard);
        std::fs::write(input.data.join("node.sqlite-wal"), b"retained-wal")?;
        assert!(readonly(&input.data).is_err());
        assert_eq!(
            std::fs::read(input.data.join("node.sqlite-wal"))?,
            b"retained-wal"
        );
        input.stopped_and_fenced = false;
        assert!(host(input).is_err());
        Ok(())
    }

    #[test]
    fn inventory_connection_refuses_writes() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let input = fixture(root.path())?;
        let before = observe(&input)?;
        let connection = readonly(&input.data)?;
        assert!(
            connection
                .execute_batch("CREATE TABLE forbidden (id TEXT)")
                .is_err()
        );
        assert!(
            connection
                .execute("UPDATE library SET id='changed'", [])
                .is_err()
        );
        drop(connection);
        assert!(before == observe(&input)?);
        Ok(())
    }

    #[test]
    fn compare_requires_members_and_preserves_uncertain_requests() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let report = host(fixture(root.path())?)?;
        let path = report_path(root.path(), &report, "host.json")?;
        let missing = compare(collection(vec![path.clone()], &report.host))?;
        assert!(
            missing
                .blocking
                .contains(&format!("missing-client-intent:{}", report.host))
        );
        let mut export = client(&report.host, &report.baseline);
        export.requests.push(ClientRequest {
            operation: "register-track".into(),
            id: "request-1".into(),
            digest: digest(b"envelope"),
            target_host: report.host.clone(),
            state: IntentState::OutcomeUnknown,
            eligibility: None,
            receipts: BTreeSet::new(),
            staging: BTreeSet::new(),
        });
        let mut accepted = export.requests[0].clone();
        accepted.id = "request-accepted".into();
        accepted.state = IntentState::Accepted;
        let mut unsent = accepted.clone();
        unsent.id = "request-never-sent".into();
        unsent.state = IntentState::NeverSent;
        export.requests.extend([accepted, unsent]);
        std::fs::write(root.path().join("queue.json"), b"[]")?;
        let export_path = root.path().join("client.json");
        std::fs::write(&export_path, serde_json::to_vec(&export)?)?;
        let mut input = collection(vec![path], &report.host);
        input.expected_hosts.insert("offline-host".into());
        input.clients.push(export_path);
        let result = compare(input)?;
        assert!(result.blocking.contains("missing-host:offline-host"));
        assert!(result.blocking.contains(&format!(
            "unresolved-client-request:{}:request-1",
            report.host
        )));
        assert!(result.blocking.contains(&format!(
            "unresolved-client-request:{}:request-accepted",
            report.host
        )));
        assert!(!result.blocking.contains(&format!(
            "unresolved-client-request:{}:request-never-sent",
            report.host
        )));
        assert!(
            result.clients[&report.host].requests[0]
                .eligibility
                .is_none()
        );
        Ok(())
    }

    #[test]
    fn compare_detects_divergence_and_keeps_local_state_separate() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let report = host(fixture(root.path())?)?;
        let first = report_path(root.path(), &report, "first.json")?;
        let mut other = report.clone();
        other.host = "other-host".into();
        other
            .categories
            .insert("addresses".into(), json!({"old": "different"}));
        other
            .categories
            .insert("shared_cursors".into(), json!({"different": true}));
        other
            .categories
            .insert("availability".into(), json!({"different": true}));
        let second = report_path(root.path(), &other, "second.json")?;
        let forward = compare(collection(
            vec![first.clone(), second.clone()],
            &report.host,
        ))?;
        let backward = compare(collection(vec![second, first], &report.host))?;
        assert!(forward.differences.contains_key("addresses"));
        assert!(!forward.differences.contains_key("shared_cursors"));
        assert!(
            forward
                .availability_differences
                .contains_key("availability")
        );
        assert_eq!(
            canonical(&serde_json::to_value(forward)?)?,
            canonical(&serde_json::to_value(backward)?)?
        );
        Ok(())
    }

    #[test]
    fn compare_membership_union_requires_an_unlisted_authorized_host() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let mut report = host(fixture(root.path())?)?;
        let other = iroh::SecretKey::from_bytes(&[9; 32]).public().to_string();
        let authority = report.proof.grants[0].id.clone();
        let bytes = format!(
            "syncstr-enrollment-grant-v1\n{}",
            serde_json::to_string(&(1u8, CLUSTER, &report.host, &other, true, Some(&authority)))?
        );
        report.proof.grants.push(crate::enrollment::Grant {
            version: 1,
            id: digest(bytes.as_bytes()),
            cluster: CLUSTER.into(),
            issuer: report.host.clone(),
            member: other.clone(),
            host: true,
            authority: Some(authority),
            signature: hex::encode(
                iroh::SecretKey::from_bytes(&[7; 32])
                    .sign(bytes.as_bytes())
                    .to_bytes(),
            ),
        });
        let path = report_path(root.path(), &report, "host.json")?;
        let result = compare(collection(vec![path], &report.host))?;
        assert!(result.blocking.contains(&format!("missing-host:{other}")));
        assert!(
            result
                .blocking
                .contains(&format!("missing-client-intent:{other}"))
        );
        Ok(())
    }

    #[test]
    fn playlists_preserve_historical_pins_occurrences_and_reject_tampering() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let report = host(fixture(root.path())?)?;
        let connection = rusqlite::Connection::open_in_memory()?;
        connection
            .execute_batch("CREATE TABLE shared_playlists (id TEXT PRIMARY KEY, payload BLOB)")?;
        let hash = digest(b"same-audio");
        let body = crate::playlists::Body {
            version: 1,
            cluster: CLUSTER.into(),
            author: report.host.clone(),
            grant: report.proof.grants[0].id.clone(),
            origin: None,
            request: None,
            request_digest: None,
            parents: vec![],
            document: crate::playlists::Document {
                id: "fixture:playlist".into(),
                source_library: "fixture".into(),
                source_playlist: "playlist".into(),
                source_fingerprint: digest(b"source"),
                name: "Fictional playlist".into(),
                kind: "manual".into(),
                parent: None,
                definition: BTreeMap::new(),
                items: ["old-a", "old-b", "old-a"]
                    .iter()
                    .enumerate()
                    .map(|(index, track)| crate::playlists::Item {
                        id: format!("occurrence-{index}"),
                        source_track: track.to_string(),
                        title: "Fictional song".into(),
                        artist: None,
                        album: None,
                        track_id: Some(track.to_string()),
                        sha256: Some(hash.clone()),
                    })
                    .collect(),
            },
        };
        let payload = format!("syncstr-playlist-v1\n{}", serde_json::to_string(&body)?);
        let signed = crate::playlists::Signed {
            id: digest(payload.as_bytes()),
            signature: hex::encode(
                iroh::SecretKey::from_bytes(&[7; 32])
                    .sign(payload.as_bytes())
                    .to_bytes(),
            ),
            payload,
        };
        connection.execute(
            "INSERT INTO shared_playlists VALUES (?, ?)",
            rusqlite::params![signed.id, serde_json::to_vec(&signed)?],
        )?;
        let mut findings = BTreeSet::new();
        let evidence = playlist_evidence(&connection, &report.proof, CLUSTER, &mut findings)?;
        assert!(findings.is_empty());
        let categories = BTreeMap::from([
            (
                "addresses".into(),
                json!({"old-a": "canonical-a", "old-b": "canonical-b"}),
            ),
            (
                "pins".into(),
                json!({"canonical-a": [hash.clone()], "canonical-b": [hash.clone()]}),
            ),
        ]);
        let pins = playlist_pins(&evidence, &categories, &mut findings)?;
        let occurrences = pins[&signed.id].as_array().expect("occurrence list");
        assert_eq!(occurrences.len(), 3);
        assert_eq!(occurrences[0]["target"], "canonical-a");
        assert_eq!(occurrences[1]["target"], "canonical-b");
        assert_eq!(occurrences[2]["occurrence"], "occurrence-2");
        assert!(findings.is_empty());
        playlist_pins(&evidence, &BTreeMap::new(), &mut findings)?;
        assert!(
            findings
                .iter()
                .any(|f| f.starts_with("unresolved-playlist-pin:"))
        );
        let mut tampered = signed;
        tampered.payload.push(' ');
        connection.execute(
            "UPDATE shared_playlists SET payload=?",
            [serde_json::to_vec(&tampered)?],
        )?;
        findings.clear();
        playlist_evidence(&connection, &report.proof, CLUSTER, &mut findings)?;
        assert!(
            findings
                .iter()
                .any(|f| f.starts_with("invalid-playlist-signature:"))
        );
        Ok(())
    }

    #[test]
    fn aliases_and_assets_detect_cycles_missing_and_corrupt_bytes() -> anyhow::Result<()> {
        let mut findings = BTreeSet::new();
        validate_aliases(
            &BTreeMap::from([
                ("tracks".into(), json!({})),
                (
                    "addresses".into(),
                    json!({"a": "b", "b": "a", "c": "missing"}),
                ),
            ]),
            &mut findings,
        );
        assert!(findings.contains("alias-cycle:a"));
        assert!(findings.contains("dangling-alias:c"));
        let root = tempfile::tempdir()?;
        std::fs::create_dir(root.path().join("objects"))?;
        std::fs::write(root.path().join("objects/bad.wav"), b"bad")?;
        let hash = digest(b"good");
        audio_evidence(
            root.path(),
            &BTreeMap::from([
                (
                    hash.clone(),
                    crate::shared_audio::Object {
                        sha256: hash.clone(),
                        bytes: Some(4),
                        locators: vec!["bad.wav".into()],
                    },
                ),
                (
                    "missing".into(),
                    crate::shared_audio::Object {
                        sha256: "missing".into(),
                        bytes: None,
                        locators: vec![],
                    },
                ),
            ]),
            &mut findings,
        )?;
        assert!(findings.contains(&format!("corrupt-audio:{hash}:bad.wav")));
        assert!(findings.contains("missing-audio:missing"));
        Ok(())
    }

    #[test]
    fn client_exports_validate_files_paths_and_request_identity() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let mut export = client("member", &digest(b"baseline"));
        let mut findings = BTreeSet::new();
        client_files(&export, root.path(), &mut findings);
        assert!(!findings.is_empty());
        std::fs::write(root.path().join("queue.json"), b"[]")?;
        findings.clear();
        client_files(&export, root.path(), &mut findings);
        assert!(findings.is_empty());
        validate_client(&mut export, CLUSTER)?;
        let request = ClientRequest {
            operation: "register-track".into(),
            id: "duplicate".into(),
            digest: digest(b"request"),
            target_host: "host".into(),
            state: IntentState::NeverSent,
            eligibility: None,
            receipts: BTreeSet::new(),
            staging: BTreeSet::new(),
        };
        export.requests = vec![request.clone(), request];
        assert!(validate_client(&mut export, CLUSTER).is_err());
        export.requests.truncate(1);
        export.requests[0].staging.insert("missing.wav".into());
        assert!(validate_client(&mut export, CLUSTER).is_err());
        export.queue_path = "../secret".into();
        assert!(validate_client(&mut export, CLUSTER).is_err());
        for path in ["/absolute", "a/../b", "a\\b", "C:/file", "a/./b"] {
            assert!(relative(path).is_err());
        }
        Ok(())
    }

    #[test]
    fn inventory_v5_invalid_history_is_reported_without_activation() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let input = fixture(root.path())?;
        let expected = digest(&serde_json::to_vec(&crate::shared_audio::legacy(
            &readonly(&input.data)?,
        )?)?);
        drop(crate::shared_audio::Store::activate(
            &input.data,
            &expected,
        )?);
        let connection = rusqlite::Connection::open(input.data.join("node.sqlite"))?;
        connection.execute(
            "INSERT INTO shared_records VALUES ('bad', ?)",
            [b"invalid-signature-fixture".as_slice()],
        )?;
        drop(connection);
        let before = observe(&input)?;
        let report = host(input)?;
        assert_eq!(report.schema, 5);
        assert!(
            report
                .findings
                .contains("invalid-music-projection-or-signatures")
        );
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.starts_with("invalid-music-record:"))
        );
        assert_eq!(
            before.len(),
            report.files.len() + before.keys().filter(|p| p.ends_with('/')).count()
        );
        Ok(())
    }

    #[test]
    fn exact_table_evidence_is_order_independent_and_preserves_payload_bytes() -> anyhow::Result<()>
    {
        let connection = rusqlite::Connection::open_in_memory()?;
        connection.execute_batch("CREATE TABLE shared_records (id TEXT, payload BLOB); INSERT INTO shared_records VALUES ('b', X'7b7d'), ('a', X'7b207d');")?;
        let original = table_evidence(&connection, "shared_records")?;
        connection.execute_batch("DELETE FROM shared_records; INSERT INTO shared_records VALUES ('a', X'7b207d'), ('b', X'7b7d');")?;
        assert_eq!(original, table_evidence(&connection, "shared_records")?);
        connection.execute_batch("UPDATE shared_records SET payload=X'7b7d' WHERE id='a'")?;
        assert_ne!(original, table_evidence(&connection, "shared_records")?);
        Ok(())
    }

    #[test]
    fn music_history_detects_missing_parents_and_invalid_signatures() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let report = host(fixture(root.path())?)?;
        let connection = rusqlite::Connection::open_in_memory()?;
        connection
            .execute_batch("CREATE TABLE shared_records (id TEXT PRIMARY KEY, payload BLOB)")?;
        let body = crate::shared_audio::Body {
            cluster: CLUSTER.into(),
            baseline: report.baseline.clone(),
            author: report.host.clone(),
            grant: report.proof.grants[0].id.clone(),
            origin: None,
            request: "fixture-request".into(),
            request_digest: digest(b"request"),
            edits: vec![crate::shared_audio::Edit {
                parents: vec![digest(b"missing-parent")],
                value: crate::shared_audio::Value::AlbumVisibility {
                    album: "fixture-album".into(),
                    hidden: true,
                },
            }],
        };
        let payload = format!("syncstr-shared-audio-v1\n{}", serde_json::to_string(&body)?);
        let mut signed = crate::shared_audio::Signed {
            id: digest(payload.as_bytes()),
            signature: hex::encode(
                iroh::SecretKey::from_bytes(&[7; 32])
                    .sign(payload.as_bytes())
                    .to_bytes(),
            ),
            payload,
        };
        connection.execute(
            "INSERT INTO shared_records VALUES (?, ?)",
            rusqlite::params![signed.id, serde_json::to_vec(&signed)?],
        )?;
        let mut findings = BTreeSet::new();
        music_evidence(
            &connection,
            &report.proof,
            CLUSTER,
            &report.baseline,
            &mut findings,
        )?;
        assert!(findings.contains(&format!("incomplete-music-parents:{}", signed.id)));
        signed.signature = "00".repeat(64);
        connection.execute(
            "UPDATE shared_records SET payload=?",
            [serde_json::to_vec(&signed)?],
        )?;
        findings.clear();
        music_evidence(
            &connection,
            &report.proof,
            CLUSTER,
            &report.baseline,
            &mut findings,
        )?;
        assert!(
            findings
                .iter()
                .any(|f| f.starts_with("invalid-music-record:"))
        );
        Ok(())
    }
}

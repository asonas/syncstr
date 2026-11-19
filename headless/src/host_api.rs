mod socket;
use axum::{
    Json, Router,
    extract::{Path, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
    routing::get,
};
use rusqlite::OptionalExtension as _;
use serde_json::json;
pub use socket::listener;
use std::{
    io::{self, Seek as _},
    path::PathBuf,
    sync::Arc,
};
use tokio::sync::Semaphore;

#[derive(Clone)]
struct Host {
    store: crate::store::Store,
    address: String,
    files: Arc<Semaphore>,
    cache: Arc<tokio::sync::Mutex<Option<Arc<Snapshot>>>>,
}

pub fn router(store: crate::store::Store, address: String) -> Router {
    let host = Host::new(store, address);
    Router::new()
        .route("/api/v1/library", get(library).head(method_error))
        .route("/api/v1/catalog", get(catalog).head(method_error))
        .route("/api/v1/audio/{id}", get(audio).head(method_error))
        .route("/api/v1/artwork/{id}", get(artwork).head(method_error))
        .method_not_allowed_fallback(method_error)
        .fallback(|| async { ApiError::Missing })
        .layer(axum::middleware::from_fn_with_state(
            host.clone(),
            response_headers,
        ))
        .with_state(host)
}

async fn response_headers(State(host): State<Host>, request: Request, next: Next) -> Response {
    let metadata = matches!(request.uri().path(), "/api/v1/library" | "/api/v1/catalog");
    let mut response = if metadata {
        match tokio::time::timeout(std::time::Duration::from_secs(300), next.run(request)).await {
            Ok(response) => response,
            Err(error) => ApiError::Storage(error.into()).into_response(),
        }
    } else {
        next.run(request).await
    };
    let headers = response.headers_mut();
    headers.insert(
        "syncstr-switch",
        format!("1.{}", host.store.host_id())
            .parse()
            .expect("UUID is ASCII"),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    response
}

enum ApiError {
    Missing,
    Busy,
    Storage(anyhow::Error),
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self::Storage(error)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Missing => (StatusCode::NOT_FOUND, "not-found", "Resource not found."),
            Self::Busy => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate-limited",
                "Too many concurrent downloads.",
            ),
            Self::Storage(error) => {
                eprintln!("Host API storage operation failed: {error}");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "storage-failed",
                    "Could not read the library.",
                )
            }
        };
        let mut response = (status, Json(json!({"error":code,"message":message}))).into_response();
        if status == StatusCode::TOO_MANY_REQUESTS {
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from_static("5"));
        }
        response
    }
}

async fn method_error() -> Response {
    (
        StatusCode::METHOD_NOT_ALLOWED,
        [(header::ALLOW, "GET")],
        Json(json!({"error":"method-not-allowed","message":"This route accepts only GET."})),
    )
        .into_response()
}

#[derive(Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Playlists {
    #[cfg(feature = "p2p")]
    playlists: Vec<crate::playlists::Document>,
    #[cfg(not(feature = "p2p"))]
    playlists: [(); 0],
    conflicted_playlists: Vec<String>,
}

struct SnapshotRows {
    id: String,
    entries: Vec<Vec<u8>>,
    organization: Vec<u8>,
    asset_ids: String,
    #[cfg(feature = "p2p")]
    playlist_records: Vec<Vec<u8>>,
    #[cfg(feature = "p2p")]
    proof: Option<crate::enrollment::ProofRows>,
}

impl SnapshotRows {
    fn read(db: &rusqlite::Connection) -> anyhow::Result<Self> {
        #[cfg(feature = "p2p")]
        let playlist_records = crate::playlists::record_rows(db)?;
        #[cfg(not(feature = "p2p"))]
        if db.table_exists(None, "playlist_records")? {
            let present: bool =
                db.query_row("SELECT EXISTS(SELECT 1 FROM playlist_records)", [], |row| {
                    row.get(0)
                })?;
            anyhow::ensure!(!present, "playlist verification requires p2p");
        }
        // Peer projections can store full images here. Only their IDs belong in the catalog.
        let (organization, asset_ids) = db.query_row(
            "SELECT CASE WHEN json_valid(doc) THEN
                        CAST(json_replace(doc, '$.artwork.assets', json('{}')) AS BLOB) END,
                    CASE WHEN json_valid(doc) THEN
                        (SELECT json_group_array(key) FROM json_each(doc, '$.artwork.assets')) END
             FROM (SELECT CAST(payload AS TEXT) AS doc FROM organization WHERE singleton = 1)",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        Ok(Self {
            id: db.query_row("SELECT id FROM library WHERE singleton = 1", [], |row| {
                row.get(0)
            })?,
            // Strip Base64 artwork before copying rows out of SQLite under the store lock.
            entries: crate::store::payloads(
                db,
                "SELECT CASE WHEN json_valid(CAST(payload AS TEXT))
                        THEN CAST(json_remove(CAST(payload AS TEXT), '$.artwork') AS BLOB)
                 END FROM tracks ORDER BY id",
            )?,
            organization,
            asset_ids,
            #[cfg(feature = "p2p")]
            proof: if playlist_records.is_empty() {
                None
            } else {
                Some(crate::enrollment::ProofRows::read(db)?)
            },
            #[cfg(feature = "p2p")]
            playlist_records,
        })
    }

    fn build(self, host_id: uuid::Uuid, generation: Generation) -> anyhow::Result<Snapshot> {
        use sha2::Digest as _;
        let entries: Vec<CatalogEntry> = crate::store::decode_rows(self.entries)?;
        let mut organization: crate::organization::Organization =
            serde_json::from_slice(&self.organization)?;
        if let Some(artwork) = &mut organization.artwork {
            artwork.assets = serde_json::from_str::<Vec<String>>(&self.asset_ids)?
                .into_iter()
                .map(|id| (id, Vec::new()))
                .collect();
        }
        let playlists = Playlists::default();
        #[cfg(feature = "p2p")]
        let playlists = {
            let mut playlists = playlists;
            if let Some(proof) = self.proof {
                let records = crate::store::decode_rows(self.playlist_records)?;
                for (id, snapshot) in crate::playlists::project(&records, &proof.decode()?)? {
                    if snapshot.conflicted {
                        playlists.conflicted_playlists.push(id);
                    }
                    playlists.playlists.push(snapshot.document);
                }
            }
            playlists
        };
        // Until ASO-161 adds a revision counter, hash the ordered wire content.
        let mut digest = sha2::Sha256::new();
        serde_json::to_writer(&mut digest, &(&entries, &organization, &playlists))?;
        let marker = format!("1.{host_id}.{:x}", digest.finalize());
        let body = serde_json::to_vec(&Catalog {
            id: &self.id,
            name: "Syncstr",
            entries,
            organization,
            playlists,
            marker: &marker,
        })?
        .into();
        Ok(Snapshot {
            id: self.id,
            marker,
            body,
            generation,
            gzip: Default::default(),
        })
    }
}

#[derive(serde::Deserialize, serde::Serialize)]
struct CatalogEntry {
    track: crate::model::Track,
    sha256: String,
    #[serde(rename = "importedAlbum", skip_serializing_if = "Option::is_none")]
    imported_album: Option<crate::organization::Imported>,
}

#[derive(serde::Serialize)]
struct Catalog<'a> {
    id: &'a str,
    name: &'a str,
    entries: Vec<CatalogEntry>,
    organization: crate::organization::Organization,
    #[serde(flatten)]
    playlists: Playlists,
    marker: &'a str,
}

#[derive(Clone, Copy, PartialEq)]
struct Generation {
    local: u64,
    external: i64,
}

struct Snapshot {
    generation: Generation,
    id: String,
    marker: String,
    body: axum::body::Bytes,
    gzip: tokio::sync::OnceCell<axum::body::Bytes>,
}

impl Snapshot {
    async fn compressed(&self) -> anyhow::Result<axum::body::Bytes> {
        let bytes = self
            .gzip
            .get_or_try_init(|| async {
                let body = self.body.clone();
                tokio::task::spawn_blocking(move || -> anyhow::Result<axum::body::Bytes> {
                    let mut encoder =
                        flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
                    std::io::Write::write_all(&mut encoder, &body)?;
                    Ok(encoder.finish()?.into())
                })
                .await?
            })
            .await?;
        Ok(bytes.clone())
    }
}

impl Host {
    fn new(store: crate::store::Store, address: String) -> Self {
        Self {
            store,
            address,
            cache: Default::default(),
            files: Arc::new(Semaphore::new(16)),
        }
    }

    async fn snapshot(&self) -> anyhow::Result<Arc<Snapshot>> {
        let mut cache = self.cache.clone().lock_owned().await;
        let previous = cache.as_ref().map(|snapshot| snapshot.generation);
        let changed = self
            .store
            .run(move |db, _| {
                let tx = db.transaction()?;
                // total_changes covers Store writers. data_version also detects out-of-band commits.
                let generation = Generation {
                    local: tx.total_changes(),
                    external: tx.query_row("PRAGMA data_version", [], |row| row.get(0))?,
                };
                if previous == Some(generation) {
                    return Ok(None);
                }
                let rows = SnapshotRows::read(&tx)?;
                Ok(Some((generation, rows)))
            })
            .await?;
        let Some((generation, rows)) = changed else {
            return Ok(cache.as_ref().expect("matching cached generation").clone());
        };
        let host_id = self.store.host_id();
        tokio::task::spawn_blocking(move || {
            let snapshot = Arc::new(rows.build(host_id, generation)?);
            *cache = Some(snapshot.clone());
            Ok(snapshot)
        })
        .await?
    }

    fn slot(&self) -> Result<tokio::sync::OwnedSemaphorePermit, ApiError> {
        self.files
            .clone()
            .try_acquire_owned()
            .map_err(|_| ApiError::Busy)
    }
}

async fn library(State(host): State<Host>) -> Result<Json<serde_json::Value>, ApiError> {
    let snapshot = host.snapshot().await?;
    let id = host.store.host_id().to_string();
    Ok(Json(json!({
        "library": snapshot.id,
        "name": "Syncstr",
        "host": {"id": id, "address": host.address},
        "role": "primary",
        "switchNumber": 1,
        "primary": id,
        "startingMarker": null,
        "marker": snapshot.marker,
        "hosts": [{"id": id, "address": host.address, "role": "primary"}]
    })))
}

fn accepts_gzip(headers: &HeaderMap) -> bool {
    let mut wildcard = false;
    for value in headers
        .get_all(header::ACCEPT_ENCODING)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
    {
        let mut parts = value.trim().split(';');
        let encoding = parts.next().unwrap_or_default().trim();
        let allowed = parts.next().is_none_or(|q| {
            q.trim()
                .strip_prefix("q=")
                .and_then(|q| q.parse::<f32>().ok())
                .is_some_and(|q| q > 0.0 && q <= 1.0)
        });
        if encoding.eq_ignore_ascii_case("gzip") {
            return allowed;
        }
        if encoding == "*" {
            wildcard = allowed;
        }
    }
    wildcard
}

async fn catalog(State(host): State<Host>, headers: HeaderMap) -> Result<Response, ApiError> {
    let snapshot = host.snapshot().await?;
    let tag = format!("\"{}.{}\"", snapshot.id, snapshot.marker);
    let matches = headers
        .get_all(header::IF_NONE_MATCH)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .any(|v| v == "*" || v.strip_prefix("W/").unwrap_or(v) == tag);
    let mut response = if matches {
        StatusCode::NOT_MODIFIED.into_response()
    } else if accepts_gzip(&headers) {
        let bytes = snapshot.compressed().await?;
        (
            [
                (header::CONTENT_ENCODING, "gzip"),
                (header::CONTENT_TYPE, "application/json"),
            ],
            bytes,
        )
            .into_response()
    } else {
        (
            [(header::CONTENT_TYPE, "application/json")],
            snapshot.body.clone(),
        )
            .into_response()
    };
    response.headers_mut().insert(
        header::ETAG,
        format!("W/{tag}").parse().map_err(anyhow::Error::from)?,
    );
    response
        .headers_mut()
        .insert(header::VARY, HeaderValue::from_static("Accept-Encoding"));
    Ok(response)
}

async fn audio(
    State(host): State<Host>,
    path: Result<Path<String>, axum::extract::rejection::PathRejection>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let Path(id) = path.map_err(|_| ApiError::Missing)?;
    audio_with_verifier(host, id, headers, stored_audio).await
}

async fn audio_with_verifier(
    host: Host,
    id: String,
    headers: HeaderMap,
    verify: impl FnOnce(PathBuf, &str, Vec<(String, i64)>) -> Result<(std::fs::File, u64), ApiError>
    + Send
    + 'static,
) -> Result<Response, ApiError> {
    let permit = host.slot()?;
    if id.len() != 64
        || !id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(ApiError::Missing);
    }
    let lookup = id.clone();
    let (indexed, objects) = host
        .store
        .run(move |db, root| {
            let mut query = db.prepare("SELECT suffix, json_extract(CAST(payload AS TEXT), '$.track.size') FROM tracks WHERE sha256 = ? ORDER BY suffix")?;
            let indexed = query.query_map([lookup], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok((indexed, root.join("objects")))
        })
        .await?;
    let lookup = id.clone();
    // A disconnected request cannot cancel a running file hash.
    let (file, size, permit) = tokio::task::spawn_blocking(move || {
        verify(objects, &lookup, indexed).map(|(file, size)| (file, size, permit))
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(crate::api::file_response(
        tokio::fs::File::from_std(file),
        size,
        &id,
        "application/octet-stream",
        &headers,
        crate::api::Download::Host(permit),
    )
    .await?)
}

fn stored_audio(
    objects: PathBuf,
    id: &str,
    indexed: Vec<(String, i64)>,
) -> Result<(std::fs::File, u64), ApiError> {
    let candidates = indexed
        .iter()
        .map(|(suffix, size)| (suffix.as_str(), Some(*size)))
        .chain(
            crate::model::AUDIO_SUFFIXES
                .iter()
                .copied()
                .filter(|suffix| !indexed.iter().any(|(s, _)| s == suffix))
                .map(|suffix| (suffix, None)),
        );
    let mut failures = Vec::new();
    for (suffix, expected) in candidates {
        match audio_candidate(&objects, id, suffix, expected) {
            Ok(opened) => return Ok(opened),
            Err(error) => failures.push((suffix, error)),
        }
    }
    if failures
        .iter()
        .all(|(_, error)| error.kind() == io::ErrorKind::NotFound)
    {
        Err(ApiError::Missing)
    } else {
        Err(ApiError::Storage(anyhow::anyhow!(
            "no usable audio copy: {failures:?}"
        )))
    }
}

fn audio_candidate(
    objects: &std::path::Path,
    id: &str,
    suffix: &str,
    expected: Option<i64>,
) -> io::Result<(std::fs::File, u64)> {
    if !crate::model::AUDIO_SUFFIXES.contains(&suffix) {
        return Err(io::Error::other("unsupported audio suffix"));
    }
    let (mut file, metadata) = crate::api::open_audio(&objects.join(format!("{id}.{suffix}")))?;
    let size = metadata.len();
    if !(1..=crate::model::MAX_AUDIO).contains(&size)
        || expected.is_some_and(|n| u64::try_from(n) != Ok(size))
    {
        return Err(io::Error::other("invalid stored audio size"));
    }
    if expected.is_none() {
        use sha2::Digest as _;
        let mut digest = sha2::Sha256::new();
        if io::copy(&mut file, &mut digest)? != size || hex::encode(digest.finalize()) != id {
            return Err(io::Error::other("stored audio hash mismatch"));
        }
        file.rewind()?;
    }
    Ok((file, size))
}

async fn artwork(
    State(host): State<Host>,
    path: Result<Path<String>, axum::extract::rejection::PathRejection>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let Path(id) = path.map_err(|_| ApiError::Missing)?;
    let permit = host.slot()?;
    let lookup = id.clone();
    let bytes: Vec<u8> = host
        .store
        .run(move |db, _| {
            Ok(db
                .query_row(
                    "SELECT payload FROM artwork_assets WHERE id = ?",
                    [lookup],
                    |r| r.get(0),
                )
                .optional()?)
        })
        .await?
        .ok_or(ApiError::Missing)?;
    let size = bytes.len() as u64;
    Ok(crate::api::file_response(
        std::io::Cursor::new(bytes),
        size,
        &id,
        "image/jpeg",
        &headers,
        crate::api::Download::Host(permit),
    )
    .await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cancelled_audio_request_holds_slot_until_verification_finishes() -> anyhow::Result<()>
    {
        use sha2::Digest as _;
        let root = tempfile::tempdir()?;
        let host = Host::new(
            crate::store::Store::open(root.path())?,
            "https://music.example.test".into(),
        );
        let id = hex::encode(sha2::Sha256::digest(b"abc"));
        std::fs::write(
            root.path().join("objects").join(format!("{id}.wav")),
            b"abc",
        )?;
        let _occupied = host.files.clone().try_acquire_many_owned(15)?;
        let (started, verifying) = tokio::sync::oneshot::channel();
        let (resume, paused) = std::sync::mpsc::channel();
        let request = tokio::spawn(audio_with_verifier(
            host.clone(),
            id,
            HeaderMap::new(),
            move |objects, id, indexed| {
                assert!(indexed.is_empty());
                started.send(()).unwrap();
                paused.recv().unwrap();
                stored_audio(objects, id, indexed)
            },
        ));
        verifying.await?;
        request.abort();
        assert!(matches!(request.await, Err(e) if e.is_cancelled()));
        assert!(matches!(host.slot(), Err(ApiError::Busy)));
        resume.send(())?;
        let _released =
            tokio::time::timeout(std::time::Duration::from_secs(5), host.files.acquire()).await??;
        Ok(())
    }

    #[tokio::test]
    async fn concurrent_refreshes_and_conditional_reads_reuse_the_snapshot() -> anyhow::Result<()> {
        use axum::response::IntoResponse;
        let root = tempfile::tempdir()?;
        let host = Host::new(
            crate::store::Store::open(root.path())?,
            "https://music.example.test".into(),
        );
        let (first, other) = tokio::try_join!(host.snapshot(), host.snapshot())?;
        assert!(Arc::ptr_eq(&first, &other));
        for _ in 0..2 {
            assert_eq!(
                library(State(host.clone())).await.into_response().status(),
                200
            );
        }
        let mut headers = HeaderMap::new();
        headers.insert(
            header::IF_NONE_MATCH,
            format!("W/\"{}.{}\"", first.id, first.marker).parse()?,
        );
        assert_eq!(
            catalog(State(host.clone()), headers)
                .await
                .into_response()
                .status(),
            304
        );
        assert!(Arc::ptr_eq(
            &first,
            host.cache.lock().await.as_ref().unwrap()
        ));
        assert!(first.gzip.get().is_none());
        let (gzip, again) = tokio::try_join!(first.compressed(), other.compressed())?;
        assert_eq!(gzip.as_ptr(), again.as_ptr());
        Ok(())
    }

    #[tokio::test]
    async fn catalog_rows_leave_embedded_artwork_in_sqlite() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let store = crate::store::Store::open(root.path())?;
        store
            .run(|db, _| {
                let mut entry: crate::model::Entry =
                    serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
                entry.artwork = Some(vec![42; 512 * 1024]);
                db.execute(
                    "INSERT INTO tracks VALUES (?, ?, ?, ?)",
                    rusqlite::params![
                        entry.track.id,
                        entry.sha256,
                        entry.track.suffix,
                        serde_json::to_vec(&entry)?
                    ],
                )?;
                let rows = SnapshotRows::read(db)?;
                entry.artwork = None;
                let expected = serde_json::to_value(entry)?;
                assert_eq!(rows.entries.len(), 1);
                assert!(rows.entries[0].len() < 1024);
                assert_eq!(
                    serde_json::from_slice::<serde_json::Value>(&rows.entries[0])?,
                    expected
                );
                let snapshot = rows.build(
                    uuid::Uuid::nil(),
                    Generation {
                        local: 0,
                        external: 0,
                    },
                )?;
                assert_eq!(
                    serde_json::from_slice::<serde_json::Value>(&snapshot.body)?["entries"][0],
                    expected
                );
                Ok(())
            })
            .await
    }

    #[tokio::test]
    async fn projected_organization_images_stay_in_sqlite_during_catalog_reads()
    -> anyhow::Result<()> {
        use sha2::Digest as _;
        let root = tempfile::tempdir()?;
        let store = crate::store::Store::open(root.path())?;
        let fixture: serde_json::Value =
            serde_json::from_slice(include_bytes!("../fixtures/album-artwork.json"))?;
        let mut organization: crate::organization::Organization =
            serde_json::from_value(fixture["organization"].clone())?;
        let payload = serde_json::to_vec(&organization)?;
        let rows = store
            .run(move |db, _| {
                db.execute("UPDATE organization SET payload = ?", [payload])?;
                SnapshotRows::read(db)
            })
            .await?;
        let assets = &mut organization.artwork.as_mut().unwrap().assets;
        assert_eq!(
            serde_json::from_str::<std::collections::BTreeSet<String>>(&rows.asset_ids)?,
            assets.keys().cloned().collect()
        );
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&rows.organization)?["artwork"]["assets"],
            serde_json::json!({})
        );
        for bytes in assets.values_mut() {
            assert!(!bytes.is_empty());
            bytes.clear();
        }
        let host_id = uuid::Uuid::nil();
        let entries = Vec::<CatalogEntry>::new();
        let playlists = Playlists::default();
        let digest =
            sha2::Sha256::digest(serde_json::to_vec(&(&entries, &organization, &playlists))?);
        let marker = format!("1.{host_id}.{digest:x}");
        let expected = serde_json::to_vec(&Catalog {
            id: &rows.id,
            name: "Syncstr",
            entries,
            organization,
            playlists,
            marker: &marker,
        })?;
        let snapshot = rows.build(
            host_id,
            Generation {
                local: 0,
                external: 0,
            },
        )?;
        assert_eq!(snapshot.marker, marker);
        assert_eq!(snapshot.body.as_ref(), expected);
        Ok(())
    }

    #[tokio::test]
    async fn sixteen_active_bodies_share_the_limit_and_release_slots_on_drop() -> anyhow::Result<()>
    {
        use std::io::Write as _;
        let root = tempfile::tempdir()?;
        let store = crate::store::Store::open(root.path())?;
        let mut file = store.stage().await?;
        file.write_all(b"abc")?;
        let entry = store
            .commit(
                serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?,
                file,
                false,
            )
            .await?;
        let host = Host::new(store, "https://music.example.test".into());
        let mut active = Vec::new();
        for _ in 0..16 {
            let response = audio(
                State(host.clone()),
                Ok(Path(entry.sha256.clone())),
                HeaderMap::new(),
            )
            .await
            .into_response();
            assert_eq!(response.status(), 200);
            active.push(response);
        }
        let response = artwork(
            State(host.clone()),
            Ok(Path("image".into())),
            HeaderMap::new(),
        )
        .await
        .into_response();
        assert_eq!(response.status(), 429);
        assert_eq!(response.headers()[header::RETRY_AFTER], "5");
        let body = axum::body::to_bytes(response.into_body(), 1024).await?;
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body)?["error"],
            "rate-limited"
        );
        active.pop();
        assert_eq!(
            audio(State(host), Ok(Path(entry.sha256)), HeaderMap::new())
                .await
                .into_response()
                .status(),
            200
        );
        Ok(())
    }
}

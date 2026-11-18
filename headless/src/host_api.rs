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
use std::sync::Arc;
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
        Ok(Self {
            id: db.query_row("SELECT id FROM library WHERE singleton = 1", [], |row| {
                row.get(0)
            })?,
            entries: crate::store::payloads(db, "SELECT payload FROM tracks ORDER BY id")?,
            organization: db.query_row(
                "SELECT payload FROM organization WHERE singleton = 1",
                [],
                |row| row.get(0),
            )?,
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
            for bytes in artwork.assets.values_mut() {
                bytes.clear();
            }
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
        })
    }
}

// Serde skips the legacy embedded artwork field without decoding the JPEG.
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
        let bytes = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
            let mut encoder =
                flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
            std::io::Write::write_all(&mut encoder, &snapshot.body)?;
            Ok(encoder.finish()?)
        })
        .await
        .map_err(anyhow::Error::from)??;
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
    let permit = host.slot()?;
    if id.len() != 64
        || !id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(ApiError::Missing);
    }
    let lookup = id.clone();
    let (payload, objects) = host
        .store
        .run(move |db, root| {
            let payload: Option<Vec<u8>> = db
                .query_row(
                    "SELECT payload FROM tracks WHERE sha256 = ? ORDER BY suffix LIMIT 1",
                    [lookup],
                    |row| row.get(0),
                )
                .optional()?;
            Ok((payload, root.join("objects")))
        })
        .await?;
    let (file, size) = if let Some(payload) = payload {
        let entry: crate::model::Entry =
            serde_json::from_slice(&payload).map_err(anyhow::Error::from)?;
        if entry.sha256 != id {
            return Err(ApiError::Storage(anyhow::anyhow!("audio hash mismatch")));
        }
        (
            crate::api::open_audio(&host.store, &entry).await?,
            entry.track.size,
        )
    } else {
        stored_audio(&objects, &id).await?
    };
    Ok(crate::api::file_response(
        file,
        size,
        &id,
        "application/octet-stream",
        &headers,
        crate::api::Download::Host(permit),
    )
    .await?)
}

async fn stored_audio(
    objects: &std::path::Path,
    id: &str,
) -> Result<(tokio::fs::File, u64), ApiError> {
    for suffix in crate::model::AUDIO_SUFFIXES {
        match tokio::fs::File::open(objects.join(format!("{id}.{suffix}"))).await {
            Ok(file) => {
                let metadata = file.metadata().await.map_err(anyhow::Error::from)?;
                if !metadata.is_file() || !(1..=crate::model::MAX_AUDIO).contains(&metadata.len()) {
                    return Err(ApiError::Storage(anyhow::anyhow!("invalid stored audio")));
                }
                return Ok((file, metadata.len()));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(ApiError::Storage(error.into())),
        }
    }
    Err(ApiError::Missing)
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

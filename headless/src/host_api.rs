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
pub use socket::WriteIdleTimeout;
use std::sync::Arc;
use tokio::sync::Semaphore;

#[derive(Clone)]
struct Host {
    store: crate::store::Store,
    address: Option<String>,
    files: Arc<Semaphore>,
}

pub fn router(store: crate::store::Store, address: Option<String>) -> Router {
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

#[cfg(feature = "p2p")]
fn read_playlists(connection: &rusqlite::Connection) -> anyhow::Result<Playlists> {
    let mut result = Playlists::default();
    let records = crate::playlists::records(connection)?;
    if !records.is_empty() {
        let proof = crate::enrollment::read_proof(connection)?;
        for (id, snapshot) in crate::playlists::project(&records, &proof)? {
            if snapshot.conflicted {
                result.conflicted_playlists.push(id);
            }
            result.playlists.push(snapshot.document);
        }
    }
    Ok(result)
}

#[derive(serde::Serialize)]
struct Catalog {
    #[serde(flatten)]
    catalog: crate::model::Catalog,
    #[serde(flatten)]
    playlists: Playlists,
    marker: String,
}

impl Host {
    fn new(store: crate::store::Store, address: Option<String>) -> Self {
        Self {
            store,
            address,
            files: Arc::new(Semaphore::new(16)),
        }
    }

    async fn snapshot(&self) -> anyhow::Result<Catalog> {
        use sha2::Digest as _;
        let host_id = self.store.host_id();
        self.store
            .run(move |db, _| {
                let tx = db.transaction()?;
                let catalog =
                    crate::store::read_catalog(&tx, crate::store::CatalogImages::References)?;
                #[cfg(feature = "p2p")]
                let playlists = read_playlists(&tx)?;
                #[cfg(not(feature = "p2p"))]
                let playlists = Playlists::default();
                tx.commit()?;
                // Until ASO-161 adds a revision counter, hash the ordered wire content.
                let mut digest = sha2::Sha256::new();
                serde_json::to_writer(
                    &mut digest,
                    &(&catalog.entries, &catalog.organization, &playlists),
                )?;
                let marker = format!("1.{host_id}.{:x}", digest.finalize());
                Ok(Catalog {
                    catalog,
                    playlists,
                    marker,
                })
            })
            .await
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
        "library": snapshot.catalog.id,
        "name": snapshot.catalog.name,
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
    let tag = format!("\"{}.{}\"", snapshot.catalog.id, snapshot.marker);
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
            serde_json::to_writer(&mut encoder, &snapshot)?;
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
        Json(snapshot).into_response()
    };
    response
        .headers_mut()
        .insert(header::ETAG, tag.parse().map_err(anyhow::Error::from)?);
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
    let entry: crate::model::Entry = host
        .store
        .run(move |db, _| {
            let data: Option<Vec<u8>> = db
                .query_row(
                    "SELECT payload FROM tracks WHERE sha256 = ? ORDER BY suffix LIMIT 1",
                    [&id],
                    |row| row.get(0),
                )
                .optional()?;
            data.map(|bytes| {
                let entry: crate::model::Entry = serde_json::from_slice(&bytes)?;
                anyhow::ensure!(entry.sha256 == id, "audio hash mismatch");
                Ok(entry)
            })
            .transpose()
        })
        .await?
        .ok_or(ApiError::Missing)?;
    let file = crate::api::open_audio(&host.store, &entry).await?;
    Ok(crate::api::file_response(
        file,
        entry.track.size,
        &entry.sha256,
        "application/octet-stream",
        &headers,
        crate::api::Download::Host(permit),
    )
    .await?)
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
            let tx = db.transaction()?;
            if !crate::store::organization_metadata(&tx)?
                .artwork
                .is_some_and(|art| art.assets.contains_key(&lookup))
            {
                return Ok(None);
            }
            let bytes = tx.query_row(
                "SELECT payload FROM artwork_assets WHERE id = ?",
                [lookup],
                |r| r.get(0),
            )?;
            Ok(Some(bytes))
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
        let host = Host::new(store, None);
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

#[derive(Clone)]
struct State {
    store: crate::store::Store,
    token_hash: [u8; 32],
    uploads: std::sync::Arc<tokio::sync::Semaphore>,
}

pub struct Error(axum::http::StatusCode, &'static str);

impl crate::api::Error {
    fn internal(error: impl std::fmt::Display) -> Self {
        eprintln!("storage operation failed: {error}");
        Self(
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            "storage operation failed",
        )
    }

    fn bad_request() -> Self {
        Self(axum::http::StatusCode::BAD_REQUEST, "invalid upload")
    }
}

impl axum::response::IntoResponse for crate::api::Error {
    fn into_response(self) -> axum::response::Response {
        axum::response::IntoResponse::into_response((self.0, self.1))
    }
}

pub fn router(store: crate::store::Store, token: &str) -> axum::Router {
    use sha2::Digest as _;
    let state = crate::api::State {
        store,
        token_hash: sha2::Sha256::digest(token.as_bytes()).into(),
        uploads: std::sync::Arc::new(tokio::sync::Semaphore::new(4)),
    };
    axum::Router::new()
        .route("/v3/catalog", axum::routing::get(crate::api::incompatible))
        .route("/v3/tracks", axum::routing::post(crate::api::incompatible))
        .route(
            "/v3/organization",
            axum::routing::post(crate::api::incompatible),
        )
        .route(
            "/v3/tracks/{id}/audio",
            axum::routing::get(crate::api::incompatible),
        )
        .route("/v2/catalog", axum::routing::get(crate::api::incompatible))
        .route("/v2/tracks", axum::routing::post(crate::api::incompatible))
        .route(
            "/v2/organization",
            axum::routing::post(crate::api::incompatible),
        )
        .route(
            "/v2/tracks/{id}/audio",
            axum::routing::get(crate::api::incompatible),
        )
        .route("/v1/catalog", axum::routing::get(crate::api::incompatible))
        .route("/v1/tracks", axum::routing::post(crate::api::incompatible))
        .route(
            "/v1/tracks/{id}/audio",
            axum::routing::get(crate::api::incompatible),
        )
        .route(
            "/v4/organization",
            axum::routing::post(crate::api::organization)
                .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024)),
        )
        .route("/v4/catalog", axum::routing::get(crate::api::catalog))
        .route("/v4/tracks", axum::routing::post(crate::api::upload))
        .route(
            "/v4/tracks/{id}/audio",
            axum::routing::get(crate::api::download),
        )
        .layer(axum::extract::DefaultBodyLimit::max(
            crate::model::MAX_AUDIO as usize + crate::model::MAX_METADATA + 65536,
        ))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            crate::api::authorize,
        ))
        .with_state(state)
}

async fn authorize(
    axum::extract::State(state): axum::extract::State<crate::api::State>,
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    use axum::response::IntoResponse as _;
    use sha2::Digest as _;
    use subtle::ConstantTimeEq as _;
    let valid = request
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|token| {
            let hash: [u8; 32] = sha2::Sha256::digest(token.as_bytes()).into();
            bool::from(hash.ct_eq(&state.token_hash))
        });
    let mut response = if valid {
        match tokio::time::timeout(
            std::time::Duration::from_secs(2 * 60 * 60),
            next.run(request),
        )
        .await
        {
            Ok(response) => response,
            Err(_) => {
                (axum::http::StatusCode::REQUEST_TIMEOUT, "request timed out").into_response()
            }
        }
    } else {
        let mut response = (axum::http::StatusCode::UNAUTHORIZED, "unauthorized").into_response();
        response.headers_mut().insert(
            axum::http::header::WWW_AUTHENTICATE,
            axum::http::HeaderValue::from_static("Bearer"),
        );
        response
    };
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store"),
    );
    response.headers_mut().insert(
        "x-content-type-options",
        axum::http::HeaderValue::from_static("nosniff"),
    );
    response
}

async fn catalog(
    axum::extract::State(state): axum::extract::State<crate::api::State>,
) -> Result<axum::Json<crate::model::Catalog>, crate::api::Error> {
    Ok(axum::Json(
        state
            .store
            .catalog()
            .await
            .map_err(crate::api::Error::internal)?,
    ))
}

async fn upload(
    axum::extract::State(state): axum::extract::State<crate::api::State>,
    mut multipart: axum::extract::Multipart,
) -> Result<axum::Json<crate::model::Entry>, crate::api::Error> {
    use sha2::Digest as _;
    use tokio::io::AsyncWriteExt as _;
    let _permit = state.uploads.try_acquire().map_err(|_| {
        crate::api::Error(
            axum::http::StatusCode::TOO_MANY_REQUESTS,
            "too many uploads",
        )
    })?;
    let mut field = multipart
        .next_field()
        .await
        .map_err(|_| crate::api::Error::bad_request())?
        .ok_or_else(crate::api::Error::bad_request)?;
    if field.name() != Some("entry") {
        return Err(crate::api::Error::bad_request());
    }
    let mut metadata = Vec::new();
    while let Some(bytes) = field
        .chunk()
        .await
        .map_err(|_| crate::api::Error::bad_request())?
    {
        if metadata.len() + bytes.len() > crate::model::MAX_METADATA {
            return Err(crate::api::Error::bad_request());
        }
        metadata.extend_from_slice(&bytes);
    }
    drop(field);
    let entry: crate::model::Entry =
        serde_json::from_slice(&metadata).map_err(|_| crate::api::Error::bad_request())?;
    entry
        .validate()
        .map_err(|_| crate::api::Error::bad_request())?;
    let mut audio = multipart
        .next_field()
        .await
        .map_err(|_| crate::api::Error::bad_request())?
        .ok_or_else(crate::api::Error::bad_request)?;
    if audio.name() != Some("audio") {
        return Err(crate::api::Error::bad_request());
    }
    let temporary = state
        .store
        .stage()
        .await
        .map_err(crate::api::Error::internal)?;
    let mut file =
        tokio::fs::File::from_std(temporary.reopen().map_err(crate::api::Error::internal)?);
    let mut hash = sha2::Sha256::new();
    let mut received = 0u64;
    while let Some(bytes) = audio
        .chunk()
        .await
        .map_err(|_| crate::api::Error::bad_request())?
    {
        received += bytes.len() as u64;
        if received > entry.track.size {
            return Err(crate::api::Error(
                axum::http::StatusCode::UNPROCESSABLE_ENTITY,
                "audio size mismatch",
            ));
        }
        hash.update(&bytes);
        file.write_all(&bytes)
            .await
            .map_err(crate::api::Error::internal)?;
    }
    if received != entry.track.size || hex::encode(hash.finalize()) != entry.sha256 {
        return Err(crate::api::Error(
            axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            "audio size or hash mismatch",
        ));
    }
    drop(audio);
    if multipart
        .next_field()
        .await
        .map_err(|_| crate::api::Error::bad_request())?
        .is_some()
    {
        return Err(crate::api::Error::bad_request());
    }
    file.flush().await.map_err(crate::api::Error::internal)?;
    file.sync_all().await.map_err(crate::api::Error::internal)?;
    drop(file);
    Ok(axum::Json(
        state
            .store
            .commit_upload(entry, temporary)
            .await
            .map_err(crate::api::Error::internal)?,
    ))
}

async fn download(
    axum::extract::State(state): axum::extract::State<crate::api::State>,
    axum::extract::Path(id): axum::extract::Path<String>,
    headers: axum::http::HeaderMap,
) -> Result<axum::response::Response, crate::api::Error> {
    let entry = state
        .store
        .get(id)
        .await
        .map_err(crate::api::Error::internal)?
        .ok_or(crate::api::Error(
            axum::http::StatusCode::NOT_FOUND,
            "track not found",
        ))?;
    entry.validate().map_err(Error::internal)?;
    let path = state.store.path(&entry);
    let (file, metadata) = tokio::task::spawn_blocking(move || open_audio(&path))
        .await
        .map_err(Error::internal)?
        .map_err(Error::internal)?;
    if metadata.len() != entry.track.size {
        return Err(Error::internal("audio size mismatch"));
    }
    file_response(
        tokio::fs::File::from_std(file),
        entry.track.size,
        &entry.sha256,
        "application/octet-stream",
        &headers,
        Download::Legacy,
    )
    .await
    .map_err(Error::internal)
}

pub(crate) fn open_audio(
    path: &std::path::Path,
) -> std::io::Result<(std::fs::File, std::fs::Metadata)> {
    use std::io::Error;
    if !std::fs::symlink_metadata(path)?.is_file() {
        return Err(Error::other("not a regular audio file"));
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    // Protect the open itself if the directory entry changes after the type check.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt as _;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(Error::other("not a regular audio file"));
    }
    Ok((file, metadata))
}

pub(crate) enum Download {
    Legacy,
    Host(tokio::sync::OwnedSemaphorePermit),
}

pub(crate) async fn file_response<
    R: tokio::io::AsyncRead + tokio::io::AsyncSeek + Unpin + Send + 'static,
>(
    mut reader: R,
    size: u64,
    id: &str,
    content_type: &'static str,
    headers: &axum::http::HeaderMap,
    download: Download,
) -> anyhow::Result<axum::response::Response> {
    use axum::http::{StatusCode, header};
    use axum::response::IntoResponse as _;
    use futures_util::StreamExt as _;
    use tokio::io::{AsyncReadExt as _, AsyncSeekExt as _};
    anyhow::ensure!(size > 0, "empty file");
    let etag = format!("\"{id}\"");
    let requested = headers
        .get(header::IF_RANGE)
        .is_none_or(|v| v == etag.as_str())
        .then(|| headers.get(header::RANGE))
        .flatten();
    let legacy = matches!(download, Download::Legacy);
    let (start, end, status) = match requested {
        Some(value) if !legacy || value.to_str().is_ok() => {
            let single = legacy || headers.get_all(header::RANGE).iter().count() == 1;
            let range = value
                .to_str()
                .ok()
                .and_then(|v| range(v, size))
                .filter(|_| single);
            let Some((start, end)) = range else {
                let status = StatusCode::RANGE_NOT_SATISFIABLE;
                let headers = [(header::CONTENT_RANGE, format!("bytes */{size}"))];
                if legacy {
                    return Ok((status, headers, "invalid range").into_response());
                }
                return Ok((
                    status,
                    headers,
                    [
                        (header::ACCEPT_RANGES, "bytes"),
                        (header::CONTENT_TYPE, content_type),
                        (header::ETAG, etag.as_str()),
                        (header::CONTENT_LENGTH, "0"),
                    ],
                )
                    .into_response());
            };
            (start, end, StatusCode::PARTIAL_CONTENT)
        }
        _ => (0, size - 1, StatusCode::OK),
    };
    reader.seek(std::io::SeekFrom::Start(start)).await?;
    let length = end - start + 1;
    // The response owns the slot until its body finishes or the caller disconnects.
    let permit = match download {
        Download::Legacy => None,
        Download::Host(slot) => Some(slot),
    };
    let stream = tokio_util::io::ReaderStream::new(reader.take(length)).map(move |chunk| {
        let _ = &permit;
        chunk
    });
    let mut response = axum::response::Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CONTENT_LENGTH, length)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::ETAG, etag);
    if status == StatusCode::PARTIAL_CONTENT {
        response = response.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
    }
    Ok(response.body(axum::body::Body::from_stream(stream))?)
}

pub(crate) fn range(value: &str, size: u64) -> Option<(u64, u64)> {
    let (start, end) = value.strip_prefix("bytes=")?.split_once('-')?;
    if start.is_empty() {
        let suffix: u64 = end.parse().ok()?;
        return (suffix > 0).then_some((size.saturating_sub(suffix), size - 1));
    }
    let start: u64 = start.parse().ok()?;
    let end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>().ok()?.min(size - 1)
    };
    (start <= end && start < size).then_some((start, end))
}

async fn incompatible() -> crate::api::Error {
    crate::api::Error(
        axum::http::StatusCode::UPGRADE_REQUIRED,
        "update Syncstr: organization protocol version 4 required",
    )
}

async fn organization(
    axum::extract::State(state): axum::extract::State<crate::api::State>,
    axum::Json(incoming): axum::Json<crate::organization::Organization>,
) -> Result<axum::http::StatusCode, crate::api::Error> {
    incoming
        .validate()
        .map_err(|_| crate::api::Error::bad_request())?;
    if serde_json::to_vec(&incoming)
        .map_err(|_| crate::api::Error::bad_request())?
        .len()
        > 64 * 1024 * 1024
    {
        return Err(crate::api::Error::bad_request());
    }
    state
        .store
        .merge_organization(incoming)
        .await
        .map_err(crate::api::Error::internal)?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

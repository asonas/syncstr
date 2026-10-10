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
        .route("/v1/catalog", axum::routing::get(crate::api::incompatible))
        .route("/v1/tracks", axum::routing::post(crate::api::incompatible))
        .route(
            "/v1/tracks/{id}/audio",
            axum::routing::get(crate::api::incompatible),
        )
        .route(
            "/v2/organization",
            axum::routing::post(crate::api::organization).layer(
                axum::extract::DefaultBodyLimit::max(crate::model::MAX_METADATA),
            ),
        )
        .route("/v2/catalog", axum::routing::get(crate::api::catalog))
        .route("/v2/tracks", axum::routing::post(crate::api::upload))
        .route(
            "/v2/tracks/{id}/audio",
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
            .commit(entry, temporary, false)
            .await
            .map_err(crate::api::Error::internal)?,
    ))
}

async fn download(
    axum::extract::State(state): axum::extract::State<crate::api::State>,
    axum::extract::Path(id): axum::extract::Path<String>,
    headers: axum::http::HeaderMap,
) -> Result<axum::response::Response, crate::api::Error> {
    use axum::response::IntoResponse as _;
    use tokio::io::AsyncReadExt as _;
    use tokio::io::AsyncSeekExt as _;
    let entry = state
        .store
        .get(id)
        .await
        .map_err(crate::api::Error::internal)?
        .ok_or(crate::api::Error(
            axum::http::StatusCode::NOT_FOUND,
            "track not found",
        ))?;
    entry.validate().map_err(crate::api::Error::internal)?;
    let mut file = tokio::fs::File::open(state.store.path(&entry))
        .await
        .map_err(crate::api::Error::internal)?;
    let metadata = file.metadata().await.map_err(crate::api::Error::internal)?;
    if !metadata.is_file() || metadata.len() != entry.track.size {
        return Err(crate::api::Error::internal("audio size mismatch"));
    }
    let etag = format!("\"{}\"", entry.sha256);
    let range = if headers
        .get(axum::http::header::IF_RANGE)
        .is_none_or(|value| value == etag.as_str())
    {
        headers
            .get(axum::http::header::RANGE)
            .and_then(|value| value.to_str().ok())
    } else {
        None
    };
    let (start, end, status) = if let Some(range) = range {
        match crate::api::range(range, entry.track.size) {
            Some((start, end)) => (start, end, axum::http::StatusCode::PARTIAL_CONTENT),
            None => {
                return Ok((
                    axum::http::StatusCode::RANGE_NOT_SATISFIABLE,
                    [(
                        axum::http::header::CONTENT_RANGE,
                        format!("bytes */{}", entry.track.size),
                    )],
                    "invalid range",
                )
                    .into_response());
            }
        }
    } else {
        (0, entry.track.size - 1, axum::http::StatusCode::OK)
    };
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(crate::api::Error::internal)?;
    let mut response = axum::response::Response::new(axum::body::Body::from_stream(
        tokio_util::io::ReaderStream::new(file.take(end - start + 1)),
    ));
    *response.status_mut() = status;
    for (name, value) in [
        (
            axum::http::header::CONTENT_TYPE,
            "application/octet-stream".to_owned(),
        ),
        (
            axum::http::header::CONTENT_LENGTH,
            (end - start + 1).to_string(),
        ),
        (axum::http::header::ACCEPT_RANGES, "bytes".to_owned()),
        (axum::http::header::ETAG, etag),
    ] {
        response
            .headers_mut()
            .insert(name, value.parse().map_err(crate::api::Error::internal)?);
    }
    if range.is_some() {
        response.headers_mut().insert(
            axum::http::header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{}", entry.track.size)
                .parse()
                .map_err(crate::api::Error::internal)?,
        );
    }
    Ok(response)
}

fn range(value: &str, size: u64) -> Option<(u64, u64)> {
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
        "update Syncstr: organization protocol version 2 required",
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
        > crate::model::MAX_METADATA
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

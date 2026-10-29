//! Authenticated v5 service. No legacy mutation routes are mounted here.

#[derive(Clone)]
struct State {
    store: crate::shared_audio::Store,
    signer: std::sync::Arc<crate::peer::Identity>,
    token: [u8; 32],
    uploads: std::sync::Arc<tokio::sync::Semaphore>,
}

pub fn router(
    store: crate::shared_audio::Store,
    signer: std::sync::Arc<crate::peer::Identity>,
    token: &str,
) -> axum::Router {
    use sha2::Digest as _;
    let state = State {
        store,
        signer,
        token: sha2::Sha256::digest(token.as_bytes()).into(),
        uploads: std::sync::Arc::new(tokio::sync::Semaphore::new(2)),
    };
    axum::Router::new()
        .route(
            "/v5/membership",
            axum::routing::get(crate::shared_audio_api::membership)
                .post(crate::shared_audio_api::merge_membership),
        )
        .route(
            "/v5/revoke",
            axum::routing::post(crate::shared_audio_api::revoke),
        )
        .route(
            "/v5/catalog",
            axum::routing::get(crate::shared_audio_api::catalog),
        )
        .route(
            "/v5/commit",
            axum::routing::post(crate::shared_audio_api::commit),
        )
        .route(
            "/v5/records",
            axum::routing::get(crate::shared_audio_api::records)
                .post(crate::shared_audio_api::receive),
        )
        .route(
            "/v5/playlists",
            axum::routing::get(crate::shared_audio_api::playlists)
                .post(crate::shared_audio_api::update_playlists),
        )
        .route(
            "/v5/playlist-records",
            axum::routing::get(crate::shared_audio_api::playlist_records),
        )
        .route(
            "/v5/objects/{hash}",
            axum::routing::put(crate::shared_audio_api::upload)
                .layer(axum::extract::DefaultBodyLimit::disable()),
        )
        .route(
            "/v5/tracks/{id}/audio/{hash}",
            axum::routing::get(crate::shared_audio_api::audio),
        )
        .fallback(|| async {
            (
                axum::http::StatusCode::UPGRADE_REQUIRED,
                "shared audio requires protocol v5",
            )
        })
        .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            crate::shared_audio_api::authorize,
        ))
        .with_state(state)
}

async fn authorize(
    axum::extract::State(state): axum::extract::State<State>,
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    use axum::response::IntoResponse as _;
    use sha2::Digest as _;
    use subtle::ConstantTimeEq as _;
    let authorized = request
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .is_some_and(|token| {
            bool::from(
                sha2::Sha256::digest(token.as_bytes())
                    .as_slice()
                    .ct_eq(&state.token),
            )
        });
    let mut response = if authorized {
        match tokio::time::timeout(std::time::Duration::from_secs(7200), next.run(request)).await {
            Ok(response) => response,
            Err(_) => {
                (axum::http::StatusCode::REQUEST_TIMEOUT, "request timed out").into_response()
            }
        }
    } else {
        (axum::http::StatusCode::UNAUTHORIZED, "unauthorized").into_response()
    };
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store"),
    );
    response
}

type Failure = (axum::http::StatusCode, String);

async fn membership(
    axum::extract::State(state): axum::extract::State<State>,
) -> Result<axum::Json<crate::enrollment::Proof>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.membership())
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

async fn merge_membership(
    axum::extract::State(state): axum::extract::State<State>,
    axum::Json(proof): axum::Json<crate::enrollment::Proof>,
) -> Result<axum::http::StatusCode, Failure> {
    tokio::task::spawn_blocking(move || state.store.merge_membership(proof))
        .await
        .map_err(crate::shared_audio_api::failed)?
        .map_err(crate::shared_audio_api::failed)?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Revoke {
    member: String,
}

async fn revoke(
    axum::extract::State(state): axum::extract::State<State>,
    axum::Json(request): axum::Json<Revoke>,
) -> Result<axum::Json<crate::enrollment::Revocation>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || {
            state.store.revoke_member(&state.signer, &request.member)
        })
        .await
        .map_err(crate::shared_audio_api::failed)?
        .map_err(crate::shared_audio_api::failed)?,
    ))
}

fn failed(error: impl std::fmt::Display) -> Failure {
    (axum::http::StatusCode::CONFLICT, error.to_string())
}

async fn catalog(
    axum::extract::State(state): axum::extract::State<State>,
) -> Result<axum::Json<crate::shared_audio::Catalog>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.catalog())
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

async fn commit(
    axum::extract::State(state): axum::extract::State<State>,
    axum::Json(request): axum::Json<crate::shared_audio::Request>,
) -> Result<axum::Json<crate::shared_audio::Signed>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.commit(&state.signer, request))
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

#[derive(serde::Deserialize)]
struct Cursor {
    #[serde(default)]
    after: i64,
}

async fn playlists(
    axum::extract::State(state): axum::extract::State<State>,
) -> Result<axum::Json<Vec<crate::playlists::Snapshot>>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.playlists())
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

async fn update_playlists(
    axum::extract::State(state): axum::extract::State<State>,
    axum::Json(request): axum::Json<crate::shared_audio::PlaylistUpdate>,
) -> Result<axum::Json<Vec<crate::playlists::Signed>>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.update_playlists(&state.signer, request))
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

async fn playlist_records(
    axum::extract::State(state): axum::extract::State<State>,
    axum::extract::Query(cursor): axum::extract::Query<Cursor>,
) -> Result<axum::Json<Vec<(i64, crate::playlists::Signed)>>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.playlist_page(cursor.after))
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

async fn records(
    axum::extract::State(state): axum::extract::State<State>,
    axum::extract::Query(cursor): axum::extract::Query<Cursor>,
) -> Result<axum::Json<Vec<(i64, crate::shared_audio::Signed)>>, Failure> {
    Ok(axum::Json(
        tokio::task::spawn_blocking(move || state.store.page(cursor.after))
            .await
            .map_err(crate::shared_audio_api::failed)?
            .map_err(crate::shared_audio_api::failed)?,
    ))
}

async fn receive(
    axum::extract::State(state): axum::extract::State<State>,
    axum::Json(records): axum::Json<Vec<crate::shared_audio::Signed>>,
) -> Result<axum::http::StatusCode, Failure> {
    tokio::task::spawn_blocking(move || state.store.receive(records))
        .await
        .map_err(crate::shared_audio_api::failed)?
        .map_err(crate::shared_audio_api::failed)?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

async fn upload(
    axum::extract::State(state): axum::extract::State<State>,
    axum::extract::Path(hash): axum::extract::Path<String>,
    body: axum::body::Body,
) -> Result<axum::http::StatusCode, Failure> {
    use futures_util::StreamExt as _;
    use tokio::io::AsyncWriteExt as _;
    let _permit = state
        .uploads
        .clone()
        .acquire_owned()
        .await
        .map_err(crate::shared_audio_api::failed)?;
    let staged = state
        .store
        .stage()
        .map_err(crate::shared_audio_api::failed)?;
    let mut file =
        tokio::fs::File::from_std(staged.reopen().map_err(crate::shared_audio_api::failed)?);
    let mut stream = body.into_data_stream();
    let mut size = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(crate::shared_audio_api::failed)?;
        size += chunk.len() as u64;
        if size > crate::model::MAX_AUDIO {
            return Err((
                axum::http::StatusCode::PAYLOAD_TOO_LARGE,
                "audio too large".into(),
            ));
        }
        file.write_all(&chunk)
            .await
            .map_err(crate::shared_audio_api::failed)?;
    }
    file.flush()
        .await
        .map_err(crate::shared_audio_api::failed)?;
    drop(file);
    tokio::task::spawn_blocking(move || state.store.put_audio(&hash, &mut staged.reopen()?))
        .await
        .map_err(crate::shared_audio_api::failed)?
        .map_err(crate::shared_audio_api::failed)?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

async fn audio(
    axum::extract::State(state): axum::extract::State<State>,
    axum::extract::Path((id, hash)): axum::extract::Path<(String, String)>,
    headers: axum::http::HeaderMap,
) -> Result<axum::response::Response, Failure> {
    use axum::response::IntoResponse as _;
    use tokio::io::{AsyncReadExt as _, AsyncSeekExt as _};
    let file = tokio::task::spawn_blocking(move || state.store.audio(&id, &hash))
        .await
        .map_err(crate::shared_audio_api::failed)?
        .map_err(|_| {
            (
                axum::http::StatusCode::NOT_FOUND,
                "audio unavailable".into(),
            )
        })?;
    let size = file
        .metadata()
        .map_err(crate::shared_audio_api::failed)?
        .len();
    let selected = if let Some(range) = headers.get(axum::http::header::RANGE) {
        match range
            .to_str()
            .ok()
            .and_then(|value| crate::api::range(value, size))
        {
            Some(range) => Some(range),
            None => {
                return Ok((
                    axum::http::StatusCode::RANGE_NOT_SATISFIABLE,
                    [(axum::http::header::CONTENT_RANGE, format!("bytes */{size}"))],
                )
                    .into_response());
            }
        }
    } else {
        None
    };
    let (start, end) = selected.unwrap_or((0, size - 1));
    let mut file = tokio::fs::File::from_std(file);
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(crate::shared_audio_api::failed)?;
    let body = axum::body::Body::from_stream(tokio_util::io::ReaderStream::new(
        file.take(end - start + 1),
    ));
    let mut response = (
        [
            (
                axum::http::header::CONTENT_TYPE,
                "application/octet-stream".to_owned(),
            ),
            (
                axum::http::header::CONTENT_LENGTH,
                (end - start + 1).to_string(),
            ),
            (axum::http::header::ACCEPT_RANGES, "bytes".to_owned()),
        ],
        body,
    )
        .into_response();
    if selected.is_some() {
        *response.status_mut() = axum::http::StatusCode::PARTIAL_CONTENT;
        response.headers_mut().insert(
            axum::http::header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{size}")
                .parse()
                .map_err(crate::shared_audio_api::failed)?,
        );
    }
    Ok(response)
}

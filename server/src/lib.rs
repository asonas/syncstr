#[derive(Clone)]
pub struct UploadService {
    music: std::path::PathBuf,
    staging: std::path::PathBuf,
    token: std::sync::Arc<String>,
    max_bytes: u64,
    slots: std::sync::Arc<tokio::sync::Semaphore>,
}

impl UploadService {
    pub fn new(
        music: &std::path::Path,
        staging: &std::path::Path,
        token: String,
        max_bytes: u64,
    ) -> std::io::Result<Self> {
        if token.len() < 32 || !token.bytes().all(|b| b.is_ascii_graphic()) || max_bytes == 0 {
            return Err(std::io::Error::other("invalid token or upload limit"));
        }
        // These directories are provisioned by the administrator, never by request paths.
        let music = music.canonicalize()?;
        let staging = staging.canonicalize()?;
        if !music.is_dir()
            || !staging.is_dir()
            || staging.starts_with(&music)
            || music.starts_with(&staging)
        {
            return Err(std::io::Error::other(
                "music and staging must be separate directories",
            ));
        }
        Ok(Self {
            music,
            staging,
            token: std::sync::Arc::new(token),
            max_bytes,
            slots: std::sync::Arc::new(tokio::sync::Semaphore::new(2)),
        })
    }

    pub fn router(self) -> axum::Router {
        axum::Router::new()
            .route("/v1/uploads/{filename}", axum::routing::put(crate::upload))
            .with_state(self)
    }
}

#[derive(serde::Serialize)]
struct UploadReceipt {
    filename: String,
    bytes: u64,
    sha256: String,
}

struct ApiError(axum::http::StatusCode, &'static str);

impl axum::response::IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (self.0, axum::Json(serde_error(self.1))).into_response()
    }
}

#[derive(serde::Serialize)]
struct ErrorBody {
    error: &'static str,
}

fn serde_error(error: &'static str) -> ErrorBody {
    ErrorBody { error }
}

impl From<std::io::Error> for ApiError {
    fn from(error: std::io::Error) -> Self {
        eprintln!("upload storage error: {error}");
        Self(
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            "storage_error",
        )
    }
}

async fn upload(
    axum::extract::State(service): axum::extract::State<crate::UploadService>,
    axum::extract::Path(filename): axum::extract::Path<String>,
    headers: axum::http::HeaderMap,
    body: axum::body::Body,
) -> Result<(axum::http::StatusCode, axum::Json<crate::UploadReceipt>), crate::ApiError> {
    use subtle::ConstantTimeEq;
    let supplied = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .unwrap_or("");
    if !bool::from(supplied.as_bytes().ct_eq(service.token.as_bytes())) {
        return Err(crate::ApiError(
            axum::http::StatusCode::UNAUTHORIZED,
            "unauthorized",
        ));
    }
    if !crate::valid_filename(&filename) {
        return Err(crate::ApiError(
            axum::http::StatusCode::BAD_REQUEST,
            "invalid_filename",
        ));
    }
    let length = headers
        .get(axum::http::header::CONTENT_LENGTH)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .ok_or(crate::ApiError(
            axum::http::StatusCode::LENGTH_REQUIRED,
            "length_required",
        ))?;
    if length == 0 || length > service.max_bytes {
        return Err(crate::ApiError(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "invalid_size",
        ));
    }
    let expected = headers
        .get("x-content-sha256")
        .and_then(|h| h.to_str().ok())
        .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or(crate::ApiError(
            axum::http::StatusCode::BAD_REQUEST,
            "checksum_required",
        ))?
        .to_ascii_lowercase();
    let _slot = service
        .slots
        .try_acquire()
        .map_err(|_| crate::ApiError(axum::http::StatusCode::TOO_MANY_REQUESTS, "busy"))?;
    let destination = service.music.join(&filename);
    match tokio::fs::symlink_metadata(&destination).await {
        Ok(_) => {
            return Err(crate::ApiError(
                axum::http::StatusCode::CONFLICT,
                "file_exists",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let temporary = tempfile::NamedTempFile::new_in(&service.staging)?;
    let file = tokio::fs::File::from_std(temporary.reopen()?);
    let digest = tokio::time::timeout(
        std::time::Duration::from_secs(900),
        crate::receive(body, file, length),
    )
    .await
    .map_err(|_| crate::ApiError(axum::http::StatusCode::REQUEST_TIMEOUT, "upload_timeout"))??;
    if digest != expected {
        return Err(crate::ApiError(
            axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            "checksum_mismatch",
        ));
    }
    crate::validate_audio(temporary.path(), &filename).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(temporary.path(), std::fs::Permissions::from_mode(0o644))
            .await?;
    }
    // hard_link publishes a complete file atomically and never replaces an existing entry.
    match tokio::fs::hard_link(temporary.path(), &destination).await {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(crate::ApiError(
                axum::http::StatusCode::CONFLICT,
                "file_exists",
            ));
        }
        Err(error) => return Err(error.into()),
    }
    Ok((
        axum::http::StatusCode::CREATED,
        axum::Json(crate::UploadReceipt {
            filename,
            bytes: length,
            sha256: digest,
        }),
    ))
}

async fn receive(
    body: axum::body::Body,
    mut file: tokio::fs::File,
    length: u64,
) -> Result<String, crate::ApiError> {
    use futures_util::StreamExt;
    use sha2::Digest;
    use tokio::io::AsyncWriteExt;
    let mut stream = body.into_data_stream();
    let mut count = 0u64;
    let mut digest = sha2::Sha256::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| {
            crate::ApiError(axum::http::StatusCode::BAD_REQUEST, "incomplete_upload")
        })?;
        count = count
            .checked_add(chunk.len() as u64)
            .filter(|count| *count <= length)
            .ok_or(crate::ApiError(
                axum::http::StatusCode::PAYLOAD_TOO_LARGE,
                "size_mismatch",
            ))?;
        file.write_all(&chunk).await?;
        digest.update(&chunk);
    }
    if count != length {
        return Err(crate::ApiError(
            axum::http::StatusCode::BAD_REQUEST,
            "size_mismatch",
        ));
    }
    file.sync_all().await?;
    Ok(format!("{:x}", digest.finalize()))
}

fn valid_filename(filename: &str) -> bool {
    if filename.is_empty()
        || filename.len() > 240
        || filename.starts_with('.')
        || filename.ends_with(['.', ' '])
        || filename
            .chars()
            .any(|c| c.is_control() || "/\\:<>\"|?*".contains(c))
    {
        return false;
    }
    let stem = filename
        .split('.')
        .next()
        .unwrap_or("")
        .to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
    {
        return false;
    }
    matches!(
        std::path::Path::new(filename)
            .extension()
            .and_then(|s| s.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("mp3" | "aac" | "m4a" | "alac" | "wav" | "aiff" | "aif" | "flac" | "ogg" | "opus")
    )
}

async fn validate_audio(path: &std::path::Path, filename: &str) -> Result<(), crate::ApiError> {
    let extension = std::path::Path::new(filename)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let format = match extension.as_str() {
        "mp3" => "mp3",
        "aac" => "aac",
        "m4a" | "alac" => "mov",
        "wav" => "wav",
        "aif" | "aiff" => "aiff",
        "flac" => "flac",
        "ogg" | "opus" => "ogg",
        _ => unreachable!(),
    };
    // Force the expected demuxer so playlists cannot reference other files or URLs.
    let mut command = tokio::process::Command::new("ffprobe");
    command
        .kill_on_drop(true)
        .args([
            "-v",
            "error",
            "-max_alloc",
            "67108864",
            "-protocol_whitelist",
            "file",
            "-format_whitelist",
            format,
            "-f",
            format,
            "-probesize",
            "5242880",
            "-analyzeduration",
            "5000000",
            "-show_entries",
            "stream=codec_type,codec_name,sample_rate,channels:stream_disposition=attached_pic",
            "-of",
            "json",
            "-i",
        ])
        .arg(path)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let output = tokio::time::timeout(std::time::Duration::from_secs(30), command.output())
        .await
        .map_err(|_| {
            crate::ApiError(
                axum::http::StatusCode::UNPROCESSABLE_ENTITY,
                "audio_validation_timeout",
            )
        })??;
    let invalid = || {
        crate::ApiError(
            axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_audio",
        )
    };
    if !output.status.success() {
        return Err(invalid());
    }
    let probe: crate::Probe = serde_json::from_slice(&output.stdout).map_err(|_| invalid())?;
    let has_audio = probe.streams.iter().any(|s| {
        s.codec_type == "audio"
            && s.codec_name.as_deref().is_some_and(|s| s != "unknown")
            && s.sample_rate
                .as_deref()
                .and_then(|s| s.parse::<u32>().ok())
                .is_some_and(|s| s > 0)
            && s.channels.is_some_and(|c| c > 0)
    });
    let only_audio_and_art = probe.streams.iter().all(|s| {
        s.codec_type == "audio" || (s.codec_type == "video" && s.disposition.attached_pic == 1)
    });
    if !has_audio || !only_audio_and_art {
        return Err(invalid());
    }
    Ok(())
}

#[derive(serde::Deserialize)]
struct Probe {
    streams: Vec<crate::ProbeStream>,
}

#[derive(serde::Deserialize)]
struct ProbeStream {
    codec_type: String,
    codec_name: Option<String>,
    sample_rate: Option<String>,
    channels: Option<u32>,
    #[serde(default)]
    disposition: crate::Disposition,
}

#[derive(Default, serde::Deserialize)]
struct Disposition {
    #[serde(default)]
    attached_pic: u8,
}

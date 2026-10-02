const TOKEN: &str = "test-only-upload-token-0123456789abcdef";

struct Fixture {
    _root: tempfile::TempDir,
    music: std::path::PathBuf,
    staging: std::path::PathBuf,
    router: axum::Router,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let music = root.path().join("music");
        let staging = root.path().join("staging");
        std::fs::create_dir(&music).unwrap();
        std::fs::create_dir(&staging).unwrap();
        let router =
            syncstr_upload::UploadService::new(&music, &staging, TOKEN.into(), 1024 * 1024)
                .unwrap()
                .router();
        Self {
            _root: root,
            music,
            staging,
            router,
        }
    }

    async fn send(
        &self,
        name: &str,
        data: Vec<u8>,
        token: &str,
        digest: Option<&str>,
    ) -> axum::http::StatusCode {
        use sha2::Digest;
        use tower::ServiceExt;
        let checksum = format!("{:x}", sha2::Sha256::digest(&data));
        let request = axum::http::Request::builder()
            .method("PUT")
            .uri(format!("/v1/uploads/{name}"))
            .header("authorization", format!("Bearer {token}"))
            .header("content-length", data.len())
            .header("x-content-sha256", digest.unwrap_or(&checksum))
            .body(axum::body::Body::from(data))
            .unwrap();
        self.router.clone().oneshot(request).await.unwrap().status()
    }

    fn empty(&self) {
        assert_eq!(std::fs::read_dir(&self.music).unwrap().count(), 0);
        assert_eq!(std::fs::read_dir(&self.staging).unwrap().count(), 0);
    }
}

fn wav() -> Vec<u8> {
    // RIFF PCM: 8 kHz, mono, 16 bit, 80 silent samples.
    let mut data = b"RIFF".to_vec();
    data.extend(196u32.to_le_bytes());
    data.extend(b"WAVEfmt ");
    data.extend(16u32.to_le_bytes());
    data.extend(1u16.to_le_bytes());
    data.extend(1u16.to_le_bytes());
    data.extend(8000u32.to_le_bytes());
    data.extend(16000u32.to_le_bytes());
    data.extend(2u16.to_le_bytes());
    data.extend(16u16.to_le_bytes());
    data.extend(b"data");
    data.extend(160u32.to_le_bytes());
    data.extend([0u8; 160]);
    data
}

#[tokio::test]
async fn accepts_audio_and_never_overwrites_an_existing_file() {
    let f = crate::Fixture::new();
    assert_eq!(f.send("song.wav", crate::wav(), TOKEN, None).await, 201);
    assert_eq!(
        std::fs::read(f.music.join("song.wav")).unwrap(),
        crate::wav()
    );
    assert_eq!(std::fs::read_dir(&f.staging).unwrap().count(), 0);
    assert_eq!(
        f.send("song.wav", b"replacement".to_vec(), TOKEN, None)
            .await,
        409
    );
    assert_eq!(
        std::fs::read(f.music.join("song.wav")).unwrap(),
        crate::wav()
    );
}

#[tokio::test]
async fn rejects_unauthorized_and_unsafe_paths_before_saving() {
    let f = crate::Fixture::new();
    assert_eq!(f.send("song.wav", crate::wav(), "wrong", None).await, 401);
    for name in [
        "..%2Fescape.wav",
        "C%3Aescape.wav",
        ".hidden.wav",
        "CON.wav",
        "script.sh",
    ] {
        assert_eq!(f.send(name, crate::wav(), TOKEN, None).await, 400, "{name}");
    }
    f.empty();
}

#[tokio::test]
async fn rejects_fake_audio_and_checksum_mismatch_without_publishing() {
    let f = crate::Fixture::new();
    assert_eq!(
        f.send("fake.mp3", b"not music".to_vec(), TOKEN, None).await,
        422
    );
    assert_eq!(
        f.send("song.wav", crate::wav(), TOKEN, Some(&"0".repeat(64)))
            .await,
        422
    );
    f.empty();
}

#[tokio::test]
async fn rejects_incomplete_and_oversized_bodies() {
    use tower::ServiceExt;
    let f = crate::Fixture::new();
    for (length, data, expected) in [(8, "short", 400), (2, "long", 413), (1048577, "x", 413)] {
        let request = axum::http::Request::builder()
            .method("PUT")
            .uri("/v1/uploads/song.wav")
            .header("authorization", format!("Bearer {TOKEN}"))
            .header("content-length", length)
            .header("x-content-sha256", "0".repeat(64))
            .body(axum::body::Body::from(data))
            .unwrap();
        assert_eq!(
            f.router.clone().oneshot(request).await.unwrap().status(),
            expected
        );
    }
    f.empty();
}

#[tokio::test]
async fn partial_upload_is_invisible_and_cancellation_removes_staging() {
    use tower::ServiceExt;
    let f = crate::Fixture::new();
    let stream = futures_util::stream::once(async {
        Ok::<_, std::io::Error>(axum::body::Bytes::from_static(b"partial"))
    });
    let stream = futures_util::StreamExt::chain(stream, futures_util::stream::pending());
    let request = axum::http::Request::builder()
        .method("PUT")
        .uri("/v1/uploads/song.wav")
        .header("authorization", format!("Bearer {TOKEN}"))
        .header("content-length", 100)
        .header("x-content-sha256", "0".repeat(64))
        .body(axum::body::Body::from_stream(stream))
        .unwrap();
    let task = tokio::spawn(f.router.clone().oneshot(request));
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while std::fs::read_dir(&f.staging).unwrap().count() == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(std::fs::read_dir(&f.music).unwrap().count(), 0);
    task.abort();
    let _ = task.await;
    f.empty();
}

#[cfg(unix)]
#[tokio::test]
async fn rejects_existing_symlink_without_touching_target() {
    let f = crate::Fixture::new();
    let target = f._root.path().join("original.wav");
    std::fs::write(&target, b"original").unwrap();
    std::os::unix::fs::symlink(&target, f.music.join("song.wav")).unwrap();
    assert_eq!(f.send("song.wav", crate::wav(), TOKEN, None).await, 409);
    assert_eq!(std::fs::read(target).unwrap(), b"original");
}

#[tokio::test]
async fn executable_receives_a_file_over_http() {
    use sha2::Digest;
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
    let f = crate::Fixture::new();
    let token_path = f._root.path().join("token");
    std::fs::write(&token_path, TOKEN).unwrap();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_syncstr-upload"))
        .env("SYNCSTR_TOKEN_FILE", token_path)
        .env("SYNCSTR_MUSIC_DIR", &f.music)
        .env("SYNCSTR_STAGING_DIR", &f.staging)
        .env("SYNCSTR_BIND", "127.0.0.1:0")
        .kill_on_drop(true)
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut logs = tokio::io::BufReader::new(child.stderr.take().unwrap());
    let mut line = String::new();
    tokio::time::timeout(std::time::Duration::from_secs(5), logs.read_line(&mut line))
        .await
        .unwrap()
        .unwrap();
    let address = line
        .trim()
        .strip_prefix("Syncstr upload listening on ")
        .unwrap();
    let data = crate::wav();
    let checksum = format!("{:x}", sha2::Sha256::digest(&data));
    let mut socket = tokio::net::TcpStream::connect(address).await.unwrap();
    socket.write_all(format!("PUT /v1/uploads/network.wav HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: {}\r\nX-Content-SHA256: {checksum}\r\nConnection: close\r\n\r\n", data.len()).as_bytes()).await.unwrap();
    socket.write_all(&data).await.unwrap();
    let mut response = Vec::new();
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        socket.read_to_end(&mut response),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(response.starts_with(b"HTTP/1.1 201 Created\r\n"));
    assert_eq!(std::fs::read(f.music.join("network.wav")).unwrap(), data);
    assert_eq!(std::fs::read_dir(&f.staging).unwrap().count(), 0);
    child.kill().await.unwrap();
}

#[tokio::test]
async fn rejects_video_but_accepts_audio_with_embedded_cover() {
    let f = crate::Fixture::new();
    let audio = f._root.path().join("audio.m4a");
    assert!(
        std::process::Command::new("ffmpeg")
            .args([
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=r=8000:cl=mono",
                "-t",
                "0.1",
                "-c:a",
                "aac",
            ])
            .arg(&audio)
            .status()
            .unwrap()
            .success()
    );
    for (disposition, expected) in [("0", 422), ("attached_pic", 201)] {
        let source = f._root.path().join(format!("fixture-{disposition}.m4a"));
        let output = std::process::Command::new("ffmpeg")
            .args(["-v", "error", "-i"])
            .arg(&audio)
            .args([
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=16x16",
                "-map",
                "0:a",
                "-map",
                "1:v",
                "-c:a",
                "copy",
                "-c:v",
                "mjpeg",
                "-frames:v",
                "1",
                "-disposition:v",
                disposition,
                "-f",
                "mp4",
            ])
            .arg(&source)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            f.send("media.m4a", std::fs::read(source).unwrap(), TOKEN, None)
                .await,
            expected
        );
    }
}

struct Node {
    store: Option<syncstr_headless::store::Store>,
    handle: axum_server::Handle<std::net::SocketAddr>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
    endpoint: String,
    identity: std::path::PathBuf,
}

impl crate::Node {
    async fn start(data: &std::path::Path, identity: &std::path::Path) -> Self {
        let store = syncstr_headless::store::Store::open(data).unwrap();
        let token = syncstr_headless::identity::token(&identity.join("token")).unwrap();
        let tls = syncstr_headless::identity::tls(identity).await.unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("https://{}", listener.local_addr().unwrap());
        let handle = axum_server::Handle::new();
        let server = axum_server::from_tcp_rustls(listener, tls)
            .unwrap()
            .handle(handle.clone());
        let router = syncstr_headless::api::router(store.clone(), &token);
        let task = tokio::spawn(server.serve(router.into_make_service()));
        handle.listening().await.unwrap();
        Self {
            store: Some(store),
            handle,
            task: Some(task),
            endpoint,
            identity: identity.to_owned(),
        }
    }

    fn client(&self) -> syncstr_headless::client::Client {
        syncstr_headless::client::Client::new(
            &self.endpoint,
            &self.identity.join("tls.crt"),
            &self.identity.join("token"),
        )
        .unwrap()
    }

    fn http(&self) -> reqwest::Client {
        reqwest::Client::builder()
            .tls_certs_only([reqwest::Certificate::from_pem(
                &std::fs::read(self.identity.join("tls.crt")).unwrap(),
            )
            .unwrap()])
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .unwrap()
    }

    fn token(&self) -> String {
        syncstr_headless::identity::token(&self.identity.join("token")).unwrap()
    }

    async fn close(mut self) {
        self.handle
            .graceful_shutdown(Some(std::time::Duration::from_secs(2)));
        tokio::time::timeout(std::time::Duration::from_secs(5), self.task.take().unwrap())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        self.store.take();
    }
}

impl Drop for crate::Node {
    fn drop(&mut self) {
        self.handle.shutdown();
        if let Some(task) = &self.task {
            task.abort();
        }
    }
}

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../apps/macos/Tests/Fixtures")
        .join(format!("untagged.{name}"))
}

fn directories() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let identity = root.path().join("identity");
    syncstr_headless::identity::initialize(&identity, "127.0.0.1").unwrap();
    let data = root.path().join("data");
    (root, data, identity)
}

#[tokio::test]
async fn two_clients_add_retry_restart_and_download_original_bytes() {
    let (root, data, identity) = crate::directories();
    let node = crate::Node::start(&data, &identity).await;
    let first = node.client();
    let second = node.client();
    let one = first
        .upload(
            &crate::fixture("mp3"),
            Some("First".into()),
            Some("Artist A".into()),
            Some("Album".into()),
        )
        .await
        .unwrap();
    let retry = second
        .upload(
            &crate::fixture("mp3"),
            Some("Changed title".into()),
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(one, retry);
    let two = second
        .upload(&crate::fixture("m4a"), Some("Second".into()), None, None)
        .await
        .unwrap();
    assert_ne!(one.track.id, two.track.id);
    let before = first.catalog().await.unwrap();
    assert_eq!(before.entries.len(), 2);
    node.close().await;
    let node = crate::Node::start(&data, &identity).await;
    let client = node.client();
    assert_eq!(before, client.catalog().await.unwrap());
    let output = root.path().join("received.mp3");
    client.download(&one.track.id, &output).await.unwrap();
    let expected = std::fs::read(crate::fixture("mp3")).unwrap();
    assert_eq!(std::fs::read(&output).unwrap(), expected);
    assert!(client.download(&one.track.id, &output).await.is_err());
    for (range, start, end) in [
        ("bytes=2-9", 2, 9),
        ("bytes=-8", expected.len() - 8, expected.len() - 1),
        ("bytes=10-", 10, expected.len() - 1),
    ] {
        let response = node
            .http()
            .get(format!(
                "{}/v1/tracks/{}/audio",
                node.endpoint, one.track.id
            ))
            .bearer_auth(node.token())
            .header("range", range)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::PARTIAL_CONTENT);
        assert_eq!(&response.bytes().await.unwrap()[..], &expected[start..=end]);
    }
    let missing = node
        .http()
        .get(format!("{}/v1/tracks/not-found/audio", node.endpoint))
        .bearer_auth(node.token())
        .send()
        .await
        .unwrap();
    assert_eq!(missing.status(), reqwest::StatusCode::NOT_FOUND);
    node.close().await;
}

#[tokio::test]
async fn concurrent_retries_return_one_identity() {
    let (_root, data, identity) = crate::directories();
    let node = crate::Node::start(&data, &identity).await;
    let first = node.client();
    let second = node.client();
    let path = crate::fixture("mp3");
    let (one, two) = tokio::join!(
        first.upload(&path, None, None, None),
        second.upload(&path, None, None, None)
    );
    assert_eq!(one.unwrap().track.id, two.unwrap().track.id);
    assert_eq!(node.client().catalog().await.unwrap().entries.len(), 1);
    node.close().await;
}

fn entry(audio: &[u8]) -> syncstr_headless::model::Entry {
    use sha2::Digest as _;
    let mut entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
    entry.sha256 = hex::encode(sha2::Sha256::digest(audio));
    entry.track.size = audio.len() as u64;
    entry.track.suffix = "mp3".into();
    entry
}

fn multipart(entry: &syncstr_headless::model::Entry, audio: &[u8]) -> Vec<u8> {
    let mut data =
        b"--test-boundary\r\nContent-Disposition: form-data; name=\"entry\"\r\n\r\n".to_vec();
    data.extend(serde_json::to_vec(entry).unwrap());
    data.extend(b"\r\n--test-boundary\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"../../outside.mp3\"\r\nContent-Type: application/octet-stream\r\n\r\n");
    data.extend(audio);
    data.extend(b"\r\n--test-boundary--\r\n");
    data
}

#[tokio::test]
async fn corrupt_partial_oversized_and_unauthorized_uploads_stay_private() {
    let (_root, data, identity) = crate::directories();
    let node = crate::Node::start(&data, &identity).await;
    let original = std::fs::read(crate::fixture("mp3")).unwrap();
    for scenario in [
        "hash",
        "short",
        "long",
        "suffix",
        "metadata",
        "interrupted",
        "unauthorized",
        "wrong token",
    ] {
        let mut entry = crate::entry(&original);
        let mut audio = original.clone();
        match scenario {
            "hash" => entry.sha256 = "0".repeat(64),
            "short" => {
                audio.pop();
            }
            "long" => audio.push(0),
            "suffix" => entry.track.suffix = "../../escape".into(),
            "metadata" => entry.track.title = "a".repeat(syncstr_headless::model::MAX_METADATA + 1),
            _ => {}
        }
        let mut body = crate::multipart(&entry, &audio);
        if scenario == "interrupted" {
            body.truncate(body.len() - 24);
        }
        let mut request = node
            .http()
            .post(format!("{}/v1/tracks", node.endpoint))
            .header(
                "content-type",
                "multipart/form-data; boundary=test-boundary",
            )
            .body(body);
        if scenario == "wrong token" {
            request = request.bearer_auth("0".repeat(64));
        } else if scenario != "unauthorized" {
            request = request.bearer_auth(node.token());
        }
        let response = request.send().await.unwrap();
        assert!(
            response.status().is_client_error(),
            "{scenario}: {}",
            response.status()
        );
        drop(response);
        assert!(
            node.client().catalog().await.unwrap().entries.is_empty(),
            "{scenario}"
        );
        for directory in ["staging", "objects"] {
            assert_eq!(
                std::fs::read_dir(data.join(directory)).unwrap().count(),
                0,
                "{scenario}: {directory}"
            );
        }
    }
    let raw = crate::multipart(&crate::entry(&original), &original);
    let response = node
        .http()
        .post(format!("{}/v1/tracks", node.endpoint))
        .bearer_auth(node.token())
        .header(
            "content-type",
            "multipart/form-data; boundary=test-boundary",
        )
        .body(raw)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    let saved: syncstr_headless::model::Entry = response.json().await.unwrap();
    assert_ne!(saved.track.id, "fixture-track");
    assert_eq!(saved.track.cover_art, Some(saved.track.id.clone()));
    assert_eq!(saved.artwork, Some(vec![1, 2, 3]));
    assert!(saved.track.album_id.is_none());
    node.close().await;
}

#[tokio::test]
async fn failed_database_commit_can_retry_and_only_one_process_owns_the_directory() {
    let (_root, data, identity) = crate::directories();
    let node = crate::Node::start(&data, &identity).await;
    assert!(syncstr_headless::store::Store::open(&data).is_err());
    let database = rusqlite::Connection::open(data.join("node.sqlite")).unwrap();
    database.execute_batch("CREATE TRIGGER reject_track BEFORE INSERT ON tracks BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;").unwrap();
    assert!(
        node.client()
            .upload(&crate::fixture("mp3"), None, None, None)
            .await
            .is_err()
    );
    assert!(node.client().catalog().await.unwrap().entries.is_empty());
    assert_eq!(std::fs::read_dir(data.join("staging")).unwrap().count(), 0);
    database
        .execute_batch("DROP TRIGGER reject_track;")
        .unwrap();
    let saved = node
        .client()
        .upload(&crate::fixture("mp3"), None, None, None)
        .await
        .unwrap();
    assert_eq!(node.client().catalog().await.unwrap().entries.len(), 1);
    assert_eq!(
        saved.sha256,
        crate::entry(&std::fs::read(crate::fixture("mp3")).unwrap()).sha256
    );
    node.close().await;
}

#[tokio::test]
async fn corrupt_download_is_never_published_and_untrusted_tls_is_rejected() {
    let (root, data, identity) = crate::directories();
    let node = crate::Node::start(&data, &identity).await;
    let saved = node
        .client()
        .upload(&crate::fixture("mp3"), None, None, None)
        .await
        .unwrap();
    let path = node.store.as_ref().unwrap().path(&saved);
    let mut audio = std::fs::read(&path).unwrap();
    audio[0] ^= 0xff;
    std::fs::write(path, audio).unwrap();
    let output = root.path().join("download");
    std::fs::create_dir(&output).unwrap();
    assert!(
        node.client()
            .download(&saved.track.id, &output.join("received.mp3"))
            .await
            .is_err()
    );
    assert_eq!(std::fs::read_dir(output).unwrap().count(), 0);
    let other = root.path().join("other");
    syncstr_headless::identity::initialize(&other, "127.0.0.1").unwrap();
    let untrusted = syncstr_headless::client::Client::new(
        &node.endpoint,
        &other.join("tls.crt"),
        &identity.join("token"),
    )
    .unwrap();
    assert!(untrusted.catalog().await.is_err());
    node.close().await;
}

#[test]
fn identity_is_private_and_cannot_overwrite_existing_credentials() {
    use std::os::unix::fs::PermissionsExt as _;
    let (_root, _, identity) = crate::directories();
    let original = std::fs::read(identity.join("token")).unwrap();
    assert!(syncstr_headless::identity::initialize(&identity, "127.0.0.1").is_err());
    assert_eq!(std::fs::read(identity.join("token")).unwrap(), original);
    for name in ["token", "tls.crt", "tls.key"] {
        assert_eq!(
            std::fs::metadata(identity.join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

#[test]
fn startup_cleans_abandoned_uploads_but_rejects_unknown_schema() {
    let (_root, data, _identity) = crate::directories();
    drop(syncstr_headless::store::Store::open(&data).unwrap());
    let abandoned = data.join("staging/upload-abandoned");
    let unrelated = data.join("staging/unrelated");
    std::fs::write(&abandoned, b"partial audio").unwrap();
    std::fs::write(&unrelated, b"unrelated data").unwrap();
    let database = rusqlite::Connection::open(data.join("node.sqlite")).unwrap();
    database.pragma_update(None, "user_version", 2).unwrap();
    assert!(syncstr_headless::store::Store::open(&data).is_err());
    assert!(abandoned.exists());
    let version: i64 = database
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, 2);
    database.pragma_update(None, "user_version", 1).unwrap();
    let store = syncstr_headless::store::Store::open(&data).unwrap();
    assert!(!abandoned.exists());
    assert_eq!(std::fs::read(unrelated).unwrap(), b"unrelated data");
    drop(store);
}

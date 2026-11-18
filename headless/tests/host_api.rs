use axum::http::header;
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use std::io::{Read as _, Write as _};
use syncstr_headless::{model::Entry, store::Store};

struct Host {
    root: tempfile::TempDir,
    store: Store,
    client: Client,
    url: String,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Host {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Host {
    async fn start() -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let root = tempfile::tempdir()?;
        let store = Store::open(root.path())?;
        let router =
            syncstr_headless::host_api::router(store.clone(), "https://music.example.test".into());
        let socket = std::net::TcpListener::bind("127.0.0.1:0")?;
        let url = format!("http://{}/api/v1", socket.local_addr()?);
        let server = tokio::spawn(async move {
            syncstr_headless::host_api::listener(socket)
                .unwrap()
                .serve(router.into_make_service())
                .await
                .unwrap();
        });
        Ok(Self {
            root,
            store,
            client: Client::builder().no_proxy().build()?,
            url,
            server,
        })
    }
    fn get(&self, path: &str) -> reqwest::RequestBuilder {
        self.client.get(format!("{}/{path}", self.url))
    }
    async fn upload(&self) -> anyhow::Result<Entry> {
        let mut file = self.store.stage().await?;
        file.write_all(b"abc")?;
        self.store
            .commit(
                serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?,
                file,
                false,
            )
            .await
    }
}

#[tokio::test]
async fn catalog_rejects_a_json5_track_payload() -> anyhow::Result<()> {
    let host = Host::start().await?;
    host.upload().await?;
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    db.execute(
        "UPDATE tracks SET payload = CAST('/* fixture */' || CAST(payload AS TEXT) AS BLOB)",
        [],
    )?;
    assert_error(
        host.get("catalog").send().await?,
        StatusCode::INTERNAL_SERVER_ERROR,
        "storage-failed",
    )
    .await
}

#[tokio::test]
async fn catalog_marker_tracks_wire_content_and_survives_conditional_reads() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let info = host.get("library").send().await?;
    let switch = info.headers()["syncstr-switch"].to_str()?.to_owned();
    let info: Value = info.json().await?;
    let id = info["host"]["id"].as_str().unwrap();
    uuid::Uuid::parse_str(id)?;
    assert_eq!(switch, format!("1.{id}"));
    assert_eq!(
        info,
        json!({"library":host.store.catalog().await?.id,"name":"Syncstr","host":{"id":id,"address":"https://music.example.test"},
        "primary":id,"switchNumber":1,"startingMarker":null,"marker":info["marker"],"role":"primary","hosts":[{"id":id,"address":"https://music.example.test","role":"primary"}]})
    );
    let before: Value = host.get("catalog").send().await?.json().await?;
    assert_eq!(before["marker"], info["marker"]);
    let entry = host.upload().await?;
    let response = host.get("catalog").send().await?;
    let etag = response.headers()[header::ETAG].to_str()?.to_owned();
    let catalog: Value = response.json().await?;
    assert_ne!(catalog["marker"], before["marker"]);
    assert_eq!(
        etag,
        format!(
            "W/\"{}.{}\"",
            catalog["id"].as_str().unwrap(),
            catalog["marker"].as_str().unwrap()
        )
    );
    assert_eq!(catalog["entries"][0]["track"]["id"], entry.track.id);
    assert!(catalog["entries"][0].get("artwork").is_none());
    assert_eq!(catalog["playlists"], json!([]));
    assert_eq!(catalog["conflictedPlaylists"], json!([]));
    let unchanged = host
        .get("catalog")
        .header(header::IF_NONE_MATCH, &etag)
        .send()
        .await?;
    assert_eq!(unchanged.status(), 304);
    assert_eq!(unchanged.headers()[header::ETAG], etag);
    assert!(unchanged.bytes().await?.is_empty());
    let gzip = host
        .get("catalog")
        .header(header::ACCEPT_ENCODING, "gzip")
        .send()
        .await?;
    assert_eq!(gzip.headers()[header::ETAG], etag);
    assert_eq!(
        host.get("catalog")
            .header(header::IF_NONE_MATCH, etag.strip_prefix("W/").unwrap())
            .send()
            .await?
            .status(),
        304
    );
    assert_eq!(gzip.headers()[header::CONTENT_ENCODING], "gzip");
    let compressed = gzip.bytes().await?;
    let mut decoded = Vec::new();
    flate2::read::GzDecoder::new(compressed.as_ref()).read_to_end(&mut decoded)?;
    assert_eq!(serde_json::from_slice::<Value>(&decoded)?, catalog);
    Ok(())
}

#[tokio::test]
async fn audio_ranges_and_storage_failures() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let entry = host.upload().await?;
    let path = format!("audio/{}", entry.sha256);
    let response = host.get(&path).send().await?;
    assert_eq!(response.status(), 200);
    let tag = format!("\"{}\"", entry.sha256);
    assert_eq!(response.headers()[header::ETAG], tag);
    assert_eq!(response.headers()[header::ACCEPT_RANGES], "bytes");
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        "application/octet-stream"
    );
    assert_eq!(response.bytes().await?.as_ref(), b"abc");
    let range = host
        .get(&path)
        .header(header::RANGE, "bytes=1-")
        .header(header::IF_RANGE, &tag)
        .send()
        .await?;
    assert_eq!(range.status(), 206);
    assert_eq!(range.headers()[header::CONTENT_RANGE], "bytes 1-2/3");
    assert_eq!(range.bytes().await?.as_ref(), b"bc");
    let stale = host
        .get(&path)
        .header(header::RANGE, "bytes=1-")
        .header(header::IF_RANGE, "\"stale\"")
        .send()
        .await?;
    assert_eq!(stale.status(), 200);
    assert_eq!(stale.bytes().await?.as_ref(), b"abc");
    let invalid = host
        .get(&path)
        .header(header::RANGE, "bytes=0-0,2-2")
        .send()
        .await?;
    assert_eq!(invalid.status(), 416);
    assert_eq!(invalid.headers()[header::CONTENT_RANGE], "bytes */3");
    assert!(invalid.bytes().await?.is_empty());
    std::fs::write(host.store.path(&entry), b"a")?;
    let failed = host.get(&path).send().await?;
    assert_error(failed, StatusCode::INTERNAL_SERVER_ERROR, "storage-failed").await
}

async fn assert_error(
    response: reqwest::Response,
    status: StatusCode,
    code: &str,
) -> anyhow::Result<()> {
    assert_eq!(response.status(), status);
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");
    assert!(response.headers().contains_key("syncstr-switch"));
    let body: Value = response.json().await?;
    assert_eq!(body["error"], code);
    assert!(!body["message"].as_str().unwrap().is_empty());
    Ok(())
}

#[tokio::test]
async fn artwork_serves_stored_images_after_the_reference_is_removed() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let image = include_bytes!("../fixtures/red.jpg").as_slice();
    let id = hex::encode(Sha256::digest(image));
    let mut org: syncstr_headless::organization::Organization =
        serde_json::from_slice(include_bytes!("../fixtures/album-organization.json"))?;
    org.artwork
        .get_or_insert_with(Default::default)
        .assets
        .insert(id.clone(), image.to_vec());
    let legacy = serde_json::to_vec(&org)?;
    host.store.merge_organization(org).await?;
    let catalog: Value = host.get("catalog").send().await?.json().await?;
    assert_eq!(
        catalog["organization"]["artwork"]["assets"],
        json!({&id:""})
    );
    let path = format!("artwork/{id}");
    let response = host.get(&path).send().await?;
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/jpeg");
    assert_eq!(response.headers()[header::ETAG], format!("\"{id}\""));
    assert_eq!(response.bytes().await?.as_ref(), image);
    let range = host
        .get(&path)
        .header(header::RANGE, "bytes=-3")
        .send()
        .await?;
    assert_eq!(range.status(), 206);
    assert_eq!(range.bytes().await?.as_ref(), &image[image.len() - 3..]);
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    db.execute("UPDATE organization SET payload = ?", [legacy])?;
    let legacy_catalog: Value = host.get("catalog").send().await?.json().await?;
    assert_eq!(
        legacy_catalog["organization"]["artwork"]["assets"],
        json!({&id:""})
    );
    db.execute(
        "UPDATE organization SET payload = CAST(json_remove(payload, '$.artwork') AS BLOB)",
        [],
    )?;
    let unreferenced = host.get(&path).send().await?;
    assert_eq!(unreferenced.status(), 200);
    assert_eq!(unreferenced.bytes().await?.as_ref(), image);
    assert_error(
        host.get(&format!("artwork/{}", "0".repeat(64)))
            .send()
            .await?,
        StatusCode::NOT_FOUND,
        "not-found",
    )
    .await
}

async fn v4_upload(host: &Host, entry: &Entry) -> anyhow::Result<Entry> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/v4/tracks", listener.local_addr()?);
    let api = syncstr_headless::api::router(host.store.clone(), "fixture-token");
    let upload = tokio::spawn(async move { axum::serve(listener, api).await });
    let form = reqwest::multipart::Form::new()
        .text("entry", serde_json::to_string(entry)?)
        .text("audio", "abc");
    let saved = host
        .client
        .post(url)
        .bearer_auth("fixture-token")
        .multipart(form)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    upload.abort();
    Ok(saved)
}

#[tokio::test]
async fn v4_upload_publishes_its_cover_with_the_track() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let mut entry: Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    let image = include_bytes!("../fixtures/red.jpg").as_slice();
    let id = hex::encode(Sha256::digest(image));
    entry.artwork = Some(image.to_vec());
    let saved = v4_upload(&host, &entry).await?;
    let catalog: Value = host.get("catalog").send().await?.json().await?;
    let candidates = catalog["organization"]["artwork"]["candidates"]
        .as_array()
        .unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["track"], saved.track.id);
    assert_eq!(candidates[0]["source"], "legacy");
    assert_eq!(candidates[0]["asset"], id);
    assert_eq!(
        catalog["organization"]["artwork"]["assets"],
        json!({&id:""})
    );
    assert!(catalog["entries"][0].get("artwork").is_none());
    let response = host.get(&format!("artwork/{id}")).send().await?;
    assert_eq!(response.status(), 200);
    assert_eq!(response.bytes().await?.as_ref(), image);
    entry.track.title = "Another fixture title".into();
    entry.artwork = Some(include_bytes!("../fixtures/blue.jpg").to_vec());
    assert_eq!(v4_upload(&host, &entry).await?, saved);
    let after: Value = host.get("catalog").send().await?.json().await?;
    assert_eq!(after, catalog);
    Ok(())
}

#[cfg(feature = "p2p")]
#[tokio::test]
async fn peer_projection_publishes_image_bytes_only_on_the_artwork_route() -> anyhow::Result<()> {
    peer_projection_publishes_image(false).await
}

#[cfg(feature = "p2p")]
#[tokio::test]
async fn peer_projection_registers_an_image_embedded_only_in_the_entry() -> anyhow::Result<()> {
    peer_projection_publishes_image(true).await
}

#[cfg(feature = "p2p")]
async fn peer_projection_publishes_image(embedded_only: bool) -> anyhow::Result<()> {
    let host = Host::start().await?;
    let key = host.root.path().join("fixture-key");
    syncstr_headless::peer::Identity::initialize(&key)?;
    let signer = syncstr_headless::peer::Identity::open(&key)?;
    host.store.create_cluster(signer.id().to_string()).await?;
    let fixture: Value = serde_json::from_slice(include_bytes!("../fixtures/album-artwork.json"))?;
    let mut organization: syncstr_headless::organization::Organization =
        serde_json::from_value(fixture["organization"].clone())?;
    let id = fixture["blue"].as_str().unwrap();
    let image = organization.artwork.as_ref().unwrap().assets[id].clone();
    let mut entry: Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    entry.sha256 = "a".repeat(64);
    entry.track.id = "track-a".into();
    if embedded_only {
        organization.artwork = None;
        entry.artwork = Some(image.clone());
    }
    let object = entry.sha256.clone();
    host.store
        .publish_cluster_change(
            &signer,
            object.clone(),
            syncstr_headless::cluster_changes::Action::Import {
                entry: Box::new(entry),
                organization: Box::new(organization),
            },
        )
        .await?;
    host.store.project_cluster_metadata(object).await?;
    let catalog: Value = host.get("catalog").send().await?.json().await?;
    if embedded_only {
        assert!(catalog["organization"]["artwork"].is_null());
    } else {
        assert_eq!(catalog["organization"]["artwork"]["assets"][id], "");
        let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
        let stored: syncstr_headless::organization::Organization =
            serde_json::from_slice(&stored_organization(&db)?)?;
        assert_eq!(stored.artwork.unwrap().assets[id], image);
    }
    assert!(catalog["entries"][0].get("artwork").is_none());
    let response = host.get(&format!("artwork/{id}")).send().await?;
    assert_eq!(response.status(), 200);
    assert_eq!(response.bytes().await?.as_ref(), image);
    if embedded_only {
        let candidates = reopen_catalog(&host)
            .await?
            .organization
            .artwork
            .unwrap()
            .candidates;
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].source, "legacy");
        assert_eq!(candidates[0].asset, id);
    }
    Ok(())
}

#[cfg(not(feature = "p2p"))]
#[tokio::test]
async fn catalog_requires_verification_when_playlist_records_exist() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    db.execute("CREATE TABLE playlist_records (payload BLOB)", [])?;
    assert_eq!(host.get("catalog").send().await?.status(), 200);
    db.execute("INSERT INTO playlist_records VALUES (?)", [b"record"])?;
    assert_error(
        host.get("catalog").send().await?,
        StatusCode::INTERNAL_SERVER_ERROR,
        "storage-failed",
    )
    .await
}

#[tokio::test]
async fn two_track_ids_share_an_audio_route_that_survives_removal() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let first = host.upload().await?;
    let mut copy = first.clone();
    copy.track.suffix = "aiff".into();
    let mut file = host.store.stage().await?;
    file.write_all(b"abc")?;
    let second = host.store.commit(copy, file, false).await?;
    assert_ne!(first.track.id, second.track.id);
    let catalog: Value = host.get("catalog").send().await?.json().await?;
    let entries = catalog["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 2);
    for id in [&first.track.id, &second.track.id] {
        assert!(
            entries
                .iter()
                .any(|e| e["track"]["id"] == *id && e["sha256"] == first.sha256)
        );
    }
    let path = format!("audio/{}", first.sha256);
    let response = host.get(&path).send().await?;
    assert_eq!(response.status(), 200);
    assert_eq!(response.bytes().await?.as_ref(), b"abc");
    // The indexed aiff copy sorts before the intact wav copy.
    std::fs::write(host.store.path(&second), b"short copy")?;
    let response = host.get(&path).send().await?.error_for_status()?;
    assert_eq!(response.bytes().await?.as_ref(), b"abc");
    std::fs::remove_file(host.store.path(&second))?;
    let response = host.get(&path).send().await?.error_for_status()?;
    assert_eq!(response.bytes().await?.as_ref(), b"abc");
    std::fs::remove_file(host.store.path(&first))?;
    assert_error(
        host.get(&path).send().await?,
        StatusCode::NOT_FOUND,
        "not-found",
    )
    .await?;
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    db.execute("DELETE FROM tracks", [])?;
    std::fs::write(host.store.path(&first), b"abc")?;
    let response = host
        .get(&path)
        .header(header::RANGE, "bytes=1-")
        .send()
        .await?;
    assert_eq!(response.status(), 206);
    assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes 1-2/3");
    assert_eq!(response.bytes().await?.as_ref(), b"bc");
    Ok(())
}

#[tokio::test]
async fn unindexed_audio_rechecks_a_replacement_with_the_same_size_and_mtime() -> anyhow::Result<()>
{
    let host = Host::start().await?;
    let id = hex::encode(Sha256::digest(b"abc"));
    let object = host.root.path().join("objects").join(format!("{id}.wav"));
    let path = format!("audio/{id}");
    let mtime = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(123456);
    let original = std::fs::File::create(&object)?;
    (&original).write_all(b"abc")?;
    original.set_modified(mtime)?;
    drop(original);
    let response = host.get(&path).send().await?.error_for_status()?;
    assert_eq!(response.headers()[header::ETAG], format!("\"{id}\""));
    assert_eq!(response.bytes().await?.as_ref(), b"abc");
    std::fs::remove_file(&object)?;
    let file = std::fs::File::create(&object)?;
    (&file).write_all(b"bad")?;
    file.set_modified(mtime)?;
    drop(file);
    assert_error(
        host.get(&path).send().await?,
        StatusCode::INTERNAL_SERVER_ERROR,
        "storage-failed",
    )
    .await?;
    Ok(())
}

#[cfg(unix)]
#[tokio::test]
async fn special_audio_objects_fail_with_a_storage_error_with_and_without_an_index()
-> anyhow::Result<()> {
    let host = Host::start().await?;
    let entry = host.upload().await?;
    let object = host.store.path(&entry);
    let target = host.root.path().join("fixture.wav");
    std::fs::rename(&object, &target)?;
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    let route = format!("audio/{}", entry.sha256);
    for indexed in [true, false] {
        if !indexed {
            db.execute("DELETE FROM tracks", [])?;
        }
        std::os::unix::fs::symlink(&target, &object)?;
        assert_error(
            host.get(&route).send().await?,
            StatusCode::INTERNAL_SERVER_ERROR,
            "storage-failed",
        )
        .await?;
        std::fs::remove_file(&object)?;
        anyhow::ensure!(
            std::process::Command::new("mkfifo")
                .arg(&object)
                .status()?
                .success()
        );
        let response = host
            .get(&route)
            .timeout(std::time::Duration::from_secs(5))
            .send()
            .await;
        // Release a blocked reader even if a regression makes the request time out.
        let _writer = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&object)?;
        assert_error(
            response?,
            StatusCode::INTERNAL_SERVER_ERROR,
            "storage-failed",
        )
        .await?;
        std::fs::remove_file(&object)?;
    }
    Ok(())
}

#[tokio::test]
async fn reopening_a_schema_four_upload_backfills_its_legacy_candidate_once() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let store = Store::open(root.path())?;
    let image = include_bytes!("../fixtures/blue.jpg");
    let mut entry: Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    entry.artwork = Some(image.to_vec());
    let mut file = store.stage().await?;
    file.write_all(b"abc")?;
    let saved = store.commit(entry, file, false).await?;
    drop(store);
    {
        // Main committed the upload and its membership before importing artwork on the next open.
        let db = rusqlite::Connection::open(root.path().join("node.sqlite"))?;
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?,
            4
        );
        db.execute_batch(
            "UPDATE organization SET payload = CAST(json_remove(payload, '$.artwork') AS BLOB);
             DELETE FROM artwork_assets;",
        )?;
    }
    let store = Store::open(root.path())?;
    let artwork = store.catalog().await?.organization.artwork.unwrap();
    assert_eq!(artwork.candidates.len(), 1);
    let candidate = &artwork.candidates[0];
    assert_eq!(candidate.track, saved.track.id);
    assert_eq!(candidate.source, "legacy");
    assert_eq!(candidate.context, saved.sha256);
    assert_eq!(candidate.asset, hex::encode(Sha256::digest(image)));
    assert_eq!(artwork.assets[&candidate.asset], image.as_slice());
    drop(store);
    assert_eq!(
        Store::open(root.path())?
            .catalog()
            .await?
            .organization
            .artwork,
        Some(artwork)
    );
    Ok(())
}

async fn reopen_catalog(host: &Host) -> anyhow::Result<syncstr_headless::model::Catalog> {
    // Use a consistent copy so the live HTTP listener can keep its store lock.
    let copy = tempfile::tempdir()?;
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    db.execute(
        "VACUUM INTO ?",
        [copy.path().join("node.sqlite").to_str().unwrap()],
    )?;
    Store::open(copy.path())?.catalog().await
}

#[tokio::test]
async fn cluster_save_serves_embedded_image_and_backfills_candidate_on_open() -> anyhow::Result<()>
{
    save_and_reopen_with_embedded_image(true).await
}

#[tokio::test]
async fn legacy_put_without_organization_backfills_candidate_on_open() -> anyhow::Result<()> {
    save_and_reopen_with_embedded_image(false).await
}

fn stored_organization(db: &rusqlite::Connection) -> rusqlite::Result<Vec<u8>> {
    db.query_row(
        "SELECT payload FROM organization WHERE singleton = 1",
        [],
        |row| row.get(0),
    )
}

async fn save_and_reopen_with_embedded_image(include_organization: bool) -> anyhow::Result<()> {
    let host = Host::start().await?;
    let store = &host.store;
    let image = include_bytes!("../fixtures/blue.jpg");
    let mut entry: Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    entry.artwork = None;
    let incoming = include_organization.then(|| {
        let mut organization = syncstr_headless::organization::Organization::default();
        organization.import(&entry);
        organization
    });
    let original_id = entry.track.id.clone();
    let mut file = store.stage().await?;
    file.write_all(b"abc")?;
    store
        .commit_organized(entry.clone(), file, true, incoming.clone())
        .await?;
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    let before = stored_organization(&db)?;
    entry.artwork = Some(image.to_vec());
    let mut file = store.stage().await?;
    file.write_all(b"abc")?;
    let saved = store.commit_organized(entry, file, true, incoming).await?;
    let canonical = if include_organization {
        original_id
    } else {
        saved.track.id
    };
    assert_eq!(stored_organization(&db)?, before);
    let id = hex::encode(Sha256::digest(image));
    let response = host
        .get(&format!("artwork/{id}"))
        .send()
        .await?
        .error_for_status()?;
    assert_eq!(response.bytes().await?.as_ref(), image);
    let artwork = reopen_catalog(&host).await?.organization.artwork.unwrap();
    assert_eq!(artwork.assets[&id], image.as_slice());
    let candidates = artwork.candidates;
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].source, "legacy");
    assert_eq!(candidates[0].track, canonical);
    assert_eq!(candidates[0].asset, id);
    Ok(())
}

#[tokio::test]
async fn invalid_embedded_image_is_saved_without_registering_artwork() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let saved = host.upload().await?;
    let bytes = saved.artwork.as_ref().unwrap();
    assert_eq!(bytes, &[1, 2, 3]);
    assert!(host.store.get(saved.track.id).await?.is_some());
    let id = hex::encode(Sha256::digest(bytes));
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM artwork_assets", [], |row| row
            .get::<_, i64>(0))?,
        0
    );
    assert_eq!(
        host.get(&format!("artwork/{id}")).send().await?.status(),
        StatusCode::NOT_FOUND
    );
    assert!(reopen_catalog(&host).await?.organization.artwork.is_none());
    Ok(())
}

#[tokio::test]
async fn updated_embedded_image_preserves_the_existing_display_candidate() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let mut entry: Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    let mut original = None;
    for image in [
        include_bytes!("../fixtures/red.jpg").as_slice(),
        include_bytes!("../fixtures/blue.jpg").as_slice(),
    ] {
        entry.artwork = Some(image.to_vec());
        entry = if original.is_none() {
            v4_upload(&host, &entry).await?
        } else {
            let mut file = host.store.stage().await?;
            file.write_all(b"abc")?;
            host.store.commit(entry, file, true).await?
        };
        let catalog: Value = host.get("catalog").send().await?.json().await?;
        let candidates = &catalog["organization"]["artwork"]["candidates"];
        assert_eq!(candidates.as_array().unwrap().len(), 1);
        assert_eq!(
            original.get_or_insert_with(|| candidates.clone()),
            candidates
        );
        let id = hex::encode(Sha256::digest(image));
        let assets = &catalog["organization"]["artwork"]["assets"];
        assert_eq!(assets.as_object().unwrap().len(), 1);
        assert_eq!(assets[candidates[0]["asset"].as_str().unwrap()], "");
        assert_eq!(
            host.get(&format!("artwork/{id}"))
                .send()
                .await?
                .error_for_status()?
                .bytes()
                .await?
                .as_ref(),
            image
        );
    }
    assert_eq!(
        reopen_catalog(&host)
            .await?
            .organization
            .artwork
            .unwrap()
            .assets
            .len(),
        1
    );
    Ok(())
}

#[tokio::test]
async fn disconnecting_mid_download_releases_a_production_listener_slot() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let data = vec![0x51; 16 * 1024 * 1024];
    let id = hex::encode(Sha256::digest(&data));
    let mut entry: Entry = serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    entry.sha256 = id.clone();
    entry.track.size = data.len() as u64;
    let mut file = host.store.stage().await?;
    file.write_all(&data)?;
    host.store.commit(entry, file, false).await?;
    let path = format!("audio/{id}");
    let mut active = Vec::new();
    for _ in 0..16 {
        let mut response = host.get(&path).send().await?;
        assert_eq!(response.status(), 200);
        assert!(response.chunk().await?.is_some());
        active.push(response);
    }
    assert_eq!(host.get(&path).send().await?.status(), 429);
    drop(active.pop());
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let response = host
                .get(&path)
                .header(header::RANGE, "bytes=0-0")
                .send()
                .await?;
            if response.status() != 429 {
                assert_eq!(response.status(), 206);
                assert_eq!(response.bytes().await?.as_ref(), &[0x51]);
                return Ok::<_, anyhow::Error>(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await??;
    Ok(())
}

#[tokio::test]
async fn errors_cover_unknown_routes_resources_and_methods() -> anyhow::Result<()> {
    let host = Host::start().await?;
    for path in ["unknown", "audio/unknown", "artwork/unknown"] {
        assert_error(
            host.get(path).send().await?,
            StatusCode::NOT_FOUND,
            "not-found",
        )
        .await?;
    }
    let post = host
        .client
        .post(format!("{}/catalog", host.url))
        .send()
        .await?;
    assert_eq!(post.headers()[header::ALLOW], "GET");
    assert_error(post, StatusCode::METHOD_NOT_ALLOWED, "method-not-allowed").await?;
    let head = host
        .client
        .head(format!("{}/audio/unknown", host.url))
        .send()
        .await?;
    assert_eq!(head.status(), 405);
    assert_eq!(head.headers()[header::ALLOW], "GET");
    assert!(head.bytes().await?.is_empty());
    Ok(())
}

#[cfg(feature = "p2p")]
#[tokio::test]
async fn catalog_projects_signed_playlists_and_reports_broken_records() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let key = host.root.path().join("key");
    syncstr_headless::peer::Identity::initialize(&key)?;
    let signer = syncstr_headless::peer::Identity::open(&key)?;
    let cluster = host.store.create_cluster(signer.id().to_string()).await?.id;
    let before: Value = host.get("catalog").send().await?.json().await?;
    let doc = json!({"id":"source:mix","sourceLibrary":"source","sourcePlaylist":"mix",
        "sourceFingerprint":"a".repeat(64),"name":"Fixture mix","kind":"snapshot","parent":null,"definition":{},"items":[]});
    host.store
        .import_playlists(&signer, cluster, vec![serde_json::from_value(doc.clone())?])
        .await?;
    let after: Value = host.get("catalog").send().await?.json().await?;
    assert_ne!(after["marker"], before["marker"]);
    assert_eq!(after["playlists"], json!([doc]));
    assert_eq!(after["conflictedPlaylists"], json!([]));
    let mut concurrent = host.store.playlist_records().await?.pop().unwrap();
    concurrent.payload = concurrent.payload.replace("Fixture mix", "Another mix");
    concurrent.signature = hex::encode(signer.sign(concurrent.payload.as_bytes()));
    concurrent.id = hex::encode(Sha256::digest(concurrent.payload.as_bytes()));
    host.store
        .receive_playlist(signer.id().to_string(), 1, concurrent)
        .await?;
    let conflict: Value = host.get("catalog").send().await?.json().await?;
    assert_ne!(after["marker"], conflict["marker"]);
    assert_eq!(conflict["conflictedPlaylists"], json!(["source:mix"]));
    assert_eq!(conflict["playlists"][0]["id"], doc["id"]);
    let db = rusqlite::Connection::open(host.root.path().join("node.sqlite"))?;
    db.execute("DELETE FROM cluster_trust", [])?;
    assert_error(
        host.get("catalog").send().await?,
        StatusCode::INTERNAL_SERVER_ERROR,
        "storage-failed",
    )
    .await
}

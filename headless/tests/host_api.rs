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
        let router = syncstr_headless::host_api::router(store.clone(), None);
        let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}/api/v1", socket.local_addr()?);
        let server = tokio::spawn(async move {
            axum::serve(socket, router).await.unwrap();
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
        json!({"library":host.store.catalog().await?.id,"name":"Syncstr","host":{"id":id,"address":null},
        "primary":id,"switchNumber":1,"startingMarker":null,"marker":info["marker"],"role":"primary","hosts":[{"id":id,"address":null,"role":"primary"}]})
    );
    let before: Value = host.get("catalog").send().await?.json().await?;
    assert_eq!(before["marker"], info["marker"]);
    let entry = host.upload().await?;
    let response = host.get("catalog").send().await?;
    let etag = response.headers()[header::ETAG].to_str()?.to_owned();
    let catalog: Value = response.json().await?;
    assert_ne!(catalog["marker"], before["marker"]);
    let revision = catalog["marker"]
        .as_str()
        .unwrap()
        .strip_prefix(&format!("{switch}."))
        .unwrap();
    assert_eq!(hex::decode(revision)?.len(), 32);
    assert_eq!(
        etag,
        format!(
            "\"{}.{}\"",
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
async fn artwork_requires_a_current_reference() -> anyhow::Result<()> {
    let host = Host::start().await?;
    let image = include_bytes!("../fixtures/red.jpg").as_slice();
    let id = hex::encode(Sha256::digest(image));
    let mut org: syncstr_headless::organization::Organization =
        serde_json::from_slice(include_bytes!("../fixtures/album-organization.json"))?;
    org.artwork
        .get_or_insert_with(Default::default)
        .assets
        .insert(id.clone(), image.to_vec());
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
    db.execute(
        "UPDATE organization SET payload = CAST(json_remove(payload, '$.artwork') AS BLOB)",
        [],
    )?;
    assert_error(
        host.get(&path).send().await?,
        StatusCode::NOT_FOUND,
        "not-found",
    )
    .await
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

#![cfg(feature = "p2p")]

async fn hello(
    endpoint: &iroh::Endpoint,
    address: iroh::EndpointAddr,
) -> (
    iroh::endpoint::Connection,
    iroh::endpoint::SendStream,
    iroh::endpoint::RecvStream,
    Vec<syncstr_headless::model::Entry>,
) {
    let connection = endpoint
        .connect(address, syncstr_headless::peer::ALPN)
        .await
        .unwrap();
    let (mut send, mut receive) = connection.open_bi().await.unwrap();
    syncstr_headless::peer::send(&mut send, &syncstr_headless::peer::Message::new("hello"))
        .await
        .unwrap();
    assert_eq!(
        syncstr_headless::peer::receive(&mut receive)
            .await
            .unwrap()
            .kind,
        "catalog"
    );
    let mut entries = Vec::new();
    loop {
        let message = syncstr_headless::peer::receive(&mut receive).await.unwrap();
        if message.kind == "ready" {
            break;
        }
        entries.push(message.entry.unwrap());
    }
    (connection, send, receive, entries)
}

#[tokio::test]
async fn paired_peers_upload_retry_restart_download_and_revoke() {
    use base64::Engine as _;
    use sha2::Digest as _;
    let root = tempfile::tempdir().unwrap();
    let server_state = root.path().join("server");
    let client_state = root.path().join("client");
    let data = root.path().join("data");
    syncstr_headless::peer::Identity::initialize(&server_state).unwrap();
    let client_id = syncstr_headless::peer::Identity::initialize(&client_state).unwrap();
    let server =
        std::sync::Arc::new(syncstr_headless::peer::Identity::open(&server_state).unwrap());
    server.pair(client_id).unwrap();
    let client = syncstr_headless::peer::Identity::open(&client_state).unwrap();
    let reservation = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let listen = reservation.local_addr().unwrap();
    assert!(
        server
            .endpoint(syncstr_headless::peer::Mode::Direct, Some(listen))
            .await
            .is_err()
    );
    drop(reservation);
    let (endpoint, lock) = server
        .endpoint(syncstr_headless::peer::Mode::Direct, Some(listen))
        .await
        .unwrap();
    let (client_endpoint, _client_lock) = client
        .endpoint(syncstr_headless::peer::Mode::Direct, None)
        .await
        .unwrap();
    let store = syncstr_headless::store::Store::open(&data).unwrap();
    let saved_address = endpoint.addr();
    assert!(saved_address.ip_addrs().any(|address| *address == listen));
    let task = tokio::spawn(syncstr_headless::peer::serve(
        server.clone(),
        endpoint.clone(),
        store.clone(),
    ));
    let address_file = root.path().join("address.json");
    syncstr_headless::peer::Address::write(&endpoint, &address_file).unwrap();
    syncstr_headless::peer::Address::write(&endpoint, &address_file).unwrap();
    assert!(syncstr_headless::peer::Address::read(&address_file, client_id).is_err());
    let (connection, mut send, mut receive, entries) =
        crate::hello(&client_endpoint, endpoint.addr()).await;
    assert!(entries.is_empty());
    let payload = vec![0xA7u8; 131079];
    let mut entry: syncstr_headless::model::Entry =
        serde_json::from_str(include_str!("../fixtures/local-entry.json")).unwrap();
    entry.track.size = payload.len() as u64;
    entry.sha256 = hex::encode(sha2::Sha256::digest(&payload));
    let mut saved_id = String::new();
    for _ in 0..2 {
        if !saved_id.is_empty() {
            entry.track.title = "Recovered ID3 title".into();
            entry.track.artist = Some("Tagged artist".into());
            entry.track.duration = Some(403.5);
        }
        let mut put = syncstr_headless::peer::Message::new("put");
        put.entry = Some(entry.clone());
        syncstr_headless::peer::send(&mut send, &put).await.unwrap();
        assert_eq!(
            syncstr_headless::peer::receive(&mut receive)
                .await
                .unwrap()
                .kind,
            "accept"
        );
        for bytes in payload.chunks(65536) {
            let mut chunk = syncstr_headless::peer::Message::new("data");
            chunk.bytes = Some(base64::engine::general_purpose::STANDARD.encode(bytes));
            syncstr_headless::peer::send(&mut send, &chunk)
                .await
                .unwrap();
        }
        syncstr_headless::peer::send(&mut send, &syncstr_headless::peer::Message::new("end"))
            .await
            .unwrap();
        let saved = syncstr_headless::peer::receive(&mut receive)
            .await
            .unwrap()
            .entry
            .unwrap();
        assert_eq!(saved.sha256, entry.sha256);
        assert_eq!(saved.track.title, entry.track.title);
        assert_eq!(saved.track.artist, entry.track.artist);
        assert_eq!(saved.track.duration, entry.track.duration);
        if !saved_id.is_empty() {
            assert_eq!(saved_id, saved.track.id)
        }
        saved_id = saved.track.id;
    }
    assert_eq!(store.catalog().await.unwrap().entries.len(), 1);
    connection.close(0u32.into(), b"restart");
    endpoint.close().await;
    task.await.unwrap();
    drop(endpoint);
    drop(lock);
    drop(store);
    let store = syncstr_headless::store::Store::open(&data).unwrap();
    let (endpoint, _lock) = server
        .endpoint(syncstr_headless::peer::Mode::Direct, Some(listen))
        .await
        .unwrap();
    let task = tokio::spawn(syncstr_headless::peer::serve(
        server.clone(),
        endpoint.clone(),
        store,
    ));
    let (_connection, mut send, mut receive, entries) =
        crate::hello(&client_endpoint, saved_address).await;
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].track.id, saved_id);
    let mut request = syncstr_headless::peer::Message::new("get");
    request.track = Some(saved_id);
    syncstr_headless::peer::send(&mut send, &request)
        .await
        .unwrap();
    let mut downloaded = Vec::new();
    loop {
        let message = syncstr_headless::peer::receive(&mut receive).await.unwrap();
        if message.kind == "end" {
            break;
        }
        downloaded.extend(
            base64::engine::general_purpose::STANDARD
                .decode(message.bytes.unwrap())
                .unwrap(),
        );
    }
    assert_eq!(downloaded, payload);
    server.unpair(client_id).unwrap();
    syncstr_headless::peer::send(&mut send, &request)
        .await
        .unwrap();
    assert!(syncstr_headless::peer::receive(&mut receive).await.is_err());
    endpoint.close().await;
    task.await.unwrap();
    client_endpoint.close().await;
}

#[tokio::test]
async fn corrupt_or_interrupted_audio_is_not_published() {
    use base64::Engine as _;
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join("server");
    let client_state = root.path().join("client");
    syncstr_headless::peer::Identity::initialize(&state).unwrap();
    let client_id = syncstr_headless::peer::Identity::initialize(&client_state).unwrap();
    let identity = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&state).unwrap());
    identity.pair(client_id).unwrap();
    let (server, _lock) = identity
        .endpoint(syncstr_headless::peer::Mode::Direct, None)
        .await
        .unwrap();
    let client = syncstr_headless::peer::Identity::open(&client_state).unwrap();
    let (endpoint, _client_lock) = client
        .endpoint(syncstr_headless::peer::Mode::Direct, None)
        .await
        .unwrap();
    let store = syncstr_headless::store::Store::open(&root.path().join("data")).unwrap();
    let task = tokio::spawn(syncstr_headless::peer::serve(
        identity,
        server.clone(),
        store.clone(),
    ));
    for interrupt in [false, true] {
        let (connection, mut send, mut receive, _) = crate::hello(&endpoint, server.addr()).await;
        let entry: syncstr_headless::model::Entry =
            serde_json::from_str(include_str!("../fixtures/local-entry.json")).unwrap();
        let mut put = syncstr_headless::peer::Message::new("put");
        put.entry = Some(entry);
        syncstr_headless::peer::send(&mut send, &put).await.unwrap();
        assert_eq!(
            syncstr_headless::peer::receive(&mut receive)
                .await
                .unwrap()
                .kind,
            "accept"
        );
        let mut chunk = syncstr_headless::peer::Message::new("data");
        chunk.bytes = Some(base64::engine::general_purpose::STANDARD.encode(b"xyz"));
        syncstr_headless::peer::send(&mut send, &chunk)
            .await
            .unwrap();
        if interrupt {
            send.finish().unwrap();
        } else {
            syncstr_headless::peer::send(&mut send, &syncstr_headless::peer::Message::new("end"))
                .await
                .unwrap();
        }
        assert!(syncstr_headless::peer::receive(&mut receive).await.is_err());
        assert!(store.catalog().await.unwrap().entries.is_empty());
        connection.close(0u32.into(), b"test complete");
    }
    server.close().await;
    task.await.unwrap();
    endpoint.close().await;
    assert_eq!(
        std::fs::read_dir(root.path().join("data/staging"))
            .unwrap()
            .count(),
        0
    );
}

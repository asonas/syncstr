pub const ALPN: &[u8] = b"syncstr/playlists/1";

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "operation", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Request {
    Catalog,
    Page {
        after: i64,
    },
    Import {
        cluster: String,
        documents: Vec<crate::playlists::Document>,
    },
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case")]
pub enum Response {
    Catalog {
        cluster: String,
        entries: Vec<crate::model::Entry>,
    },
    Page {
        next: i64,
        record: Option<crate::playlists::Signed>,
    },
    Imported {
        added: usize,
    },
    Rejected {
        reason: String,
    },
}

pub(crate) async fn serve_connection(
    identity: &crate::peer::Identity,
    store: &crate::store::Store,
    connection: iroh::endpoint::Connection,
) -> anyhow::Result<()> {
    let peer = connection.remote_id().to_string();
    let (mut output, mut input) = connection.accept_bi().await?;
    let hello: crate::cluster_sync::Hello =
        crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
    store
        .authenticate_cluster_peer(peer.clone(), hello.proof)
        .await?;
    crate::cluster_sync::authorized(store, &peer, false).await?;
    crate::cluster_sync::authorized(store, &identity.id().to_string(), true).await?;
    crate::cluster_net::send(&mut output, &crate::cluster_sync::hello(store).await?).await?;
    output.finish()?;
    while let Ok((mut output, mut input)) = connection.accept_bi().await {
        crate::cluster_sync::authorized(store, &peer, false).await?;
        crate::cluster_sync::authorized(store, &identity.id().to_string(), true).await?;
        let request: crate::playlist_sync::Request =
            crate::cluster_net::receive(&mut input, 32 * 1024 * 1024).await?;
        let response = match request {
            crate::playlist_sync::Request::Catalog => {
                let cluster = store.local_cluster_grant(identity).await?.cluster;
                let catalog = store.catalog().await?;
                let entries = catalog
                    .entries
                    .into_iter()
                    .map(|mut entry| {
                        entry.track.id = catalog.organization.canonical_track(&entry.track.id);
                        entry.artwork = None;
                        entry.imported_album = None;
                        entry
                    })
                    .collect();
                crate::playlist_sync::Response::Catalog { cluster, entries }
            }
            crate::playlist_sync::Request::Page { after } => {
                let (next, record) = store
                    .playlist_page(after)
                    .await?
                    .map_or((after, None), |(next, record)| (next, Some(record)));
                crate::playlist_sync::Response::Page { next, record }
            }
            crate::playlist_sync::Request::Import { cluster, documents } => {
                match store.import_playlists(identity, cluster, documents).await {
                    Ok(added) => crate::playlist_sync::Response::Imported { added },
                    Err(error) => crate::playlist_sync::Response::Rejected {
                        reason: error.to_string(),
                    },
                }
            }
        };
        crate::cluster_net::send(&mut output, &response).await?;
        output.finish()?;
        output.stopped().await?;
    }
    Ok(())
}

pub struct Session {
    connection: iroh::endpoint::Connection,
}

impl Drop for crate::playlist_sync::Session {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"done");
    }
}

impl crate::playlist_sync::Session {
    pub async fn connect(
        endpoint: &iroh::Endpoint,
        address: iroh::EndpointAddr,
        store: &crate::store::Store,
    ) -> anyhow::Result<Self> {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let connection = endpoint
                .connect(address, crate::playlist_sync::ALPN)
                .await?;
            let session = Self { connection };
            let (mut output, mut input) = session.connection.open_bi().await?;
            crate::cluster_net::send(&mut output, &crate::cluster_sync::hello(store).await?)
                .await?;
            output.finish()?;
            let hello: crate::cluster_sync::Hello =
                crate::cluster_net::receive(&mut input, 4 * 1024 * 1024).await?;
            store
                .authenticate_cluster_peer(session.connection.remote_id().to_string(), hello.proof)
                .await?;
            crate::cluster_sync::authorized(
                store,
                &session.connection.remote_id().to_string(),
                true,
            )
            .await?;
            Ok(session)
        })
        .await?
    }

    pub async fn request(
        &self,
        request: &crate::playlist_sync::Request,
    ) -> anyhow::Result<crate::playlist_sync::Response> {
        tokio::time::timeout(std::time::Duration::from_secs(120), async {
            let (mut output, mut input) = self.connection.open_bi().await?;
            crate::cluster_net::send(&mut output, request).await?;
            output.finish()?;
            crate::cluster_net::receive(&mut input, crate::cluster_net::MAX_FRAME).await
        })
        .await?
    }

    pub async fn reconcile(&self, store: &crate::store::Store) -> anyhow::Result<()> {
        let peer = self.connection.remote_id().to_string();
        let mut after = store.playlist_cursor(peer.clone()).await?;
        for _ in 0..10000 {
            let crate::playlist_sync::Response::Page { next, record } = self
                .request(&crate::playlist_sync::Request::Page { after })
                .await?
            else {
                anyhow::bail!("invalid playlist page");
            };
            let Some(record) = record else {
                return Ok(());
            };
            anyhow::ensure!(next > after, "non-progressing playlist cursor");
            store.receive_playlist(peer.clone(), next, record).await?;
            after = next;
        }
        anyhow::bail!("playlist history exceeds refresh limit")
    }
}

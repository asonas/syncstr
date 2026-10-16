#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct PendingMetadata {
    id: String,
    entry: crate::model::Entry,
    organization: crate::organization::Organization,
    parents: Vec<String>,
}

pub struct PlaybackClient {
    identity: crate::peer::Identity,
    store: crate::store::Store,
}

#[derive(serde::Serialize)]
pub struct Library {
    #[serde(flatten)]
    pub catalog: crate::model::Catalog,
    pub conflicts: Vec<String>,
}

impl crate::cluster_client::PlaybackClient {
    pub fn open(root: &std::path::Path, secret: [u8; 32]) -> anyhow::Result<Self> {
        Ok(Self {
            identity: crate::peer::Identity::from_secret(&root.join("identity"), secret)?,
            store: crate::store::Store::open(root)?,
        })
    }

    pub fn id(&self) -> iroh::EndpointId {
        self.identity.id()
    }

    pub async fn hosts(&self) -> anyhow::Result<Vec<String>> {
        self.validate_identity().await?;
        if self.store.cluster_inventory().await?.cluster.is_none() {
            return Ok(Vec::new());
        }
        let proof = self.store.cluster_membership_proof().await?;
        Ok(proof
            .grants
            .iter()
            .filter(|grant| grant.host && proof.verify(&grant.id).is_ok())
            .map(|grant| grant.member.clone())
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect())
    }

    pub async fn enroll(&self, json: &str, socket: std::net::SocketAddr) -> anyhow::Result<()> {
        self.validate_identity().await?;
        anyhow::ensure!(json.len() <= 16 * 1024, "invitation too large");
        let invitation: crate::enrollment::Invitation = serde_json::from_str(json)?;
        let address = iroh::EndpointAddr::new(invitation.host.parse()?).with_ip_addr(socket);
        let (endpoint, _lock) = self
            .identity
            .cluster_endpoint(&["0.0.0.0:0".parse()?])
            .await?;
        let result = crate::cluster_net::enroll(
            &self.identity,
            &endpoint,
            address,
            &invitation,
            &self.store,
        )
        .await;
        endpoint.close().await;
        result
    }

    pub async fn refresh(
        &self,
        address: iroh::EndpointAddr,
    ) -> anyhow::Result<crate::cluster_client::Library> {
        self.validate_identity().await?;
        let (endpoint, _lock) = self
            .identity
            .cluster_endpoint(&["0.0.0.0:0".parse()?])
            .await?;
        let result = async {
            let session =
                crate::cluster_sync::Session::connect(&endpoint, address, &self.store).await?;
            session.reconcile(&self.store).await?;
            for edit in self.pending_metadata().await? {
                session.edit_metadata(edit.entry.clone(), edit.organization.clone(), edit.parents.clone()).await?;
                self.store.run(move |connection, _| {
                    connection.execute("DELETE FROM client_metadata_queue WHERE object = ? AND id = ?", rusqlite::params![edit.entry.sha256, edit.id])?;
                    Ok(())
                }).await?;
            }
            session.reconcile(&self.store).await?;
            self.catalog().await
        }
        .await;
        endpoint.close().await;
        result
    }

    pub async fn catalog(&self) -> anyhow::Result<crate::cluster_client::Library> {
        self.validate_identity().await?;
        let mut conflicts = Vec::new();
        for state in self.store.cluster_object_states().await? {
            if state.conflicted() {
                conflicts.push(state.object);
                continue;
            }
            if let Err(error) = self
                .store
                .project_cluster_metadata(state.object.clone())
                .await
            {
                if error.is::<crate::cluster_replica::AlbumMetadataConflict>() {
                    conflicts.push(state.object);
                } else {
                    return Err(error);
                }
            }
        }
        let mut catalog = self.store.catalog().await?;
        for edit in self.pending_metadata().await? { catalog.organization.merge(&edit.organization)?; }
        Ok(crate::cluster_client::Library {
            catalog,
            conflicts,
        })
    }

    async fn pending_metadata(&self) -> anyhow::Result<Vec<crate::cluster_client::PendingMetadata>> {
        self.store.run(|connection, _| {
            connection.execute_batch("CREATE TABLE IF NOT EXISTS client_metadata_queue (object TEXT PRIMARY KEY, id TEXT NOT NULL, payload BLOB NOT NULL)")?;
            let mut statement = connection.prepare("SELECT payload FROM client_metadata_queue ORDER BY object")?;
            statement.query_map([], |row| row.get::<_, Vec<u8>>(0))?
                .map(|bytes| Ok(serde_json::from_slice(&bytes?)?)).collect()
        }).await
    }

    pub async fn set_album_hidden(&self, album: &str, hidden: bool) -> anyhow::Result<crate::cluster_client::Library> {
        let mut library = self.catalog().await?;
        library.catalog.organization.set_hidden(album, hidden)?;
        let pending = self.pending_metadata().await?;
        let states = self.store.cluster_object_states().await?;
        let mut edits = Vec::new();
        for entry in &library.catalog.entries {
            let organization = library.catalog.organization.for_object(&entry.sha256)?;
            if !organization.choices.iter().any(|c| c.kind == "visibility" && organization.canonical(&c.subject).ok() == library.catalog.organization.canonical(album).ok()) { continue; }
            let state = states.iter().find(|state| state.object == entry.sha256).ok_or_else(|| anyhow::anyhow!("missing object history"))?;
            anyhow::ensure!(!state.conflicted(), "resolve this album's conflicts first");
            let parents = pending.iter().find(|edit| edit.entry.sha256 == entry.sha256).map(|edit| edit.parents.clone())
                .unwrap_or_else(|| state.heads.iter().map(|head| head.id.clone()).collect());
            edits.push(crate::cluster_client::PendingMetadata { id: uuid::Uuid::new_v4().to_string(), entry: entry.clone(), organization, parents });
        }
        anyhow::ensure!(!edits.is_empty(), "album has no editable tracks");
        self.store.run(move |connection, _| {
            let transaction = connection.transaction()?;
            for edit in edits { transaction.execute("INSERT OR REPLACE INTO client_metadata_queue VALUES (?, ?, ?)",
                rusqlite::params![edit.entry.sha256, edit.id, serde_json::to_vec(&edit)?])?; }
            transaction.commit()?;
            Ok(())
        }).await?;
        self.catalog().await
    }

    pub async fn download(
        &self,
        address: iroh::EndpointAddr,
        object: &str,
    ) -> anyhow::Result<std::path::PathBuf> {
        self.validate_identity().await?;
        let (endpoint, _lock) = self
            .identity
            .cluster_endpoint(&["0.0.0.0:0".parse()?])
            .await?;
        let result = async {
            let session =
                crate::cluster_sync::Session::connect(&endpoint, address, &self.store).await?;
            session
                .download(&self.identity, &self.store, object)
                .await?;
            self.local_file(object)
                .await?
                .ok_or_else(|| anyhow::anyhow!("saved audio unavailable"))
        }
        .await;
        endpoint.close().await;
        result
    }

    pub async fn download_from(
        &self,
        addresses: Vec<iroh::EndpointAddr>,
        object: &str,
    ) -> anyhow::Result<std::path::PathBuf> {
        anyhow::ensure!(
            !addresses.is_empty() && addresses.len() <= 256,
            "no available library host"
        );
        let mut failure = None;
        for address in addresses {
            match self.download(address, object).await {
                Ok(path) => return Ok(path),
                Err(error) => failure = Some(error),
            }
        }
        Err(failure.expect("nonempty sources"))
    }

    pub async fn local_file(&self, object: &str) -> anyhow::Result<Option<std::path::PathBuf>> {
        self.validate_identity().await?;
        Ok(self
            .store
            .cluster_local_file(object)
            .await?
            .map(|entry| self.store.path(&entry)))
    }

    async fn validate_identity(&self) -> anyhow::Result<()> {
        if let Some(cluster) = self.store.cluster_inventory().await?.cluster {
            anyhow::ensure!(
                cluster.member_id == self.id().to_string(),
                "cluster belongs to another identity"
            );
        }
        Ok(())
    }
}

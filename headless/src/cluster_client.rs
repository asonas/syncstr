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
        Ok(crate::cluster_client::Library {
            catalog: self.store.catalog().await?,
            conflicts,
        })
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

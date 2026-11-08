//! Read-only v5 client catalog. Open an enrolled, disposable profile before supplying a key.

mod projection;
pub use projection::{
    Album, ArtworkCandidate, CatalogView, ExactTrack, Occurrence, OrganizationChoice, Playlist,
    Track,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    ProfileBusy,
    Storage,
    InvalidCatalog,
    IdentityMismatch,
    MembershipMismatch,
    BaselineMismatch,
    ProtocolMismatch,
    Transport,
    Cancelled,
    Closed,
}

impl std::fmt::Display for crate::catalog_client::Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "catalog client: {self:?}")
    }
}
impl std::error::Error for crate::catalog_client::Error {}

/// Domain address supplied by discovery; no transport implementation types cross this boundary.
pub struct Host {
    pub member: String,
    pub socket: std::net::SocketAddr,
}

#[derive(Clone, Default)]
pub struct Operation {
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl crate::catalog_client::Operation {
    pub fn cancel(&self) {
        self.cancelled
            .store(true, std::sync::atomic::Ordering::Release);
    }

    async fn cancelled(&self) {
        while !self.cancelled.load(std::sync::atomic::Ordering::Acquire) {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Retained {
    proof: crate::enrollment::Proof,
    local_grant: String,
    snapshot: Option<crate::shared_audio_net::Snapshot>,
    incomplete: Vec<String>,
}

/// Calls are serialized by exclusive ownership. Run open and refresh on the application worker.
pub struct Client {
    root: std::path::PathBuf,
    connection: Option<rusqlite::Connection>,
    lock: Option<crate::node_lock::NodeLock>,
    retained: crate::catalog_client::Retained,
}

impl crate::catalog_client::Client {
    /// Restores a verified cache without reading or creating a private identity key.
    pub fn open(root: &std::path::Path) -> Result<Self, crate::catalog_client::Error> {
        use rusqlite::OptionalExtension as _;
        let lock = crate::platform_fs::private_file_options()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(root.join("node.lock"))
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let lock = crate::node_lock::NodeLock::acquire(lock)
            .map_err(|_| crate::catalog_client::Error::ProfileBusy)?;
        let registration = rusqlite::Connection::open_with_flags(
            root.join("node.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .map_err(|_| crate::catalog_client::Error::Storage)?;
        let proof = crate::enrollment::read_proof(&registration)
            .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
        let local_grant: String = registration
            .query_row(
                "SELECT local_grant FROM cluster_trust WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let connection = rusqlite::Connection::open(root.join("catalog-client.sqlite"))
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        connection.execute_batch("CREATE TABLE IF NOT EXISTS verified_catalog (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload BLOB NOT NULL);").map_err(|_| crate::catalog_client::Error::Storage)?;
        let bytes: Option<Vec<u8>> = connection
            .query_row(
                "SELECT payload FROM verified_catalog WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let mut retained: crate::catalog_client::Retained = match bytes {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| crate::catalog_client::Error::InvalidCatalog)?,
            None => crate::catalog_client::Retained {
                proof: proof.clone(),
                local_grant: local_grant.clone(),
                snapshot: None,
                incomplete: Vec::new(),
            },
        };
        if retained.proof.root != proof.root || retained.local_grant != local_grant {
            return Err(crate::catalog_client::Error::MembershipMismatch);
        }
        for grant in proof.grants {
            if let Some(existing) = retained.proof.grants.iter().find(|g| g.id == grant.id) {
                if existing != &grant {
                    return Err(crate::catalog_client::Error::MembershipMismatch);
                }
            } else {
                retained.proof.grants.push(grant);
            }
        }
        for revocation in proof.revocations {
            if let Some(existing) = retained
                .proof
                .revocations
                .iter()
                .find(|r| r.id == revocation.id)
            {
                if existing != &revocation {
                    return Err(crate::catalog_client::Error::MembershipMismatch);
                }
            } else {
                retained.proof.revocations.push(revocation);
            }
        }
        // The cached proof may contain newer revocations than the enrollment database.
        retained
            .proof
            .verify(&local_grant)
            .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
        let client = Self {
            root: root.to_owned(),
            connection: Some(connection),
            lock: Some(lock),
            retained,
        };
        client.catalog()?;
        Ok(client)
    }

    pub fn catalog(
        &self,
    ) -> Result<crate::catalog_client::CatalogView, crate::catalog_client::Error> {
        self.ensure_open()?;
        let mut view = match &self.retained.snapshot {
            Some(snapshot) => {
                crate::catalog_client::projection::project(snapshot, &self.retained.proof)?
            }
            None => crate::catalog_client::CatalogView::default(),
        };
        view.incomplete_records
            .clone_from(&self.retained.incomplete);
        Ok(view)
    }

    /// Fetches only the authenticated v5 snapshot, never audio or legacy writes.
    pub async fn refresh(
        &mut self,
        host: &crate::catalog_client::Host,
        secret: [u8; 32],
        operation: &crate::catalog_client::Operation,
    ) -> Result<crate::catalog_client::CatalogView, crate::catalog_client::Error> {
        self.ensure_open()?;
        let grant = self
            .retained
            .proof
            .verify(&self.retained.local_grant)
            .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
        if iroh::SecretKey::from_bytes(&secret).public().to_string() != grant.member {
            return Err(crate::catalog_client::Error::IdentityMismatch);
        }
        let member: iroh::EndpointId = host
            .member
            .parse()
            .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
        let identity = crate::peer::Identity::from_secret(&self.root.join("identity"), secret)
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let (endpoint, _identity_lock) = tokio::select! {
            biased;
            _ = operation.cancelled() => return Err(crate::catalog_client::Error::Cancelled),
            result = identity.endpoint(crate::peer::Mode::Direct, &[]) => result.map_err(|_| crate::catalog_client::Error::Transport)?,
        };
        let result = tokio::select! {
            biased;
            _ = operation.cancelled() => Err(crate::catalog_client::Error::Cancelled),
            result = async {
                let session = crate::shared_audio_net::Session::connect(&endpoint,
                    iroh::EndpointAddr::new(member).with_ip_addr(host.socket), self.retained.proof.clone()).await
                    .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
                let snapshot = session.request(crate::shared_audio_net::Request::Catalog).await
                    .map_err(|_| crate::catalog_client::Error::Transport)?;
                Ok((snapshot, session.proof))
            } => result,
        };
        endpoint.close().await;
        let (snapshot, proof) = result?;
        if operation
            .cancelled
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(crate::catalog_client::Error::Cancelled);
        }
        self.accept(snapshot, proof)?;
        self.catalog()
    }

    /// Exclusive ownership ensures an in-flight refresh finishes or is cancelled before shutdown.
    pub fn shutdown(&mut self) {
        self.connection.take();
        self.lock.take();
    }

    fn ensure_open(&self) -> Result<(), crate::catalog_client::Error> {
        self.connection
            .as_ref()
            .map(|_| ())
            .ok_or(crate::catalog_client::Error::Closed)
    }

    fn accept(
        &mut self,
        snapshot: crate::shared_audio_net::Snapshot,
        proof: crate::enrollment::Proof,
    ) -> Result<(), crate::catalog_client::Error> {
        let invalid = crate::catalog_client::Error::InvalidCatalog;
        let catalog = &snapshot.catalog;
        if catalog.version != 1 {
            return Err(crate::catalog_client::Error::ProtocolMismatch);
        }
        let grant = proof
            .verify(&self.retained.local_grant)
            .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
        if proof.root != self.retained.proof.root || catalog.cluster != grant.cluster {
            return Err(crate::catalog_client::Error::MembershipMismatch);
        }
        if !crate::catalog_client::projection::hash(&catalog.baseline) {
            return Err(invalid);
        }
        if let Some(previous) = &self.retained.snapshot {
            if (catalog.baseline.as_str(), catalog.library.as_str())
                != (
                    previous.catalog.baseline.as_str(),
                    previous.catalog.library.as_str(),
                )
            {
                return Err(crate::catalog_client::Error::BaselineMismatch);
            }
            if catalog.incomplete.is_empty()
                && (!previous
                    .catalog
                    .tracks
                    .keys()
                    .all(|id| catalog.tracks.contains_key(id))
                    || !previous
                        .catalog
                        .addresses
                        .iter()
                        .all(|(id, target)| catalog.addresses.get(id) == Some(target))
                    || !previous.catalog.pins.iter().all(|(id, pins)| {
                        catalog.pins.get(id).is_some_and(|new| pins.is_subset(new))
                    }))
            {
                return Err(invalid);
            }
        }
        if catalog.incomplete.len() > 100_000
            || !catalog
                .incomplete
                .iter()
                .all(|id| crate::catalog_client::projection::hash(id))
        {
            return Err(invalid);
        }
        if catalog.incomplete.is_empty() {
            crate::catalog_client::projection::project(&snapshot, &proof)?;
        }
        let retained = crate::catalog_client::Retained {
            proof,
            local_grant: self.retained.local_grant.clone(),
            incomplete: catalog.incomplete.clone(),
            snapshot: if catalog.incomplete.is_empty() {
                Some(snapshot)
            } else {
                self.retained.snapshot.clone()
            },
        };
        let bytes = serde_json::to_vec(&retained).map_err(|_| invalid)?;
        self.connection
            .as_mut()
            .ok_or(crate::catalog_client::Error::Closed)?
            .execute(
                "INSERT OR REPLACE INTO verified_catalog VALUES (1, ?)",
                [bytes],
            )
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        self.retained = retained;
        Ok(())
    }
}

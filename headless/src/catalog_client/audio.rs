#[derive(Clone, Copy, Debug)]
pub struct TransferPolicy {
    pub online: bool,
    pub cellular: bool,
    pub allow_cellular_saves: bool,
    pub execution_allowed: bool,
    pub cache_limit_bytes: u64,
}

impl Default for crate::catalog_client::TransferPolicy {
    fn default() -> Self {
        Self {
            online: false,
            cellular: false,
            allow_cellular_saves: false,
            execution_allowed: true,
            cache_limit_bytes: 10 * 1024 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Default)]
pub struct Policy(std::sync::Arc<std::sync::RwLock<crate::catalog_client::TransferPolicy>>);

impl crate::catalog_client::Policy {
    pub fn update(&self, policy: crate::catalog_client::TransferPolicy) {
        if let Ok(mut value) = self.0.write() {
            *value = policy;
        }
    }
    pub fn current(&self) -> crate::catalog_client::TransferPolicy {
        self.0.read().map(|value| *value).unwrap_or_default()
    }
    fn permits(&self, saving: bool) -> bool {
        let policy = self.current();
        policy.online
            && policy.execution_allowed
            && (!saving || !policy.cellular || policy.allow_cellular_saves)
    }
    async fn restricted(&self, saving: bool) {
        while self.permits(saving) {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }
}

/// Retain this handle until the native player has closed its file.
#[derive(Clone)]
pub struct VerifiedAudio(pub(super) std::sync::Arc<Lease>);

pub(super) struct Lease {
    pub pin: crate::catalog_client::ExactTrack,
    pub path: std::path::PathBuf,
    pub bytes: u64,
    pub storage: std::sync::Arc<crate::catalog_client::audio_storage::Storage>,
    pub _lock: std::sync::Arc<crate::node_lock::NodeLock>,
}

struct Downloaded {
    path: tempfile::TempPath,
    _guard: crate::catalog_client::audio_storage::Transfer,
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.storage.release(&self.pin.sha256);
    }
}
impl crate::catalog_client::VerifiedAudio {
    pub fn pin(&self) -> &crate::catalog_client::ExactTrack {
        &self.0.pin
    }
    pub fn path(&self) -> &std::path::Path {
        &self.0.path
    }
    pub fn byte_len(&self) -> u64 {
        self.0.bytes
    }
}

impl crate::catalog_client::Client {
    pub fn policy(&self) -> crate::catalog_client::Policy {
        self.audio.policy.clone()
    }

    pub fn trim_cache(&mut self) -> Result<(), crate::catalog_client::Error> {
        self.ensure_open()?;
        self.audio.trim()
    }

    /// The optional hash selects exact historical bytes instead of the preferred pin.
    pub async fn prepare_playback(
        &mut self,
        track: &str,
        hash: Option<&str>,
        hosts: &[crate::catalog_client::Host],
        secret: Option<[u8; 32]>,
        operation: &crate::catalog_client::Operation,
    ) -> Result<crate::catalog_client::VerifiedAudio, crate::catalog_client::Error> {
        let pin = self.audio_pin(track, hash)?;
        self.acquire(&pin, hosts, secret, operation, false).await
    }

    pub(super) fn audio_pin(
        &self,
        track: &str,
        hash: Option<&str>,
    ) -> Result<crate::catalog_client::ExactTrack, crate::catalog_client::Error> {
        let view = self.catalog()?;
        let canonical = view.aliases.get(track).map_or(track, String::as_str);
        let record = view
            .tracks
            .get(canonical)
            .ok_or(crate::catalog_client::Error::InvalidPin)?;
        let hash = hash
            .map(str::to_owned)
            .or_else(|| record.preferred.as_ref().map(|pin| pin.sha256.clone()))
            .ok_or(crate::catalog_client::Error::InvalidPin)?;
        let pin = crate::catalog_client::ExactTrack {
            track_id: canonical.into(),
            sha256: hash,
        };
        view.exact_track(&pin)
            .ok_or(crate::catalog_client::Error::InvalidPin)?;
        Ok(pin)
    }

    pub(super) async fn acquire(
        &mut self,
        pin: &crate::catalog_client::ExactTrack,
        hosts: &[crate::catalog_client::Host],
        secret: Option<[u8; 32]>,
        operation: &crate::catalog_client::Operation,
        saving: bool,
    ) -> Result<crate::catalog_client::VerifiedAudio, crate::catalog_client::Error> {
        self.ensure_open()?;
        if operation
            .cancelled
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(crate::catalog_client::Error::Cancelled);
        }
        let bytes = self
            .catalog()?
            .audio_bytes(pin)
            .ok_or(crate::catalog_client::Error::InvalidPin)?;
        let lock = self
            .lock
            .as_ref()
            .ok_or(crate::catalog_client::Error::Closed)?
            .clone();
        match self.audio.lease(pin.clone(), bytes, lock.clone()) {
            Ok(asset) => {
                if operation
                    .cancelled
                    .load(std::sync::atomic::Ordering::Acquire)
                {
                    return Err(crate::catalog_client::Error::Cancelled);
                }
                self.connection
                    .as_ref()
                    .ok_or(crate::catalog_client::Error::Closed)?
                    .execute(
                        "UPDATE client_audio SET used=? WHERE hash=?",
                        rusqlite::params![crate::model::addition_time(), pin.sha256],
                    )
                    .map_err(|_| crate::catalog_client::Error::Storage)?;
                return Ok(asset);
            }
            Err(
                crate::catalog_client::Error::UnavailableSource
                | crate::catalog_client::Error::Integrity,
            ) => {}
            Err(error) => return Err(error),
        }
        if !self.audio.policy.permits(saving) {
            return Err(crate::catalog_client::Error::PolicyRestricted);
        }
        let secret = secret.ok_or(crate::catalog_client::Error::AuthenticationRequired)?;
        let grant = self
            .retained
            .proof
            .verify(&self.retained.local_grant)
            .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
        if iroh::SecretKey::from_bytes(&secret).public().to_string() != grant.member {
            return Err(crate::catalog_client::Error::IdentityMismatch);
        }
        if hosts.len() > 256 {
            return Err(crate::catalog_client::Error::UnavailableSource);
        }
        let authorized: Vec<_> = hosts
            .iter()
            .filter(|host| {
                crate::shared_audio_net::authorize(&self.retained.proof, &host.member, true).is_ok()
            })
            .collect();
        if authorized.is_empty() {
            return Err(crate::catalog_client::Error::UnavailableSource);
        }
        let identity = crate::peer::Identity::from_secret(&self.root.join("identity"), secret)
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let policy = self.audio.policy.clone();
        let (endpoint, _identity_lock) = tokio::select! {
            biased;
            _ = operation.cancelled() => return Err(crate::catalog_client::Error::Cancelled),
            _ = policy.restricted(saving) => return Err(crate::catalog_client::Error::PolicyRestricted),
            result = identity.endpoint(crate::peer::Mode::Direct, &[]) => result.map_err(|_| crate::catalog_client::Error::Transport)?,
        };
        let result = self
            .fetch_audio(&endpoint, pin, bytes, &authorized, operation, saving)
            .await;
        endpoint.close().await;
        let staged = result?;
        if operation
            .cancelled
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(crate::catalog_client::Error::Cancelled);
        }
        if !policy.permits(saving) {
            return Err(crate::catalog_client::Error::PolicyRestricted);
        }
        let asset = self.audio.publish(
            self.connection
                .as_ref()
                .ok_or(crate::catalog_client::Error::Closed)?,
            staged.path,
            pin.clone(),
            bytes,
            lock,
        )?;
        if operation
            .cancelled
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(crate::catalog_client::Error::Cancelled);
        }
        if !policy.permits(saving) {
            return Err(crate::catalog_client::Error::PolicyRestricted);
        }
        Ok(asset)
    }

    async fn fetch_audio(
        &mut self,
        endpoint: &iroh::Endpoint,
        pin: &crate::catalog_client::ExactTrack,
        bytes: u64,
        hosts: &[&crate::catalog_client::Host],
        operation: &crate::catalog_client::Operation,
        saving: bool,
    ) -> Result<Downloaded, crate::catalog_client::Error> {
        let policy = self.audio.policy.clone();
        for host in hosts {
            let member = host
                .member
                .parse()
                .map_err(|_| crate::catalog_client::Error::MembershipMismatch)?;
            let session = tokio::select! {
                biased;
                _ = operation.cancelled() => return Err(crate::catalog_client::Error::Cancelled),
                _ = policy.restricted(saving) => return Err(crate::catalog_client::Error::PolicyRestricted),
                result = crate::shared_audio_net::Session::connect(endpoint, iroh::EndpointAddr::new(member).with_ip_addr(host.socket), self.retained.proof.clone()) => match result { Ok(session) => session, Err(error) => {
                    if error.chain().any(|error| error.is::<iroh::endpoint::ConnectError>() || error.is::<tokio::time::error::Elapsed>()) { continue; }
                    return Err(crate::catalog_client::Error::MembershipMismatch);
                } },
            };
            let snapshot = tokio::select! {
                biased;
                _ = operation.cancelled() => return Err(crate::catalog_client::Error::Cancelled),
                _ = policy.restricted(saving) => return Err(crate::catalog_client::Error::PolicyRestricted),
                result = session.request(crate::shared_audio_net::Request::Catalog) => match result { Ok(snapshot) => snapshot, Err(_) => continue },
            };
            self.accept(snapshot, session.proof.clone())?;
            if self.catalog()?.audio_bytes(pin) != Some(bytes) {
                return Err(crate::catalog_client::Error::InvalidPin);
            }
            let staged = tempfile::Builder::new()
                .prefix(".acquiring-")
                .tempfile_in(&self.audio.root)
                .map_err(crate::catalog_client::audio_storage::io_error)?
                .into_temp_path();
            let guard = self.audio.begin_transfer(
                operation.clone(),
                self.lock
                    .as_ref()
                    .ok_or(crate::catalog_client::Error::Closed)?
                    .clone(),
            )?;
            let (endpoint, pin, operation, policy) = (
                endpoint.clone(),
                pin.clone(),
                operation.clone(),
                policy.clone(),
            );
            let downloading = tokio::spawn(async move {
                {
                    let download =
                        session.download_exact(&pin.track_id, &pin.sha256, &staged, bytes);
                    tokio::pin!(download);
                    let result = tokio::select! {
                    biased;
                    _ = operation.cancelled() => Err(crate::catalog_client::Error::Cancelled),
                    _ = policy.restricted(saving) => Err(crate::catalog_client::Error::PolicyRestricted),
                    result = &mut download => result.map_err(download_error),
                    };
                    if matches!(
                        result,
                        Err(crate::catalog_client::Error::Cancelled
                            | crate::catalog_client::Error::PolicyRestricted)
                    ) {
                        endpoint.close().await;
                        let _ = download.await;
                    }
                    result?;
                }
                Ok::<_, crate::catalog_client::Error>(Downloaded {
                    path: staged,
                    _guard: guard,
                })
            });
            let result = downloading
                .await
                .map_err(|_| crate::catalog_client::Error::Storage)?;
            match result {
                Ok(staged) => {
                    return Ok(staged);
                }
                Err(
                    error @ (crate::catalog_client::Error::Cancelled
                    | crate::catalog_client::Error::PolicyRestricted),
                ) => {
                    return Err(error);
                }
                Err(
                    error @ (crate::catalog_client::Error::Integrity
                    | crate::catalog_client::Error::InsufficientStorage
                    | crate::catalog_client::Error::Storage),
                ) => return Err(error),
                Err(_) => {}
            }
        }
        Err(crate::catalog_client::Error::UnavailableSource)
    }
}

fn download_error(error: anyhow::Error) -> crate::catalog_client::Error {
    if error
        .downcast_ref::<crate::shared_audio_net::AudioIntegrityFailure>()
        .is_some()
    {
        return crate::catalog_client::Error::Integrity;
    }
    if let Some(error) = error.downcast_ref::<std::io::Error>() {
        return crate::catalog_client::audio_storage::io_error(std::io::Error::from(error.kind()));
    }
    crate::catalog_client::Error::Transport
}

pub struct Client {
    http: reqwest::Client,
    endpoint: reqwest::Url,
    token: String,
}

impl crate::client::Client {
    pub fn new(
        endpoint: &str,
        certificate: &std::path::Path,
        token_file: &std::path::Path,
    ) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let endpoint = reqwest::Url::parse(endpoint)?;
        anyhow::ensure!(
            endpoint.scheme() == "https"
                && endpoint.host_str().is_some()
                && endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.query().is_none()
                && endpoint.fragment().is_none()
                && endpoint.path() == "/",
            "node URL must be an HTTPS origin"
        );
        let certificate = reqwest::Certificate::from_pem(&std::fs::read(certificate)?)?;
        let http = reqwest::Client::builder()
            .https_only(true)
            .tls_certs_only([certificate])
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(std::time::Duration::from_secs(2 * 60 * 60))
            .build()?;
        Ok(Self {
            http,
            endpoint,
            token: crate::identity::token(token_file)?,
        })
    }

    fn request(
        &self,
        method: reqwest::Method,
        path: &str,
    ) -> anyhow::Result<reqwest::RequestBuilder> {
        Ok(self
            .http
            .request(method, self.endpoint.join(path)?)
            .bearer_auth(&self.token))
    }

    async fn response(request: reqwest::RequestBuilder) -> anyhow::Result<reqwest::Response> {
        let response = request.send().await?;
        anyhow::ensure!(
            response.status() == reqwest::StatusCode::OK,
            "node returned HTTP {}",
            response.status().as_u16()
        );
        Ok(response)
    }

    async fn json<T: serde::de::DeserializeOwned>(
        response: reqwest::Response,
        limit: usize,
    ) -> anyhow::Result<T> {
        use futures_util::StreamExt as _;
        let mut body = response.bytes_stream();
        let mut bytes = Vec::new();
        while let Some(chunk) = body.next().await {
            let chunk = chunk?;
            anyhow::ensure!(
                bytes.len() + chunk.len() <= limit,
                "node response exceeds metadata limit"
            );
            bytes.extend_from_slice(&chunk);
        }
        Ok(serde_json::from_slice(&bytes)?)
    }

    pub async fn catalog(&self) -> anyhow::Result<crate::model::Catalog> {
        let response =
            crate::client::Client::response(self.request(reqwest::Method::GET, "v1/catalog")?)
                .await?;
        crate::client::Client::json(response, 256 * 1024 * 1024).await
    }

    pub async fn upload(
        &self,
        path: &std::path::Path,
        title: Option<String>,
        artist: Option<String>,
        album: Option<String>,
    ) -> anyhow::Result<crate::model::Entry> {
        use sha2::Digest as _;
        use tokio::io::AsyncReadExt as _;
        use tokio::io::AsyncSeekExt as _;
        let mut file = tokio::fs::File::open(path).await?;
        let metadata = file.metadata().await?;
        anyhow::ensure!(
            metadata.is_file() && metadata.len() > 0 && metadata.len() <= crate::model::MAX_AUDIO,
            "invalid audio file"
        );
        let mut hash = sha2::Sha256::new();
        let mut buffer = vec![0u8; 262144];
        loop {
            let count = file.read(&mut buffer).await?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
        }
        file.seek(std::io::SeekFrom::Start(0)).await?;
        let entry = crate::model::Entry {
            track: crate::model::Track {
                id: String::new(),
                title: title.unwrap_or_else(|| {
                    path.file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned()
                }),
                artist,
                album,
                album_id: None,
                cover_art: None,
                duration: None,
                track: None,
                disc_number: None,
                suffix: path
                    .extension()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_lowercase(),
                size: metadata.len(),
            },
            sha256: hex::encode(hash.finalize()),
            artwork: None,
        };
        entry.validate()?;
        let encoded = serde_json::to_string(&entry)?;
        anyhow::ensure!(
            encoded.len() <= crate::model::MAX_METADATA,
            "metadata too large"
        );
        let audio = reqwest::multipart::Part::stream_with_length(
            reqwest::Body::wrap_stream(tokio_util::io::ReaderStream::new(file)),
            entry.track.size,
        )
        .file_name(format!("audio.{}", entry.track.suffix));
        let form = reqwest::multipart::Form::new()
            .text("entry", encoded)
            .part("audio", audio);
        let response = crate::client::Client::response(
            self.request(reqwest::Method::POST, "v1/tracks")?
                .multipart(form),
        )
        .await?;
        let saved: crate::model::Entry =
            crate::client::Client::json(response, crate::model::MAX_METADATA).await?;
        saved.validate()?;
        anyhow::ensure!(
            saved.sha256 == entry.sha256
                && saved.track.size == entry.track.size
                && saved.track.suffix == entry.track.suffix
                && !saved.track.id.is_empty(),
            "node returned a different audio version"
        );
        Ok(saved)
    }

    pub async fn download(&self, id: &str, output: &std::path::Path) -> anyhow::Result<()> {
        use futures_util::StreamExt as _;
        use sha2::Digest as _;
        use tokio::io::AsyncWriteExt as _;
        let entry = self
            .catalog()
            .await?
            .entries
            .into_iter()
            .find(|entry| entry.track.id == id)
            .ok_or_else(|| anyhow::anyhow!("track not found"))?;
        entry.validate()?;
        let mut url = self.endpoint.clone();
        url.path_segments_mut()
            .map_err(|_| anyhow::anyhow!("invalid node URL"))?
            .clear()
            .extend(["v1", "tracks", id, "audio"]);
        let response =
            crate::client::Client::response(self.http.get(url).bearer_auth(&self.token)).await?;
        let parent = output
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or(std::path::Path::new("."));
        let temporary = tempfile::Builder::new()
            .prefix(".syncstr-download-")
            .tempfile_in(parent)?;
        let mut file = tokio::fs::File::from_std(temporary.reopen()?);
        let mut stream = response.bytes_stream();
        let mut hash = sha2::Sha256::new();
        let mut received = 0;
        while let Some(bytes) = stream.next().await {
            let bytes = bytes?;
            received += bytes.len() as u64;
            anyhow::ensure!(received <= entry.track.size, "audio size mismatch");
            hash.update(&bytes);
            file.write_all(&bytes).await?;
        }
        anyhow::ensure!(
            received == entry.track.size && hex::encode(hash.finalize()) == entry.sha256,
            "audio size or hash mismatch"
        );
        file.flush().await?;
        file.sync_all().await?;
        drop(file);
        let output = output.to_owned();
        let parent = parent.to_owned();
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            temporary.persist_noclobber(output)?;
            std::fs::File::open(parent)?.sync_all()?;
            Ok(())
        })
        .await??;
        Ok(())
    }
}

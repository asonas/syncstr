pub fn validate_url(value: &str) -> anyhow::Result<iroh::RelayUrl> {
    anyhow::ensure!(value.len() <= 2048, "relay URL too long");
    let relay: iroh::RelayUrl = value.parse()?;
    let url = &*relay;
    let loopback = url
        .host_str()
        .and_then(|host| {
            host.trim_start_matches('[')
                .trim_end_matches(']')
                .parse::<std::net::IpAddr>()
                .ok()
        })
        .is_some_and(|ip| ip.is_loopback());
    anyhow::ensure!(
        url.scheme() == "https" || (url.scheme() == "http" && loopback),
        "relay requires HTTPS; HTTP is restricted to loopback tests"
    );
    anyhow::ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "relay URL must not contain credentials, query, or fragment"
    );
    anyhow::ensure!(
        url.host_str().is_some() && url.path() == "/" && url.port() != Some(0),
        "relay URL must name a root endpoint with a valid port"
    );
    Ok(relay)
}

impl crate::store::Store {
    pub async fn cluster_relay(&self) -> anyhow::Result<Option<String>> {
        self.run(|connection, _| {
            use rusqlite::OptionalExtension as _;
            let value: Option<String> = connection
                .query_row(
                    "SELECT relay FROM cluster_remote WHERE singleton = 1",
                    [],
                    |row| row.get(0),
                )
                .optional()?
                .flatten();
            if let Some(value) = &value {
                crate::cluster_remote::validate_url(value)?;
            }
            Ok(value)
        })
        .await
    }

    pub async fn set_cluster_relay(&self, relay: Option<String>) -> anyhow::Result<()> {
        let relay = relay
            .map(|value| crate::cluster_remote::validate_url(&value).map(|url| url.to_string()))
            .transpose()?;
        self.run(move |connection, _| {
            anyhow::ensure!(
                connection.query_row(
                    "SELECT EXISTS(SELECT 1 FROM cluster_identity)",
                    [],
                    |row| row.get::<_, bool>(0)
                )?,
                "create or join a cluster first"
            );
            connection.execute(
                "INSERT OR REPLACE INTO cluster_remote VALUES (1, ?)",
                [relay],
            )?;
            Ok(())
        })
        .await
    }
}

pub fn initialize(directory: &std::path::Path, host: &str) -> anyhow::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::DirBuilderExt as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    anyhow::ensure!(!host.trim().is_empty(), "--host is required");
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)?;
    let mut params = rcgen::CertificateParams::new(vec![host.to_owned()])?;
    params.not_before = time::OffsetDateTime::now_utc() - time::Duration::hours(1);
    params.not_after = time::OffsetDateTime::now_utc() + time::Duration::days(365);
    params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
    let key = rcgen::KeyPair::generate()?;
    let certificate = params.self_signed(&key)?;
    let token: [u8; 32] = rand::random();
    let files = [
        ("tls.crt", certificate.pem()),
        ("tls.key", key.serialize_pem()),
        ("token", format!("{}\n", hex::encode(token))),
    ];
    let mut created = Vec::new();
    for (name, data) in files {
        let path = directory.join(name);
        let result = (|| -> std::io::Result<()> {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)?;
            created.push(path.clone());
            file.write_all(data.as_bytes())?;
            file.sync_all()
        })();
        if let Err(error) = result {
            for path in created {
                std::fs::remove_file(path)?;
            }
            return Err(error.into());
        }
    }
    Ok(())
}

pub fn token(path: &std::path::Path) -> anyhow::Result<String> {
    let token = std::fs::read_to_string(path)?.trim().to_owned();
    anyhow::ensure!(
        hex::decode(&token)?.len() == 32,
        "token must contain 32 random bytes encoded as hexadecimal"
    );
    Ok(token)
}

pub async fn tls(
    directory: &std::path::Path,
) -> anyhow::Result<axum_server::tls_rustls::RustlsConfig> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Ok(axum_server::tls_rustls::RustlsConfig::from_pem_file(
        directory.join("tls.crt"),
        directory.join("tls.key"),
    )
    .await?)
}

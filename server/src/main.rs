#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token_path = std::env::var("SYNCSTR_TOKEN_FILE")?;
    let token = tokio::fs::read_to_string(token_path)
        .await?
        .trim()
        .to_owned();
    let music = std::env::var("SYNCSTR_MUSIC_DIR")?;
    let staging = std::env::var("SYNCSTR_STAGING_DIR")?;
    let limit = std::env::var("SYNCSTR_MAX_UPLOAD_BYTES")
        .unwrap_or_else(|_| "1073741824".into())
        .parse()?;
    let service = syncstr_upload::UploadService::new(
        std::path::Path::new(&music),
        std::path::Path::new(&staging),
        token,
        limit,
    )?;
    let bind = std::env::var("SYNCSTR_BIND").unwrap_or_else(|_| "127.0.0.1:4545".into());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    eprintln!("Syncstr upload listening on {}", listener.local_addr()?);
    axum::serve(listener, service.router())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

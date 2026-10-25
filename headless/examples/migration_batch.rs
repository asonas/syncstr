#[derive(serde::Deserialize)]
struct Request {
    entry: std::path::PathBuf,
    organization: std::path::PathBuf,
    file: std::path::PathBuf,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    use std::io::{BufRead as _, Write as _};
    let data = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("data path required"))?;
    let data = std::path::Path::new(&data);
    let identity = syncstr_headless::peer::Identity::open(&data.join("peer"))?;
    let store = syncstr_headless::store::Store::open(data)?;
    println!("ready");
    std::io::stdout().flush()?;
    for line in std::io::stdin().lock().lines() {
        let request: Request = serde_json::from_str(&line?)?;
        let entry = serde_json::from_slice(&std::fs::read(request.entry)?)?;
        let organization = serde_json::from_slice(&std::fs::read(request.organization)?)?;
        store
            .import_cluster_file(&identity, entry, Some(organization), &request.file, false)
            .await?;
        println!("verified");
        std::io::stdout().flush()?;
    }
    Ok(())
}

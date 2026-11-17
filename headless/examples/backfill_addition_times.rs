#[derive(serde::Deserialize)]
struct Request {
    library_id: String,
    tracks: Vec<syncstr_headless::cluster_changes::AdditionTimeUpdate>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    anyhow::ensure!(args.len() == 3, "usage: backfill_addition_times DATA REQUEST");
    let root = std::path::Path::new(&args[1]);
    let request: Request = serde_json::from_slice(&std::fs::read(&args[2])?)?;
    let identity = syncstr_headless::peer::Identity::open(&root.join("peer"))?;
    let store = syncstr_headless::store::Store::open(root)?;
    let changed = store.backfill_addition_times(identity, request.library_id, request.tracks).await?;
    println!("{}", serde_json::json!({"updated": changed}));
    Ok(())
}

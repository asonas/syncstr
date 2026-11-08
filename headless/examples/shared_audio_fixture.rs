#[path = "../fixtures/create_shared_audio.rs"]
mod fixture;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let root = std::env::args_os()
        .nth(1)
        .map(std::path::PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("usage: shared_audio_fixture <new-output-directory>"))?;
    fixture::create(root).await
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct SavedOriginal {
    original_id: String,
    pin: syncstr_headless::catalog_client::ExactTrack,
    file: std::path::PathBuf,
}

pub async fn copy_win32(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        !destination.exists(),
        "The destination profile already exists"
    );
    let source = source.canonicalize()?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(source.join("node.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock)?;
    let parent = destination
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Profile needs a parent directory"))?;
    anyhow::ensure!(
        !parent.canonicalize()?.starts_with(&source),
        "The destination cannot be inside the source profile"
    );
    let staged = tempfile::Builder::new()
        .prefix(".profile-copy-")
        .tempdir_in(parent)?;
    copy_tree(&source, staged.path())?;
    let secret = crate::windows_identity::load(staged.path(), false)?;
    let legacy = syncstr_headless::cluster_client::PlaybackClient::open(staged.path(), secret)?;
    let catalog = legacy.catalog().await?;
    let mut saved = Vec::new();
    for entry in catalog.catalog.entries {
        if let Some(file) = legacy.local_file(&entry.sha256).await? {
            saved.push(SavedOriginal {
                original_id: entry.track.id.clone(),
                pin: syncstr_headless::catalog_client::ExactTrack {
                    track_id: catalog
                        .catalog
                        .organization
                        .canonical_track(&entry.track.id),
                    sha256: entry.sha256,
                },
                file: file.strip_prefix(staged.path())?.to_owned(),
            });
        }
    }
    drop(legacy);
    std::fs::write(
        staged.path().join("win32-saves.json"),
        serde_json::to_vec(&saved)?,
    )?;
    std::fs::OpenOptions::new()
        .write(true)
        .open(staged.path().join("win32-saves.json"))?
        .sync_all()?;
    std::fs::rename(staged.path(), destination)?;
    syncstr_headless::platform_fs::sync_directory(parent)?;
    drop(lock);
    Ok(())
}

fn copy_tree(source: &std::path::Path, destination: &std::path::Path) -> anyhow::Result<()> {
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        if name == "node.lock" || name == "device.lock" || name == "node.sqlite-shm" {
            continue;
        }
        let kind = entry.file_type()?;
        use std::os::windows::fs::MetadataExt as _;
        anyhow::ensure!(
            entry.metadata()?.file_attributes() & 0x400 == 0,
            "Profile copies cannot follow reparse points"
        );
        let target = destination.join(name);
        if kind.is_dir() {
            std::fs::create_dir(&target)?;
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            std::fs::copy(entry.path(), &target)?;
            std::fs::OpenOptions::new()
                .write(true)
                .open(target)?
                .sync_all()?;
        }
    }
    Ok(())
}

pub fn restore_saves(
    root: &std::path::Path,
    client: &mut syncstr_headless::catalog_client::Client,
) -> anyhow::Result<usize> {
    let path = root.join("win32-saves.json");
    if !path.exists() {
        return Ok(0);
    }
    let pending: Vec<SavedOriginal> = serde_json::from_slice(&std::fs::read(&path)?)?;
    let mut remaining = Vec::new();
    for original in pending {
        anyhow::ensure!(
            !original.file.is_absolute()
                && original
                    .file
                    .components()
                    .all(|c| matches!(c, std::path::Component::Normal(_))),
            "Invalid relative original path"
        );
        match client.import_saved_audio(&original.pin, &root.join(&original.file)) {
            Ok(_) => {}
            Err(
                syncstr_headless::catalog_client::Error::InvalidPin
                | syncstr_headless::catalog_client::Error::UnavailableSource,
            ) => remaining.push(original),
            Err(error) => return Err(error.into()),
        }
    }
    use std::io::Write as _;
    let mut staged = tempfile::NamedTempFile::new_in(root)?;
    staged.write_all(&serde_json::to_vec(&remaining)?)?;
    staged.as_file().sync_all()?;
    syncstr_headless::platform_fs::persist_replace(staged, &path)?;
    Ok(remaining.len())
}

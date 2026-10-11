use std::path::Path;

pub fn create_private_dir(path: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt as _;
        builder.mode(0o700);
    }
    builder.create(path)
}

pub fn private_file_options() -> std::fs::OpenOptions {
    #[allow(unused_mut)]
    let mut options = std::fs::OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options
}

pub fn sync_directory(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        std::fs::File::open(path)?.sync_all()
    }
    #[cfg(windows)]
    {
        // Windows does not permit opening directories through std::fs::File.
        // FlushFileBuffers is applied to every created/replaced file instead;
        // MoveFileExW write-through is used by the Windows application boundary.
        let _ = path;
        Ok(())
    }
}

pub fn absolute_directory(path: &Path) -> std::io::Result<std::path::PathBuf> {
    #[cfg(unix)]
    {
        path.canonicalize()
    }
    #[cfg(windows)]
    {
        // canonicalize opens every ancestor and can fail in managed Windows
        // environments even when the application directory itself is usable.
        // Store callers only require a stable absolute path, not symlink
        // resolution.
        if path.is_absolute() {
            Ok(path.to_owned())
        } else {
            Ok(std::env::current_dir()?.join(path))
        }
    }
}

pub fn persist_replace(
    temporary: tempfile::NamedTempFile,
    destination: &Path,
) -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        temporary.persist(destination)?;
        Ok(())
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt as _;
        let mut temporary = temporary.into_temp_path();
        let source: Vec<u16> = temporary.as_os_str().encode_wide().chain([0]).collect();
        let destination: Vec<u16> = destination.as_os_str().encode_wide().chain([0]).collect();
        let result = unsafe {
            windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                windows_sys::Win32::Storage::FileSystem::MOVEFILE_REPLACE_EXISTING,
            )
        };
        if result == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        temporary.disable_cleanup(true);
        Ok(())
    }
}

pub(crate) struct NodeLock {
    file: std::fs::File,
    owner: u32,
}

impl NodeLock {
    pub(crate) fn acquire(file: std::fs::File) -> std::io::Result<Self> {
        fs2::FileExt::try_lock_exclusive(&file)?;
        Ok(Self {
            file,
            owner: std::process::id(),
        })
    }
}

impl Drop for NodeLock {
    fn drop(&mut self) {
        // A spawning child can retain the file after our close, so end ownership explicitly.
        // An inherited guard in that child must not unlock its parent's live store.
        if self.owner == std::process::id() {
            let _ = fs2::FileExt::unlock(&self.file);
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    #[test]
    fn dropping_an_inherited_guard_keeps_parent_ownership() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let path = root.path().join("node.lock");
        let open = || {
            crate::platform_fs::private_file_options()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path)
        };
        let guard = super::NodeLock::acquire(open()?)?;
        // The child only drops its file descriptor and exits; it never uses Rust runtime state.
        let child = unsafe { libc::fork() };
        assert!(child >= 0);
        if child == 0 {
            drop(guard);
            unsafe { libc::_exit(0) };
        }
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(child, &mut status, 0) }, child);
        assert_eq!(status, 0);
        assert!(super::NodeLock::acquire(open()?).is_err());
        drop(guard);
        let _next_owner = super::NodeLock::acquire(open()?)?;
        Ok(())
    }
}

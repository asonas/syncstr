pub fn load(root: &std::path::Path, create: bool) -> anyhow::Result<[u8; 32]> {
    let path = root.join("device-key.dpapi");
    if path.exists() {
        let encrypted = std::fs::read(path)?;
        anyhow::ensure!(
            !encrypted.is_empty(),
            "The protected identity is unreadable; restore the original identity."
        );
        let input = windows::Win32::Security::Cryptography::CRYPT_INTEGER_BLOB {
            cbData: encrypted.len().try_into()?,
            pbData: encrypted.as_ptr() as *mut u8,
        };
        let mut output = windows::Win32::Security::Cryptography::CRYPT_INTEGER_BLOB::default();
        unsafe {
            windows::Win32::Security::Cryptography::CryptUnprotectData(
                &input,
                None,
                None,
                None,
                None,
                0,
                &mut output,
            )?;
        }
        let bytes =
            unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
        unsafe {
            let _ = windows::Win32::Foundation::LocalFree(Some(
                windows::Win32::Foundation::HLOCAL(output.pbData.cast()),
            ));
        }
        return bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("The protected identity has an invalid length"));
    }
    anyhow::ensure!(
        create && !root.join("node.sqlite").exists(),
        "The existing identity is missing. Restore it instead of creating a replacement."
    );
    let secret: [u8; 32] = rand::random();
    store(root, secret)?;
    Ok(secret)
}

pub fn store(root: &std::path::Path, secret: [u8; 32]) -> anyhow::Result<()> {
    use std::io::Write as _;
    syncstr_headless::platform_fs::create_private_dir(root)?;
    let input = windows::Win32::Security::Cryptography::CRYPT_INTEGER_BLOB {
        cbData: 32,
        pbData: secret.as_ptr() as *mut u8,
    };
    let mut output = windows::Win32::Security::Cryptography::CRYPT_INTEGER_BLOB::default();
    unsafe {
        windows::Win32::Security::Cryptography::CryptProtectData(
            &input,
            windows::core::w!("Syncstr device identity"),
            None,
            None,
            None,
            0,
            &mut output,
        )?;
    }
    let protected =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        let _ = windows::Win32::Foundation::LocalFree(Some(windows::Win32::Foundation::HLOCAL(
            output.pbData.cast(),
        )));
    }
    let mut file = tempfile::NamedTempFile::new_in(root)?;
    file.write_all(&protected)?;
    file.as_file().sync_all()?;
    file.into_temp_path()
        .persist_noclobber(root.join("device-key.dpapi"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn identity_survives_copy_and_never_replaces_a_missing_enrolled_key() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let first = root.path().join("first");
        let secret = super::load(&first, true)?;
        let copy = root.path().join("copy");
        std::fs::create_dir(&copy)?;
        std::fs::copy(
            first.join("device-key.dpapi"),
            copy.join("device-key.dpapi"),
        )?;
        assert_eq!(super::load(&copy, false)?, secret);
        std::fs::write(copy.join("node.sqlite"), b"existing")?;
        std::fs::remove_file(copy.join("device-key.dpapi"))?;
        assert!(super::load(&copy, true).is_err());
        assert!(!copy.join("device-key.dpapi").exists());
        Ok(())
    }
}

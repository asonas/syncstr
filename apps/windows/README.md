# Syncstr for Windows

The Windows client reuses the Rust cluster playback implementation. It discovers
LAN library hosts, confirms a pasted invitation against the selected endpoint,
refreshes catalog metadata without automatically downloading originals, saves a
selected original with integrity verification, and plays saved audio through the
Windows multimedia subsystem.

Discovery, enrollment, catalog reads, transfers, and file verification run on a
serialized worker. The window remains available for movement and repainting,
and existing playback can be paused/resumed during a transfer. Closing cancels
pending delivery and the active task without waiting in the window procedure;
interrupted jobs are recovered when the saved store opens again.

The device secret is protected with Windows DPAPI for the current user and is
stored separately from the SQLite catalog under `%LOCALAPPDATA%\Syncstr`. If an
existing catalog has no readable protected identity, startup fails with a
recovery error instead of creating a different cluster identity.

## Build and run

Install the MSVC Rust 1.99 toolchain. From the repository root:

```powershell
cargo +1.99.0 test --manifest-path apps/windows/Cargo.toml --locked
cargo +1.99.0 build --release --manifest-path apps/windows/Cargo.toml --locked
./apps/windows/target/release/syncstr-windows.exe
```

The release executable is `apps/windows/target/release/syncstr-windows.exe`.

## Connection and playback

1. Select **Discover** while the Windows computer and library host share a LAN.
2. Paste a fresh playback invitation and select the endpoint ID shown by the
   expected host. Select **Register** only after checking that the two IDs match.
3. Select **Refresh library**. This downloads catalog state, not audio originals.
4. Select a track and choose **Save**. The verified original is retained under
   the per-user Syncstr data directory.
5. Choose **Play** for a saved track. **Pause / Resume** controls local playback.

Windows may ask for firewall access when LAN discovery or QUIC is first used.
Review the network scope before allowing it. Remote relay access, Windows library
hosting, packaging, signing, and store distribution are not included in this
initial playback-client slice.

## Verification boundary

Automated tests cover the existing enrollment, membership, catalog conflict,
transfer integrity, and wire contracts in `headless`, plus Windows DPAPI identity
restoration. A build does not prove audible output or a real host interaction.
Record LAN enrollment, physical playback, offline restart, and firewall behavior
separately when they are checked on the target Windows computer.

See the [review repair record](../../docs/validation/windows-android-review-repairs.md)
for cross-build evidence and pending device checks.

# Windows shared Rust client validation

ASO-11, 2026-11-08. The Windows gpui client uses the shared Rust catalog,
verified audio acquisition and independent offline-save ownership. The checks
below used disposable synthetic libraries and profiles, not production data.

## Build and revision

- Initial Windows UI validation base: `03238e6b737a4a7eae1a4f5d8ba6951bad50e7d1` (`main`, PR #57).
- Implementation: `9d26b26cdfba248c0ab45f32442baca901ae8f7d`, branch
  `codex/aso-11-shared-client`, rebased onto main `3b38cf3` on 2026-11-10.
- Windows x64, Rust 1.99.1; the launched executable was verified to come from
  this worktree, with one gpui client process running.
- `cargo build --manifest-path apps/desktop/Cargo.toml --locked --bin syncstr-desktop --example windows_audio -j 1`: passed.
- `cargo test --manifest-path apps/desktop/Cargo.toml --locked -j 1`: 7 passed.
- `cargo clippy --manifest-path apps/desktop/Cargo.toml --locked --all-targets -j 1 -- -D warnings`: passed.
- `cargo test --manifest-path headless/Cargo.toml --locked --features p2p --test catalog_audio -j 1`: 7 passed; the subprocess-only crash entry point was ignored by the normal runner and exercised by its parent recovery test.
- `cargo clippy --manifest-path headless/Cargo.toml --locked --features p2p --lib -j 1 -- -D warnings`: passed.

These are local results. CI results are reported separately on the pull request.
The existing Windows-only timeout in
`shared_audio::quic_audio_additions_share_bytes_and_reject_invalid_uploads`,
previously reproduced on unmodified main, was not reclassified as fixed or
rerun as part of these focused checks.

### Publication recheck, 2026-11-10

After rebasing, desktop tests (7 passed), desktop all-target Clippy and the
Windows client/example build passed again. The shared catalog-audio suite
(7 passed, 1 subprocess-only entry point ignored) and shared-core library Clippy
also passed again. The muted native-audio example
also passed again: copied DPAPI identity, exact legacy-save import, authenticated
v5 acquisition, native decode/pause/resume/stop, independent saves with one object,
credential-free offline reopen and lease-safe removal. The November 8 UI and
human audibility checks below were not repeated for publication.

## Native engine and storage

The [`windows_audio` example](../../apps/desktop/examples/windows_audio.rs)
used a generated one-second WAV, three distinct logical tracks sharing one
audio hash, and a signed playlist with repeated occurrences and an old alias.

- An enrolled synthetic Win32-format profile was copied under its writer lock.
  The original database and DPAPI-protected key remained byte-for-byte unchanged;
  the copied key decrypted to the same device identity.
- The first migration run exposed a device-local track ID absent from the host
  catalog. Migration now follows the old catalog's explicit track aliases,
  retains the original device ID in the manifest and validates the exact hash
  against v5. It does not select another track merely because its hash matches.
  The corrected run imported exactly one original logical save.
- Authenticated v5 refresh and audio acquisition completed. Saving `TRACK-A`
  and `TRACK-B` produced independent receipts and one managed audio file.
- Windows MediaPlayer decoded the verified file, advanced its position,
  paused without advancing, resumed and stopped. These automated checks were muted.
- After shutdown, the host was stopped and the copied protected key temporarily
  withheld. Reopening retained the catalog and played saved bytes without a host
  or key. Removing the final receipt retained bytes while a verified playback
  handle existed and removed them after native source closure and handle release.
- The shared-core tests also cover partial-save restart, interrupted process
  recovery, cancellation, integrity failure and shutdown draining.

## gpui interactions and audibility

- Authenticated Refresh displayed three independent rows and migrated the old save.
- Selecting and saving `TRACK-A` and `TRACK-B` separately updated their own Saved
  states. Inspection confirmed one managed audio file for all three receipts.
- Playing `TRACK-B` from gpui produced the confirmation tone. The owner explicitly
  confirmed hearing it; human audibility is separate from engine progress.
- After normal window closure and host termination, reopening without a host hint
  restored all three rows and saves. Searching for `TRACK-A` and playing it reached
  the end of the one-second audio without transport errors.
- Clearing search restored the rows. The signed playlist retained three separate
  occurrence rows; the old alias occurrence played offline. Artist, album and Saved
  presentation resolve explicit aliases without replacing the occurrence's pin.
- Selection spans the row width. The changed controls and rows expose UI Automation
  roles and names; Saved and unavailable state are included in row names.
- Normal window closure completed without a lingering client process. Shared
  library mutations are absent, with an explanation in the window.

## LAN discovery and cache-free GUI acquisition

The owner handled the Windows network-permission prompts for the test host and
client. Discovery still resolved no host after both processes were restarted.
An independent 12-second browse also produced search events but no resolved
service, so success cannot be inferred by increasing the GUI's three-second
search window. At the observed times, neither test process owned a UDP 5353
endpoint; other mDNS services did. The root cause is not established. Existing
services and OS security settings were not changed by the agent.

The same LAN fixture worked with an explicit `--host` hint. Its profile was
already enrolled, legacy-save imports were deferred, and managed audio storage
contained zero files before acquisition. From the GUI:

1. Refresh authenticated the host and displayed three unsaved logical tracks.
2. Save on `TRACK-A` fetched a 16,044-byte audio object into managed storage.
3. Save on `TRACK-B` independently marked the second row Saved. The UI showed
   two saved versions while managed storage contained one file.
4. SHA-256 comparison against the fixture's source WAV matched.

Thus authenticated catalog/audio transfer and save ownership work through the
Windows UI with a supplied endpoint. This does **not** establish automatic LAN
discovery or a separate-device LAN test. Discovery remains an ASO-11 follow-up.

After verification, the client was closed normally and the identified disposable
fixture host was stopped. No client, host or diagnostic process from this worktree
remained. Test profiles were retained; production profiles were untouched.

## Remaining verification and scope

- Automatic LAN discovery remains unresolved as described above. The current
  discovery result message is also replaced by the ordinary catalog status after
  the operation; the absence of a host row was checked separately.
- Fresh invitation enrollment was not exercised. The existing enrollment flow
  is a pre-v5 enrollment service; the current v5-only server does not provide that
  service. The tested profiles were already enrolled. There is no legacy catalog
  refresh or mutation fallback after activation.
- Native Remove save interaction, narrow-window resizing and the complete UI
  cancellation matrix remain unverified. Save removal and lease lifetime were
  exercised through the real core/native-engine validation path.
- Japanese IME was not rerun for this integration; the existing vendored ASO-56
  fix remains. Broader UI Automation traversal, media keys/SMTC, daily-use playback
  and full macOS parity are not established by these checks.
- Apple and Android integration/builds were not run on this Windows machine.
  The macOS gpui scaffold remains in demo mode; existing Apple native clients
  and the Win32 client were not changed.
- No production migration, profile cutover, source deletion or identity reset
  was performed. Deployment and merge are outside this validation result.

Use the [desktop verification procedure](../../apps/desktop/README.md#disposable-native-audio-verification)
to reproduce the synthetic checks. Generated credentials, device IDs, addresses,
personal paths and raw session logs must stay out of published evidence.

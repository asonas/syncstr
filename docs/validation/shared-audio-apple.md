# Apple v5 validation

The Apple client follows the [ASO-8 contract](../shared-audio-v5-handoff.md).
Logical rows remain keyed by track ID. Playlist occurrences and playback queues
retain their original ID/hash pairs; save ownership uses the canonical logical
ID and pinned hash. Audio filenames use the hash rather than metadata suffixes.
Managed saves share an inode with cached v5 audio, so cache eviction cannot
remove a saved reference. The wire contract is unchanged.

## Reproduction

Use an isolated worktree and synthetic fixtures. Do not import fixture identities
into an everyday app profile. The fixture updater refuses directories without
the generator's `expected.json`; it also requires the server to be stopped.

Build the server and both examples into a stable directory. If a build-cache
manager automatically removes target output, use the native toolchain through
`rustup run` so a separate Swift process can consume the resulting artifacts:

```sh
mise exec -- rustup run 1.99.1 cargo build --manifest-path headless/Cargo.toml \
  --locked --features p2p --target-dir /tmp/syncstr-v5-rust \
  --bin syncstr-headless --example shared_audio_fixture \
  --example shared_audio_fixture_update
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TEST_RUNNER_SYNCSTR_V5_TEST_BIN_DIR=/tmp/syncstr-v5-rust/debug \
  xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme SyncstrMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/syncstr-v5-mac \
  CODE_SIGNING_ALLOWED=NO ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= \
  -only-testing:LocalMusicTests/SharedAudioTests \
  -only-testing:LocalMusicTests/OfflineSaveTests \
  -only-testing:LocalMusicTests/CatalogMigrationTests \
  -only-testing:LocalMusicTests/PlayerInteractionTests test
```

Confirm the real-server test actually ran. A skip is not interoperability
verification. Its fixture starts with an enrolled reader, distinct registrations
sharing one WAV, and repeated signed playlist occurrences. It exercises restart,
metadata/preferred-audio/correspondence updates, old pinned playback, and reader
revocation. It does not use an administrative token in the playback client.

For the iOS model tests, run the `Syncstr` scheme on an isolated Simulator with
the corresponding `SyncstrTests` filters. The process-based Rust test is macOS
only; the catalog, save, cache and queue tests are shared with iOS.

For iOS UI verification, build the `SyncstrUITests` scheme, install its app in a
dedicated Simulator, and generate a new fixture directory with
`shared_audio_fixture`. Copy only `snapshot.json`, `reader-enrollment.json` and
`tone.wav` into a fresh directory under the installed app's Documents container.
Do not copy private keys or the HTTPS token. Set
`TEST_RUNNER_SYNCSTR_V5_FIXTURE_ROOT` to that directory when running
`SyncstrUITests/SharedAudioFlowTests` with `test-without-building`,
`-parallel-testing-enabled NO`, `-testLanguage ja` and `-testRegion JP`.
The DEBUG fixture stores app data in an `apple-ui` subdirectory and preserves it
across relaunch. Repeated verification uses a new fixture directory.

## Acceptance status

Verified on 2026-10-30:

- 47 macOS regression tests passed: catalog migration (7), membership (12),
  offline saves (16), player interactions (11), and legacy Rust transfer (1).
- All 10 shared-audio tests passed, including the real v5 Rust server test.
  The latter exercised metadata/preferred-hash changes, correspondence removal,
  exact old playlist downloads, reconnect and rejected revoked enrollment.
- All 11 Rust shared-audio contract tests passed in both a serial run and a
  subsequent parallel run. The first parallel run had two transient lock errors;
  they did not reproduce individually, serially or in the parallel recheck.
- The current macOS app showed three distinct logical rows. Removing A's save
  retained B's saved state after app restart; selecting B opened its player
  without a playback error. The target executable and single process were
  checked before interaction. Audible physical-device output was not checked.
- The iOS app and UI-test bundle built successfully. UI execution did not reach
  the test method: CoreSimulator blocked in `launchApplicationWithID` /
  `host_support_mig_launch_app`. The dedicated Simulator was rebooted using the
  repository's migration-recovery procedure. Its app installed, but the UI
  runner still did not start; the stalled test process was interrupted.

ASO-9 remains in progress. Final iOS model/UI execution, full visual acceptance
(including search and conflict/incomplete states), and physical-device gaps
must remain explicit. Build success is not interaction verification. No result
authorizes production migration, enrollment reset, deployment or distribution.
Cross-platform acceptance remains ASO-12 work.

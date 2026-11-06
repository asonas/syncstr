# Apple v5 validation

The Apple client follows the [ASO-8 contract](../shared-audio-v5-handoff.md).
Logical rows remain keyed by track ID. Playlist occurrences and playback queues
retain their original ID/hash pairs; save ownership uses the canonical logical
ID and pinned hash. Audio filenames use the hash rather than metadata suffixes.
Managed saves share an inode with cached v5 audio, so cache eviction cannot
remove a saved reference. Playback detects the format from the local bytes and
passes its MIME type to AVFoundation; mutable metadata does not name the file
or choose its parser. The wire contract and server behavior are unchanged.

## Projection and unresolved refreshes

The Apple projection retains the existing album organization, edition and
compilation distinctions, artist credits, and visibility choices. Logical IDs
remain distinct even when their bytes match. Empty artwork payloads mean no
image; they do not invalidate the catalog. Image acquisition has moved to
ASO-47, including any server-side hydration.

The current projection lists incomplete record IDs without identifying their
affected tracks. ASO-9 therefore retains the last verified catalog and playlist
bindings, persists an incomplete-refresh notice across relaunch, and continues
verified local playback. A later complete accepted refresh clears that notice.
This fallback defers every unverified update in that snapshot, including updates
that may be unrelated. Record-based attribution and partial refresh application
have moved to ASO-46. Known track conflicts still block only the
affected track; the library shows a persistent conflict notice without choosing
a winner.

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

For iOS model and UI verification, use the repository runner:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SYNCSTR_V5_TEST_BIN_DIR=/tmp/syncstr-v5-rust/debug \
  python3 apps/ios/scripts/verify_simulator.py --device iphone \
  --only-testing SyncstrUITests/SharedAudioFlowTests
```

The runner creates a dedicated Simulator and copies only `snapshot.json`,
`reader-enrollment.json` and `tone.wav` into its app's Documents directory.
Generated private keys and tokens remain outside the uploaded artifacts and
are removed after fixture generation. The UI runner passes a path relative to
Documents so Xcode can relocate the app container during installation. The
DEBUG fixture uses independent `apple-ui-normal`, `apple-ui-conflict` and
`apple-ui-incomplete` stores, retained across app relaunch. Missing fixtures or
interoperability tools fail the relevant tests rather than skipping them.

## Earlier evidence

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

The October run did not establish actual AVFoundation playback of hash-named
files. On November 6, the same synthetic TRACK-B bytes reproduced
`AVFoundationErrorDomain -11828` with underlying `-12847` through the unchanged
`c2a7df3` projection, file path and default AVPlayer. Explicitly supplying the
byte-detected MIME type resolves that recognition failure without renaming or
duplicating saved audio.

## Current validation

Verified on 2026-11-06:

- The final macOS regression selection passed 47 tests (50 parameter-expanded
  runs), with zero failures and zero skips. This includes real Rust v5
  interoperability, artwork present/empty projection, incomplete retention and
  recovery, independent logical saves, and byte-format playback of MP3, M4A and
  FLAC from shared hash paths despite incorrect metadata suffixes.
- The final iPhone Simulator model selection passed 106 tests (110
  parameter-expanded runs), with zero failures and zero skips. Its separate
  responsiveness test also passed with zero skips.
- Both final iPhone v5 UI tests passed with zero skips. They exercised search,
  A's save removal while B remains saved after relaunch, B's full player, and
  conflict/incomplete notices across relaunch. Exported screenshots also show
  the retained notices and B's one-second completed playback.
- All seven Simulator-runner regression tests passed, including missing fixture
  failure, public-input-only copying, relative-path forwarding and cleanup.
- The isolated macOS app showed normal, conflict and incomplete states.
  Search returned B without A; removing A's save preserved B after relaunch.
  Following the MIME fix, B advanced in playback and reached completion.
  Conflict left unrelated B playable; incomplete retained the verified catalog
  and saved playback, and its notice survived app relaunch. The exact target
  executable and single running process were checked; that process was stopped.
- The Rust contract selection passed all 11 tests serially and in one parallel
  diagnostic run. Other parallel runs failed with
  `Resource temporarily unavailable (os error 35)`; the last uninstrumented
  diagnostic run passed nine tests and failed two. Its backtrace identifies `Store::locked` at
  `shared_audio.rs:365`, acquiring the replica's `node.lock` during fixture
  activation immediately after inspection. The remaining lock owner or release
  timing is unresolved. A temporary failure-time `lsof` probe reproduced the
  error but captured no remaining holder; it does not confirm or refute a
  transient child-process lock inheritance hypothesis. The probe was removed.
  No server change is included here.

Physical iPhone/iPad playback, audible output on physical hardware, a fresh
iPad Simulator run, narrow-window and accessibility appearance variants, and
cross-platform ASO-12 acceptance remain unverified. Build success is not
interaction verification. No result authorizes production migration,
enrollment reset, deployment or distribution.

# Updating an imported playlist

Reimporting the original Music/iTunes XML can fill unresolved occurrences without
deleting the playlist. The playlist ID, folder ancestry, occurrence IDs, order,
duplicates, source fingerprint and smart-playlist snapshot definition stay intact.
This operation does not import a revised XML structure or evaluate smart rules.

## Review and save

1. Choose **XMLから移行** and the original XML. The host supplies its current
   catalog and playlist revisions. No playlist or metadata candidate is selected
   automatically.
2. Select the playlists and review candidates. The review shows the existing and
   resulting resolved-occurrence counts. Unselected candidates retain existing
   mappings; unresolved occurrences remain in place.
3. **一意の候補を採用** only fills source tracks without an existing mapping in the
   selected playlists. Replacing an adopted audio reference requires an explicit
   candidate choice, a visible before/after comparison and confirmation.
4. **プレイリストを更新** submits the reviewed revisions. A stale preview is rejected
   atomically; reload the XML and review again. Other clients receive the revision
   through their normal playlist refresh.

An exact retry of a saved request does not append another record, even if a later
revision has since arrived. It does not revert that later revision. A different
request based on an old revision is rejected. Newly imported playlists and
updates in the same selection commit together or not at all.

## Signed history and rollout

Original version-1 records remain unchanged. An update appends a version-2 body
with signed parent record IDs. Readers validate the signatures and relationships,
then project the remaining heads independently of arrival order. Divergent heads
are conflicts, not a last-writer-wins update. A missing ancestor is an incomplete
history and is not displayed as a successfully updated playlist.

The authenticated `syncstr/playlists/1` service adds `preview` and `reconcile`
operations. The original `catalog` and create-only `import` operations remain.
The server checks the expected heads and current audio references within the
SQLite write transaction. Acknowledged records and replication cursors retain
their existing append-only storage.

Update hosts and all Apple clients before writing a version-2 revision. Older
readers reject it and cannot advance their playlist cursor. This is not a
database-reset migration. Do not delete playlists, replace pairing credentials,
or downgrade readers after the first update.

## Repeatable local verification

Use a feature worktree. These tests use temporary stores, fictional metadata,
loopback servers and test-specific credentials; they do not modify a live library.

```sh
mise exec -- rustc --version
mise exec -- cargo test --manifest-path headless/Cargo.toml --features p2p --test playlists
mise exec -- cargo build --manifest-path headless/Cargo.toml --features p2p
mise exec -- cargo clippy --manifest-path headless/Cargo.toml --features p2p --all-targets -- -D warnings
mise exec -- xcodegen generate --spec apps/ios/project.yml
env SYNCSTR_HEADLESS_TEST_BINARY="$PWD/headless/target/debug/syncstr-headless" \
  xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme SyncstrMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/syncstr-playlist-check \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalMusicTests/PlaylistMigrationTests \
  -only-testing:LocalMusicTests/PeerTransferTests/testNativeClientUploadsRetriesDownloadsAndRestoresAgainstRustNode test
xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme Syncstr \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/syncstr-playlist-ios-check CODE_SIGNING_ALLOWED=NO build
```

Select the full Xcode developer directory if the machine currently uses Command
Line Tools. Build the Rust executable explicitly before interoperability tests;
compiling integration tests alone is insufficient. Treat skipped interoperability
tests as a verification gap.

The Rust regression preserves 73 occurrences while increasing resolved mappings
from 44 to 65, checks repeat import, stale review, changed source structure,
arrival ordering and database reopen. The authenticated protocol test checks
another client's refresh without downloading audio. The native paired-client
test checks preview, update, retry and verified cache restoration against Rust.
The Swift model test checks preservation and explicit replacement reporting.

## Visual and delivery checks

Inspect the review at normal and narrow widths, search focus/typing/clear,
candidate selection, preserved mappings, replacement confirmation, network
failure and stale-preview recovery. Verify the executable and bundle ID before
launching with the macOS launcher. Use an isolated library and credentials for
fixtures; a seeded review proves presentation, not the complete network journey.

Track implementation, local verification, main integration, push, host rollout,
TestFlight delivery and physical-device acceptance separately. Production
acceptance is the user's existing playlist retaining its identity and folder,
showing the expected new resolved count, and appearing on a second updated
device after refresh. Local fixture success does not establish that result.

Human boundaries for this iteration are candidate acceptance, deliberate changes
to adopted audio, production deployment and the user's real import/device check.
Local builds and automated regression checks require no repeated design decisions.

### Local verification record (2026-10-28)

- Rust playlist regression and authenticated replication: passed.
- Rust build and Clippy with warnings denied: passed.
- Swift migration model tests and native paired Swift/Rust interoperability:
  passed without skipping the server test.
- macOS and iOS Simulator builds: passed.
- An isolated macOS review fixture was built and launched with a distinct bundle
  ID, temporary library and separate credentials. The native UI automation
  service failed to start (`native pipe startup failed`), so visual inspection,
  search interactions, narrow layout and confirmation-dialog acceptance remain
  unverified. The fixture launch alone is not visual proof.
- Production data, host rollout, TestFlight and physical devices were not changed
  or verified. Integration and push are separate delivery steps.

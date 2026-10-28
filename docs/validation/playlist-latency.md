# Playlist latency: fixture measurements

ASO-5 remains incomplete. These measurements establish a runnable, small-fixture
Swift-to-Rust check, not an XML-selection-to-review baseline or a reproduction of
the reported excessive wait.

## Measured scope

`PeerTransferTests.testNativeClientUploadsRetriesDownloadsAndRestoresAgainstRustNode`
uses the actual Apple transfer implementation and a locally spawned Rust host,
temporary stores, fictional metadata and unique test credentials. At the measured
point the host has one audio entry and one playlist with one occurrence. The
playlist starts unresolved and the update resolves that occurrence. No XML is
parsed by this test. There is no embedded artwork in the measured catalog.

The measurement surrounds each public transfer call using `ContinuousClock`.
It includes credential/database access, connection/authentication, request and
response work, and the automatic history synchronization before return. It does
not separate those phases, measure UI presentation, or subtract logging overhead.
Output contains only fixed operation names, elapsed milliseconds and outcome.
There is no shared client/server operation identifier yet.

Every call opens a playlist connection. The test supplies the local host's
advertised addresses; it does not assert the actual selected direct/relay path.
The initial import already synchronizes history, so **both preview labels refer
to an up-to-date cursor**. The update fetches its newly appended revision.
`history-current-cursor` includes connection setup and authentication; it is not
an isolated history-processing duration.

## Reproduction

Follow [the reconciliation checks](../playlist-reconciliation.md#repeatable-local-verification)
for the toolchain prerequisites. From this worktree:

```sh
mise exec -- which rustc cargo swift xcodegen
mise exec -- rustc --version
mise exec -- cargo --version
mise exec -- swift --version
mise exec -- cargo build --manifest-path headless/Cargo.toml --features p2p
mise exec -- cargo test --manifest-path headless/Cargo.toml --features p2p --test playlists
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme SyncstrMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/syncstr-playlist-latency \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalMusicTests/PlaylistMigrationTests \
  -only-testing:LocalMusicTests/PeerTransferTests/testNativeClientUploadsRetriesDownloadsAndRestoresAgainstRustNode \
  -test-iterations 3 test
```

The test uses `headless/target/debug/syncstr-headless` by default. A missing
executable causes a skip, which is not successful interoperability verification.
Retain full Xcode output privately: existing framework/server diagnostics may
contain local environment details. Only the `PLAYLIST_FIXTURE` lines are intended
as sanitized measurement output.

## Observation on 2026-10-29

Source base: `6a87cd1465a379d42fa8e0ccbbfe6df59c0f99fd`, with the test-only timing
addition in this worktree. macOS 27.2 (26B123), arm64; Xcode 27.1 (27A9275), Swift
6.4; Rust/Cargo 1.99.1. Both the Rust dev executable and Xcode Debug tests were
unoptimized. Rust compilation and dependency caches were warm for the measured
run. Other machine activity was not controlled. Each test iteration created a
new host store and client store; the calls within an iteration shared those stores.

Final measurements after review and revalidation, in milliseconds:

| Operation | Run 1 | Run 2 | Run 3 |
|---|---:|---:|---:|
| Preview, current cursor | 20.533 | 17.139 | 18.872 |
| Update including acknowledgment and synchronization | 21.889 | 23.926 | 22.954 |
| Exact update retry | 19.498 | 21.601 | 21.012 |
| Stale update rejected | 18.351 | 19.688 | 20.395 |
| Repeated preview 1 | 17.498 | 18.905 | 19.497 |
| Repeated preview 2 | 17.758 | 18.239 | 18.648 |
| Repeated preview 3 | 16.756 | 18.671 | 18.442 |
| Current-cursor synchronization 1 | 15.386 | 16.253 | 17.376 |
| Current-cursor synchronization 2 | 15.067 | 17.034 | 15.042 |
| Current-cursor synchronization 3 | 14.792 | 15.554 | 15.240 |

All three interoperability iterations passed without skipping. The five Swift
migration model tests passed, including explicit candidate selection and mapping
preservation. All three Rust playlist tests passed. The added stale-update check
asserts the exact stale-preview rejection reason; subsequent refresh verifies
that the accepted document was retained. Exact retry adds zero records.

The existing Apple media framework emitted service-connection diagnostics during
tests; these did not fail the checks. This run is not audible playback acceptance.

## Remaining acceptance evidence

- Identify the original XML and representative host dataset privately, together
  with the build, connection path, history count/cursor, and observed wait. The
  issue's 7,122-entry catalog observation and standalone XML benchmark are not
  measurements made in this run and cannot establish preview causality.
- Instrument the actual XML-selection and update UI boundaries, connection,
  server request processing, response transfer/decoding, XML parsing/matching,
  and history synchronization with one operation identifier. Capture counts,
  available byte sizes, retries and sanitized failure categories. Separate queue
  and lock waits only where directly measured.
- Repeat with a fresh cursor and a current cursor on the same XML/dataset,
  including failures. Keep user candidate acceptance and real-data updates under
  human control. No production library was modified by this run.
- Define the excessive-wait signal from the original observation and establish
  a check that detects it. No latency threshold is asserted by this fixture.
- Measure history request counts and durations before deciding whether batching
  warrants another issue. Current-cursor timings do not answer that question.

Product instrumentation, representative-scale fixtures, cold-history measurements,
UI end-to-end measurements and cross-process correlation remain unfinished work,
not verification blocked solely by the absent original dataset. No performance
optimization, synchronization change, or production rollout is included here.

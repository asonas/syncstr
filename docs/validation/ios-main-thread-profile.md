# iOS main-thread profiling

Baseline Release profiling at `5d29759` identified synchronous catalog loading inside the offline-save worker as the dominant cause of multi-second main-thread stalls. The worker performed this work even when there were no save requests. The implementation and remeasurement below record the fix and the remaining UI stalls.

## Measurement setup

- Source revision: `5d29759`.
- Instruments 27 Time Profiler, including its potential-hangs table.
- Dedicated iPhone 18 Pro Simulator running iOS 27.0 on an Apple Silicon MacBook Air with 16 GB RAM.
- A private copy of the actual NAS catalog: 1,436 tracks, 359 album groups, 1,417 artwork candidates, and 302 local image files. Entry JSON totals 107,054,404 bytes; SQLite occupies 133,525,504 bytes.
- No offline-save request file was present. No audio files or cluster credentials were copied. The NAS and normal application data were not modified.
- Release build used compiler optimization and debug symbols. A separate Debug recording provided an initial comparison.

The UI exercise covered album selection and return, artist selection and return, artist-list scrolling, and opening an artist with 182 tracks. A gesture attempted in the large artist's song list did not change the accessibility tree; successful scrolling of that song list is not established. Automation call durations include tool overhead and are not treated as application latency.

## Recorded hangs

Recording labels correspond to the private Instruments artifacts retained outside the repository.

| Recording | Approximate duration | Hangs reported by Instruments |
| --- | ---: | --- |
| `debug-browse` | 45.6 s | One 424 ms microhang, predominantly initial SwiftUI layout and runtime conformance work |
| `release-launch` | 146.2 s | Four severe hangs, each 2.32–2.42 s |
| `release-browse` | 60.6 s | Two severe hangs: 7.298 s and 2.293 s |
| `release-large-artist` | 45.6 s | Three severe hangs: 2.606 s, 2.241 s, and 2.232 s |
| `release-idle` | 20 s | No hangs; no UI actions during recording |

These are hang intervals reported by Instruments, not independently measured tap-to-render times. The launch recording does not establish first-frame startup latency.

In the 7.298 s interval, 6,718 of 6,755 sampled main-thread CPU milliseconds included `LocalTransfer.resumeSaves` (99.5%). In the 2.606 s interval, all 2,245 sampled main-thread CPU milliseconds included that worker. Wall duration and sampled CPU time are different measures.

The latter interval provides a representative breakdown:

| Inclusive stack frame | Sampled main-thread CPU time |
| --- | ---: |
| `LocalTransfer.resumeSaves` task | 2,245 ms |
| `LocalMusicStore.load` / `snapshot` | 2,240 ms |
| `CatalogDatabase.readSnapshot` | 1,811 ms |
| Database construction | 946 ms |
| Explicit database snapshot | 870 ms |
| `LocalCatalog.organize` | 538 ms |
| `JSONDecoder.decode` | 536 ms |
| `LocalMusicStore.writeArtwork` | 424 ms |

Times overlap because frames contain other frames; they must not be added. File writes and renames are visible in the sampled leaf frames. Accessibility processing is also present in these automated recordings, but it does not explain the worker-dominated hang intervals.

## Confirmed baseline execution path

1. [`LocalTransfer`](../../apps/macos/LocalTransfer.swift) is `@MainActor`. Its [`resumeSaves`](../../apps/macos/OfflineSaves.swift) creates `Task {}`, which inherits that actor. It calls `store.load()` before checking for eligible requests or task cancellation. A task here does not move synchronous work to a background thread.
2. [`LocalMusicStore.snapshot`](../../apps/macos/LocalCatalog.swift) constructs a database and requests a snapshot. [`CatalogDatabase.init`](../../apps/macos/CatalogDatabase.swift) already calls `readSnapshot()` unconditionally, including for the current schema. The explicit snapshot therefore reconstructs the catalog a second time.
3. `readSnapshot()` decodes every entry, including image data, restores artwork assets, validates organization, recomputes membership, and validates organization again. It can persist repaired organization during the read.
4. `LocalMusicStore.snapshot()` then calls `writeArtwork()`. This validates image data and hashes, compares existing files, and atomically writes legacy per-entry artwork. The read therefore also performs image persistence.

Lifecycle resumption and network-path callbacks can invoke `resumeSaves`; the source also contains other callers. The traces establish the expensive worker execution, but do not separately identify the callback responsible for every invocation. An album tap should not be described as directly invoking this worker without additional instrumentation.

## Other findings and limits

- Album projection work accounted for only about 9–10 sampled CPU milliseconds across each of the launch and mixed-browse Release recordings. It was not the dominant source of the measured stalls.
- Synchronous local image loading in `MusicImage.body` remains a possible scrolling cost, but only a few samples reached that path in these recordings. It is not established as the cause of the severe hangs.
- The idle control had no hangs, which supports episodic work rather than a continuously blocked baseline. It does not prove all browsing or lifecycle transitions are smooth.
- Simulator measurements establish the main-thread execution defect. Physical-device timings, sustained song-list scrolling, and exact callback attribution remain unverified.

## Recommended implementation order

1. Prevent an offline-save worker from loading the catalog when there are no eligible requests. Check cancellation and worker generation before expensive work.
2. Move legitimate catalog, hashing, and artwork I/O off the main actor through a serialized storage boundary. Publish UI state on the main actor and preserve catalog consistency, cancellation, and save retry behavior.
3. Remove duplicate full reconstruction when opening and reading the database. Separate ordinary reads from migration, membership repair, and artwork persistence, while retaining integrity checks at the appropriate data-change boundary. Avoid decoding embedded images when a save operation only needs track metadata.
4. Reprofile before changing display-image loading. Add background decoding or caching only if the remaining traces demonstrate that cost.

Implementation should verify that an empty save queue causes no catalog reconstruction, foreground/network changes remain responsive, and save/retry/cancellation behavior and catalog integrity are preserved. Repeat Release profiling with this catalog, album navigation, artist-list scrolling, the 182-track artist, and successfully exercised song-list scrolling. Investigate any remaining main-thread interval over 250 ms; this is a proposed verification threshold, not a measured improvement.

## Implementation and remeasurement

The shared Apple implementation now skips workers with no eligible save requests. Both save preparation and worker catalog loading use an explicitly `@concurrent` snapshot operation with an independently owned database connection. SQLite transactions still serialize catalog reconstruction and repair; the connection and its mutable state do not cross the actor boundary. State publication remains on the main actor.

Workers check cancellation and generation before and after loading, and obsolete workers cannot publish an error. Save preparation uses a token per scope so an older preparation cannot replace a newer request or undo cancellation while awaiting the catalog. The macOS track menu, iOS Now Playing menu, and shared save controls await this operation.

Current-schema database initialization no longer reconstructs the full catalog. Older schemas retain transactional migration; actual snapshot reads retain entry validation, membership repair, and organization validation. Artwork files are compared before writing, including legacy per-entry images, while missing or changed copies are still restored. This is a targeted reduction of read amplification, not a wholesale conversion of persistence to read-only operations.

### Release profiling after the fix

Final recordings used the same dedicated Simulator, catalog, and optimization settings. No build or test suite was running during these recordings.

| Recording | Recording limit | Observed potential hangs |
| --- | ---: | --- |
| `fixed-browse` | 120 s | 356 ms, 281 ms, and 1,145 ms; no severe hangs |
| `fixed-large-artist` | 60 s | 559 ms; no severe hangs |
| `fixed-warm-browse` | 60 s | 306 ms microhang; no severe hangs |

The mixed recording covered album selection and return, artist-list scrolling and selection, and song-list scrolling. The large-artist recording covered opening the 182-track artist, scrolling down twice and back up, and a background/foreground transition. The warm control repeated the artist selection, scrolling, and return. Accessibility-tree changes confirmed that both list types actually scrolled.

The 120 s mixed recording contained no sampled main-thread execution of the save-worker catalog load, `CatalogDatabase.readSnapshot`, or artwork persistence. The previous 2.23–7.30 s storage-dominated stalls were not reproduced. Local display-image loading accounted for only seven sampled CPU milliseconds in that recording.

The remaining intervals contain UIKit/SwiftUI update, layout, and accessibility frames. The 1,145 ms interval contains 132 sampled main-thread CPU milliseconds; the 559 ms interval contains 104; the warm 306 ms interval contains 88. Heavy catalog/storage frames are absent from those intervals. These observations do not establish the root cause of the remaining wall-time delays or prove they are framework defects. The proposed 250 ms target is not fully met. No speculative view rewrite or image cache was added on this evidence.

### Regression checks

Tests use the agreed offline-save and catalog save/load interfaces with real temporary storage and SQLite connections. Regressions were reproduced before the corresponding fixes:

- An empty queue attempted to read an unavailable catalog and published an unrelated save error.
- A pending worker prevented the main actor from releasing a SQLite writer for about 10.6 s.
- Save preparation similarly blocked for about 5.3 s and failed to create the request.
- Opening a current-schema database decoded unrelated entry payloads; snapshot validation still rejects corrupt entries after that eager decode is removed.
- Reading unchanged artwork replaced the existing file. Missing-file restoration remains covered.

After the fixes, the contention checks allow the main actor to release its writer and saves complete. Cancellation during retry preparation remains cancelled after restart. Existing partial-save, retry, cached-audio protection, loopback transfer, migration rollback, membership, and artwork tests continue to pass.

Final full-suite results:

- iOS Simulator: 70 XCTest cases passed, plus two Swift Testing cases.
- macOS: 93 XCTest cases executed, six skipped, zero failures; two additional Swift Testing cases passed. Four skips require a separately built Rust P2P node and two require external deployment/upload configuration.
- Release iOS build and macOS/iOS test compilation succeeded. Existing unrelated Swift concurrency/delegate warnings remain.

### Standards review

No documented-standard violations or actionable code smells remained in the final static review. The review confirmed actor-boundary ownership, token cleanup, and preservation of migration and image-repair behavior. It did not independently run builds, tests, or the UI.

### Spec review

The first review identified a blocking save-start path racing with background reconstruction. Save preparation was made asynchronous and covered by contention and cancellation tests. The final review reported no remaining findings and confirmed that the broader persistence redesign was a recommendation rather than a prerequisite for this measured fix.

Physical-device performance, audible playback, live NAS transfers, and macOS screen interaction were not checked in this change. Main integration, push, and deployment are separate delivery steps.

## Save preparation lifecycle follow-up

A subsequent Swift review reproduced save preparation finishing after the library was closed and restarting the stopped worker. It also identified repeated Save actions starting redundant full-catalog reads before stale tokens were discarded.

Save preparation now owns its snapshot task. Closing or replacing the library cancels preparations and invalidates their tokens. Explicit save cancellation and caller cancellation also cancel the corresponding task. A repeated request for the same scope and track IDs returns without starting another read; a changed selection cancels the superseded preparation. SQL row reads, entry decoding, and artwork persistence check cancellation between items.

Two Swift Testing regressions failed before the fix and pass afterward. One closes the library during a blocked catalog read and checks that no save intent or audio appears after completion. The other repeats Save while the first read is blocked and verifies that the duplicate returns without waiting for another database read, while the original request remains intact.

Full validation passed on both platforms: 70 iOS XCTest cases and four Swift Testing cases; 93 macOS XCTest cases with the same six external-environment skips, plus four Swift Testing cases. This follow-up did not repeat Instruments recording or physical-device and screen-interaction checks. Cancellation is cooperative between storage operations; it does not interrupt an in-progress SQLite busy wait or image decoder call.

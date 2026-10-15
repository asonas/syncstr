# Library browsing performance investigation

Status: implementation, automated verification, isolated macOS interaction checks, and both review axes complete. No installed application or NAS deployment was replaced.

## Finding

Selecting an album or artist performs expensive synchronous library presentation work on the main thread. The largest measured cost is selecting cover artwork for every album, including albums unrelated to the selection.

The inspected source is commit `4666528`. The sampled installed macOS app is build 75. Its exact source revision and matching debug symbols were not available; the release sample establishes main-thread view-update activity, while the isolated source benchmark identifies the expensive operation. These are complementary evidence, not a fully symbolicated release trace.

## Measurements

The live app was sampled at 10 ms intervals during a compilation album selection and an artist selection. The album sample contains 1,601 of 3,918 main-thread samples beneath SwiftUI body evaluation during an accessibility press. Repeated application frames and Swift string comparisons dominate this subtree. The artist sample also contains the same application call-chain addresses during view updates. Network or filesystem waiting did not dominate the observed selection subtrees.

Accessibility observation initially took over three minutes and one later observation timed out. Tool-call durations are not reliable end-to-end selection latency measurements and are excluded from the benchmark results.

An isolated executable compiled with `swiftc -O` used the unmodified `Library.albums` getter extracted from the source, along with the actual `Track`, `AlbumOrganization`, `AlbumMembership`, and `AlbumArtwork` source files. Minimal catalog/entry containers and a SHA-256 utility supplied compile-time dependencies; the real organization lookup methods were not replaced. Parsing, setup, file access, and network transfer were outside the timed sections. The input was an authenticated snapshot of the production NAS catalog. Private input data and raw process samples are not included in this repository.

Input: 1,436 tracks, 1,436 organization records, 359 album groups, 1,417 artwork candidates, and zero listener-choice revisions.

| Operation | Elapsed time |
| --- | ---: |
| Complete album projection, run 1 | 5.059 s |
| Complete album projection, run 2 | 5.063 s |
| Complete album projection, run 3 | 5.066 s |
| Artist credits for all groups | 0.259 s |
| Cover selection for all groups | 4.797 s |

The component measurements are separate invocations, not instrumentation inside a single getter call. Cover selection accounts for approximately 95% of the measured projection cost. The getter returned 359 albums; cover lookup returned 337 nonempty covers. The executable does not measure SwiftUI layout or image decoding, so those could add further cost.

A synthetic scaling check, with ten tracks per album and one artwork candidate per track, measured 0.040 s at 400 tracks, 0.229 s at 800 tracks, and 1.290 s at 1,436 tracks. Real source identifiers, album distribution, and metadata make the production input slower than this synthetic case.

## Why selection triggers this work

- [Library.albums](../../apps/macos/Library.swift) groups and sorts the full track list on every access, and calls `artistCredit` and `coverAsset` for every album. It is a computed property, not a retained projection.
- [The macOS selection views](../../apps/macos/Syncstr.swift) resolve the selected album through `library.albums.first`. Artist detail likewise constructs `library.albums` before filtering to the selected artist. Opening one item therefore pays for every album.
- [AlbumOrganization.artistCredit](../../apps/macos/AlbumOrganization.swift) linearly searches organization records for each member track. Across all albums this produces quadratic record lookup work.
- [AlbumOrganization.artworkCandidates](../../apps/macos/AlbumArtwork.swift) rebuilds the track-record dictionary, calculates candidate heads, and scans all active candidates for each album. Each candidate calls `albumID`, which linearly searches track records. With albums A, candidates C, and records T, this includes work proportional to A × C × T, before sorting and choice-resolution costs.
- `coverAsset` calls `artworkCandidates` twice when candidates exist. Removing that duplicate alone would still leave seconds of work for this catalog.
- Selection, playback position updates, and transfer updates notify the shared observable `Library`. Playback position is published every 250 ms, creating additional opportunities for these getters to run when dependent views reevaluate. The exact number of projections per action was not instrumented.

## Implementation

`AlbumArtworkLookup` resolves record membership once and groups and sorts active candidates by album. The existing candidate order, source priority, manual choices, and preferred-image keys remain in use. `Library` retains albums and artist lookups and rebuilds them when its track projection changes. Both catalog replacement and organization edits replace that projection; selection and playback position do not. macOS selected-album and artist details and the iOS artist entry use the retained lookups.

An optimized source benchmark using the same NAS snapshot rebuilt the projection in 15.7 ms, compared with approximately 5.05 seconds per access before the change. Three subsequent accesses reused the retained array. The encoded output for all 359 albums matched byte for byte, including IDs, titles, artist credits, ordered tracks, and selected covers. The benchmark excludes catalog decoding, persistence, import validation, and SwiftUI rendering; it is not an end-to-end UI latency measurement.

The new public-API regression test uses 200 fictional tracks. Before the fix, its warm browsing loop took 1.080 seconds and failed its 200 ms budget. After the fix, the entire test, including catalog setup and cleanup, took approximately 53 ms. A separate public-API test verifies artwork override and clearing, disc order and individual credits, same-library replacement, artist membership refresh, and removal on library close.

No background projection task was introduced: the measured indexed rebuild is short, and asynchronous publication would add unnecessary stale-result handling.

## Final verification

- The full macOS suite ran 89 tests with zero failures and six skips. A supplementary run with a real Rust P2P executable exercised the previously skipped native cluster, relay, direct-peer, and idle-session recovery paths: eight XCTest cases with zero failures and two external-environment skips, plus the two new Swift Testing cases passing. The remaining skips require a separately supplied upload batch and a deployed rendezvous service.
- The full iOS Simulator suite ran 66 tests with zero failures. After the review-driven conversion of the new tests to Swift Testing, both new cases passed again on macOS and iOS.
- Standards review initially requested Swift Testing for the new file; that change was verified and the finding closed. Spec review found no discrepancies. Both axes finished with zero unresolved findings.
- A separately signed macOS validation app used the actual modified `LibraryView` and shared library sources, a NAS catalog snapshot, isolated storage, and separate pairing services. Its executable path and bundle identity were checked before interaction. Compilation detail showed 20 tracks; two artist selections showed their expected album and track lists, including artwork. Accessibility observations completed without the earlier timeout.
- Post-change main-thread samples were predominantly idle: 1,777 of 1,805 samples for the album/search interaction and 1,343 of 1,360 for the final artist interaction were in the event-loop wait path. The sampled interaction paths did not show the earlier repeated artwork lookup or album rebuild. Tool timing includes automation overhead; an end-to-end UI p95 below 100 ms has not been established.
- The usual installed app was restarted after validation. No physical iPhone interaction, distribution build, main integration, push, or NAS deployment was performed for this change.

## Original implementation proposal

1. **Build the effective lookup tables once per catalog revision.** Resolve canonical track and album identities and listener choices once, index organization records by track ID, calculate active artwork heads once, and group candidates by effective album ID. Preserve candidate ordering, source priority, both preferred-image keys, and manual artwork overrides. Do not change the retained organization or provenance to gain speed.
2. **Retain the presentation projection.** Build the sorted albums, album-by-ID lookup, and artist membership lookup when tracks, organization, or artwork evidence changes. Selection, search, playback position, volume, and transfer progress must not invalidate the underlying album projection. Search should filter the retained data. Selected album and artist views should use direct lookups.
3. **Measure projection rebuilding after indexing.** If rebuilding still blocks interaction, build from a consistent immutable snapshot away from the main actor and publish the completed result. Discard stale results when a newer catalog arrives. Do not introduce asynchronous selection races or background work merely to hide repeated full-library work.

The first two changes belong in the shared library/presentation layer, which also serves iOS. The macOS and iOS selection entry points must both be checked. No data schema migration, NAS deployment, or compilation regrouping is needed for this presentation fix.

## Verification for implementation

- Compare all 359 projected albums against the current implementation: canonical IDs, titles, artist credits, disc/track ordering, membership, and cover selection must match.
- Use the existing membership/artwork fixtures for manual overrides, automatic aliases, conflicting evidence, superseded candidate heads, source priority, and both forms of preferred image keys. Add focused coverage only for cache invalidation and behavior not already protected.
- Verify that catalog updates and artwork changes refresh the projection, while selection and playback progress reuse it.
- Repeat album and artist selections in the installed target build with a main-thread trace. Target warm selection latency below 100 ms at the 95th percentile on the measured catalog; this is a proposed acceptance target, not an achieved result.
- Check during playback and offline, then exercise a larger fictional catalog to detect scaling regressions. Verify the shared result on iOS separately; no iPhone performance measurement was performed in this investigation.

## Boundaries

The live installed macOS app was inspected without replacing or restarting it during diagnosis. The NAS was queried for catalog data but was not redeployed or repaired. The exact contents of the app's sandboxed catalog were not read, so the NAS benchmark input must not be described as a verified copy of the app's complete retained state. Implementation and automated tests use an isolated worktree and temporary data.

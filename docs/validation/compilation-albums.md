# Compilation album verification

This record covers the local implementation of the [approved specification](../compilation-implementation-spec.md). No production catalog, source audio, distribution build, or deployment was changed during verification.

## Automated checks

- Shared native model tests exercise edition grouping, imported classification disagreements, concrete artist credits, reversible membership and classification choices, concurrent revisions, former album references, unavailable tracks, exact-content recovery, and long revision histories. Invalid reference cycles are rejected.
- MP3, FLAC, and M4A fixtures exercise the pinned AudioTags dependency with album artist, compilation, and MusicBrainz release fields. Fixture copies are modified; originals remain unchanged.
- Native catalog and transfer tests exercise legacy migration, persistence, real TLS transfer, retained audio with refreshed organization, conflicting peer choices, unavailable source recovery, and idle-session retry.
- Swift-to-Rust transfer tests exercise upload, retry, download, and restart with the shared organization wire representation.
- Rust tests exercise the shared fixture, transactional persistence, invalid-update rollback, exact-content identity aliases, edition reconciliation, and concurrent choices. `cargo test` and `cargo clippy --all-targets -- -D warnings` pass.
- macOS and iPhone Simulator tests build the production targets and exercise their shared native model and catalog tests. The final macOS run executes 29 tests with two platform-dependent skips and no failures; the iPhone Simulator run executes 16 tests with no failures.
- `LibraryCheck` exercises a real AVPlayer: saving album organization keeps the current track, active playback, and existing queue. Pause, resume, seek, shuffle, repeat, and queue restoration checks also pass.

## Native interaction checks

Dedicated fixture applications compile the production `Library` and `OrganizationView` with separate bundle identities and catalogs. The normal application and its catalog remain untouched.

On macOS, cancellation discards a pending conflict resolution; selecting an incoming classification resolves the displayed conflict; accepting a membership proposal produces one album with both tracks; saving displays the actual participating artist credits. Restart preserves the grouping. Clearing the classification override preserves membership. The native sheet remains usable at its minimum width.

On an iPhone Simulator, the same sheet displays imported evidence, conflict controls, and membership proposals. Selecting an incoming classification and accepting the proposal updates both tracks to the same album, with readable native controls and wrapping. This checks the shared sheet in a fixture application, not every production navigation route.

## Compatibility and limits

- Catalog schema 2 and transfer message version 2 are required. Older peers receive a compatibility error and need updating; the existing ALPN name is retained. Headless HTTP clients use `/v2`; `/v1` returns HTTP 426.
- MusicBrainz release UUIDs are the supported imported external edition identifiers. Release-group and recording identifiers do not establish edition membership.
- Native imports and uploads decode the supported embedded tags. The headless CLI upload does not extract these additional embedded fields itself; it retains organization supplied by native peers or the organization API.
- Physical iPhone behavior, accessibility at every Dynamic Type size, every production menu route, distribution signing, and deployed interoperability have not been verified by these local checks.
- Source files whose identity cannot be proven require explicit reassociation. Similar titles or a reused path do not automatically inherit earlier user choices.

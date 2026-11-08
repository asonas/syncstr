# Shared Rust catalog

`syncstr_headless::catalog_client` provides a read-only catalog boundary for the
Windows and Android client work. It reuses authenticated v5 sessions and signed
playlist contracts. Catalog refresh sends no legacy writes and does not migrate
an installed application's profile. The client also provides separately described
[verified audio and offline-save operations](shared-rust-audio.md).

## Ownership and calls

Open an already enrolled, disposable profile with `Client::open`. Enrollment stays
with the existing enrollment flow. Opening reads the membership registration and
restores `catalog-client.sqlite` without loading, creating, or requesting a private
identity key. The cache and existing stores share the exclusive `node.lock`.

Call `catalog()` to obtain owned domain records. Supply the platform secure-store
key only to `refresh(&host, secret, &operation)`. The key must match the enrolled
member. The refresh requests only a v5 catalog from an authenticated host. Transport
types, wire JSON, signed payloads, and SQLite connections remain inside the module.

The Rust owner must run open and refresh on its application worker using its
retained Tokio runtime. Exclusive `&mut Client` access serializes refreshes and
cache commits. A cloned `Operation` cancels an in-flight refresh without committing
its response. Await completion or cancellation before calling the idempotent
`shutdown().await`, which drains transfers and the writer, waits for active audio
handles, and releases the database and profile lock. Dropping an operation
handle does not cancel it.

This is the direct Rust boundary. Kotlin bindings, the foreign-language runtime
owner, and app lifecycle wiring belong to the subsequent app integration. The
ASO-68 synthetic binding experiment is not a production catalog binding.

## Retained state

The cache stores the snapshot, membership proof, and incomplete-refresh notice in
one SQLite row. A successful update atomically replaces that row. Proofs retained
by refresh are combined with enrollment records on reopening so an older
enrollment database cannot discard known revocations.

Identity, membership, catalog version, library, and baseline mismatches fail without
replacing the verified view. Complete snapshots must preserve previously accepted
track IDs, aliases, and historical pins. An unknown-scope incomplete snapshot
retains the previous verified snapshot and persists the unresolved record IDs.
The first incomplete refresh exposes an empty catalog with that notice. A complete
verified refresh clears it.

Tracks are keyed by logical identity, never by audio hash. Aliases resolve at read
time. Artist, album artist, compilation values, imported tags, release evidence,
album editions, organization choices, and visibility remain distinct.
Artwork assets and their candidate/preference graph are projected as domain
records. Empty image references are omitted from the display graph while the raw
snapshot remains retained, matching the Apple projection's handling.

Playlist records are signature-checked and projected with the existing Rust contract;
received snapshots must match that projection. Ordered occurrences retain their
original track ID/hash pair, even when the current preferred hash changes.
`exact_track` resolves only a recorded pin. `audio_bytes` reports availability
without substituting another track or hash; retired or conflicted tracks remain
unavailable while unrelated tracks remain readable.

## Verification

Run on Windows or another supported Rust host:

```powershell
cargo test --manifest-path headless/Cargo.toml --features p2p --test catalog_client
```

The tests create disposable enrolled profiles and loopback QUIC endpoints. One
uses the production v5 server. A scripted authenticated host exercises invalid
and incomplete responses without changing production server behavior. Synthetic
cases follow the identity, alias, preferred-hash, exact-pin, scoped-conflict, and
incomplete-refresh cases in
[`SharedAudioTests.swift`](../apps/macos/Tests/SharedAudioTests.swift), adding signed
playlist history and credential-free Rust reopen checks.
The existing [`album-artwork.json`](../headless/fixtures/album-artwork.json) fixture
is exercised through the public API with both JPEG bytes and empty references.

### Windows result, 2026-11-08

Started from `origin/main` at `55e2343` with Rust/Cargo 1.99.1.
Rebased onto `2ab58bc` before publication and repeated the focused checks below.
The headless CI regression step includes the catalog integration suite.

| Check | Result |
| --- | --- |
| Public catalog API, authenticated v5 host and scripted responses | 4 passed |
| Existing `cluster_client` tests | 3 passed |
| Existing signed `playlists` tests | 3 passed |
| Clippy for the library and catalog integration test, `-D warnings` | Passed |
| rustfmt for added Rust files and `git diff --check` | Passed |

Verified pre-request and in-flight cancellation, idempotent shutdown and lock
release, unsigned playlist-view substitution rejection, mismatch preservation,
incomplete-notice recovery, and cache restoration after the host stops. No real
application profile or audio library was used.

Native Apple execution, Android ARM64 packaging, Kotlin bindings, application UI,
and production-profile migration are not covered by these catalog tests. See the
[ASO-71 audio implementation and verification](shared-rust-audio.md) for acquisition
and offline-save jobs.

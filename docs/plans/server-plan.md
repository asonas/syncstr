# Music Player Server Implementation Plan

**Goal:** Build the NAS-authoritative server with SyncService as the only synchronization source of truth.

**Architecture:** Navidrome remains an optional media/stream adapter; it never owns product history or conflicts. SQLite transactions own `operation_id` deduplication and `server_seq` assignment. HTTP `/v1` is documented in OpenAPI.

**Dependencies:** design spec; sync vectors; Navidrome report (authenticated probes BLOCKED); Rust shared core is rejected because FFI, release, and fault-surface evidence is absent.

## Boundaries

| Module | API / DB boundary | Acceptance evidence |
| --- | --- | --- |
| AuthService | passkeys, devices, refresh_tokens | passkey registration, revocation, rate-limit tests |
| LibraryScanner / CatalogService | tracks, metadata, sidecars, search index | stable-file, missing-file, duplicate-candidate tests |
| MediaService | `GET /v1/tracks/{id}/stream` | Range, SHA-256, original-first tests |
| SyncService / ProjectionUpdater | sync_operations, cursors, projections | shared JSON vector conformance and snapshot tests |
| TrashService / BackupService | trash records, backup manifest | restore and irreversible-delete authorization tests |

## Implementation order

1. Create SQLite migrations, transaction helper, and migration rollback/forward tests.
2. Implement AuthService with passkeys as default, device tokens, revocation, and audit events; publish OpenAPI authentication paths.
3. Implement scanner, metadata/sidecar boundary, catalog/search, and missing-file state without deleting history.
4. Implement MediaService original Range streaming; add compatibility-copy/server-transcode only after a client reports a native format failure.
5. Implement SyncService in the server language from the machine-readable vector contract: operation uniqueness, device counter, server sequence, tombstones, snapshots, and ProjectionUpdater.
6. Add Navidrome adapter only for scanner/stream comparison behind an interface; do not route sync, ratings, or play event truth through it.
7. Add trash, backup/restore, OpenAPI contract tests, and end-to-end Docker tests.

## Test cycles and acceptance

- Each migration, service endpoint, and projection change starts with a failing unit/integration test.
- `/v1/sync` must pass all shared vectors and preserve server-sequence ordering under retry.
- Media Range response, content hash, missing-file, and authenticated access are integration-tested.
- Backup restores DB, events, settings, sidecars, and does not silently restore deleted media.
- Publish a versioned OpenAPI diff; no endpoint crosses module DB tables directly.

## Risks / decisions

- Authenticated Navidrome API/media results are unmeasured: treat its adapter capability as BLOCKED until a disposable credential run passes.
- Rust core is not a dependency; reconsider only after measured FFI, packaging, cancellation, and reduced fault surface.
- Transcoding policy, retention capacity, and server implementation language remain decisions after original-stream evidence.

# syncstr Implementation Plan

This document preserves the initial long-term plan. For current app development, start with the [README](../../README.md#code-and-documentation-map). Apply these tasks only when explicitly resuming this plan. Paths below describe the planned layout at the time; they are not a map of the current checkout.

**Goal:** Implement the NAS-authoritative syncstr server, migration, and macOS/iPhone clients in independent test cycles.

**Tech Stack:** Rust + Axum is the leading server candidate; compare minimal Go and TypeScript implementations in Task 1 before deciding. Use SQLite, OpenAPI v1, Docker Compose, Swift and SwiftUI for macOS/iPhone, C# and WinUI 3 for Windows, and Kotlin and Jetpack Compose for Android. Server filenames in this plan assume Rust + Axum. If another candidate is selected, update the ADR and planned paths before Task 2.

**Spec:** [Design specification](../design-spec.md)

## Global Constraints

- The NAS server is authoritative for the library, metadata, playlists, ratings, and history.
- Initial migration covers only DRM-free local audio and iTunes or Music XML.
- Register MP3, AAC, M4A, ALAC, WAV, and AIFF without modifying original audio.
- Store WAV and AIFF metadata in the database and sidecars, and compare original SHA-256 hashes before and after migration.
- Offline operations carry `operation_id`, `device_id`, `device_counter`, and `server_seq`.
- Use passkeys by default and implement device revocation, recovery, rate limits, and audit logs.
- Start with macOS and iPhone. Mark Windows and Android as supported only after they pass the same OpenAPI and synchronization vectors.
- Do not turn BLOCKED Apple results caused by unavailable XCTest or a disconnected physical iPhone into PASS.

---

### Task 1: Establish the Repository Foundation and Select a Server Runtime

**Files:**

- Create: docs/decisions/ADR-0001-server-runtime.md
- Create: .gitignore
- Create: LICENSE
- Create: server/README.md
- Create: server/Cargo.toml
- Create: server/src/main.rs
- Create: infra/compose.yaml
- Test: scripts/check-foundation.sh

**Interfaces:**

- Consumes: docs/design-spec.md, docs/decisions.md, docs/validation/sync-core-report.md
- Produces: A server runtime decision, Docker startup contract, and a foundation that excludes secrets from commits

- [ ] **Step 1: Capture server comparison criteria in tests**

Use `scripts/check-foundation.sh` to verify that Docker Compose uses a defined internal network and does not mount validation credentials or audio into production images.

- [ ] **Step 2: Compare Rust with alternative server implementations**

Implement identical minimal healthz, SQLite connection, and container startup behavior for each candidate. Record startup time, image size, build time, and error classification.

- [ ] **Step 3: Record selection and rejection reasons in an ADR**

Record the selected language, web framework, SQLite driver, asynchronous runtime, and minimum supported OS in `ADR-0001-server-runtime.md`.

- [ ] **Step 4: Run foundation checks**

Run: `sh scripts/check-foundation.sh`

Expected: Secret detection, Compose configuration, healthz responses, and runtime version checks pass.

- [ ] **Step 5: Commit**

~~~sh
git add .gitignore LICENSE server infra scripts docs/decisions/ADR-0001-server-runtime.md
git commit -m "Establish syncstr server foundation"
~~~

### Task 2: Define OpenAPI and Synchronization Contracts

**Files:**

- Create: contracts/openapi/openapi.yaml
- Create: contracts/sync/schema.json
- Create: contracts/sync/vectors/convergence-basic.json
- Create: contracts/sync/vectors/convergence-conflicts.json
- Create: contracts/sync/vectors/history-events.json
- Create: contracts/sync/vectors/rejections/device-counter-regression.json
- Create: contracts/sync/vectors/rejections/unknown-operation.json
- Create: contracts/sync/vectors/rejections/missing-required-field.json
- Create: contracts/sync/vectors/rejections/missing-server-seq.json
- Test: contracts/tests/contract_test.py
- Create: scripts/contract-test

**Interfaces:**

- Consumes: The seven vectors established during validation and docs/design-spec.md
- Produces: Types for /v1/auth, /v1/catalog, /v1/media, /v1/sync, and /v1/backups, plus synchronization conformance tests

- [ ] **Step 1: Move existing vectors into the contract paths and validate with JSON Schema**

Require `operation_id`, `device_id`, `device_counter`, `server_seq`, `entity_type`, `entity_id`, `operation_type`, and `payload`. Reject unknown operations and invalid payloads.

- [ ] **Step 2: Define the OpenAPI error format**

Normalize authentication failures, insufficient permissions, conflicts, invalid cursors, missing media, and invalid ranges into JSON containing `code`, `message`, `request_id`, and any required `details`.

- [ ] **Step 3: Run failing tests first**

Run: `scripts/contract-test`

Expected: Tests fail for missing required fields, missing `server_seq`, unknown operations, duplicate retries, malformed JSON, and incompatible API changes.

- [ ] **Step 4: Validate OpenAPI and vectors**

Run: `scripts/contract-test`

Expected: All vectors load, and OpenAPI schema references and error codes agree.

- [ ] **Step 5: Commit**

~~~sh
git add contracts scripts/contract-test
git commit -m "Define syncstr service contracts"
~~~

### Task 3: Implement Authentication, the Catalog, and Media Delivery

**Files:**

- Create: server/src/auth.rs
- Create: server/src/catalog.rs
- Create: server/src/media.rs
- Create: server/migrations/
- Test: server/tests/auth_tests.rs
- Test: server/tests/catalog_tests.rs
- Test: server/tests/media_tests.rs

**Interfaces:**

- Consumes: contracts/openapi/openapi.yaml, contracts/sync/schema.json
- Produces: Passkey registration, device revocation, a scanned catalog, and GET /v1/tracks/{id}/stream

- [ ] **Step 1: Create SQLite migrations and authentication failure tests**

Create `devices`, `passkey_credentials`, `refresh_tokens`, `audit_events`, `tracks`, and `metadata_values`. Reject expired, revoked, and other-device tokens.

- [ ] **Step 2: Implement passkey registration and device revocation**

Implement registration challenges, verification, token refresh, device listing, and revocation. Never log private keys or challenges.

- [ ] **Step 3: Scan stable files and represent missing audio**

Skip temporary files. Extract hashes, formats, durations, and tags only after size and mtime stabilize. Mark external deletions as missing without removing history or playlists.

- [ ] **Step 4: Implement original-audio-first Range delivery**

Test `206 Partial Content`, `Content-Range`, `Content-Length`, SHA-256 verification, authentication, and revoked URLs. Do not transcode until a device reports playback failure.

- [ ] **Step 5: Commit**

~~~sh
git add server
git commit -m "Implement syncstr auth catalog and media boundaries"
~~~

### Task 4: Implement iTunes or Music XML Migration

**Files:**

- Create: server/src/migration/xml_reader.rs
- Create: server/src/migration/inventory.rs
- Create: server/src/migration/matcher.rs
- Create: server/src/migration/report.rs
- Create: server/tests/fixtures/migration/
- Test: server/tests/migration_tests.rs

**Interfaces:**

- Consumes: XML, audio in the import area, and migration staging tables for tracks and metadata
- Produces: Candidates, pending confirmations, finalized rows, failure reports, and WAV/AIFF sidecars

- [ ] **Step 1: Write XML and audio read-failure tests**

Create fixtures for XML without audio, missing paths, multiple candidates, DRM, cloud-only tracks, WAV, AIFF, playlist order, and malformed XML.

- [ ] **Step 2: Implement a non-destructive inventory**

Compare audio SHA-256 hashes, sizes, and durations before and after migration. Fail tests if files are moved, deleted, or overwritten.

- [ ] **Step 3: Implement deterministic matching and pending confirmation**

Narrow candidates by exact path, size, duration, and hash in that order. Never automatically finalize multiple candidates.

- [ ] **Step 4: Import metadata, ratings, history, and playlists after confirmation**

Pass tag-writable formats to `MetadataStore`. Store WAV, AIFF, and failed tag writes in sidecars.

- [ ] **Step 5: Commit**

~~~sh
git add server/src/migration server/tests/fixtures/migration server/tests/migration_tests.rs
git commit -m "Add non-destructive music library migration"
~~~

### Task 5: Implement SyncService and ProjectionUpdater

**Files:**

- Create: server/src/sync.rs
- Create: server/src/projections.rs
- Create: server/migrations/0005_sync_operations.sql
- Test: server/tests/sync_tests.rs
- Create: scripts/sync-conformance-test

**Interfaces:**

- Consumes: /v1/sync operation batches and the seven vectors from Task 2
- Produces: POST /v1/sync, cursor retrieval, snapshots, history aggregates, and playlist tombstones

- [ ] **Step 1: Create failure tests**

Test unknown operations, missing required fields, missing `server_seq`, regressing `device_counter`, repeated `operation_id`, and conflicting playlist moves and deletions.

- [ ] **Step 2: Implement operation uniqueness and acceptance order**

Deduplicate `operation_id` through a SQLite uniqueness constraint. Assign `server_seq` in a single transaction before handing operations to `ProjectionUpdater`.

- [ ] **Step 3: Implement scalar, playlist, and history projections**

Apply favorites, ratings, item-ID-based additions, moves, and deletions, plus playback start, progress, completion, and skip events in `server_seq` order.

- [ ] **Step 4: Implement snapshots, cursors, and tombstone compaction**

Return snapshots to long-disconnected devices. Retain tombstones for 90 days and satisfy acknowledgment requirements for all devices before compaction.

- [ ] **Step 5: Run shared vectors**

Run: `scripts/sync-conformance-test`

Expected: The Swift reference, Rust candidate, and server normalize successful states, history, and rejection errors to identical JSON.

- [ ] **Step 6: Commit**

~~~sh
git add server/src/sync.rs server/src/projections.rs server/migrations/0005_sync_operations.sql server/tests/sync_tests.rs
git commit -m "Implement syncstr server synchronization"
~~~

### Task 6: Implement Native macOS and iPhone Clients

**Files:**

- Create: clients/apple/SyncstrApp/
- Create: clients/apple/SyncstrCore/
- Create: clients/apple/SyncstrTests/
- Modify: docs/validation/apple-playback-report.md
- Test: clients/apple/SyncstrTests/

**Interfaces:**

- Consumes: OpenAPI, synchronization vectors, and the PlaybackProbe case contract
- Produces: A SwiftUI catalog, SQLite local store, Keychain credentials, offline operations, and AVFoundation playback

- [ ] **Step 1: Write local database and Keychain failure tests**

Persist pending operations, cursors, download state, and device credentials. Verify that forced app termination does not lose operations awaiting retry.

- [ ] **Step 2: Implement the OpenAPI client and SyncClient**

Verify batch retries, exponential backoff, duplicate responses, snapshot restoration, authentication refresh, and device revocation with shared vectors.

- [ ] **Step 3: Implement the SwiftUI catalog, playlists, and settings**

Verify VoiceOver, Dynamic Type, keyboard interaction, focus order, empty states, and error retries through accessibility identifiers.

- [ ] **Step 4: Implement downloads and original-audio-first playback**

Implement Range resume, partial-file isolation, SHA-256 verification, storage quotas, and protection of explicit downloads.

- [ ] **Step 5: Validate playback on Apple hardware**

Save JSON for the same 11 cases on macOS and iPhone. Judge gapless playback, background playback, media keys, and HTTPS Range from physical-device results.

- [ ] **Step 6: Commit**

~~~sh
git add clients/apple docs/validation/apple-playback-report.md
git commit -m "Build syncstr Apple clients"
~~~

### Task 7: Implement Operations, Backups, and Trash

**Files:**

- Create: infra/compose.yaml
- Create: infra/reverse-proxy/
- Create: ops/backup/
- Create: ops/runbooks/
- Test: ops/tests/

**Interfaces:**

- Consumes: AuthService, CatalogService, SyncService, TrashService, BackupService
- Produces: An HTTPS frontend, health checks, encrypted backups, restoration procedures, audit logs, and an open-source license audit

- [ ] **Step 1: Create production Compose configuration and checks**

- [ ] **Step 2: Implement HTTPS, rate limits, and audit logs**

Expose only HTTPS publicly, restrict administrative endpoints to the internal network, and exclude credentials from logs.

- [ ] **Step 3: Implement backups and isolated restoration**

Encrypt backup manifests covering the database, events, sidecars, configuration, and audio inventory. Restore in a separate environment and verify hashes and cursors.

- [ ] **Step 4: Implement trash, tombstone retention, and event compaction**

Record enforcement of the 90-day rule, device revocation, reauthentication for permanent deletion, and restoration operations in the audit log.

- [ ] **Step 5: Commit**

~~~sh
git add infra ops
git commit -m "Add syncstr operations and recovery"
~~~

### Task 8: Validate MVP Acceptance and Daily Use

**Files:**

- Create: docs/acceptance/mvp-checklist.md
- Create: docs/acceptance/failure-log.md
- Modify: docs/design-spec.md
- Create: scripts/mvp-test

**Interfaces:**

- Consumes: All server, macOS, iPhone, migration, and operations deliverables
- Produces: Four weeks of daily-use results, failure records, and a Windows/Android readiness decision

- [ ] **Step 1: Define NAS downtime, network switching, app termination, and duplicate retry scenarios**

For each scenario, record whether playback, pending operations, recovered `server_seq`, and history duplication match expected results.

- [ ] **Step 2: Verify non-destructive migration and restoration**

Compare audio SHA-256 hashes before and after XML migration, WAV/AIFF sidecars, and playlists and history after backup restoration.

- [ ] **Step 3: Assess unresolved macOS/iPhone BLOCKED results**

Do not mark unavailable XCTest, disconnected physical iPhone checks, gapless playback, media keys, or HTTPS Range as passing without measured evidence.

- [ ] **Step 4: Verify prerequisites for Windows and Android**

Start conforming implementations only after shared contracts for OpenAPI, synchronization vectors, media formats, authentication, and offline operations are settled.

- [ ] **Step 5: Commit**

~~~sh
git add docs/acceptance docs/design-spec.md scripts/mvp-test
git commit -m "Define syncstr MVP acceptance"
~~~

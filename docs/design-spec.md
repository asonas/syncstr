# Personal Cross-Platform Music Player Design Specification

Created: 2026-08-14

Scope: long-term design and initial validation records. See the [README](../README.md#current-implementation) for the current implementation.

Intended audience: initially a single user, with a future open-source release.

## Overview

This system is a personal music player for playing local audio stored on a NAS from macOS, Windows, iPhone, and Android.

The NAS holds the authoritative library, metadata, playlists, ratings, and playback history. Each device stores the audio it needs for offline playback.

An existing iTunes or Music library is input to the initial migration. There is no ongoing bidirectional synchronization with Apple's applications after migration.

An iTunes or Music XML export contains track information and playlists but no audio files. Import the XML and audio separately and match them. Cloud-only Apple Music tracks and DRM-protected audio are out of scope.

## Design Principles

- **UI state:** Follow the platform guidance in [DESIGN.md](../DESIGN.md).
- **NAS authority:** The server owns library state; devices hold caches and originate operations.
- **Original audio first:** Store and serve original audio. Generate a compatibility copy only when a device cannot play the original.
- **Prevent lost operations:** Record each offline operation uniquely and avoid applying retries more than once.
- **Eventual convergence:** All devices converge to the same state after synchronization, even when they operate independently.
- **Native implementation:** Share information architecture and design, while using each OS's APIs for UI code, audio playback, background execution, and system integration.
- **Portability:** Use Docker Compose as the standard server distribution and evaluate a single-binary distribution.
- **Recoverability:** Restore the database, history events, sidecars, and configuration as well as audio.

## Terminology

- **Library:** The audio and metadata managed by the server.
- **Track:** An internal entity representing one registered audio file. Separate files with identical content, different mixes, different masters, and different formats are separate tracks.
- **Audio file:** An original audio file stored in the NAS media area.
- **Sidecar:** A supplementary metadata file used when metadata cannot be written into the audio file's tags.
- **Operation event:** A unique event issued by a device or server to represent a state change.
- **Authoritative state:** The current state produced by applying operation events on the server.
- **Device cache:** Audio, metadata, and operation events retained on a device for offline use.

## Scope

### Included Features

- Initial migration of DRM-free local audio
- Registration and playback of MP3, AAC, M4A, ALAC, WAV, and AIFF
- An audio decoder boundary that allows additional formats
- Management of title, artist, album, album artist, genre, year, disc number, track number, composer, comments, and artwork
- Tag writing for audio that supports tags
- Database and sidecar storage for audio that cannot accept tags
- Browsing albums, artists, tracks, playlists, favorites, and history
- Full-text search and metadata filtering
- Normal playback, queues, gapless playback, and volume normalization
- Original-audio streaming and offline downloads
- Automatic downloads for selected playlists and favorites
- History events for playback start, a progress threshold, completion, and skipping
- Offline edits to ratings, favorites, and playlists
- Operation retries, deduplication, and conflict resolution
- Remote access over HTTPS
- Passkey authentication and per-device credential revocation
- Adding and scanning NAS audio, detecting missing files, and identifying potential duplicates
- Audio deletion through a trash area
- Backup and recovery of the database, history, configuration, and sidecars
- Native macOS and iPhone applications as the initial vertical slice
- Subsequent native Windows and Android clients conforming to the same contracts

### Excluded Features

- Ongoing bidirectional synchronization with Apple Music or iTunes
- Cloud-only Apple Music tracks
- Playback of DRM-protected audio in a general-purpose player
- Subscription streaming service integration
- Casting to external devices through Chromecast, AirPlay, or similar protocols
- Lyrics
- Recommendations
- Smart playlists
- EQ
- Exclusive output and automatic sample-rate switching
- External scrobbling to Last.fm, ListenBrainz, or similar services
- Multi-user roles
- A web player

## Usage Scenarios

### Initial Migration

1. The user exports XML from Music or iTunes.
2. The user copies audio into the NAS import area.
3. The server reads the XML and audio files, then produces candidates using paths, filenames, sizes, and durations.
4. Tracks with a unique match are registered; tracks with multiple candidates await confirmation.
5. Available playlists, ratings, play counts, and last-played timestamps from the XML become initial values.
6. The migration report records DRM-protected tracks, cloud-only tracks, and unmatched tracks.
7. Import does not move or delete audio. The user reviews the results before finalizing the library.

### Audio Scanning

1. The server starts scans from watched folders or manual requests.
2. Scanning skips files in a transient state and extracts metadata and audio information only after they stabilize.
3. Store the content SHA-256, size, format, duration, sample rate, and channel count.
4. Present path changes as candidates matched by identical content hashes.
5. Do not automatically merge identical content or similar metadata. Keep separate tracks or request user review.
6. Mark externally deleted files as missing without immediately removing their history or playlist entries.

### Playback

1. The client fetches metadata and a playback URL.
2. Prefer a complete local audio file if one is available.
3. Otherwise, stream the original over HTTPS.
4. Request a compatibility copy if the device cannot handle the original format.
5. Integrate the playback engine with OS media sessions, background playback, media keys, and notifications.
6. Provide gapless playback.
7. Apply volume normalization in the playback path without modifying the original file.
8. Persist playback operations locally and send history events when connectivity returns.

### Offline Playback and Downloads

1. Users can explicitly download tracks, albums, playlists, and favorites.
2. Automatic downloads cover favorites and selected playlists.
3. Manage automatic caches within a user-defined quota. Never automatically remove explicit downloads.
4. Resume downloads with HTTP Range and verify SHA-256 after completion.
5. Do not expose partial files in the library before verification.
6. Reject operations that would reduce available storage below the safety limit.
7. Store files in app-private storage by default. Copy them to shared storage only on an explicit export request.

### Synchronization

1. The client persists each operation with a unique `operation_id`, a per-device counter, and a device ID.
2. The client batches pending operations for the server.
3. The server deduplicates through an `operation_id` uniqueness constraint and assigns `server_seq` in acceptance order.
4. The server applies operations to authoritative state and returns results and the next synchronization cursor.
5. Clients fetch operations after their cursor and apply the same operations locally.
6. Keep pending operations after failures and retry with exponential backoff.
7. Devices offline beyond the incremental retention window fetch a complete snapshot.

### Playlist Conflicts

Record playlist additions, deletions, and moves as operations on item IDs rather than entire arrays.

The server applies accepted operations in `server_seq` order. When an item has multiple moves, the last accepted move determines its final position.

Retain deleted items as tombstones so retries from stale devices cannot resurrect them. Keep tombstones for 90 days even after all devices acknowledge synchronization, then compact them into a snapshot.

## Architecture

### Server

The server is responsible for:

- Library scanning, metadata extraction, migration, and duplicate candidate detection
- Authoritative database access and search index updates
- Range delivery of original audio and compatibility-copy generation
- Synchronization acceptance, deduplication, conflict resolution, and cursor management
- Passkey registration, authentication, device management, and credential revocation
- Administrative audio deletion, trash, backup, and restoration
- Health checks, audit logs, and configuration

Logical modules have the following responsibilities:

- `AuthService`: Passkey challenges and verification, device registration, token refresh, and revocation.
- `LibraryScanner`: Watched-folder scanning, file stabilization, hashing, and missing-file detection.
- `LibraryImporter`: Matching iTunes or Music XML to audio, pending confirmations, and migration results.
- `MetadataStore`: Database, tag, and sidecar access and inconsistencies between them.
- `CatalogService`: Tracks, albums, artists, and search indexes.
- `MediaService`: Original-audio Range delivery, signed URLs, and compatibility copies.
- `SyncService`: Operation acceptance, deduplication, `server_seq` allocation, cursors, and snapshots.
- `ProjectionUpdater`: Applying operations to authoritative state, history aggregates, and search indexes.
- `TrashService`: Deletion, trash, restoration, and permanent erasure.
- `BackupService`: Consistent backup and restoration of the database, configuration, and history.
- `AuditLog`: Authentication changes, administrative actions, and destructive operations.

Expose an HTTP JSON API documented in OpenAPI. Use `/v1` in URLs and isolate breaking changes in a new major version.

Use SQLite with WAL mode and migration history. Even if multiple server processes become necessary, guarantee operation uniqueness and `server_seq` allocation in a single database transaction.

### Clients

Divide each client into these layers:

- **UI:** Native screens, navigation, accessibility, and keyboard interaction.
- **Application:** Library browsing, playback control, downloads, synchronization, and settings.
- **Local data:** SQLite persistence for metadata, caches, pending operations, and synchronization cursors.
- **OS integration:** Audio sessions, background tasks, notifications, media keys, and credential storage.
- **Networking:** OpenAPI requests, authentication refresh, retries, and Range retrieval.

The initial clients target macOS and iPhone. Use Swift and SwiftUI, with AppKit or UIKit where needed. Use C# and WinUI 3 for Windows and Kotlin and Jetpack Compose for Android.

Define shared information architecture, design principles, colors, typography, and component states in Figma. Follow each OS's conventions for back navigation, menus, sharing, windows, keyboards, and background execution.

### Shared Synchronization Core

Maintain state-transition specifications, machine-readable test vectors, failure scenarios, and conformance tests as shared assets so clients do not interpret synchronization rules independently.

Compare a Rust shared core with a Swift-only implementation against these criteria:

- Both can implement the same synchronization scenarios as state machines.
- Per-device counters, `operation_id`, `server_seq`, retries, and deduplication converge to identical results.
- The Swift, Kotlin, and C# FFI boundaries safely handle errors, cancellation, threads, and asynchronous work.
- Binary distribution, debugging, crash analysis, build time, and size remain acceptable on each OS.
- Adopting Rust reduces the test scope and failure surface compared with separate implementations.

Move the synchronization state machine and conflict resolution into a shared core only if Rust meets these conditions. Keep networking, local databases, file operations, audio playback, and OS lifecycle handling outside it.

## Data Model

The following DDL is a logical schema. Adapt its types to the selected database during implementation.

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

CREATE TABLE passkeys (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  credential_id BLOB NOT NULL UNIQUE,
  public_key BLOB NOT NULL,
  sign_count INTEGER NOT NULL DEFAULT 0,
  label TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE refresh_tokens (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  token_hash BLOB NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE tracks (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  file_size INTEGER NOT NULL,
  content_hash BLOB NOT NULL,
  format TEXT NOT NULL,
  codec TEXT NOT NULL,
  duration_ms INTEGER NOT NULL,
  sample_rate INTEGER,
  channels INTEGER,
  bitrate INTEGER,
  title TEXT,
  album TEXT,
  album_artist TEXT,
  artist TEXT,
  genre TEXT,
  year INTEGER,
  disc_number INTEGER,
  disc_total INTEGER,
  track_number INTEGER,
  track_total INTEGER,
  composer TEXT,
  comment TEXT,
  artwork_hash BLOB,
  sidecar_path TEXT,
  state TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX tracks_content_hash_idx ON tracks(content_hash);
CREATE INDEX tracks_artist_album_idx ON tracks(artist, album);
CREATE INDEX tracks_state_idx ON tracks(state);

CREATE TABLE playlists (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  description TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE playlist_items (
  id TEXT PRIMARY KEY,
  playlist_id TEXT NOT NULL REFERENCES playlists(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  position_key TEXT NOT NULL,
  added_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE INDEX playlist_items_order_idx
  ON playlist_items(playlist_id, deleted_at, position_key);

CREATE TABLE favorites (
  user_id TEXT NOT NULL REFERENCES users(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  enabled INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, track_id)
);

CREATE TABLE ratings (
  user_id TEXT NOT NULL REFERENCES users(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  value INTEGER NOT NULL CHECK (value BETWEEN 0 AND 5),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, track_id)
);

CREATE TABLE play_events (
  id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL UNIQUE,
  device_id TEXT NOT NULL REFERENCES devices(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  event_type TEXT NOT NULL,
  position_ms INTEGER NOT NULL,
  occurred_at TEXT NOT NULL,
  received_at TEXT NOT NULL
);

CREATE INDEX play_events_track_time_idx
  ON play_events(track_id, occurred_at);

CREATE TABLE sync_operations (
  operation_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  device_counter INTEGER NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  server_seq INTEGER NOT NULL UNIQUE,
  received_at TEXT NOT NULL
);

CREATE INDEX sync_operations_entity_idx
  ON sync_operations(entity_type, entity_id, server_seq);

CREATE TABLE sync_device_cursors (
  device_id TEXT PRIMARY KEY REFERENCES devices(id),
  acknowledged_server_seq INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE TABLE media_trash (
  id TEXT PRIMARY KEY,
  track_id TEXT NOT NULL,
  original_path TEXT NOT NULL,
  trash_path TEXT NOT NULL,
  deleted_at TEXT NOT NULL,
  purge_after TEXT NOT NULL
);

CREATE TABLE audit_logs (
  id TEXT PRIMARY KEY,
  device_id TEXT,
  action TEXT NOT NULL,
  target_type TEXT,
  target_id TEXT,
  created_at TEXT NOT NULL,
  details_json TEXT NOT NULL
);
```

### Identifiers and Time

Use random IDs that do not collide across devices for all internal IDs and `operation_id` values.

Use `content_hash` to identify identical file contents, not to identify the same song after tag or container changes. Retain device timestamps for display and analysis, but never use them to order conflicts.

Use `device_counter` for operations within a device and `server_seq` for server-wide application order.

## API and Synchronization Contracts

### Main APIs

- `POST /v1/auth/passkeys/register/options`: Issue a challenge for initial or additional registration.
- `POST /v1/auth/passkeys/register/verify`: Register a passkey and issue device credentials.
- `POST /v1/auth/passkeys/login/options`: Issue a login challenge.
- `POST /v1/auth/passkeys/login/verify`: Issue an access token and refresh credentials.
- `POST /v1/auth/token/refresh`: Rotate refresh credentials.
- `POST /v1/sync/push`: Accept pending operations.
- `GET /v1/sync/pull?cursor=<server_seq>`: Return operations after the cursor or a complete snapshot.
- `GET /v1/library/tracks`: List, search, and filter tracks.
- `GET /v1/library/albums`: List albums.
- `GET /v1/library/artists`: List artists.
- `GET /v1/playlists`: Return playlists and their entries.
- `POST /v1/media/{track_id}/stream-url`: Issue a short-lived streaming URL.
- `POST /v1/media/{track_id}/download-url`: Issue a short-lived download URL.
- `POST /v1/library/imports`: Start an initial XML and audio migration.
- `POST /v1/library/scans`: Start a scan.
- `POST /v1/admin/tracks/{track_id}/trash`: Move audio to trash after administrator reauthentication.
- `POST /v1/admin/trash/purge`: Permanently empty trash after administrator reauthentication.

### Operation Idempotency

Store `operation_id` as a unique key. Receiving the same ID again returns its original result without applying the state change twice.

If an accepted operation cannot be applied, return an error code, the target entity, and whether retrying is possible instead of discarding it. Devices retain operations after retryable errors and notify the user about permanent failures such as revoked authentication, deleted targets, or invalid formats.

### Synchronization Cursors

Clients store the last fully applied `server_seq` as their cursor. If the application terminates during application, roll back the transaction and fetch from the same cursor next time.

Return a complete snapshot when event compaction has removed operations needed by a cursor. “All devices have acknowledged synchronization” refers to non-revoked devices. Devices disconnected for 90 days or longer fetch a complete snapshot on reconnection rather than replaying compacted events.

### Error Codes

Include these machine-readable codes in API error bodies:

- `auth_required`: The access token is missing or expired.
- `auth_revoked`: The device or refresh credentials have been revoked.
- `reauth_required`: A destructive operation requires reauthentication.
- `rate_limited`: A rate limit has been reached.
- `operation_duplicate`: The operation was already accepted; return its original result.
- `operation_rejected`: Target state or permissions prevent applying the operation.
- `media_missing`: The original audio file is missing.
- `media_hash_mismatch`: The downloaded file's hash does not match.
- `unsupported_format`: The playback path cannot handle the format.
- `quota_exceeded`: The operation exceeds the device quota or free-space limit.
- `invalid_import`: The XML or audio information is invalid for migration.
- `migration_failed`: A database migration failed.
- `server_unavailable`: The server cannot be reached.

## Playback History

Clients persist these events:

- `play_started`
- `progress_reached`
- `play_completed`
- `play_skipped`

Aggregate `play_completed` events into play counts. Emit `play_completed` when the engine reports natural completion or playback reaches 90 percent. Deduplicate retries from the same playback session by `operation_id`.

The server retains events for 90 days, aggregates them into snapshots, and compacts older events. Play counts, last-played timestamps, and skip counts are derived values that can be recalculated from events.

## Metadata and File Management

The database is authoritative for search and synchronization. For formats that support writable tags, save administrative edits to the database before writing them to files.

Treat a failed tag write as a failed database change, and record the original value and write error in the audit log.

For formats with limited tag compatibility, such as WAV and AIFF, store the database values and a sidecar as a portable representation of authoritative metadata. Sidecars are JSON containing the relative audio path, internal ID, metadata, and artwork references.

Automatic file moves and renames are outside the MVP.

## Authentication and Security

### Passkeys

Passkeys are the standard authentication method. During initial setup, the NAS CLI issues a one-time registration code for the first passkey. Recovery uses a new registration code from the NAS CLI or a previously issued recovery code.

Fix the passkey RP ID to the canonical hostname chosen during setup. A hostname change requires registering new passkeys as part of migration.

After passkey-based device registration, native apps use short-lived access tokens and rotating refresh credentials. Store refresh credentials in the OS's secure storage, such as macOS Keychain, iOS Keychain, Windows Credential Manager, or Android Keystore.

### Connection Protection

Allow only HTTPS in production. Permit localhost HTTP only in development builds. Accept self-signed certificates only after the user explicitly establishes trust.

Use short-lived signed media URLs. Never write them to application logs, audit logs, or error messages.

### Permissions and Reauthentication

The initial version is single-user, without fine-grained roles for normal authenticated operations. Require passkey reauthentication for permanent audio deletion, trash purging, revoking all devices, and server configuration changes.

List devices with last-used time, OS, and revocation status. Per-device revocation immediately invalidates existing refresh credentials.

Rate-limit authentication, registration, and reauthentication by IP address and credential. Initial defaults are five authentication operations per 15 minutes and 120 normal API requests per device per minute. Administrative configuration can lower these limits.

Audit administrative actions, authentication changes, audio deletion, and trash purging.

### Privacy

Send no telemetry by default. Send crash information that does not directly identify a person only with explicit consent. Exclude track titles, filenames, audio paths, server URLs, and history events from telemetry.

## Errors and Boundary Conditions

- **NAS unavailable:** Keep cached audio and pending operations available; synchronize after reconnection.
- **Authentication revoked:** Continue local playback, stop server operations, and display reauthentication.
- **Missing audio:** Mark the track as missing and retain history and playlist entries.
- **Hash mismatch:** Discard the incomplete download and prompt for retry.
- **Unsupported format:** Try original streaming, then request a compatibility copy if playback fails.
- **Compatibility generation failure:** Explain the failure, indicate that the original exists, and show how to retry.
- **Synchronization conflict:** Apply operations in `server_seq` order and report results without discarding operations.
- **Database migration failure:** Restore the pre-update snapshot and allow restarting the previous server version.
- **Insufficient space:** Preserve explicit downloads, stop new automatic caching, and notify the user.
- **Invalid XML:** Continue migration where possible and retain readable entries and errors with line numbers in the report.

## Operations

### Distribution

Support Docker Compose with separate volumes for media, the database, configuration, and trash. A single-binary distribution must accept external paths for configuration, the database, and media.

Evaluate Navidrome in an isolated environment without replacing the existing server.

For internet access, place a TLS-terminating reverse proxy or tunnel in front of the server and give the application its public HTTPS URL. Router configuration, certificate issuance, and port forwarding are outside the application's responsibilities.

### Backups

Back up audio files, the database, sidecars, configuration, synchronization events, and audit logs. Capture the database and synchronization events as a consistent snapshot.

Restore the database onto an empty server, verify audio hashes, apply sidecars, and then distribute complete snapshots to devices.

### Trash and Event Compaction

Client deletion moves audio to trash. Permanently erase it after 30 days by default; make this retention period configurable.

Compact synchronization events after a snapshot and acknowledgment from all devices. Do not retain detailed playback events beyond 90 days.

### Updates

Automatically snapshot the database and configuration before updates. Make database migrations rerunnable and recover with the previous version and snapshot after failure. Never include audio moves or conversion in database migrations.

### Open-Source Licensing

Apache-2.0 is the leading candidate for the project's server, clients, synchronization specification, and test assets.

Integrate with Navidrome only through APIs; do not distribute linked or modified copies of its source. Inventory dependency licenses before publication and reject dependencies incompatible with the distribution model.

Prefer OS audio APIs. Before adding an external decoder, review its license, dynamic-linking conditions, and redistribution requirements.

## Existing Software Evaluation

Evaluate Navidrome first for NAS audio management, play counts, playlists, ratings, and its OpenSubsonic-compatible API. Check that:

- MP3, AAC, M4A, ALAC, WAV, and AIFF can be registered, searched, and served correctly.
- macOS and iPhone clients receive identical metadata and original audio.
- Offline history can be imported without loss or duplication.
- Conflicting history, rating, favorite, and playlist operations converge.
- Device authentication, revocation, short-lived URLs, and reauthentication can be implemented.
- Only missing capabilities require custom APIs or a supplementary server.

If Navidrome cannot satisfy every item, use it as a media server and provide missing synchronization state and device management through a supplementary server. Consider a fully custom server only after verifying that a supplementary server cannot express the requirements.

Use Swinsian as a comparison for macOS local-library management and playback, not as a reference for unified Windows, iPhone, Android, or NAS synchronization.

## Implementation Sequence

### Technical Validation

1. Install Navidrome in an isolated NAS environment.
2. Import iTunes or Music XML and audio into a small validation library.
3. Test original playback, gapless playback, volume normalization, and Range downloads on macOS and iPhone.
4. Test offline retries, deduplication, and playlist conflicts.
5. Compare Swift-only synchronization and a Rust shared core using identical vectors.
6. Decide the Navidrome integration model and whether to adopt Rust from the results.

### MVP

1. Implement server authentication, scanning, search, and media delivery.
2. Implement macOS browsing, playback, playlists, favorites, history, and downloads.
3. Implement the same synchronization contract, background playback, and offline playback on iPhone.
4. Use both clients daily for four weeks, testing NAS downtime, network switching, app termination, duplicate retries, and restoration.
5. Proceed to conforming Windows and Android implementations after acceptance.

## Testing Strategy

- **Synchronization unit tests:** Reordering, retries, duplicates, concurrent additions, deletions, and moves, and delete/move conflicts.
- **Property tests:** Identical final states when arbitrary operations reach multiple devices in different orders.
- **API integration tests:** Authentication, cursors, pagination, Range delivery, signed URLs, and error codes.
- **Migration tests:** XML/audio matching, untagged WAV, AIFF, duplicate candidates, DRM tracks, and malformed XML.
- **Audio tests:** Gapless boundaries, silence, long tracks, variable bitrates, unsupported formats, and compatibility copies.
- **Failure tests:** NAS downtime, disconnection, forced app termination, failed database migration, and insufficient storage.
- **Security tests:** Passkey registration, reauthentication, device revocation, signed URL expiry, rate limits, and audit logs.
- **Accessibility tests:** Keyboard use, screen readers, text scaling, contrast, and focus order on each OS.
- **Conformance tests:** Passing shared synchronization vectors is a release requirement for every client.

## Deliverables

- This design specification
- OpenAPI specification
- Logical schema and database migrations
- Synchronization state-machine specification
- Synchronization conformance vectors
- iTunes or Music XML migration tool
- Server Docker Compose definition
- Server backup and restoration procedures
- Native macOS client
- Native iPhone client
- Native Windows client
- Native Android client
- Audio playback conformance matrix by format
- Security model and threat model
- Open-source license inventory
- User setup guide

## External Specifications

- [Apple Music XML export](https://support.apple.com/ja-jp/guide/music/-mus27cd5060f/mac)
- [MediaPlayer playCount](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/playcount)
- [MediaPlayer lastPlayedDate](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/lastplayeddate)
- [MusicKit library operations](https://developer.apple.com/documentation/musickit/musiclibrary)
- [Navidrome overview](https://www.navidrome.org/docs/overview/)
- [Swinsian 3](https://swinsian.com/blog/2025/08/19/swinsian-3/)

## Historical Status (2026-08-15)

The design interview and technical validation were complete at this point. Product implementation had not started. This checklist records that milestone; see the [README](../README.md#current-implementation) for the current implementation.

### Checklist

- [x] Define the purpose, authoritative state, target operating systems, and MVP boundary
- [x] Define initial migration and coexistence with Apple's applications
- [x] Define audio formats, metadata, and sidecar policy
- [x] Define offline synchronization, conflict resolution, and history
- [x] Define the native-client approach
- [x] Define passkeys, device revocation, and reauthentication for destructive operations
- [x] Define backups, trash, event compaction, and updates
- [x] Define Navidrome suitability and Rust shared-core evaluation criteria
- [x] Write the design specification
- [x] Evaluate Navidrome: unauthenticated execution was BLOCKED; limit its product role to a media adapter
- [x] Evaluate the Rust shared core: confirm seven-vector conformance; do not adopt it as the product's shared core
- [ ] Create OpenAPI and synchronization conformance tests
- [ ] Implement the macOS and iPhone MVP
- [ ] Complete four weeks of daily-use validation
- [ ] Implement conforming Windows and Android clients

### Updates

- 2026-08-14: Completed the design interview and established NAS authority, native clients, offline synchronization, passkeys, and MVP exclusions.
- 2026-08-14: Created this specification. Evaluate Navidrome and the Rust shared core before implementation.
- 2026-08-15: Completed Navidrome, Swift synchronization, Rust candidate, and Apple playback evaluations. Recorded Apple XCTest and physical iPhone validation as BLOCKED.
- 2026-08-15: Created implementation plans for the server, migration, Apple clients, and operations.

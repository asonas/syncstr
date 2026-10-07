# syncstr design interview record

This document preserves assumptions established during the initial design interview and technical validation. Check the [current scope](../README.md#current-implementation) before applying them to implementation work.

## Established answers

### Product boundary

syncstr is a personal service for playing NAS-hosted music on multiple devices. The NAS library, metadata, playlists, ratings, and playback history are authoritative.

After the initial iTunes or Music XML migration, the product does not continuously synchronize bidirectionally with Apple's apps. It starts with a single user and is intended for a later open-source release.

### Clients

Target macOS, Windows, iPhone, and Android. Share UI information architecture and visual language through Figma. Use each OS's APIs for audio playback, background execution, media keys, and file access.

Implement macOS and iPhone first, followed by conforming Windows and Android clients.

### Audio and migration

Support MP3, AAC, M4A, ALAC, WAV, and AIFF where possible. Use the DB and sidecars for untagged files or formats where tag writing is unavailable.

Exclude DRM-protected audio and tracks available only in Apple Music's cloud. Migration does not modify, move, or delete source audio. Report ambiguous candidates and failure reasons.

### Synchronization and authentication

Persist offline ratings, favorites, playlist changes, and history operations, then resend them. Deduplicate by operation_id, validate per-device ordering with device_counter, and record server acceptance order with server_seq.

Address playlist entries by item ID. Tombstones prevent stale devices from resurrecting deleted entries. Default to passkeys and provide per-device revocation and recovery.

### Validation results

The Swift reference implementation and Rust candidate matched state, history, and error classifications for seven shared vectors. The shared Rust core was not adopted because FFI, cancellation, thread boundaries, and distribution had not been measured.

## Questions to revisit before implementation

### Server

Adopting a Rust server requires comparing API implementation speed, Docker image size, startup time, SQLite concurrency, and operational diagnosis. Do not infer shared-core reuse from that choice.

### Migration

Create anonymized fixtures for paths, encodings, and artwork references found in real Music or iTunes XML exports. Require confirmation for multiple matches; silently selecting one can associate history and ratings with the wrong audio.

### Synchronization

Specify the playback percentage that records completion and the conditions that record a skip in the API contract. Test the boundary between 90-day tombstone retention and snapshot compaction using each device's last synchronization cursor.

### Operations

Provide a recovery path for lost passkeys before use, even for a single user. Keep permanent deletion disabled until trash retention, backup destinations, and encryption-key custody are decided.

### Publication

Before open-source publication, automatically check that audio, personal XML exports, identifying fixture data, and validation credentials are excluded. Complete license and trademark review before using repository descriptions that imply a relationship with Apple or Napster.

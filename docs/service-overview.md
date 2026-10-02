# syncstr service overview

This is the long-term service vision. See the [README](../README.md#current-implementation) for the current implementation and development entry points.

## Purpose

syncstr provides consistent access to a personal music library stored on a NAS. Users work with the same tracks, playlists, ratings, and playback history from macOS, Windows, iPhone, and Android.

When disconnected, they continue playback and editing with explicitly downloaded audio and locally stored operations.

## Users

The initial service has one user who manages their own NAS and migrates an existing iTunes or Music library. A future open-source release retains the safety properties of that single-user design.

## Authoritative state and caches

The server owns media registrations, metadata, playlists, ratings, favorites, playback history, and operation events. Clients cache metadata, some or all audio, pending operations, and synchronization cursors.

Clients persist local changes as events with operation_id, device_id, and device_counter. The server assigns server_seq in acceptance order and never applies the same operation_id twice.

## Main flows

### Initial migration

The user exports XML from Music or iTunes and places audio in the NAS import area. Migration matches XML tracks against file paths, sizes, durations, and hashes.

Tracks without a unique match await confirmation. The process can stop without moving or deleting audio. DRM-protected, cloud-only, and unmatched tracks are reported with reasons.

### Playback

Prefer a complete local audio file; otherwise stream the original over HTTPS. Request a compatibility copy only when the device cannot handle the original format. Integrate the playback engine with each OS's media session, background execution, and media keys.

### Offline operations

Favorites, ratings, playlist edits, and playback history remain available offline. Persist operations locally and retry with exponential backoff after reconnecting. The server deduplicates them and returns acceptance order and conflict-resolution results.

### Backup and restore

Back up the audio inventory, DB, operation events, sidecars, and configuration. Verify restoration in an isolated environment before applying it to production data. Restore must not silently discard trashed audio, history, or playlist tombstones.

## In scope

- Migration of local DRM-free audio
- Registration and playback of MP3, AAC, M4A, ALAC, WAV, and AIFF
- Metadata, artwork, ratings, playlists, and history
- Original-audio streaming and offline downloads
- Operation deduplication and conflict resolution
- Passkey authentication and device revocation
- NAS scanning, missing-file detection, and duplicate candidates
- Trash, backup, and restore
- Native macOS and iPhone clients
- Conforming Windows and Android clients

## Out of scope

- Continuous bidirectional synchronization with Apple Music or iTunes
- General-purpose playback of DRM-protected audio
- A subscription streaming service
- Lyrics, recommendations, and smart playlists
- EQ, exclusive output, and automatic sample-rate switching
- External scrobbling
- Casting
- Multi-user permission models
- A web player

## Success criteria

macOS and iPhone pass the same synchronization contract, and offline operations converge after connectivity returns during daily use.

Initial migration preserves audio, retains WAV/AIFF metadata, and exposes failure reasons. Windows and Android are supported only after conforming to the same server API and synchronization vectors.

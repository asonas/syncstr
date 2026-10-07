# syncstr design decisions

These decisions record the initial long-term design. Check applicability to the current Navidrome player against the [README](../README.md#long-term-design-and-deferred-work) and successor issues.

This document separates established decisions from questions to resolve before implementing the corresponding part of the design.

## Established decisions

| ID | Decision | Rationale | Consequence |
|---|---|---|---|
| D-001 | The NAS server is authoritative | Keep media and state consistent across devices | Clients hold caches and submit operations |
| D-002 | Use iTunes or Music XML only for initial migration | Apple's public APIs do not guarantee continuous bidirectional synchronization for general-purpose apps | syncstr owns state after migration |
| D-003 | Build native clients | Use OS APIs for audio sessions, background execution, media keys, and file access | Use Swift, C#, or Kotlin for each platform |
| D-004 | Prefer original audio | Avoid quality loss and irreversible transformations | Generate compatibility copies only for unsupported formats |
| D-005 | Keep WAV and AIFF metadata in the DB and sidecars | Preserve originals when tag writing is unavailable | Verify original-file hashes |
| D-006 | Include operation_id, device_counter, and server_seq in sync operations | Make retries, ordering, and conflicts explicit | Enforce uniqueness in server-side SQLite transactions |
| D-007 | Default to passkey authentication | Avoid routine password use and support per-device revocation | Design registration, recovery, and device management separately |
| D-008 | Limit Navidrome to a media adapter | Ratings and play counts do not satisfy the product's history-event contract | Add an authoritative syncstr SyncService |
| D-009 | Do not adopt a shared Rust synchronization core | FFI, cancellation, thread boundaries, and distribution remain unmeasured; a smaller failure surface has not been demonstrated | Share synchronization vectors and conformance tests instead |
| D-010 | Implement macOS and iPhone first | Validate native audio paths early | Windows and Android follow as conforming implementations |
| D-011 | Provide a Mac-folder-to-iPhone local copy path ([issue #12](https://github.com/asonas/syncstr/issues/12)) | Nontechnical users can start without administering a server | For this path, replace D-001's NAS requirement with a Mac source and durable phone copies; defer D-006 server ordering, D-007 passkeys, and D-008 SyncService. Keep the existing Navidrome path as an alternative |

## Decisions to resolve before the relevant implementation

### D-101 Server language

The initial recommendation is a Rust web server. Types and ownership can help manage the boundaries around long-running synchronization, files, and backups on the NAS. This is separate from adopting a shared Rust client core.

Compare Rust and alternatives using the same API contract, startup time, binary size, and development speed in the first implementation task.

### D-102 Audio directory layout

The initial recommendation separates original audio, import staging, trash, sidecars, and backup working files. The scanner reads originals; only dedicated services import or delete them.

### D-103 Backup destination

The initial recommendation combines a separate NAS volume with encrypted external storage. Do not count a backup as successful until a restore drill passes.

### D-104 Open-source license

The initial recommendation allows separate licensing of server and clients and audits dependency licenses in CI. Select the license before the corresponding implementation release and reflect it in README and NOTICE.

### D-105 iPhone playback acceptance

At the initial validation, AudioValidation built on macOS, but the environment did not provide XCTest, so automated probes were BLOCKED. Physical iPhone playback, background audio, media keys, gapless playback, and HTTPS Range require corresponding device results before acceptance.

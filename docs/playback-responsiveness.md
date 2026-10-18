# Responsive connection and playback preparation

Playback and connection waits must leave navigation, scrolling, and cancellation responsive. Network latency and main-thread stalls are measured separately.

## Execution and ownership

- `Library` and `LocalTransfer` retain UI state and player ownership on MainActor.
- `CatalogStorage` runs synchronous SQLite work on a dedicated serial executor and reuses its playback-query connections. Current-schema database opens do not perform migrations or acquire a write transaction.
- Playback resolves a single track and library identity without decoding the full catalog, organizing albums, or extracting artwork.
- Connection catalog loading, merging, persistence, and saved-file inspection run off MainActor. Prepared results are published only while the originating operation remains current.
- The small library-activation marker is written at the accepted MainActor boundary, after the connection generation check, so a cancelled worker cannot reopen a closed library on the next launch.
- Cluster sessions execute reconciliation and transfer coordination on `TransportActor`, sharing the catalog executor. No SQLite transaction spans a network suspension.
- `PlaybackDownload` owns each partial file on a separate serial executor. Writes, hash verification, import, and durable cluster-file synchronization finish there before playback or receipt publication.
- SwiftUI saved-copy checks use the prepared in-memory file set.
- Stop-time cache maintenance waits for the preceding acquisition and maintenance task. Cache verification waits for maintenance before handing a file to playback.

## Connection lifetime

A playback request waits for an existing legacy connection or transfer to become idle. Concurrent requests recheck availability after waking, so they cannot consume one another's replies. Cancelling a waiting playback request removes its waiter without cancelling the shared connection. Explicit disconnection invalidates waiting requests.

An idle authenticated legacy channel is reused. Cancelling an active legacy transfer can still close its shared stream to preserve framing; the next request reconnects using saved credentials. Reconnection retains the existing catalog exchange. Multiplexed streams and a protocol for skipping catalog exchange are separate work.

## Presentation

The existing playback controls show checking, connecting, catalog synchronization, receiving, and player preparation states. During preparation the transport button retains its play icon and is disabled; it does not turn into a text cancel button. Transfer progress updates are bounded; obsolete requests cannot publish state or late failures after pause, replacement, or library closure. macOS and iOS share these states.

## Acceptance

- With a real SQLite exclusive lock, starting playback returns promptly, MainActor continues scheduling, and pause cancels preparation without a late failure.
- Playback requested during TLS approval waits, then obtains the correct verified audio through that connection.
- A cancelled waiter does not prevent another playback request from using the connection.
- Existing queue, pause/resume, save, pairing, catalog persistence, and diagnostic behavior remain covered by their suites.
- Inspect loading and cancellation in the signed macOS app against the retained catalog and configured endpoint. Record iOS build/tests separately from physical-device verification.

This change targets connection and playback preparation. It does not claim to remove every synchronous filesystem call from all import, organization-editing, or settings operations. Remaining UI work must be profiled before claiming that the application is free of hangs.

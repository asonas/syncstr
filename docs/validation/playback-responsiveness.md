# Connection and playback responsiveness

## Regression evidence

The real SQLite exclusive-lock fixture reproduced two MainActor stalls before the change: starting playback took 5.258 seconds, and a scheduled 100 ms heartbeat resumed after 5.265 seconds. Preparation had already failed before the listener could cancel it.

After the change, the same public `Library.play`/`pause` test completed in approximately 0.32 seconds, including its 100 ms and 200 ms observation waits. Both response checks stayed below one second, preparation remained cancellable while the database was locked, and cancellation did not publish a late failure.

The real TLS approval test also failed before the change: playback immediately returned `clusterUnavailable` while the existing connection awaited approval. It now waits for that connection and verifies the original audio hash. Cancelling an earlier waiter leaves the connection available to the next request.

## Automated validation

- The macOS suite ran 95 XCTest cases: 89 passed and six environment-dependent cases were skipped. All 26 Swift Testing cases passed.
- Skipped cases require a local P2P headless executable, a configured directory deployment, or an external upload fixture. Cluster transport changes are compiled, but these results do not establish native-to-headless or relay interoperability.
- The iOS Simulator target built successfully. No physical iPhone interaction or TestFlight distribution was performed.
- Standards and spec reviews were performed separately. Cache maintenance, background cache playback, activation-marker ownership, and connection-history capture were corrected following review.

## Signed macOS app, 2026-10-18

The development build was verified by executable path and bundle identifier, then launched as the only running Syncstr process. It used the retained catalog and saved endpoint already used for reproduction; settings and caches were not reset.

Observed through computer use:

1. The retained album and track list opened.
2. An uncached track displayed the connection indicator and cancel action.
3. Navigation to the artist screen remained available during the connection wait.
4. A retry could be cancelled, with the playback control returning immediately.
5. A cached track started, advanced past five seconds, and paused successfully.

A two-second process sample during the connection wait found the main thread waiting in the application event loop, rather than SQLite or file verification. This is a bounded observation, not a guarantee that every app interaction is free of stalls.

The configured endpoint timed out while establishing the peer transport during this run. Consequently, fresh audio acquisition through that endpoint remains unverified in this build. The real local TLS test verifies the acquisition path independently. Narrow-window layout and physical-device behavior were not checked.

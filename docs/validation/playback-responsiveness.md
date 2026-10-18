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

## Album and loading UI follow-up, 2026-10-18

The signed macOS Debug build was launched through `apps/macos/run.sh`, with its executable path and single running process verified. Computer use confirmed:

- One ordinary album-card click opens details directly. Command-click still adds two albums to the batch selection; an ordinary click opens details and clears that selection.
- Returning through the icon-only toolbar action centers the previously opened album in the grid rather than returning to the top. Back and search share the toolbar row.
- The detail header uses an icon-only download action beside Play and no longer contains a visibility button. The retained catalog's multi-artist album displays `V.A.` while track rows retain individual artist names.
- During an uncached playback request, the mini-player displays a spinner and a disabled Play icon, with accessibility reporting a disabled Play button. It does not replace Play with a textual Cancel action.

The focused regression run passed 19 AlbumOrganization XCTest cases and eight LibraryPresentation Swift Testing cases. The new case checks abbreviated detail credits, unchanged full browsing credits and track artists, and preservation of an explicit album artist. macOS Debug and iOS Simulator builds passed. iOS changes were compiled, not visually checked on a device. Narrow-window layout and every offline-save state were not manually rechecked in this follow-up.

The editable [album detail proposal](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=103-1142) and [row state comparison](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=103-1435) were visually inspected. The proposed hover/selection row appearance remains a design-only deliverable pending approval.

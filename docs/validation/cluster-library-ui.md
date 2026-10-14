# Apple cluster-library interaction validation

The Apple apps implement the [accepted interaction specification](../cluster-ui-review.md), reusing the player and cache work described in [player validation](player-interactions.md). Validation below was performed in a development worktree. Git integration, push, and distribution are recorded separately from these acceptance results.

## Behavior delivered

- Both apps offer existing-library enrollment and local file import. macOS retains folder selection. Local import does not assign a host role or start new legacy pairing. Existing pairing credentials remain readable, and an existing paired folder can resume hosting without re-pairing.
- Daily navigation contains browsing, import, and refresh. Legacy device transfer is in Settings. Enrollment, host/path diagnostics, conflicts and membership attention, communication policy, and storage settings are separate from daily playback.
- Track and album actions use a shared offline-save queue. Its atomic `offline-saves.json` stores library identity, the requested track snapshot, successful content digests, cancellation, and failures. Existing audio and registrations are not reclassified or erased.
- Pending saves resume while the app is active, after connection availability changes, or on a 15-second retry. Explicit requests can use cellular; other pending requests follow the automatic-audio policy. No background-execution guarantee is made. Cache promotion requires no network, even when an earlier album track is unreachable.
- Cancellation retains verified successes. Retry checks existing protected files and acquires only missing audio. Later album additions appear as incomplete coverage and need an explicit new Save. Failures retain successful files and an actionable retry.
- Removal cancels overlapping save requests, confirms interruption, deletes managed and cached copies, and preserves catalog entries and originals. The storage boundary rejects host-copy removal and removal of imports awaiting host confirmation.
- Startup opens retained local content before awaiting Keychain-backed identity restoration. An unavailable original folder does not replace or clear a cluster catalog. Folder restoration retains separately imported managed audio.

## Build and automated checks

Validation uses Xcode 27.0, Swift 6.4 in the project's Swift 5 language mode, and Apple Silicon. XcodeGen's `apps/ios/project.yml` includes shared save code in both apps and the verification targets. Build outputs use signing-disabled Debug configuration; these results do not establish TestFlight behavior.

The focused macOS run passed 30 tests: catalog migration, legacy transfer, offline saves, and player behavior. A subsequent run passed 27 tests covering offline saves, player behavior, and signed cluster membership/policy. The final offline-save run passed all 10 tests, including cold cluster restoration with an unavailable original folder, folder-plus-managed-import restoration, an album whose later cached track can be protected while earlier tracks wait for a source, and the library's save-state lookup used by the UI.

The iOS generic Apple Silicon Simulator `build-for-testing` passed for the application and test targets. This compiles the shared save tests and the full-player save/removal actions; it does not establish runtime behavior on an iPhone.

The tests use disposable storage and test-only pairing credentials. Real TLS loopback verifies pending saves after pairing, cancellation at a completed-track boundary, retry, file integrity, and preservation of originals. Other save tests verify durable intent and results, album snapshots and explicit additions, manual retry, cache promotion, physical removal of managed/cache files, and host-copy rejection. Existing migration checks preserve old audio and credentials.

## macOS screen checks

The launched executable was `apps/macos/.build/Checks/Build/Products/Debug/Syncstr.app/Contents/MacOS/Syncstr`, in the implementation worktree, with bundle identifier `as.ason.syncstr.ios`. The repository launch script verified one matching process. This is the Xcode Debug variant, not the manual-build or TestFlight variant.

Checked the retained library, album details, per-track save menu, Settings, storage accounting, and the legacy-transfer disclosure. Daily navigation has no iPhone-transfer action, and save actions remain available without a connected source. At approximately 1080×740 and 703×623 points, album save controls remain reachable by scrolling; long metadata wraps and the compact player retains transport controls. Accessibility inspection exposes save controls, menu actions, and legacy navigation with names.

The first unsigned launch waited in Keychain identity retrieval before displaying local content. A process sample identified `restoreLibrary` → `restorePeer` → `CredentialStore.load` → `SecItemCopyMatching`. After changing startup order, the retained library and Settings became usable while credential retrieval still waited. Credential access controls were not changed.

## Remaining acceptance

iOS runtime/visual checks, fresh-install screen checks, actual cellular transitions, multiple live authorized sources, device-space exhaustion, physical-device transfers and audible playback, narrow iPhone and accessibility text sizes, VoiceOver navigation, and reduced transparency/motion remain unverified in this delivery. Tests of a pure communication policy do not prove behavior on a cellular interface. The unsigned macOS preview still waits for Keychain-backed identity access, so live enrollment and source acquisition are not verified through that preview. No production catalog repair, deployment, or new cluster/host-role GUI is included.

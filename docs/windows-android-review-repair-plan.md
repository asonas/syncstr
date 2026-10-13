# Windows and Android review repair plan

Repair playback lifecycle, UI responsiveness, and catalog presentation before integrating the Windows/Android branch into main. Keep the existing native clients and cluster protocol; these fixes do not require a UI framework migration or a new storage schema.

Status: proposed implementation plan, not an implementation or acceptance record.

Reviewed baseline: `codex/windows-app` at `37e74c85d10099d5129e7146e60cd930bc6be013`, compared with main at `5588b72616505bd530dd213764e0331b0c02d7ff`. Recheck the diff if either branch moves.

This document is for the developer continuing work on Windows, including Android development on that machine. Use the [Windows app guide](../apps/windows/README.md) and [Android build guide](../apps/android/README.md) for toolchains. The older [Android handoff](android-ui-development-handoff.md) still contains superseded statements about the missing Gradle wrapper and Windows build script; the reviewed branch includes both.

## Evidence and scope

The preceding review passed 59 shared Rust tests with the `p2p` feature, Android unit tests, and Android Lint on macOS. These checks do not exercise the affected Activity transitions or the Windows message loop. The five findings below are based on source inspection; target-device reproduction is still required.

| Priority | Finding | Implementation boundary |
|---|---|---|
| P1 | Switching Android tracks queries a released player | `MainActivity.startPlayback`, mini-player rendering, playback callbacks |
| P1 | Windows discovery, transfer, and file verification block the message loop | `WM_COMMAND`, startup loading, `perform`, operation completion and shutdown |
| P2 | Android groups distinct albums by display title | Catalog presentation and album grouping |
| P2 | Android ignores the serialized disc number | Track ordering |
| P2 | Restored Android Connections screen can omit registration | Startup loading, render methods, busy-state ownership |

Preserve enrolled identities, saved originals, explicit download choices, conflict visibility, and offline playback. No relay changes, new Windows hosting features, Android background playback service, or distribution work are part of this repair. Follow [design guidance](../DESIGN.md) and [review standards](../CODING_STANDARDS.md) for the affected states.

## 1. Android: replace the player before rendering its state

In [MainActivity.kt](../apps/android/app/src/main/java/as/ason/syncstr/MainActivity.kt), `startPlayback` releases `player`, then calls `renderMiniPlayer` before replacing the reference. The mini-player reads `isPlaying` on the released instance. The [MediaPlayer API](https://developer.android.com/reference/android/media/MediaPlayer#isPlaying()) defines this as an illegal state. A worker-thread catch cannot handle an exception thrown later by a posted UI callback.

Recommended change:

1. On the UI thread, clear the active reference and readiness state before releasing the old instance. Remove pending progress callbacks that refer to the old session.
2. Create and assign the replacement before any code can inspect its state. Present a preparing state with playback controls disabled until preparation completes; do not infer readiness by calling player methods during preparation.
3. Accept prepared, completion, and error callbacks only when their player is still the active instance. A late callback from a replaced player must not change the current title, readiness, or playback position.
4. Catch source/setup failures on the UI thread where they occur, release the failed instance, clear readiness, and show the existing retryable playback error. Do not hide errors with a blanket exception catch around rendering.
5. Preserve the current pause-on-stop behavior and restored position. This change does not introduce background playback.

Acceptance: play saved track A, switch to B, select B again, pause/resume, and rapidly switch while preparation is pending. The selected track alone becomes active; controls recover after an invalid local file and after Activity recreation. Confirm audible output separately from player state.

## 2. Windows: keep work outside the message loop

In [main.rs](../apps/windows/src/main.rs), `WM_COMMAND` calls `perform` synchronously. That path runs discovery, enrollment, catalog refresh, download, and local-file validation with `block_on`. Startup also loads the catalog synchronously. Moving only the network request would leave file hashing and startup work blocking the window.

Use one serialized background worker for client/store operations, with a long-lived Tokio runtime owned by that worker. Keep window handles, control reads/writes, and playback commands on the UI thread. Do not move the existing `perform` function wholesale to a thread: it accesses controls and the global UI state.

The operation flow should be:

1. The UI captures owned input: invitation text, selected endpoint, object ID, and a snapshot of candidate sources. Validate selection and invitation/endpoint agreement before dispatch.
2. Mark the operation pending and enqueue that data. Do not pass a list index or borrow UI state across the asynchronous boundary.
3. The worker performs the current client operation and returns owned results or an error. Client creation, DPAPI/file access, catalog loading, and file integrity checks stay off the UI thread.
4. Store completion data in an owned synchronized queue and use a private `WM_APP` message only as a wake-up signal. The UI drains results, updates controls, and clears the pending state on both success and failure. Avoid heap pointers in message parameters that can leak when a window closes.

Allow one client operation at a time; do not silently queue repeated clicks. During it, disable conflicting discovery/register/refresh/save/play requests. Keep repainting, moving the window, and pausing/resuming already-playing audio available. The completion must apply to the captured object even if the user changes selection. Restore controls after failure so retry works without restarting.

Shutdown requires an explicit lifetime rule. On close, stop accepting work, close local playback, and invalidate UI delivery. Request cancellation of the active async operation and let the worker/runtime clean up without joining it inside the window procedure. Review the shared transfer cleanup path before using future cancellation: an interrupted file must remain unpublished, and cancellation must not bypass required cleanup. A synchronous file check may finish in the background; its result must not touch the destroyed window. Drain/drop queued results and handle failed wake-up delivery. Do not add unsafe `Send` implementations to carry UI handles into worker code.

Acceptance on native Windows:

- Discover and refresh against a real LAN host; the window continues repainting and moving.
- Download a sufficiently large fixture, pause/resume existing playback, and attempt repeated actions. No duplicate client operation starts.
- Make the host unavailable, then retry after recovery; controls and status recover correctly.
- Change the selected row during a save; the originally requested object is saved.
- Close during transfer, reopen, and verify retained identity/catalog plus absence of a falsely saved partial file. Previously saved audio still plays offline.

This worker belongs to the Windows app. A general task framework or changes to the transport protocol are unnecessary.

## 3. Android: group albums by identity, sort by labels

`renderGroups` currently uses album title as a map key. It merges unrelated releases with the same title, and the case-insensitive sorted map can discard one of two distinct keys that compare equal. Changing the key to title plus artist would still split compilations and ignore established membership choices.

Recommended change:

- Keep grouping identity separate from display title. Preserve all groups in a list and sort that list by display title with an identity tie-breaker, rather than inserting labels into a case-insensitive map.
- Resolve album membership using the existing catalog organization: explicit membership decisions and canonical aliases precede imported membership. Use `track.albumId` only when organization has no applicable record. If both are unavailable, use an object-specific unresolved group rather than inventing a shared album from its title.
- Inspect and reuse the rules in [organization.rs](../headless/src/organization.rs), [membership.rs](../headless/src/membership.rs), and the Apple catalog presentation in [Library.swift](../apps/macos/Library.swift). Android currently discards `organization` when loading the catalog; retaining or projecting it is necessary to honor those rules.
- Prefer resolving existing organization rules in Rust and exposing only the presentation values Android needs through its existing JNI catalog response. Do not rewrite alias/conflict resolution in Kotlin. Before changing a shared catalog response, identify its consumers; prefer Android-local derived fields over changing persisted metadata or the wire format.
- Preserve the existing treatment of conflicts. Do not select a winning membership or merge records as a side effect of browsing. A compilation's subtitle must represent its album credit, not whichever track happened to arrive first.

Acceptance fixtures: two distinct album IDs with the same title; titles differing only by case; a compilation with multiple track artists; an established alias/membership choice; and entries with missing album metadata. Every input track remains visible in the appropriate group, with stable ordering across refresh and Saved filtering. Cover unresolved/conflicted membership without silently choosing a winner.

## 4. Android: consume the actual disc-number contract

[Track](../headless/src/model.rs) serializes `disc_number` as `discNumber`. Android currently requests `disc_number`, so every entry falls back to disc 1.

Read `discNumber` and preserve the existing `track` key for the track number. Treat absent/non-positive disc numbers as disc 1 and absent/non-positive track numbers as unnumbered tracks after numbered tracks. Sort by disc, track number, then a deterministic title/object-ID tie-breaker. This is presentation behavior; do not rewrite tags or stored metadata.

Use a fixture whose expected order is written independently: disc 1 tracks 1 and 2, followed by disc 2 tracks 1 and 2, even when input is shuffled. Include missing values and repeated numbers. Apply the ordering to grouped album tracks without changing the separately defined Songs view ordering.

## 5. Android: render Connections from loaded state

`renderConnections` starts a `task`, but startup rendering can run while the outer task still holds `busy`. The nested task returns immediately, so the host count and registration button are never created. Error recovery can take the same path.

Make rendering synchronous and free of JNI/task side effects. Load host information with the existing serialized worker during startup and after successful enrollment or explicit refresh, then publish a UI snapshot. Keep host state distinct as loading, loaded, or failed; do not display a failed query as zero registered hosts.

Always render the registration control. Enable it once identity/startup prerequisites are ready and no conflicting operation is running. Show a loading state or actionable failure while host information is unavailable. An error must not require switching tabs to recover.

Give the outer operation responsibility for completion: publish its result, clear busy state, and render the currently selected screen in one UI callback. Do not rely on a render method starting a second operation. Ignore delivery to a destroyed Activity; recreation reloads persisted state into the new instance.

Acceptance: open Connections, recreate the Activity, and repeat with a deliberately delayed startup read. Registration returns without navigating away. Repeat for a failed host read and retry, and navigate away during loading to ensure an obsolete screen is not populated. Preserve the current registered identity and saved music.

## Implementation order and verification

Use separate reviewable commits for Android playback, Android Connections state, album identity/order, and Windows operation lifecycle. Start with playback and Connections so the device can reliably exercise subsequent checks. Implement Windows independently after defining its completion/shutdown contract.

| Boundary | Minimum useful verification |
|---|---|
| Android playback and restoration | Instrumentation exercising the real Activity and MediaPlayer, plus audible playback on an ARM64 device |
| Album grouping/order | Small behavioral fixture tests at the presentation boundary, using the actual Rust/JSON field names; add a JNI contract check if derived fields are introduced |
| Windows operation lifecycle | Native Windows window interaction during real host transfer/failure/shutdown; focused worker integration checks only where they cover an additional failure |
| Identity, catalog, transfer | Existing real-headless integration tests; rerun affected shared contracts if Rust presentation code changes |

The current Android [PlaybackCheck](../apps/android/app/src/androidTest/java/as/ason/syncstr/PlaybackCheck.kt) invokes JNI and MediaPlayer directly. Keep that transport/offline coverage, but extend device verification to drive the Activity for these UI regressions. Do not substitute source-text assertions or mocked player call order for the public behavior.

From native Windows PowerShell, after the toolchain/native library setup in the app guides:

```powershell
cargo +1.99.0 test --manifest-path apps/windows/Cargo.toml --locked
cargo +1.99.0 clippy --manifest-path apps/windows/Cargo.toml --locked --all-targets -- -D warnings
cargo +1.99.0 test --manifest-path headless/Cargo.toml --locked --features p2p --all-targets
./apps/android/gradlew.bat -p apps/android testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest
```

The Gradle command builds device-test artifacts; it does not execute them. Follow the Android guide for installation and device execution. Preserve the existing development signing identity or use an isolated test application ID; do not uninstall a user's enrolled app to bypass a signing mismatch. Use fictional metadata and generated audio for fixtures, without operational device IDs or private addresses in committed evidence.

Before integration, record the tested commit, native Windows build and interactions, Android device/build and Activity transitions, audible/offline playback, failures/retries, and remaining gaps. macOS/iOS need no UI change for these platform-specific defects. If a shared Rust projection or contract is changed, document its consumers and run the affected compatibility tests; do not claim Apple acceptance from Android or Windows results.

Completion requires all five regression scenarios to pass, retained identity/saved music after restart, and responsive Windows failure/shutdown behavior. Update stale handoff statements alongside the final verification record. Commit, main integration, push, and distribution remain separate delivery actions; this document does not record them as completed.

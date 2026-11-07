# Windows and Android playback support

Status: daily-use contract and staged Windows/Android delivery accepted on 2026-11-07. [ASO-45](https://linear.app/asonas/issue/ASO-45) remains open for full-parity follow-up scope. The owner agreed to both local-only and cluster entry paths and implemented macOS behavior as the target. This document does not establish delivered platform parity.

Deliver v5 identity and save compatibility first, then require the daily-use contract below before describing Windows or Android as a supported daily player. The owner agreed to require continuous playback, automatic acquisition, offline restart, OS media controls and background/lock-screen playback. These are separate acceptance gates: a successful build or a saved-track playback check cannot establish background playback, queue continuity, or physical audio behavior.

The source assessment uses revision `fd50ab9bf604d415571ef35b5ad855b5b01d932a`. Before publication, main advanced to `50d4d95`: ASO-53's Apple mutation guards and ASO-60's typed mutation transport are now merged. These changes prevent unsupported legacy writes and provide transport infrastructure; they do not complete the individual v5 mutation features. The [v5 completion design](v5-completion-design.md), accepted [player specification](player-interaction-spec.md) and [cluster interaction specification](cluster-ui-review.md) provide the reference contracts. The inventory below checks their implementation and evidence rather than treating every Apple specification as delivered macOS functionality. This Windows session did not run a macOS app.

## Current merge decision packet

The [accepted decision packet](native-client-merge-decisions.md) records D1–D4, the merged Windows/Android binding evidence and delivery order without weakening the daily-use or full-parity targets. This document's source/status tables retain their dated assessment.

Since that assessment, PRs #41–43 delivered Apple playlist updates, conflict resolution and durable metadata editing, and PR #47 delivered host-side album visibility. The [v5 handoff](shared-audio-v5-handoff.md) records current wire behavior. Host visibility support alone does not establish client projection or enabled controls. Preserve those distinctions when implementing the platform slices rather than treating the historical gap inventory below as the latest feature list.

## macOS reference inventory

The target is equivalent user behavior with platform-native controls, not identical SwiftUI layout. Preserve each feature's supported context: local/legacy operations do not prove v5 support.

| Capability | Implemented macOS reference | Evidence and limits |
| --- | --- | --- |
| Local music and library entry | [Library](../apps/macos/Library.swift) and [LocalSetup](../apps/macos/LocalSetup.swift): file import, folder selection, retained local library and cluster enrollment | [Cluster-library record](validation/cluster-library-ui.md) covers local restoration, imports and save tests; live enrollment through its unsigned preview was not verified. New v5 enrollment is separate ASO-39 work |
| Browse and find music | [Syncstr](../apps/macos/Syncstr.swift): recently added, albums, artists, tracks, search, album detail, mini-player and full player; [PlaylistViews](../apps/macos/PlaylistViews.swift): playlist browsing | Existing UI and v5 UI records cover search, distinct rows and retained catalog. Organization/edition/artist distinctions must survive projection; v5 artwork retrieval remains ASO-47 |
| Queue and transport | [Library](../apps/macos/Library.swift): list/album/playlist queues, natural progression, paused Previous/Next, three-second Previous threshold, seeking, volume, shuffle and repeat off/all/one | [Player record](validation/player-interactions.md): focused tests and a real AVPlayer check with silent fixtures. This is not physical audible or hardware-control acceptance |
| Return to playback | `persistPlayback` / `restorePlayback` retain track, position, queue, order, shuffle and repeat, restoring paused | Automated state checks plus macOS screen relaunch/paused-navigation checks. Nonzero restored position was tested automatically, not in that screen run |
| Acquisition and offline saves | [LocalTransfer](../apps/macos/LocalTransfer.swift), [PlaybackCache](../apps/macos/PlaybackCache.swift), [OfflineSaves](../apps/macos/OfflineSaves.swift): verified acquisition, separate cache, track/album save jobs, retry/cancel, partial results and protected saves | Cluster save tests and [v5 record](validation/shared-audio-apple.md). Pending jobs resume while active; this does not guarantee background transfer after termination |
| v5 identity and pinned playback | [SharedAudio](../apps/macos/SharedAudio.swift): distinct logical tracks sharing bytes, independent save ownership, exact ID/hash playlist bindings, retained verified state and conflict/incomplete notices | Latest v5 record: 47 macOS tests / 50 expanded runs, zero failures/skips, including real Rust interoperability and MP3/M4A/FLAC hash-path playback. UI playback advanced to completion; physical audible output remains unverified |
| Settings and diagnostics | [SettingsView](../apps/macos/SettingsView.swift) and [PeerSetup](../apps/macos/PeerSetup.swift): membership, connection/conflict information, communication policy, storage and legacy connections; [PlaybackDiagnostics](../apps/macos/PlaybackDiagnostics.swift): bounded local playback records and export | [Diagnostic record](validation/playback-diagnostics.md) distinguishes tested recording/recovery from pending clipboard and physical checks. Preserve useful diagnostics without copying machine-specific details into fixtures |
| Appearance and input | [Appearance](../apps/macos/Appearance.swift): persistent System/Light/Dark; native keyboard menus, named controls and search/scroll restoration | [Appearance record](validation/appearance-switching.md) includes macOS screen and restart checks. Platform-native input, accessibility and small-window verification need their own acceptance; identical geometry is not the target |
| OS commands and interruptions | [PlaybackCommands](../apps/macos/PlaybackCommands.swift) supplies macOS menu shortcuts. OS media-session and audio-route/focus handlers were found in [PhonePlayback](../apps/ios/Sources/PhonePlayback.swift), which is iPhone code | Do not describe macOS global media keys or output-route interruption handling as delivered based on iPhone code. Windows/Android OS controls and lifecycle remain explicitly requested daily-use requirements |
| Mutations and remote access | Local/legacy UI includes visibility and playlist import/update operations; these are not evidence that v5 accepts them | ASO-53 now guards unsupported legacy mutations, and ASO-60 supplies typed transport. ASO-61–66 cover individual mutation contracts/implementation. ASO-40 owns v5 remote continuity |

The initial suggestion to omit shuffle/repeat is superseded as a target definition: both already exist on macOS and belong in the parity inventory. Their delivery order can be staged, but omitting them cannot be described as reaching the macOS feature set. Queue editing and cross-device handoff remain outside the accepted player scope.

## Proposed support contract

Both platforms should support joining an existing cluster and opening local audio without enrollment. Host creation is a separate role. A listener should be able to choose an album, hear its tracks in order, pause or seek, save it, and return to the saved music after restarting without a network connection.

In this table, **required** means required for the proposed daily-use claim, not an addition to the scope of ASO-10 or ASO-11. Windows refers to `apps/desktop`, the gpui replacement; the Win32 client remains available until its replacement is accepted.

| Concern | Windows daily-use requirement | Android daily-use requirement | Deferred from this baseline |
| --- | --- | --- | --- |
| Entry and catalog | Local audio without enrollment; join an existing cluster; retain the catalog offline | Same | GUI host creation and library administration |
| Browse | Albums, artists, tracks, recently added, search and playlist reading, preserving logical rows and organization | Equivalent native navigation | New v5 image retrieval and mutation features until their shared contracts are delivered |
| Queue | Snapshot the originating list; start the selected track; continue through the queue; inspect/select queued tracks; Previous/Next; retain exact playlist occurrence order/pins | Same | Queue editing and cross-device handoff |
| Shuffle and repeat | Match the implemented macOS history, stable shuffle order and repeat off/all/one semantics | Same | Initial delivery order still needs agreement; these are part of the macOS parity target |
| Acquisition | Play automatically selects an authorized source and acquires/verifies the needed whole file; responsive cancellation and failure/retry state | Same, with the accepted communication policy applied to cellular transfers | Progressive playback and speculative whole-album acquisition |
| Transport | Pause/resume and seek preserve intent; browsing does not change the queue; expose native volume control | Equivalent playback actions and platform volume control | Gapless and crossfade guarantees |
| Offline restart | Retain catalog, queue, selected track and position; restore paused; explicit Play works for verified local audio without contacting a host | Same, including a cold process launch rather than Activity recreation alone | Automatic playback after relaunch |
| Saves and cache | Track and album save actions; independent logical-track ownership, durable pending requests, partial results, retry/cancel and protected saved bytes; playback cache stays evictable | Same | Background save completion after app termination |
| OS media controls | SMTC metadata and Play/Pause/Previous/Next, including media keys while the app is unfocused | Media session, notification and lock-screen controls, including headset actions | Remote control of another playback device |
| Background and lock | Continue while minimized or the screen is locked and the computer remains awake; closing the app stops playback | Continue after leaving the Activity and while the screen is locked, using an OS-supported playback lifecycle | Windows tray/autostart behavior; playback through system sleep or after force-stop/termination |
| Interruptions | Pause when the output route is lost or the device suspends; retain position; require explicit resume | Pause on audio-focus loss or output-route loss; retain position; require explicit resume | Automatic resume after route reconnection, interruption or network recovery |
| Unavailable audio | Keep the requested track and explain failure; no silent substitution or automatic skip | Same | Remote access as a prerequisite for LAN playback |

Adopt the existing player's transport rules for these supported operations: Previous at three seconds or later restarts the track; below three seconds it selects the preceding track. Paused navigation does not start audio or acquisition. Natural completion advances, or stops at the retained last track. Explicit external Play and Pause commands are idempotent. Cancelling preparation or choosing another track invalidates late completion from the old request.

Logical-track identity, exact playlist revision pins, independent save ownership for tracks sharing bytes, and protection of original files remain existing requirements. A host being offline does not mean a track was deleted. Reuse the accepted acquisition and retention policy; do not infer a new policy from the legacy saved-only clients.

## Current implementation and evidence

Missing behavior below means the inspected source does not implement the contract. Pending verification means the cited evidence does not demonstrate the behavior; it is not a recorded failure.

| Area | Windows | Android |
| --- | --- | --- |
| Current playback path | [gpui model](../apps/desktop/src/model.rs) changes fixture playback state only; it has no audio or catalog backend. [Win32](../apps/windows/src/main.rs) plays an explicitly saved local file with MCI and supports pause/resume | [MainActivity](../apps/android/app/src/main/java/as/ason/syncstr/MainActivity.kt) owns a MediaPlayer, plays explicitly saved files, and exposes pause/resume and seeking |
| Queue and acquisition on Play | Missing in gpui and Win32. Win32 requires Save before Play | Missing: Play requires local audio, and completion does not advance to another track |
| v5 identity and independent saves | Legacy Win32 calls the [playback client](../headless/src/cluster_client.rs) using object hashes. gpui has no integration. ASO-11 owns the migration | [JNI](../apps/android/native/src/lib.rs) uses the same legacy hash-based client. ASO-10 owns the migration |
| Offline state | Legacy catalog and verified saves persist. Durable queue/position restoration is missing; native offline-restart audio acceptance is pending | Legacy retained catalog and saved audio have physical offline-relaunch evidence. Activity saved-instance state is not durable queue persistence across cold launches |
| OS controls and background | Product SMTC integration is missing. The toolkit experiment established HWND feasibility only. gpui UI/IME verification is not audio verification | No playback service or media-session integration in the [manifest](../apps/android/app/src/main/AndroidManifest.xml). `onStop` pauses; `onDestroy` releases the player |
| Interruptions | No evidence establishing the proposed output-loss and suspend contract | Audio-focus loss pauses. Physical route-loss, interruptions and background acceptance for this contract remain pending |
| Recorded verification | [M5 record](cluster-windows-m5.md): native build, automated checks and launch smoke; physical enrollment, audible playback and offline restart remain pending | [M5 record](cluster-android-m5.md): physical enrollment, verified MP3 acquisition and audible offline relaunch. The [refreshed UI handoff](android-ui-development-handoff.md) still requires device visual, accessibility and playback checks |

The OS integration must be evaluated separately from the Rust core design. Windows exposes [SMTC for an application's top-level HWND](https://learn.microsoft.com/en-us/windows/win32/api/systemmediatransportcontrolsinterop/nf-systemmediatransportcontrolsinterop-isystemmediatransportcontrolsinterop-getforwindow). Android's [background playback guidance](https://developer.android.com/media/media3/session/background-playback) separates the player/session lifetime from the Activity; its [audio-focus contract](https://developer.android.com/media/optimize/audio-focus) must also be respected. These references establish supported integration paths, not a decision to adopt a particular playback engine in ASO-45.

## Owner direction and remaining scope review

| Decision | Recommendation | Alternative and consequence | Status |
| --- | --- | --- | --- |
| What does "supported playback" promise? | Require the daily-use matrix; label earlier v5-only milestones narrowly | Accept saved-file foreground playback as the product baseline. It ships less behavior, but cannot claim continuous/background daily playback | Daily-use gate agreed, 2026-11-07 |
| Which initial entry paths are required? | Offer both local-only playback and joining an existing cluster | Ship cluster-join first and explicitly defer local import; this narrows standalone use | Both paths agreed, 2026-11-07 |
| What is the feature reference? | Reach implemented macOS behavior, including shuffle/repeat; preserve known v5 limits explicitly | An intentionally smaller initial milestone may precede parity, with its omissions stated | macOS reference and D4 staged delivery agreed, 2026-11-07 |

Windows hosting, remote access and distribution are separate decisions regardless of the chosen baseline. Building an executable or APK does not establish installer behavior, signing continuity, store eligibility or release readiness. Hosting remains with the host-role work; remote continuity remains with ASO-40. Do not add either to the v5 compatibility tickets implicitly.

## Existing Linear work

The Syncstr project inventory was read on 2026-11-07, including archived entries and pagination: the initial audit returned 36 issues, and the pre-publication check returned 37 before creating the follow-ups below, both with no further page. The relevant issue bodies and dependency relationships were inspected. Status below is that snapshot, not a completion claim based on the title alone.

| Existing issue | Status | Responsibility |
| --- | --- | --- |
| [ASO-10](https://linear.app/asonas/issue/ASO-10) | Backlog | Android v5 client, logical IDs, independent saves, offline restart and native verification |
| [ASO-11](https://linear.app/asonas/issue/ASO-11) | Backlog | gpui Windows v5 client and Win32 profile/behavior preservation; explicitly waits for ASO-45/48 agreement |
| [ASO-45](https://linear.app/asonas/issue/ASO-45) | Backlog | This per-platform support contract and bounded follow-up slices; design only |
| [ASO-48](https://linear.app/asonas/issue/ASO-48) | Backlog | Shared Rust core, binding and migration design; native UI/audio stay platform-owned |
| [ASO-12](https://linear.app/asonas/issue/ASO-12) | Backlog | Cross-platform shared-audio identity/save verification after ASO-9/10/11 |
| [ASO-57](https://linear.app/asonas/issue/ASO-57) | Done | gpui scaffold and Windows/macOS CI; fixture UI, not audio playback |
| [ASO-56](https://linear.app/asonas/issue/ASO-56) | Backlog | Windows gpui IME overlap; adopted patch validation belongs here |
| [ASO-51](https://linear.app/asonas/issue/ASO-51) | In Progress | Toolkit experiment and its remaining list/memory/media-key evidence |

ASO-50 is Done for choosing gpui. ASO-58 evaluates gpui on macOS; it is not a Windows/Android porting ticket. ASO-9 is Done for Apple v5 implementation, while its older body and ASO-10/12 still contain pre-merge notes; main already includes the server and Apple client. Use current source and the latest validation record instead of those stale starting-point statements.

No dedicated implementation issue for the complete daily-player gap (queues, shuffle/repeat, native media controls and Android background playback) was found in the initial inventory. The published follow-ups below track those gaps; ASO-10/11 retain v5 compatibility ownership. Settings, appearance and diagnostics still need scoped per-platform slices in ASO-45 rather than being hidden inside the v5 tickets. Shared prerequisites remain ASO-39 (v5 enrollment), ASO-40 (remote), ASO-42 (offline playlist editing), ASO-44 (host roles), ASO-46 (scoped incomplete state) and ASO-47 (artwork). ASO-53/60 are now Done; individual mutation work remains ASO-61–66.

## Bounded implementation sequence after agreement

These are the accepted delivery boundaries under D4. Native implementation and acceptance belong to the tracking issues below; unresolved Apple adoption and full-parity follow-up details remain explicitly gated.

| Slice | Boundary and ownership | Completion evidence |
| --- | --- | --- |
| 1. Preserve v5 identity and saves | Existing ASO-10 for Android and ASO-11 for the gpui Windows replacement; use the ASO-48 core decision. Preserve existing credentials and profiles. Keep Win32 until replacement acceptance | Existing compatibility checks plus isolated-profile device verification; retain ASO-12 ownership of cross-platform identity/save acceptance |
| 2. Queue and native playback, one platform per issue | Deterministic queue, transport, shuffle/repeat, automatic verified acquisition, cancellation and durable paused restoration. Keep native audio engines outside the shared core as directed by ASO-48 | Reuse current Apple contracts and fixtures for focused parity tests; physical multi-track playback, seeking and offline cold restart |
| 3. Library and save UI, one platform per issue | Browsing/search, recently added, playlist reading, queue inspection and album save controls, backed by slices 1/2 | Verify distinct rows, organization/order, saved-only/offline views, partial saves and preserved browse context through the native UI |
| 4. Windows OS controls | SMTC and minimize/lock/output-loss behavior | Native command checks plus physical media keys, lock and output-loss/suspend evidence |
| 5. Android playback lifecycle | Playback service/session, notification/lock-screen controls and focus/route-loss behavior | Physical headset, background/lock and interruption evidence; distinguish normal backgrounding from termination |
| 6. Standalone entry, one platform per issue | Local import/open and retained local catalog without enrollment; preserve originals and keep membership optional | Fresh isolated profile can import, play and restart offline without cluster credentials |
| 7. Settings and presentation parity | Separate per-platform issues for connection/storage/communication settings, diagnostic export and persistent native appearance. Keep legacy transport compatibility distinct from new v5 behavior | Focused persistence/export checks and native appearance, keyboard/accessibility and small-window interaction evidence |

ASO-57 establishes the gpui UI scaffold and ASO-56 resolves its IME issue; neither completes Windows playback. ASO-45 and ASO-48 supply the product and architecture decisions needed before ASO-11 implementation. Start from current main and coordinate any future shared `headless` edits with active work there.

## Published implementation issues

The following Backlog issues record the bounded platform work under the accepted D1–D4 contract. ASO-10/11 continue to own v5 compatibility; the new issues do not replace them. ASO-45/48 remain open for their separate full-parity and Apple obligations.

| Capability | Windows | Android |
| --- | --- | --- |
| Queue, native playback and restoration | [ASO-72](https://linear.app/asonas/issue/ASO-72) | [ASO-75](https://linear.app/asonas/issue/ASO-75) |
| Library browsing and save controls | [ASO-73](https://linear.app/asonas/issue/ASO-73) | [ASO-76](https://linear.app/asonas/issue/ASO-76) |
| Standalone local audio import | [ASO-74](https://linear.app/asonas/issue/ASO-74) | [ASO-77](https://linear.app/asonas/issue/ASO-77) |
| OS controls and playback lifecycle | [ASO-78](https://linear.app/asonas/issue/ASO-78) | [ASO-79](https://linear.app/asonas/issue/ASO-79) |

The [shared Rust design](shared-rust-client-design.md#published-implementation-issues) links ASO-68–71 for the binding experiment, Apple packaging measurements, logical catalog and verified save ownership. Settings, appearance and diagnostic parity still need agreed platform boundaries before separate implementation issues are created.

## Acceptance record to collect

Record the commit, platform/OS, fixture and outcome separately for each evidence level. Use fictional tracks and an isolated profile; do not alter a daily-use library or enroll a test client without authorization.

| Evidence level | What it establishes | What it cannot establish |
| --- | --- | --- |
| Build and focused automated tests | Compile/link, queue transitions, cancellation, persistence and v5 identity/save contracts | Audible output, real device routing or OS controls |
| Emulator and native UI checks | Visible states, commands, navigation and reproducible lifecycle scenarios; Android emulator where supported | Physical headset/media-key behavior, OEM lifecycle behavior or audible device acceptance |
| Physical audio and OS integration | Audible continuity, transport, offline restart, background/lock, media controls and interruption recovery | Packaging, signing, store delivery or remote-network support |

Use three acceptance scenarios for each platform, with any failure linked to its owning slice:

1. From a three-track album with uncached audio, Play the second track, change the browsing view, seek, pause and resume, then hear the third track and observe a stopped final state. Cancel or supersede one acquisition and confirm its late completion never plays.
2. Save two logical tracks that share bytes independently, remove one save, and confirm the remaining save is protected. Restart offline: retain catalog, queue and position, remain paused, and play the saved track explicitly. Report unavailable unsaved audio without substituting another track. Keep shared identity/save assertions under ASO-12.
3. While playing, minimize/leave the Activity and lock the screen; exercise Play, Pause and navigation from native controls. Disconnect the output route and trigger a supported interruption. Confirm pause, retained position and explicit resume. On Windows, also verify closing the app stops playback; on Android, distinguish normal backgrounding from force-stop.

ASO-45 can close only after the owner agrees on the contract, deferred items and follow-up boundaries. This draft and its source audit alone do not satisfy that condition.

# Player interaction specification

Status: accepted. Q1–Q23 and the consolidated specification are confirmed. Application implementation has not started.

## Goal and scope

Define predictable playback, queue behavior, and state presentation for macOS and iPhone. Preserve the established visual direction and dimensions except for the explicit changes below. Current track, position, queue, shuffle, and repeat are device-local; cross-device playback handoff is separate work.

Use the accepted [cluster interaction specification](cluster-ui-review.md) for authorized source selection, whole-file acquisition and verification, cache retention, offline saves, cellular policy, and acquisition failure. Do not introduce a competing storage or transfer policy.

## Current implementation evidence

Read-only inspection found shared playback in [Library.swift](../apps/macos/Library.swift), macOS controls in [Syncstr.swift](../apps/macos/Syncstr.swift), and iPhone controls in [PhoneRoot.swift](../apps/ios/Sources/PhoneRoot.swift), [PhoneNowPlaying.swift](../apps/ios/Sources/PhoneNowPlaying.swift), and [PhonePlayback.swift](../apps/ios/Sources/PhonePlayback.swift).

The inspected implementation always moves back on Previous; does not restore playback state across launches; toggles pause/resume from album Play when that album is active; and has separate iPhone full-player tab and sheet entries. macOS preparation presentation does not consistently match its toggle behavior. These facts require rechecking against the implementation checkout. No audible playback, interruptions, or hardware controls were verified during this interview.

The earlier visual audit observed an unselected macOS player with disabled transport and zero durations, plus overlap with lower artist rows. Its running executable was not matched to main. The contracts below, rather than those screenshots alone, define acceptance.

## Queue construction and navigation

- Starting playback from a library row snapshots that originating list into the queue and starts the selected track from the beginning, including when it is already current. Albums use disc/track order; track lists and search results use displayed order.
- Subsequent browsing, search edits, or screen changes do not mutate the active queue. Starting playback from another list replaces it.
- Album Play always rebuilds the album queue and starts with the album's first track. Pause/resume belongs to the player. If shuffle is enabled, the selected starting track remains first and subsequent ordering follows shuffle rules.
- Selecting a row inside the active queue starts that track without rebuilding the queue.
- Both apps show the queue and permit track selection. Queue reordering, next-up insertion, and adding/removing entries are deferred.

## Transport rules

| Operation or event | Required behavior |
| --- | --- |
| Player pause/resume | Pause at the current position or resume from it. Completed final-track playback restarts that track from the beginning. |
| Previous at position >= 3 seconds | Seek to the current track's beginning. |
| Previous below 3 seconds | Move to the preceding queued track, subject to repeat boundaries. At the first track without wrapping, still allow restarting that track. |
| Previous/Next while paused | Change the selected track without starting audio. Do not acquire uncached audio until Play. |
| Previous/Next while playing | Move under queue/repeat rules and continue playback intent, acquiring audio as required. |
| Seek | Change position while preserving playing/paused intent. Seeking is unavailable until the audio is ready. |
| Natural end with repeat off | Advance if a next track exists; otherwise stop and retain the final track and queue. |
| Play after queue completion | Restart the retained last track. Use album Play to restart the album. |

Lock-screen, headset, and media-key controls use these same semantics where the platform exposes them. Distinguish explicit Play/Pause commands from toggle commands; external operations must not invert the listener's intent merely because they arrive twice.

## Shuffle and repeat

- Enabling shuffle during playback preserves the current track, position, playback intent, and already traversed prefix. Randomize only the sequence after the current track so Previous can return to the track just heard.
- Disabling shuffle restores source-list order without restarting the current track or changing its playing/paused intent. This explicitly replaces shuffle ordering, including navigation order.
- Keep a decided shuffle order stable during the round and restore it across application restarts; do not randomize merely because a view or app reopens.
- Repeat modes are off, all, and one. Repeat-one applies to natural completion; manual navigation may move to other tracks and does not gain repeat-all wrapping.
- Repeat-all wraps queue boundaries. With shuffle enabled, natural completion of a round creates a new permutation; when multiple tracks exist, its first track must differ from the track that just ended. Manual boundary navigation follows the established queue order rather than inventing a new round.

## Playback state and presentation

| State | Presentation and action |
| --- | --- |
| No track selected | Hide the mini-player. Do not show disabled transport or zero durations as an idle placeholder. |
| Preparing | Show track information, preparation status, and a distinct cancel action. Disable seeking; another track may be selected. |
| Playing | Show current track and appropriate pause/transport controls. |
| Paused or completed | Retain selected track, queue, and mini-player; show the appropriate Play action. |
| Acquisition failed | Stop at the requested track with a reason and manual retry. Do not automatically skip or start on reconnection. |
| Restored track deleted from library | Explain that it cannot be played and remain stopped until another track is selected; do not silently substitute a different track. |

Changing tracks or cancelling preparation supersedes the old playback request. Late acquisition completion must not start the old track. A host being offline is not evidence of deletion; retain the track, position, and catalog in that case.

## Mini-player and full-player responsibilities

- Track information/artwork opens the full player independently of transport controls. A playback button never also navigates.
- iPhone uses the mini-player's full-player sheet; remove the separate Now Playing tab. Both full-player implementations provide queue inspection and selection.
- macOS uses the in-window detail view. Returning restores the prior library search and scroll position.
- Reserve enough scrollable clearance to fully expose the final row when the mini-player is visible.
- Compact macOS retains track information and basic transport. Seeking remains available in the full player when omitted from the mini-player.
- Preserve the platform-native materials, semantic colors, control names, and dimensions in [DESIGN.md](../DESIGN.md), except where these accepted visibility/navigation changes supersede earlier behavior.

## Restoration, interruptions, and background use

- Persist current track, position, queue including its decided order, shuffle, and repeat. Restore them paused, without audio or automatic acquisition on launch. Play may acquire missing audio and resume the retained position.
- Pause on OS audio interruption. Its end does not automatically resume playback.
- Pause on unexpected loss of the active headphones or Bluetooth output. Neither speaker fallback nor reconnection resumes playback. Explicit user selection of another output is distinct from unexpected loss.
- Continue background audio where supported, including when switching apps or closing the playback screen. This is not a promise of continued playback after application termination.
- If OS restrictions prevent acquiring the next queued track, retain the stopped state and expose the reason and manual retry on return. Do not promise unsupported background transfers.

## Implementation work packages

1. **Transport and queue semantics:** implement shared navigation, album Play, stable source-list snapshots, shuffle history, repeat boundaries, and command intent.
2. **Persistence and audio events:** restore device-local state paused, handle unavailable/deleted tracks, and align interruptions and output-loss behavior.
3. **Acquisition coordination:** integrate the cluster specification's preparation, cancellation, supersession, and failure rules; defer uncached acquisition during paused navigation.
4. **Apple presentation:** align mini/full-player states, consolidate iPhone entry, expose its queue, preserve macOS navigation context, and ensure content clearance.

Reuse existing player and transfer boundaries. Persistence schema, event serialization, and platform mechanisms are implementation decisions within these observable contracts. Keep the cluster specification's work packages coordinated with these; do not implement duplicate acquisition or cache systems.

## Acceptance scenarios

| Scenario | Required result |
| --- | --- |
| Start from album, tracks, or search | Snapshot the correct order, start the selected track, and preserve the queue during later browsing. |
| Album Play while the same album is active | Rebuild and start from the album beginning rather than pausing or resuming. |
| Previous around the 3-second boundary and at queue start | Apply the threshold exactly and retain a usable restart action. |
| Paused Previous/Next/seek, including an uncached track | Change selection/position without audio; do not acquire uncached audio before Play. |
| Re-select current library row versus a queue row | Restart the selected track; only library-origin playback rebuilds the queue. |
| Off/all/one at natural completion and manual boundaries | Follow the distinct natural/manual rules; preserve the last track when playback ends. |
| Toggle shuffle midway, restore after relaunch, repeat a round | Preserve current position and traversed prefix on enable, restore source order on disable, persist decided order, and avoid adjacent repeats across randomized rounds. |
| Cancel preparation or rapidly select another track | A late result never starts the superseded track; UI action and label match. |
| Relaunch with local, uncached, offline-host, or deleted current track | Restore paused without acquisition; distinguish temporary unavailability from deletion. |
| Audio interruption or active-output loss | Pause without automatic resumption, including after reconnection or interruption end. |
| Background playback and external commands | Apply the same transport rules; report unsupported next-track acquisition accurately. |
| No track, preparing, playing, paused, ended, or failed UI | Correct controls, labels, cancellation/retry, and mini-player visibility on both platforms. |
| Full-player navigation and compact layouts | Preserve macOS search/scroll, expose iPhone queue, separate navigation from transport, and keep final rows reachable. |

Use focused state/queue tests with independently derived sequences, plus actual platform interaction checks. Record tested build identity. Verify keyboard access, VoiceOver labels/state feedback, physical interruption/output behavior, and audible playback separately from compilation and automated tests.

## Decision closure

All interview decisions Q1–Q23 are recorded above. The listener confirmed the consolidated specification as the shared understanding. Application implementation and distribution remain separate from this documentation work.

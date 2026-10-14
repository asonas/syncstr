# Player interaction verification

## Implemented locally

The accepted [player specification](../player-interaction-spec.md) is implemented in the shared Apple player and both interfaces. Transport preserves paused intent, Previous uses the three-second threshold, album playback starts a new queue, shuffle preserves the traversed prefix, and natural shuffle/repeat rounds avoid adjacent repeats. State restores paused with the decided queue order. Missing/deleted tracks, cancellation, late acquisition results, interruptions, and output loss have explicit handling.

The mini-player is hidden before selection. iPhone uses one full-player sheet with queue inspection. macOS keeps library content mounted behind the full player so search and scroll context survive return. Preparation and failure controls use distinct cancellation/retry feedback, and seeking requires ready audio.

Playback acquisition uses existing verified transfer paths with a separate cache. It does not record an explicit offline-save receipt or evict existing saved audio, host copies, or original import sources. The cache defaults to 10 GB, has a configurable limit, and accounts separately from protected audio. A cached track can be promoted to an explicit cluster save without another download. Broader cluster onboarding, persistent save jobs, and album save-removal work remain outside this player delivery.

## Automated checks

- macOS focused run: eight shared player tests and ten existing local-transfer tests passed. These cover queue snapshots, paused transport, the Previous threshold, album restart, shuffle history, restoration, deletion, cancellation, background acquisition, cache-budget protection, and legacy verified playback acquisition.
- The initial macOS full-suite run executed 76 tests with six environment-dependent skips and found one cache-protection failure. Canonicalizing protected paths corrected that failure; the affected tests passed on the focused rerun. The entire suite was not repeated after that focused correction.
- The standalone real-AVPlayer check passed with silent fixtures: offline playback, source-folder restoration, album/organization stability, pause/resume, seeking, natural progression, final-track restart, repeat-all/one, and volume behavior.
- A final macOS run of all eight shared player tests passed after the last implementation change.
- The iOS application and test bundle compiled successfully for the iOS simulator. iPhone simulator boot did not return; a direct test attempt on an already-booted iOS simulator also remained in test-application startup without emitting test results and was stopped. iOS runtime tests, including the added interruption/route notification assertions, remain unverified. Compilation is not a test-pass claim.
- Swift syntax parsing and Git whitespace checks passed.

No headless test binary was available for the optional live Swift/Rust cluster interoperability tests. The cache-only cluster-download assertion is present in that suite but was skipped with its environment gate. Actual cluster source failover and end-to-end playback-cache acquisition require that verification.

## Native screen checks

The locally built macOS application was launched using the repository launcher. Its executable path and single-process state were verified against the worktree build, rather than the installed distribution app. The debug executable was linker-ad-hoc signed; this is not distribution validation.

Observed on the new macOS build:

- No mini-player before track selection.
- Acquisition failure displays its reason, disables unavailable seeking, and offers manual retry.
- The full player shows the unchanged active queue even while the library search is filtered.
- Returning from the full player retains the search text and filtered list.
- Relaunch restores the selected track and queue paused, with Play available and no playback acquisition started.
- Next while paused changes selection without starting audio or acquisition.

The resize gesture did not change the window, so narrow-window behavior was not visually verified. The two-row library used for these checks does not establish final-row reachability in a long list. Nonzero restored position is covered by automated state tests rather than this screen run.

## Outstanding acceptance

- iPhone screen interaction, Dynamic Type, and VoiceOver traversal.
- Physical audible playback, real phone interruptions, headphones/Bluetooth disconnect and reconnect, and macOS output-device changes.
- Actual cellular acquisition, background OS suspension, and hardware media controls.
- Narrow layouts, long-list clearance, reduced transparency/motion, and measured whole-file startup delay.
- Real-cluster cache acquisition, failover, and protected-save promotion against live hosts.

Automated notification checks do not substitute for physical audio-route verification. Main integration, push, TestFlight/App Store distribution, and production data repair are separate from these local checks.

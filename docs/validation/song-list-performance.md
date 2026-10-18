# macOS song-list performance

The song list resolves `visibleTracks` once per geometry-content evaluation and
shares that array with row construction, playback actions, and the empty state.
Previously, realizing each row filtered the entire catalog again on the main
actor. Search and catalog changes still produce a fresh array; no persistent
cache or invalidation mechanism is added.

## Validation on 2026-10-19

SwiftUI Instruments recordings used the same retained library, window size,
25-second recording limit, and half-page scroll sequence: ten downward scrolls,
then fifteen downward and fifteen upward scrolls. The baseline local build had
the earlier artist-layout improvement but the original song-list implementation.
The candidate is based on main at `2ba8bb9` with only the song-list change.

`Library.visibleTracks.getter` appeared in 7,104 of 31,405 CPU samples before
the change (22.6%), versus 1,556 of 47,836 afterward (3.3%). These are inclusive
stack-sample shares, not wall-clock time, FPS, or an end-to-end hitch reduction.
Automation timing and profiling overhead differ between recordings. The result
supports removal of the repeated row-level catalog scan, not elimination of
every possible rendering stall.

The maximum `LazySubviewPlacements<LazyVStackLayout>` update fell from 97.89 ms
to 9.64 ms. Its accumulated inclusive duration fell from 1,448.87 ms to
230.33 ms. Inclusive update durations must not be added together as CPU time.

- Signed macOS Debug build and strict code-signature verification passed.
- The repository launcher verified one process running the candidate build,
  using the existing local-build bundle identifier and retained library.
- Repeated scrolling, the normal table, search focus and typing, matching
  results, no-match state, and clearing search were checked in the app.
- Selecting a search result and advancing selected the next result in that
  filtered list. Clearing search preserved the selected playback item.
- Playback preparation was cancelled through Controls. Audio acquisition did
  not finish during this check; audible playback and pause/resume are unverified.
- Whitespace validation passed. No source-shape test was added for this view
  evaluation change; the regression was measured through the real app.

The iPhone list already passes one resolved track array into its rows and needs
no corresponding change. Shared library and playback code are unchanged; iPhone
build/device verification and narrow-window inspection were not performed.
Main integration, push, and distribution were not performed.

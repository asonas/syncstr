# Artist scrolling validation

## Change

The macOS artist screen virtualizes album groups with an outer `LazyVStack`.
Rows inside a realized album use a regular `VStack`, so discovering individual
rows does not repeatedly revise the album's height during scrolling. Album
details and the playback queue retain their lazy row containers. Row actions,
ordering, separators, and accessibility labels share the existing implementation.

This is a macOS view-only change. The iPhone view and shared library, database,
transfer, and playback code are unchanged. Hover state was not changed because
profiling did not establish it as the cause.

## Validation on 2026-10-18

- Signed Debug build succeeded with the existing local-build bundle identifier.
- The repository launcher verified a single process running the new build.
- The same retained library showed 26 albums and 281 tracks for the selected
  artist. Wide layout, repeated scrolling, reaching the final album and its final
  track, returning to the beginning, and opening an eight-track album passed.
- Whitespace validation passed. No source-shape tests were added: the regression
  is layout cost and was checked in the actual application with Instruments.

SwiftUI profiling used approximately 20-second recordings and repeated half-page
scrolls. The maximum `LayoutChildGeometries` update fell from 12.23 ms to 0.16 ms;
its inclusive accumulated duration fell from 237.49 ms to 3.86 ms. Inclusive
durations are not additive CPU time or an FPS measurement. Album realization
still has a cost, and these measurements include automation/profiling overhead.

Do not claim an end-to-end hitch-count improvement from these recordings. The
second hitch export included near-continuous 16.67 ms records even outside the
scroll loop, unlike the first capture; its count is not a reliable like-for-like
comparison. The evidence establishes reduction of the identified layout hotspot,
not elimination of all rendering stalls.

Narrow-window resizing was attempted but the automation did not change the window
size, so compact-layout visual verification remains incomplete. Physical-device
and TestFlight validation, main integration, and push were not performed.

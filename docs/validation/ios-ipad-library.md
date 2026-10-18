# iPhone and iPad library operations

The mobile library now supports the approved album operations and playback
diagnostics, with native navigation for each device family. This report separates
Simulator evidence from device checks still needed before distribution.

## Implemented scope

- iPhone keeps its Library, Search, and Settings tabs. iPad uses a native split
  view that collapses in narrow windows.
- Album grids adapt to width and use one column at accessibility text sizes.
  Details use horizontal artwork and metadata in wide layouts and a vertical
  arrangement in compact layouts. Native navigation provides Back and Search.
- The album browser supports title/artist sorting, ascending/descending order,
  explicit batch selection, Command-click selection, and synchronized hide/restore
  through the existing library metadata operations. Returning centers the opened
  album. Context menus remain available.
- Album details use the existing compilation artist presentation (`V.A.`), an
  icon-only download control, and no hide action in the header. Current track
  rows use the accent background; current or hovered rows show Play.
- Playback errors and Settings expose the shared JSONL diagnostic exporter.
  Attempt creation was previously macOS-only; mobile playback now starts and
  links attempts too. Retention, redaction, and retry ancestry remain shared.

The editable [Figma comparison](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=123-196)
contains iPhone, regular iPad, and compact iPad layouts.

## Automated verification

Focused iOS checks passed across serial runs:

- Eight library presentation tests, including sorting, visibility, stale playback
  results, and UI responsiveness during database work.
- One diagnostic test covering failed acquisition, retry ancestry, and JSONL.
- Two offline playback tests and two local-library tests, including cold launch
  and AVPlayer playback of a temporary audio fixture.

The existing missing-audio test originally asserted after a fixed number of
executor yields. It now waits for the public failure state with a bounded timeout.
One responsiveness deadline failed during competing Simulator test jobs and
passed on the focused serial run; the deadline was not relaxed.

The macOS build and 22 focused library/diagnostic tests passed after the shared
sorting and diagnostic UI changes.

UI tests launch a Debug-only fictional catalog with isolated temporary storage
and credential services. The fixture is excluded from Release builds. No
production catalog, cached audio, or connection settings are deleted.

On iPhone Simulator, sorting and batch hide/restore, returning to the opened
album, playback failure copying, long-press menus, and accessibility-sized grids
passed. Command selection and search focus checks also passed: Space enters text
while editing, but does not alter the preserved query after returning from
details. Native search initially restored editing on return; explicitly ending
search and restoring only its query resolved that regression.

On a narrow iPad Simulator window, sorting and batch hide/restore,
restoration, failure copying, Command selection, and search keyboard behavior
passed.

The iPhone artist list was exercised with 281 fictional tracks. Three measured
scroll-deceleration durations averaged 2.300 seconds. This measures the gesture's
deceleration interval, not frame rate or main-thread blocking. Without a matching
baseline it does not establish a performance improvement; no speculative artist
list restructuring was added.

## Remaining device checks

- Inspect the regular-width iPad window, rotation, and interactive window resizing.
- Verify external-keyboard and pointer behavior on physical iPad hardware.
- Verify audible playback, audio-session activation, interruptions, lock-screen
  controls, and background behavior on physical devices.
- Exercise hide/restore synchronization between enrolled devices and production
  audio acquisition in TestFlight. The UI fixture proves client interaction, not
  remote service availability.

Local builds and Simulator results do not establish TestFlight delivery.

The Simulator emitted an audio-session main-thread responsiveness warning during
playback tests. These tests do not establish physical-device activation latency;
that remains part of the playback check above.

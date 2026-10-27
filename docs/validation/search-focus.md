# macOS search focus validation

The library search field accepts automatic first-responder requests only while
handling its own mouse click. A window-scoped local mouse-event monitor ends
editing when a left or right click occurs outside the field. The event is returned
unchanged so the clicked control still receives its action. The monitor is removed
when the field moves between windows or SwiftUI dismantles it.

## Verified on 2026-10-18

- Signed macOS Debug build succeeded; the repository launcher confirmed exactly
  one process running the new app, using the existing local bundle identifier.
- After launch and library restoration, the window, not search, had focus.
- Space started the restored track and Space again paused it.
- Clicking search allowed typing a query and a space without starting playback.
- A pointer click on empty content ended editing; Space then resumed playback.
- A pointer click on an artist opened its albums and ended editing. Space resumed
  playback without changing the query; a second Space paused it.
- The query remained intact after leaving search. Whitespace validation passed.

Native pointer clicks were used for outside-click verification. Accessibility
press actions may invoke buttons without delivering mouse events and therefore
are not equivalent to this interaction. VoiceOver-specific interaction and IME
composition were not independently verified. iPhone code is unaffected.

The build also includes the preceding artist-scroll change. Main integration,
push, and TestFlight distribution have not been performed.

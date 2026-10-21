# macOS Recently Added

The sidebar destination reuses the album grid and the shared
`Library.recentlyAddedAlbums` projection. It preserves newest-addition order
during search and omits the ordinary album sorting menu. Normal Albums retains
its sort settings. Hidden albums remain excluded. Album details return to this
destination through the existing centered-scroll behavior.

## Verification

- `LocalMusicTests/LibraryPresentationTests` passed all nine tests. The extended
  contracts cover destination ordering, title/artist search, ordinary sorting
  after navigation, and hidden/restored album membership. Existing tests cover
  persisted dates, undated records, and newly added member tracks.
- Both the macOS app and generic iOS Simulator app built successfully. The iOS
  Recently Added entry remains unchanged because it already uses the shared
  addition projection directly.
- Computer Use checked the macOS validation app after the launcher confirmed a
  single process at the requested executable path. Checks covered the sidebar
  entry, grid, absent sort menu, search focus/typing/clear, album detail and return,
  Command selection and Escape, and a narrow window. Light appearance was used.
- A subsequent macOS rebuild enabled native text selection on the album detail
  title. Computer Use selected the full title by dragging, copied it with
  Command-C, and verified the exact title pasted into search with Command-V.
  The temporary search was then cleared. iOS title selection is unchanged.
- Date ordering was checked with controlled fixtures. The visual run did not
  import tracks, change visibility, or exercise production audio playback.

Dark-appearance visual acceptance, physical-device verification, TestFlight
distribution, and main integration are not established by these checks.

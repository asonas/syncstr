# Appearance switching on Apple platforms

Settings offers System, Light, and Dark on macOS, iPhone, and iPad. System is the
default. The device preference persists through `AppStorage`; it is independent
of shared library metadata. A shared view modifier applies the selected scheme
to the library and Settings, with presented player screens inheriting it.

## Palette and native surfaces

Both application targets compile `apps/macos/Appearance.swift` and
`apps/macos/Appearance.xcassets`. Named colors adapt to the view's appearance.
The [mobile reference](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=135-325)
and [Mac reference](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=139-1754)
provide the light values.

| Role | Light | Dark |
| --- | --- | --- |
| Content | `#FFFFFF` | `#232426` |
| Sidebar / placeholder | `#F5F6F8` | `#121214` |
| Hover / neutral control | `#EDEFF3` | `#45464D` |
| Primary text | `#202126` | `#FFFFFF` |
| Secondary text | `#5C6069` | `#A6A8AD` |
| Action text / icons | `#2A65D1` | `#528FFF` |
| Filled Play / current row | `#1253FF` | `#1253FF` |
| Content separators | `#D9DDE4` | `#45464D` |

White remains the foreground for blue Play buttons and current-track rows.
Neutral controls and separators have separate roles. Artwork has an adaptive
separator outline inside its rounded bounds, one physical pixel wide at the
current display scale. Image dimensions and the original Regen SVG geometry
are unchanged. Native toolbars, search, tabs, and floating
players retain system materials and semantic material foregrounds.
The appearance review boards also use inside artwork strokes: one third of a
point for the 3x phone reference and half a point for the 2x tablet/Mac references.
Light strokes bind to the existing `border/subtle` variable; Dark uses `#45464D`.

## Verification

- The macOS build succeeded. Computer Use confirmed Settings and library windows
  update together when choosing Light and Dark. Album details, track text,
  search, sidebar, and the floating player were inspected in both appearances.
  Restart retained Dark. Selecting System returned the app to the current OS
  light appearance. The host OS appearance setting was not changed.
  A final rebuild and restart confirmed the outline around white artwork in
  both the album grid and album details.
- The iPhone UI flow passed: default System, Light, relaunch with Light retained,
  Dark, relaunch with Dark retained, and return to System. Screenshots include
  Settings and album details. UI tests use a fictional catalog and a separate
  preference suite; resetting test appearance does not change production prefs.
  After the outline change, another iPhone run confirmed System follows a dark
  Simulator appearance and an explicit Light choice overrides it. The selected
  row's white save action, outlined artwork, and light full player were inspected.
- The same preference and relaunch flow passed on iPad Simulator, including
  Light and Dark album details and a selected row. This run used a narrow
  multitasking window; a full-width iPad visual check remains separate.
- A runtime palette test passed on iPhone Simulator. It resolves the compiled
  color assets with light and dark trait collections, verifies changing content
  and text accents, and checks normal-text contrast for the represented text
  roles and white on the filled action color. This does not establish contrast
  for every native material over arbitrary artwork.

Simulator fixture audio is intentionally absent; these checks cover appearance,
not production transfer or audible playback. Physical iPhone/iPad, TestFlight,
increased contrast, and reduced-transparency visual checks remain separate.

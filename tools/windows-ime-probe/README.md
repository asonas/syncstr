# Windows IME placement diagnostics

Throwaway diagnostics for ASO-56. Run on an unlocked Windows desktop with one
`Syncstr Desktop` scaffold window. These tools do not inspect a real library.

```powershell
mise exec -- cargo build --release --locked --manifest-path tools/windows-ime-probe/Cargo.toml
& tools/windows-ime-probe/target/release/windows-ime-probe.exe observe
& tools/windows-ime-probe/target/release/windows-ime-probe.exe bottom
& tools/windows-ime-probe/target/release/windows-ime-probe.exe normal
```

`observe` reads window DPI and physical window/work-area rectangles. `bottom`
and `normal` also move the scaffold, preserving size, activation and z-order.
The helper verifies the caption and executable filename, rejects minimized or
maximized windows, and verifies the requested position. Run one instance only.
The bottom placement puts the window top 150 logical pixels above the work-area
bottom. The helper does not read another process's IMM context or determine B3.

For the visual repro, select Microsoft IME or Google Japanese Input and hiragana
mode, place the scaffold at the bottom, and focus Search. In a computer-use Node
session, import `reproduce.mjs` from this directory and run:

```js
await reproduceB3(sky, desktopWindow)
```

The routine clears Search, sends roman letter keys for `kyouhaiitenki`, opens
conversion candidates and returns a settled screenshot. Review whether the
candidate footer covers the composing text. It does not infer pass/fail from
accessibility text; candidate pixels are the acceptance evidence. This exact
routine was run against the pinned backend and the exclusion-rectangle build.

## Upstream source patch

`gpui-candidate-exclusion.patch` targets Zed revision
`4304dec732a75505066de5ce2dbbfb2bec369498`. Apply it to a separate Zed checkout:

```powershell
git -C ../zed apply ../syncstr/tools/windows-ime-probe/gpui-candidate-exclusion.patch
```

It preserves the caret rectangle through both Windows update paths and sends
`CFS_EXCLUDE` with an outward-rounded physical exclusion rectangle. Zero-width
carets exclude at least one physical pixel. Composition-window placement remains
at the caret center. The candidate point is at the rectangle's bottom.

The desktop adopts this patch through its
[vendored Windows backend](../../apps/desktop/vendor/gpui_windows/README.syncstr.md).
The patch contains the source changes; the vendor manifest separately expands
upstream workspace inheritance. Do not edit a shared Cargo cache as a durable
installation method. During the earlier comparison experiment, the two source
files were backed up and restored byte-for-byte, and the backend artifacts were
explicitly rebuilt for each variant.

See [the validation report](../../docs/validation/windows-gpui.md) for the
initial-position input fix, coordinates, screenshots and remaining work.

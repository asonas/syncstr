# gpui Windows scaffold and IME verification

Windows interaction checks for ASO-57 passed on 2026-11-07. ASO-56 has two
separate findings: the scaffold initially rejects the first IME caret query
while showing its placeholder, and the pinned gpui backend supplies a point
inside the text instead of an exclusion rectangle. The input condition is
corrected in this branch. The backend patch is adopted through the vendored
`gpui_windows` dependency, and the ordinary release build passes B1–B5 with both
IMEs at both requested scales. Earlier comparison evidence is preserved below.

## Build and scope

- Base: merged PR #20, commit `fcbebcbedd9cf9a02708000b8cb5158e297470d1`.
- gpui and gpui_platform: Zed `4304dec732a75505066de5ce2dbbfb2bec369498`.
- Windows 11 Pro 26H2, build 26300.9711; Rust 1.99.1 x64 MSVC;
  Windows SDK 10.0.26100.0, including `fxc.exe`.
- Microsoft IME component version 10.0.26100.9549 and Google Japanese Input
  TIP component version 3.34.6260.0, as recorded in ASO-51. These are file
  versions, not About-screen product versions.
- 3840 × 2160 display, 125%/120 DPI and 150%/144 DPI verified on the window.
  A fresh process was launched after each IME or scale change. The registered
  TSF profile was verified by description, with provider-specific candidate UI.
- Only `apps/desktop` and diagnostic artifacts changed. No headless, Win32,
  Swift, playback-core, cluster or real-library code was changed.
- Source branch: `codex/windows-gpui-validation`. Existing worktrees and
  unrelated main edits were preserved.

## ASO-57: Windows interaction

The release executable was identified by its full path and one running process.
The window displayed Search, 5,000 fictional tracks, Play/Pause and playback text.

| Check | Observed result |
| --- | --- |
| Tab / Shift+Tab | Search → selected track → button → Search; reverse traversal also works. Visible focus and the reported focused element follow each other. |
| Down / Up | First row → second Japanese-title row → first row. |
| Page Down / Page Up | Row 1 → row 12 → row 1 at the tested viewport; selection scrolls into view. |
| End / Home | Row 5000 (`track-4999`, Fictional Ensemble 500) → row 1. |
| Search | `PAPER LANTERN` filters case-insensitively to 500 rows. End reaches the last match, `track-4990`. Clearing restores the full list. |
| Button | Space changes Play to Pause and the playback text; Enter pauses and restores Play. |

Evidence: [search](evidence/windows-gpui/aso57-search-0.jpg),
[filtered End](evidence/windows-gpui/aso57-filtered-end-0.jpg),
[Play](evidence/windows-gpui/aso57-play-0.jpg), and
[final-build End](evidence/windows-gpui/aso57-final-end-0.jpg).

PR #20's Desktop Windows and macOS CI jobs succeeded. The local release build,
six existing model tests and all-target Clippy with warnings denied also pass
after the input correction. Windows screen checks do not establish macOS
interaction correctness. SMTC and real playback are not implemented in this
scaffold and were not attributed to its simulated Play/Pause button.

## ASO-56: initial candidate location in the input

On the unmodified scaffold, conversion text changed, but the candidate popup
was absent from the captured normal and bottom positions. A temporary trace
inside `SearchInput::bounds_for_range` recorded the initial request as
`range=0..0`, `content_bytes=0`, `layout_matches=false`. The display line
contains `Search tracks`, while the actual content is empty; the guard returned
`None`, so the backend had no initial caret location to apply.

Allowing index zero of the placeholder layout when content is empty restores
the initial caret bounds. The same roman-key sequence then displays Google's
candidate list at the normal position. The owner also confirmed it was visible.
The stale-layout guard remains for nonempty values. No text or personal data
was written to the trace; temporary instrumentation was removed afterward.

Compare [before](evidence/windows-gpui/google-150-diagnostic-normal-0.jpg) and
[after the input correction](evidence/windows-gpui/google-150-normal-input-fix-0.jpg).
The trace concerns Google/150%; the corrected input was exercised in all four
combinations below.

## ASO-56: bottom-edge overlap in gpui

After the input correction, the original overlap reproduces on the scaffold.
The pinned backend implements it in
[`events.rs`, caret retrieval and candidate positioning](https://github.com/zed-industries/zed/blob/4304dec732a75505066de5ce2dbbfb2bec369498/crates/gpui_windows/src/events.rs#L645)
and [`window.rs`, coordinate updates](https://github.com/zed-industries/zed/blob/4304dec732a75505066de5ce2dbbfb2bec369498/crates/gpui_windows/src/window.rs#L1066).
Both paths reduce the logical caret rectangle to its left edge and vertical
center, scaled to physical pixels. `ImmSetCandidateWindow` receives
`CFS_CANDIDATEPOS` and an empty `rcArea`.

Microsoft documents that the system may adjust `CFS_CANDIDATEPOS`; only
[`CFS_EXCLUDE` declares an area that the candidate UI must avoid](https://learn.microsoft.com/en-us/windows/win32/api/imm/ns-imm-candidateform).
At the display bottom the popup moves upward, but the backend's center point
does not protect the text above/below that point.

The initial caret bounds and corresponding physical coordinates are:

| Scale | Recorded logical caret origin / height | Original candidate point | Experimental exclusion rectangle |
| --- | --- | --- | --- |
| 150% | `(24.666666, 73.333336)`, height `24` | `(37, 128)` | `[37, 110, 38, 146]` |
| 125% | `(24.8, 72.8)`, height `24` | `(31, 106)` | `[31, 91, 32, 121]` |

Coordinates are client-relative physical pixels. The point/rect values above
are calculated from the recorded input bounds and the inspected backend/patch
formulas, not a successful cross-process `ImmGetCandidateWindow` read. That
external-context attempt returned no usable candidate form and was discarded.

The [source patch](../../tools/windows-ime-probe/gpui-candidate-exclusion.patch)
preserves the bounds through both Windows paths, rounds the exclusion rectangle
outward, keeps a zero-width caret at least one physical pixel wide, and sends
`CFS_EXCLUDE`. A comparison build was made from that patch. The cached source
files were restored byte-for-byte; the backend was explicitly rebuilt when
returning to the unpatched dependency.

With Google/150%, the same saved
[`reproduceB3(sky, desktopWindow)` routine](../../tools/windows-ime-probe/reproduce.mjs)
shows overlap with the pinned backend, separation with the patch, and overlap
again after restoring the pinned backend. See
[point version](evidence/windows-gpui/google-150-repro-command-point-0.jpg) and
[exclusion version](evidence/windows-gpui/google-150-repro-command-exclusion-0.jpg).
This isolates the remaining overlap to backend placement rather than the
scaffold's returned text height. The routine sends real letter keys and returns
a screenshot; the overlap verdict comes from visual inspection, not a unit test.

## Experimental backend regression matrix

All rows use the input correction plus the experimental backend patch. They
are not results for an unchanged Cargo dependency.

| IME | Scale | B1 Commit/filter | B2 Preedit/underline | B3 Normal/bottom | B4 Every clause | B5 Focus loss |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft | 125% | Pass | Pass | Pass | Pass | Pass |
| Microsoft | 150% | Pass | Pass | Pass | Pass | Pass |
| Google | 125% | Pass | Pass | Pass | Pass | Pass |
| Google | 150% | Pass | Pass | Pass | Pass | Pass |

- B1: roman `toukyou` commits `東京`, correctly yielding no matches in this
  fixture. `aoimado` commits `青い窓`; End confirms 500 Japanese-title matches.
  This fixture differs from ASO-51's prototype, where `東京` matches 50 tracks.
- B2: composition and its marked-span underline remain visible. There is no
  separate active-clause styling; this uses the same B2 interpretation as ASO-51.
- B3: candidates appear below normally and above at the bottom without covering
  the composing text. Bottom captures clip the popup above the app rectangle;
  its lower edge and the full composing text remain visible and separated.
- B4: `kyouhaiitenki`; change alternatives in both Google segments or all three
  Microsoft segments, then commit. Candidate order varies with IME history.
- B5: committed `東京` plus uncommitted converted `天気`; click another window,
  return, and observe exactly `東京天気`, with no loss or duplication.

| IME / scale | Bottom-edge evidence | Focus-loss result |
| --- | --- | --- |
| Microsoft / 125% | [Separated](evidence/windows-gpui/microsoft-125-bottom-exclusion-0.jpg) | [東京天気](evidence/windows-gpui/microsoft-125-exclusion-after-focus-loss-0.jpg) |
| Microsoft / 150% | [Separated](evidence/windows-gpui/microsoft-150-bottom-exclusion-0.jpg) | [東京天気](evidence/windows-gpui/microsoft-150-exclusion-after-focus-loss-0.jpg) |
| Google / 125% | [Separated](evidence/windows-gpui/google-125-bottom-exclusion-0.jpg) | [東京天気](evidence/windows-gpui/google-125-exclusion-after-focus-loss-0.jpg) |
| Google / 150% | [Separated](evidence/windows-gpui/google-150-bottom-exclusion-0.jpg) | [東京天気](evidence/windows-gpui/google-150-exclusion-after-focus-loss-0.jpg) |

## Adopted dependency verification

On 2026-11-07, the owner requested formal adoption. `apps/desktop/Cargo.toml`
overrides Zed's `gpui_windows` through a relative path to
[`vendor/gpui_windows`](../../apps/desktop/vendor/gpui_windows/README.syncstr.md).
The other gpui crates retain their original revision. The lockfile changes
only the source of `gpui_windows`; no package versions change. No Cargo cache
modification or patch-application step is required for a normal checkout.

Cargo metadata confirms one `gpui_windows` at the vendored path and one `gpui`.
All 24 dependency declarations and crate features match the upstream manifest
after expanding workspace inheritance. The 25 upstream files were compared:
only `Cargo.toml`, `src/events.rs` and `src/window.rs` have content changes.
The license symlink is materialized as the full upstream Apache license text;
shaders are retained unchanged. The source patch also removes its unused
point-conversion helper and marks modified files. It passes `git apply --check`
against the pinned upstream checkout, which remains clean.

The ordinary desktop release build compiled the vendored backend. Verification:

- `cargo build --release --locked --offline`: pass.
- `cargo test --release --locked --offline`: all six model tests pass.
- `cargo clippy --release --locked --offline --all-targets -- -D warnings`: pass.
- The same Clippy check with `-p gpui_windows`: pass for the vendored crate.
- Desktop and vendored-crate `cargo fmt -- --check`, and `git diff --check`: pass.
- `cargo metadata --locked --filter-platform aarch64-apple-darwin`: resolves
  `gpui_macos`, excluding `gpui_windows` from the target graph. This is dependency
  resolution only; macOS compilation and interaction were not run on Windows.

The release process was restarted after every IME/scale change. Actual window
DPI was 120 at 125% and 144 at 150%. The same B1–B5 cases above were repeated
using the adopted dependency, including a check of hiragana mode before testing.

| IME / scale | B1 / B2 / B4 / B5 | B3 normal / bottom | Adopted-build evidence |
| --- | --- | --- | --- |
| Microsoft / 125% | Pass | Pass | [Bottom](evidence/windows-gpui/adopt-microsoft-125-bottom-0.jpg), [focus return](evidence/windows-gpui/adopt-microsoft-125-after-focus-loss-0.jpg) |
| Microsoft / 150% | Pass | Pass | [Bottom](evidence/windows-gpui/adopt-microsoft-150-bottom-0.jpg), [focus return](evidence/windows-gpui/adopt-microsoft-150-after-focus-loss-0.jpg) |
| Google / 125% | Pass | Pass | [Bottom](evidence/windows-gpui/adopt-google-125-bottom-0.jpg), [focus return](evidence/windows-gpui/adopt-google-125-after-focus-loss-0.jpg) |
| Google / 150% | Pass | Pass | [Bottom](evidence/windows-gpui/adopt-google-150-bottom-0.jpg), [focus return](evidence/windows-gpui/adopt-google-150-after-focus-loss-0.jpg) |

Normal-position evidence also shows candidate separation and clause changes:
[Microsoft / 125%](evidence/windows-gpui/adopt-microsoft-125-clause-3-0.jpg),
[Microsoft / 150%](evidence/windows-gpui/adopt-microsoft-150-clause-3-0.jpg),
[Google / 125%](evidence/windows-gpui/adopt-google-125-clause-2-0.jpg), and
[Google / 150%](evidence/windows-gpui/adopt-google-150-clause-2-0.jpg).
Focus-loss checks activate the separate Win32 probe and return to the desktop;
the final value is exactly `東京天気`. No production library is involved.

After restoring 150%, ordinary keyboard navigation still reaches
[row 5000](evidence/windows-gpui/adopt-final-end-0.jpg). Space activates
[simulated Play](evidence/windows-gpui/adopt-final-play-0.jpg), and Enter returns
to [Pause with an empty search](evidence/windows-gpui/adopt-final-restored-0.jpg).

## Delivery boundary

The input fix and backend override are active on this branch. The Desktop
workflow can verify the published revision with `workflow_dispatch`; previous
PR #20 CI does not verify this change. Native macOS interaction remains a
separate check. Vendor provenance and update/removal instructions are included.

Google Japanese Input and 150% scaling were restored. The final running process
uses the adopted backend and the input correction, with diagnostics removed,
normal window placement and an empty Search. ASO-51's full-list/memory/media
verification and prototype publication remain separate work.

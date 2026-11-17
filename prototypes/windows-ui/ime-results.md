# ASO-51 Japanese IME verification

All twelve requested IME/scale/probe combinations were checked on 2026-11-06.
Win32 passes B1–B5. Slint fails B2 and B5; GPUI fails B3. Each failure reproduces
with Microsoft IME and Google Japanese Input at both 125% and 150%.
These results apply to the pinned prototypes; they do not select a toolkit.

## Matrix

| IME | Scale | Probe | B1 Commit/filter | B2 Preedit/underline | B3 Candidates/edge | B4 Clauses | B5 Focus loss |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Microsoft | 125% | Win32 | Pass | Pass | Pass* | Pass | Pass |
| Microsoft | 125% | Slint | Pass | Fail | Pass | Pass | Fail |
| Microsoft | 125% | GPUI | Pass | Pass† | Fail | Pass | Pass |
| Microsoft | 150% | Win32 | Pass | Pass | Pass* | Pass | Pass |
| Microsoft | 150% | Slint | Pass | Fail | Pass | Pass | Fail |
| Microsoft | 150% | GPUI | Pass | Pass† | Fail | Pass | Pass |
| Google | 125% | Win32 | Pass | Pass | Pass* | Pass | Pass |
| Google | 125% | Slint | Pass | Fail | Pass | Pass | Fail |
| Google | 125% | GPUI | Pass | Pass† | Fail | Pass | Pass |
| Google | 150% | Win32 | Pass | Pass | Pass* | Pass | Pass |
| Google | 150% | Slint | Pass | Fail | Pass | Pass | Fail |
| Google | 150% | GPUI | Pass | Pass† | Fail | Pass | Pass |

*Win32 candidates move above the text at the display bottom. The bounded app
capture clips most of the popup above the title bar; its visible lower edge
remains above the composing text. This is a capture limitation.

†GPUI draws an underline across the entire marked span. The active clause is
not styled separately. B2 passes for visible composition and an underline;
distinct active-clause styling is not established by this result.

## Method and environment

See [the overall results](results.md) for Windows build, dependency revisions
and IME component file versions. Display Settings was changed between 125% and
150%; `GetDpiForWindow` confirmed 120 and 144 DPI respectively on all three
prototypes. Each probe was restarted after changing the IME or scale.

Microsoft IME component files were present initially, but its keyboard profile
was absent from the available input methods. The built-in Microsoft IME keyboard
was added in Japanese language options. No external IME package was installed.
The existing unavailable input-method entry and default override were retained.
Different input methods per app was unchecked. The Rust helper selected each
registered TSF profile for the desktop session and verified its description;
candidate UI also identified Microsoft or Google. IMM32 returned the same HKL
for both, so HKL alone was not used to identify the provider.

All cases used actual letter-key events, rather than Unicode text insertion:

1. **B1:** `toukyou` produces `とうきょう`; Space converts it to `東京` and
   Return commits it. Search filters the fictional catalog to 50 matching rows.
2. **B2:** Inspect the preedit and converted text before confirmation.
3. **B3:** Open candidates at the normal window position, then repeat with
   Search near the display bottom. Inspect separation from the composing text.
4. **B4:** Enter `kyouhaiitenki`, convert, navigate between clauses and request
   alternatives for every generated clause, then commit. A supplemental pass
   covered all clauses in every combination: Google generated two segments
   and Microsoft three in these runs. Alternatives included `きょうは`, `良い`
   or `いい`, and `天気` or `転機`. Candidate ordering can change with IME history.
5. **B5:** Commit `東京`, enter `tenki`, convert to uncommitted `天気`, click
   another window, return to Search, and check for exactly `東京天気`.

An empty Search and actual input focus were checked before independent cases.
Win32 and Slint were cleared with the UIA value pattern. GPUI was cleared with
Escape, Ctrl+A and Backspace because its SetValue did not clear an existing
value in this probe. An observation with stale accessibility text was followed
by a settled observation and visual review. Attempts with an old prefix or
without actual input focus were discarded and rerun.

## Slint: underline and focus-loss failures

The whole composing span has a selection-style background instead of a clause
underline. The blue line across the Search control is the field's focus border,
not an underline beneath the composing text. This fails B2. The pinned default
renderer also maps the preedit range to the selection range in
`internal/core/textlayout/sharedparley.rs`, consistent with the observation.

For B5, `東京` is committed and `天気` remains highlighted as preedit. After
clicking another window and returning, the field contains only `東京`.
The uncommitted suffix is lost. This reproduced in all four IME/scale
combinations, with an additional repeat for Google at 150%.

| IME / scale | Before focus loss (also shows preedit highlighting) | After focus loss |
| --- | --- | --- |
| Microsoft / 125% | [東京 + 天気](evidence/microsoft-125-slint-before-focus-loss-0.jpg) | [東京 only](evidence/microsoft-125-slint-after-focus-loss-0.jpg) |
| Microsoft / 150% | [東京 + 天気](evidence/microsoft-150-slint-before-focus-loss-0.jpg) | [東京 only](evidence/microsoft-150-slint-after-focus-loss-0.jpg) |
| Google / 125% | [東京 + 天気](evidence/google-125-slint-before-focus-loss-0.jpg) | [東京 only](evidence/google-125-slint-after-focus-loss-0.jpg) |
| Google / 150% | [東京 + 天気](evidence/google-150-slint-before-focus-loss-0.jpg) | [東京 only, repeated](evidence/google-150-slint-after-focus-loss-repeat-0.jpg) |

Slint still commits and filters correctly, changes clause candidates, and puts
the candidate popup above the input at the display bottom without overlap.

## GPUI: candidate overlap at the display bottom

At the bottom edge, the candidate popup moves above Search, but its footer
overlaps the upper part of the composing text. This fails B3 with both IMEs
and both scales. The popup sometimes appeared only after clause navigation
and a settled observation; an immediate capture without it was not treated
as proof that candidates were unavailable.

| IME / scale | Bottom-edge evidence |
| --- | --- |
| Microsoft / 125% | [Candidate footer overlaps text](evidence/microsoft-125-gpui-bottom-0.jpg) |
| Microsoft / 150% | [Candidate footer overlaps text](evidence/microsoft-150-gpui-bottom-0.jpg) |
| Google / 125% | [Candidate footer overlaps text](evidence/google-125-gpui-bottom-0.jpg) |
| Google / 150% | [Candidate footer overlaps text](evidence/google-150-gpui-bottom-0.jpg) |

GPUI commits and filters correctly, underlines marked text, changes clause
candidates, and preserves exactly `東京天気` after the focus-loss case.
The candidate-position cause has not been isolated between the upstream
Windows backend and the probe's custom text input; this is a prototype result,
not a claim that every GPUI application has the defect.

## Win32 baseline and completion

All four Win32 combinations pass B1–B5. Representative Google/150% evidence:
[committed 東京](evidence/google-150-win32-commit-0.jpg),
[normal candidates](evidence/google-150-win32-candidates-0.jpg),
[bottom candidates](evidence/google-150-win32-bottom-0.jpg),
[before focus loss](evidence/google-150-win32-before-focus-loss-0.jpg), and
[after focus loss](evidence/google-150-win32-after-focus-loss-0.jpg).
Supplemental clause traversal also covers
[Microsoft/125%](evidence/microsoft-125-win32-all-clauses-commit-0.jpg) and
[Google/125%](evidence/google-125-win32-all-clauses-commit-0.jpg).

No new prototype crash was observed during these IME checks. The earlier
unisolated GPUI crash with Narrator remains a separate finding. Narrator stayed
stopped. At completion, the original Google Japanese Input and 150% scaling
were restored, all three windows reported 144 DPI, and fresh probes were placed
normally with empty Search fields. Microsoft IME remains available as an added
keyboard. Diagnostic examples build in release mode and pass all-target Clippy
with warnings denied. The other ASO-51 checks remain listed in [results](results.md).

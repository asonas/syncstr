# ASO-51 Windows verification

All three prototypes build and start, and each acknowledges system Play and
Pause requests through SMTC. Direct Rust UIA checks pass A1–A4 for Slint and
GPUI after prototype corrections. Win32 passes A1/A3/A4 but fails the explicit
row-position requirement in A2 because its LISTBOX provider does not expose
PositionInSet or SizeOfSet. The twelve-combination IME matrix is complete:
Win32 passes B1–B5, Slint fails B2/B5, and GPUI fails B3 with both IMEs at both
scales. The remaining toolkit acceptance checks are incomplete; these results
do not select a toolkit or complete ASO-51.

## Environment and scope

- Windows 11 Pro x64, version 26H2, build 26300.9711, confirmed in `winver` as well as the OS version registry.
- Rust 1.99.1, x64 MSVC; Visual Studio Build Tools 18; Windows SDK 10.0.26100.0 and its `fxc.exe`.
- Microsoft IME component files were present, but its keyboard profile was initially unavailable. The built-in keyboard was added in Japanese language options for verification and remains available. IMJPAPI/IMJPCD file version is 10.0.26100.9549; Google Japanese Input TIP file version is 3.34.6260.0. These are component file versions, not independently verified About-screen versions.
- Both 125% and 150% were verified at 3840 by 2160; all three windows reported 120 and 144 DPI respectively. The original 150% scaling and Google Japanese Input were restored. See [the IME report](ime-results.md) for profile identification and methods.
- The owner changed group A to keyboard and UI Automation checks on 2026-11-06. Narrator speech is excluded. The user confirmed that speech was audible during the earlier check; Narrator was then stopped at the user's request. The follow-up keyboard/UIA checks below ran without Narrator.
- Slint commit `f5481bdaa5a9ccb68fe3b948d1ee0d3efe592669`; GPUI/Zed commit `4304dec732a75505066de5ce2dbbfb2bec369498`. See [build instructions](README.md).
- The branch is local: `codex/aso-51-windows-ui`. Source is not committed or pushed, so a remotely accessible branch link is pending. No changes were made to the production clients or shared playback core.

## Acceptance checklist

`Partial` means that part of the check remains unperformed, including checks
blocked by tool capabilities. It does not mean that the toolkit failed.

| Check | Win32 | Slint | GPUI |
| --- | --- | --- | --- |
| A1 Names, roles, Tab | Pass — Search/Edit, Tracks/List and Play/Button have names; Tab and Shift+Tab traverse them and UIA focus follows | Pass in direct UIA recheck — actual Edit/List/Button controls and forward/reverse focus confirmed; supersedes the earlier desktop-tool failure | Pass — after correcting the prototype's tracked-handle Tab flags, Tab and Shift+Tab traverse all three controls; UIA focus follows the selected row/button |
| A2 Arrows, Page Down, End, position | Fail — UIA focus follows the correct rows, but PositionInSet and SizeOfSet are unsupported on this native LISTBOX provider | Pass — UIA focus follows Home, Down, Page Down and End, with positions 1, 2, 7 and 5000, SizeOfSet 5000 | Pass after correcting prototype metadata — positions 1, 2, 14 and 5000, SizeOfSet 5000 |
| A3 Duplicate-title navigation | Pass — first/tenth Intro rows have different UIA runtime IDs and remain responsive | Pass — first/tenth Intro rows have different UIA runtime IDs and remain responsive | Pass — first/tenth Intro rows have different UIA runtime IDs and remain responsive |
| A4 Space and UIA state update | Pass — Space/Enter change button name and playback label through UIA | Pass — Space changes button name and playback label through UIA | Pass — Space/Enter change button name and Status through UIA |
| A5 Full traversal with inspector, memory | Partial — no full traversal | Partial — End jump succeeds; no full traversal | Partial — End jump succeeds; no full traversal |
| B1 IME conversion to 東京 | Pass — both IMEs at both scales; 50 matching tracks | Pass — all four combinations | Pass — all four combinations |
| B2 Composition and clause underline | Pass — all four combinations | Fail — whole preedit highlighted instead of clause underline, all four | Pass — marked-span underline in all four; active clause is not separately styled |
| B3 Candidate position and screen bottom | Pass — all four; bottom popup above text, mostly clipped by bounded capture | Pass — all four; bottom popup above text without overlap | Fail — candidate footer overlaps composing text at the bottom, all four |
| B4 Multi-clause conversion | Pass — alternatives for every generated clause, all four | Pass — same | Pass — same |
| B5 Focus loss during composition | Pass — exactly 東京天気 preserved, all four | Fail — uncommitted 天気 lost, leaving 東京, all four | Pass — exactly 東京天気 preserved, all four |
| C1 Flyout metadata, app name/icon | Partial — track title read through system session API; flyout/name/icon unverified | Partial — same | Partial — same |
| C2 Physical media key, foreground/background | Partial — input tool rejects media-key names; physical key pending | Partial — same | Partial — same |
| C3 Flyout Play/Pause | Partial — system API Play/Pause requests acknowledged; flyout buttons unverified | Partial — same | Partial — same |
| D1 Stripped release exe size | Pass — 169,984 bytes | Pass — 15,004,672 bytes | Pass — 10,912,768 bytes |
| D2 Idle RAM from Task Manager | Partial — process counters sampled; Task Manager idle measurement pending | Partial — same | Partial — same |
| D3 Build from empty output directory | Pass — 8.25 s | Pass — 65.64 s | Pass — 64.45 s; see measurement limits below |
| D4 Extra setup | Pass — no extra SDK beyond MSVC/Windows SDK | Pass — Cargo fetched pinned source; no extra installed build tools | Pass — SDK `fxc.exe` added to PATH; Cargo fetched pinned source |

## Observations

Win32 search was checked with literal `Night Train 0042`: the list contains one
row and the now-playing label selects that track. Tab reaches the button, and
Space changes both its label and the playback label. See
[the search screenshot](evidence/win32-search.jpg) and
[the last-row selection](evidence/win32-end.jpg). This is not an IME test.

Slint exposes only the virtualized rows near the viewport. Keyboard selection
moves visually, including to the last row, and the now-playing label follows.
The earlier desktop tool reported Search while visible focus was on the list
or button. The independent Rust inspector does not reproduce that finding:
`GetFocusedElement` and `CurrentHasKeyboardFocus` follow both list items and
the button, and row positions and size are correct. Repeated direct checks
supersede the earlier A1/A2 failure. The cause of the discrepancy with the
desktop tool remains unisolated. See the earlier evidence in
[the follow-up without Narrator](evidence/slint-uia-focus-without-narrator.jpg),
[End navigation](evidence/slint-end.jpg) and [Space on Play](evidence/slint-play.jpg).

GPUI initially did not move focus on Tab. Its tracked `FocusHandle`s defaulted
to `tab_stop(false)`; a div's `.tab_stop(true)` only configures a handle created
by that div, not an explicitly tracked handle. The probe now sets the flag on
the three handles and displays focus borders. The same keyboard/UIA check
that remained at Search now reaches the selected track, the Play button, and
Search in reverse order. Down selects 東京 0001, Page Down selects Night Train
0013, and End selects the last Intro row, each with the matching UIA-focused
name. Space/Enter update both the button name and the Status element. See
[GPUI End](evidence/gpui-end.jpg) and [GPUI Play](evidence/gpui-play.jpg).

Direct UIA inspection also found incorrect GPUI metadata in the prototype:
the first/last rows reported positions 2/5001 and no SizeOfSet. AccessKit uses
a zero-based row index and puts the item count on the ListBox container. The
probe had supplied a one-based index and attached the count to each item.
After correcting those calls, the first, second and last rows report 1/5000,
2/5000 and 5000/5000. This was a prototype error, not an established GPUI defect.

The Rust [UIA inspector](uia-check/src/main.rs) uses named control types to avoid
confusing Search/Tracks labels with their controls. It records focus and
selection independently, uses `CheckNotSupported` to distinguish unsupported
properties from zero, and
checks separate runtime IDs for the first and tenth Intro rows. Raw JSON stays
in ignored local evidence because runtime IDs belong to a desktop session.

In the completed run, all three return an Edit named Search, a List named
Tracks, a Button named Play/Pause, and a focused ListItem for each navigation
step. Win32 reaches Intro, 東京 0001, Night Train 0016 and the last Intro row,
but both position properties are unsupported on every inspected item. Its A2
failure is limited to that explicit metadata requirement. The first and tenth
Intro rows have nonempty, unequal runtime IDs in all three probes. Space
changes Play to Pause or Pause to Play while the button retains UIA focus.
The inspector also detects a changed foreground window and stops sending
keys; a run interrupted that way is retried rather than treated as toolkit
failure. Visible focus checks still rely on the earlier app screenshots.

Windows Error Reporting recorded one GPUI crash (`0xc0000409`) during the
earlier interactive session with Narrator running. Its cause is not isolated.
The process has not crashed during the subsequent checks without Narrator;
the Tab-order correction is not established as a fix for that crash.

The `common/examples/media_check.rs` process finds only sessions belonging to
the three probe executables. For each, it reads a nonempty track title, requests
Play then Pause through Windows, and waits for the published state to match.
All six requests were acknowledged. This exercises the real Windows event path
and each toolkit's UI-thread dispatch, without replacing the physical media-key
or flyout checks.

## Cost measurement limits

The empty-output-directory timings include compilation/linking with source
downloads already cached. They were measured during the initial implementation;
minor fixture and initial-layout corrections were built incrementally afterward.
These are local build measurements, not clean CI verification. One earlier GPUI
measurement aborted inside `link.exe` while Slint was also building. A separate
run with a shorter output path and no concurrent Slint build succeeded in
64.45 s. The cause of the aborted linker run was not isolated.

One post-launch sample, with Narrator running and the inspection tool in use,
reported the following process counters. Working set and private bytes differ
from Task Manager's default memory column; these samples do not establish an
idle-memory ranking.

| Probe | Working set | Private bytes |
| --- | ---: | ---: |
| Win32 | 42,905,600 | 11,931,648 |
| Slint | 94,711,808 | 90,599,424 |
| GPUI | 74,559,488 | 93,573,120 |

The shared fixture/search test passed, and release Clippy checks passed for all owned crates.
The shared test checks the count, one-based every-tenth duplicates, title
search, Japanese titles and an empty result. No production tests or Apple/Android
builds were run because these prototypes have no dependency on those clients.

## Remaining verification

See [the completed IME matrix, reproduction steps and evidence](ime-results.md).
Slint's B2/B5 failures and GPUI's B3 failure reproduce with both Microsoft IME
and Google Japanese Input at 125% and 150%. No new crash was observed in these
checks. Both Rust toolkit probes fail group B at their current pinned revisions;
this meets the stated condition for considering a WinUI 3 follow-up, without
selecting a replacement or implementing one here.

The SDK Inspect GUI could not be resized usefully. With the owner's approval,
the Rust inspector replaced it for row properties and keyboard/UIA checks.
Narrator remains stopped.

Complete the remaining checks in ASO-51: full-list traversal and memory,
and media keys/flyout controls.
Capture the screen for any failure or partial result in A/B. Record the confirmed
Windows/IME/scale values and Task Manager measurements, then publish the
prototype branch and add its link to ASO-51 before requesting the ASO-50 decision.

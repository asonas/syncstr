# Windows toolkit probes

These independent, silent prototypes supply evidence for ASO-51 and the
toolkit decision in ASO-50. Keep this branch unmerged. They do not use
`syncstr-headless`, the real catalog, or the production Windows client.

Each probe has a search field, 5,000 fictional tracks, a Play/Pause button,
and a now-playing label. Every tenth title repeats an earlier title. Search
matches title substrings without case sensitivity. `東京` matches 50 tracks.
Tab/Shift+Tab navigate controls; the list supports arrows, Page Up/Down,
Home and End; Space/Enter activate the button. Playback is a boolean flag;
no audio device or music files are needed.

## Versions and build

Use Rust 1.99.1 with the x64 MSVC toolchain, Visual Studio Build Tools, and
the Windows SDK. GPUI release builds also need the SDK's `fxc.exe` on PATH.
Run these commands from the repository worktree root:

```powershell
mise exec -- rustc --version
mise exec -- cargo build --release --locked --manifest-path prototypes/windows-ui/win32/Cargo.toml
mise exec -- cargo build --release --locked --manifest-path prototypes/windows-ui/slint/Cargo.toml
mise exec -- cargo build --release --locked --manifest-path prototypes/windows-ui/gpui/Cargo.toml
```

| Probe | Pinned dependency |
| --- | --- |
| Win32 | `windows` 0.62.2; native EDIT, LISTBOX and BUTTON |
| Slint | `slint-ui/slint` at `f5481bdaa5a9ccb68fe3b948d1ee0d3efe592669` (1.19.0 development source), default features plus `raw-window-handle-06` |
| GPUI | `zed-industries/zed` at `4304dec732a75505066de5ce2dbbfb2bec369498`, including `gpui_platform` |

Cargo lockfiles pin transitive dependencies. Each probe has its own target
directory, so clean-build comparisons can start with an empty output directory
without deleting another probe's artifacts. Download dependencies before timing
a build, and do not build the other probes concurrently during measurement.

Launch the three executables in separate terminals or use `Start-Process`:

```powershell
Start-Process prototypes/windows-ui/win32/target/release/toolkit-probe-win32.exe
Start-Process prototypes/windows-ui/slint/target/release/toolkit-probe-slint.exe
Start-Process prototypes/windows-ui/gpui/target/release/toolkit-probe-gpui.exe
```

The Slint probe displays `AboutSlint` under the Royalty-free 2.0 license
choice recorded in ASO-50. The GPUI input adapts its pinned upstream
`crates/gpui/examples/input.rs`; the Apache license is in
[gpui/LICENSE-APACHE](gpui/LICENSE-APACHE).

## Windows media integration

`common` contains the identical track fixture and SMTC implementation used by
all three probes. It obtains SMTC with
`ISystemMediaTransportControlsInterop::GetForWindow`, publishes title/artist
and playback status, and enables Play/Pause requests.

| Probe | HWND and UI-thread delivery |
| --- | --- |
| Win32 | Created HWND; `ButtonPressed` posts a private window message |
| Slint | `raw-window-handle-06`; initialize after the event loop starts and deliver events with `invoke_from_event_loop` |
| GPUI | `HasWindowHandle`; a channel delivers events to a GPUI task on the UI thread |

With exactly one instance of each probe running, the following check reads
only their system media sessions, requests Play and Pause, and waits for each
probe to publish the new state:

```powershell
mise exec -- cargo run --release --locked --manifest-path prototypes/windows-ui/common/Cargo.toml --example media_check
```

This validates the SMTC request/acknowledgment path. Check physical media keys,
background operation, and the flyout's name, icon and buttons separately.

## Verification

With one instance of each prototype running, the Rust UIA inspector checks the
actual Edit, List and Button controls, independently of the desktop inspection
tool. It clears search, sends Tab, Home, Down, Page Down, End, Space and
Shift+Tab, and records focus and selection separately. It also reads
PositionInSet, SizeOfSet and the runtime IDs of the first and tenth rows, whose
titles are both Intro.

```powershell
mise exec -- cargo build --release --locked --manifest-path prototypes/windows-ui/uia-check/Cargo.toml
New-Item -ItemType Directory -Force prototypes/windows-ui/evidence/local
& prototypes/windows-ui/uia-check/target/release/toolkit-uia-check.exe | Set-Content -Encoding utf8 prototypes/windows-ui/evidence/local/uia.json
```

Keep the desktop idle while it runs. The program verifies each probe's window
title, executable filename and process ID, and refuses key input if the
foreground window changes. JSON contains raw observations and four Boolean
checks. A missing UIA property is `null`, not zero; separate support flags use
UIA's `CheckNotSupported`. Exit code 1 means a probe
could not be inspected; a completed inspection can contain failed checks.
The program changes the selected track and toggles each probe's playing flag.
It does not verify visible focus, IME, full-list performance or Task Manager
memory. Compare visible focus with the recorded UIA focus separately.

The fixture/search contract has one focused test:

```powershell
mise exec -- cargo test --locked --manifest-path prototypes/windows-ui/common/Cargo.toml
```

### IME diagnostics

The two diagnostic examples support the interactive B1–B5 checks:

```powershell
mise exec -- cargo build --release --locked --manifest-path prototypes/windows-ui/uia-check/Cargo.toml --examples
& prototypes/windows-ui/uia-check/target/release/examples/ime_identity.exe
& prototypes/windows-ui/uia-check/target/release/examples/ime_layout.exe win32 bottom
& prototypes/windows-ui/uia-check/target/release/examples/ime_layout.exe win32 normal
```

`ime_identity` without arguments reads the observer's active TSF profile and
each probe window's DPI, thread keyboard layout and IMM description. Modern
TSF IMEs can share an HKL and return an empty IMM description; do not infer
the IME from those fields alone. A profile lookup failure exits unsuccessfully;
missing probe windows are reported individually in the JSON.

Passing `microsoft` or `google` explicitly selects that installed Japanese
keyboard profile using TSF `TF_IPPMF_FORSESSION`, which affects the current
desktop session, and verifies its active description. It neither installs nor
enables profiles. Record the original IME before using this write operation,
check whether per-app input methods are enabled, and restore the original IME
after verification. These runs used the same input method across apps and also
confirmed the provider in candidate UI. See Microsoft's
[ActivateProfile documentation](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itfinputprocessorprofilemgr-activateprofile).

`ime_layout <win32|slint|gpui> <normal|bottom>` moves only a window with the
expected prototype caption and executable filename. Restore minimized or
maximized windows before use. It keeps size, activation and z-order unchanged,
uses the current monitor's work area and DPI, and verifies the resulting
position. `bottom` puts the window top 150 logical pixels above the work-area
bottom so Search is close to the display edge; `normal` centers the window.

Use actual roman letter-key events for IME composition. A Unicode paste or
UIA SetValue is suitable for clearing Search, but cannot establish conversion,
clause navigation or candidate placement. Inspect screenshots as well as
settled UIA values; accessibility text can lag a composition update. Bounded
app captures can clip candidate popups outside the app's rectangle. See the
[complete IME matrix](ime-results.md) for the exact cases and evidence.

For each probe, run Clippy with `--release -- -D warnings` after its manifest
path. Use the A1–D4 checklist from ASO-51 for keyboard/UI Automation, both
Japanese IMEs at 125% and 150%, media controls, and build costs. Narrator speech
is excluded by the owner's updated criterion. Literal Unicode injection into
the search field does not validate IME composition or conversion.

See [the results](results.md) for observed behavior and remaining
acceptance checks. Screenshots show fictional data only. Keep raw session logs,
local process details and personal filesystem paths out of published results.

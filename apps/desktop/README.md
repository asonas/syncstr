# Syncstr Desktop

An independent gpui scaffold for macOS and Windows. This crate is not part of a
Cargo workspace and does not depend on `syncstr-headless` or modify the existing
Windows client. It displays 5,000 fictional tracks with unique IDs; ten fictional
titles, including Japanese titles, repeat throughout the list.

Search matches title substrings without case sensitivity. Select a track with
the pointer or keyboard, then use Play/Pause to toggle simulated playback.
Selection and the current playback track have separate identities. Filtering
does not stop playback; an empty result retains the current playback track.
No audio is produced, and playback is not persisted.

## Build and test

On a development machine with sufficient disk space and the platform's native
build tools installed, run from this directory:

```sh
rustup toolchain install 1.99.1 --profile minimal --component clippy
cargo +1.99.1 build
cargo +1.99.1 test
cargo +1.99.1 clippy --all-targets -- -D warnings
cargo +1.99.1 run
```

The package uses edition 2024 and requires Rust 1.99 or newer. CI pins Rust 1.99.1
and builds/tests on `xcode-27` and `windows-2025`; Windows also runs Clippy.

Do not build or fetch dependencies on the resource-constrained implementation
machine. In particular, do not run Cargo build, check, test, fetch, or lockfile
generation there: fetching the Zed repository and compiling gpui can consume
several gigabytes. Do not use Simulator or Xcode builds there. Local validation
is restricted to `git diff --check` and file-specific checks such as
`rustfmt --edition 2024 --check src/model.rs`. Builds and tests first run in CI.

## Dependency pin and lockfile bootstrap

Both `gpui` and `gpui_platform` use Zed revision
`4304dec732a75505066de5ce2dbbfb2bec369498`. Keep their adjacent git dependencies
in `Cargo.toml` on the same revision and update both together. The platform crate
provides application initialization for macOS and Windows. The crates.io gpui
release does not provide the accessibility APIs required by this scaffold.

The initial scaffold intentionally has no `Cargo.lock`. The first CI runs omit
`--locked` and upload the generated lockfile as `desktop-lock-macos` and
`desktop-lock-windows`, including after later build/test failures when the file
exists. Reconcile both platforms' resolutions and commit the resulting lockfile;
then add `--locked` to build, test, Clippy, and the commands above, and change both
cache keys from the manifest hash to the lockfile hash. Until then, dependency
resolution is not reproducible even though the gpui revision is pinned.

## Keyboard and accessibility

- Tab and Shift+Tab cycle through search, the track list, and Play/Pause.
- In the list, Up/Down move one row, Page Up/Page Down move by a visible page,
  and Home/End select the first/last result. Selection scrolls into view.
- Space and Enter activate Play/Pause while the button has focus.
- Search supports selection, grapheme-aware deletion, clipboard shortcuts,
  and the native text-input handler with UTF-16 ranges and marked composition.
- The list exposes a ListBox with its result count, and selected options expose
  zero-based positions and active descendant focus. Rows are not extra Tab stops.

## Windows acceptance still required

CI compilation and model tests do not establish native interaction correctness.
Verify on Windows:

- Japanese IME composition, candidate placement, commit/cancel, and text selection.
- UI Automation roles, names, unique IDs, selected/focused state, and positions
  across all 5,000 tracks; repeat after filtering and with no results.
- Keyboard traversal in both directions, scrolling and paging, pointer selection,
  button activation, long queries, and narrow windows.
- SMTC integration and media keys, when implemented. Neither is implemented here;
  simulated Play/Pause does not register an OS media session.

macOS may be used for development, but it cannot establish Windows IME, UI
Automation, SMTC, or media-key behavior. Native visual and interaction checks on
both platforms remain separate from CI builds and tests.

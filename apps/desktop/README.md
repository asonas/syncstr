# Syncstr Desktop

An independent gpui client. On Windows it uses `syncstr-headless` directly for
authenticated v5 catalogs, verified audio and durable offline saves, and Windows
MediaPlayer for playback. The existing Win32 client remains unchanged.
macOS retains the scaffold; Windows `--demo` also displays its 5,000 fictional tracks.

Search matches title substrings without case sensitivity. Select a track with
the pointer or keyboard, then use Play/Pause. Playback is simulated only in demo mode.
Selection and the current playback track have separate identities. Filtering
does not stop playback; an empty result retains the current playback track.
The current playback position is not persisted.

## Windows v5 client

The default profile is `%LOCALAPPDATA%/SyncstrDesktop`, separate from Win32's
`Syncstr` profile. Use `--profile <directory>` for an isolated profile. Discover
hosts, select the intended public identity, copy its invitation to the clipboard,
then choose **Enroll from clipboard** against the existing pre-v5 enrollment
service. The current v5-only server does not expose enrollment; use an already
enrolled profile when connecting to it. **Refresh / retry saves** fetches only the
authenticated v5 catalog and retries retained partial save jobs. A discovered
address is a hint, not proof of membership. `--host <member>@<socket>` is an optional
explicit hint for local testing. Invitations are not persisted or logged.

Select a row and choose **Save**, **Remove save**, or **Play**. Distinct logical
tracks retain separate save ownership even when their verified bytes are shared.
Playlist rows retain their occurrence identities and original exact ID/hash pins;
missing entries remain unavailable rather than selecting a hash match. Catalogs
and completed saves reopen offline without loading the protected device key.
Shared-library editing is unavailable until the v5 member-write contract exists.

Network, verification and profile operations run on a dedicated worker. Native
audio runs on another worker, retaining a verified-file lease until the native
source closes. Cancel interrupts the active core operation; window shutdown
cancels work, closes the player and drains the core outside the UI executor.

### Copy-validation from Win32

Close Win32 first. Choose a **new, nonexistent** destination whose parent already
exists, then launch with `--profile <destination> --copy-win32-profile <source>`.
The source is locked against concurrent writers and copied without following
reparse points. Its DPAPI-protected identity is preserved, not regenerated.
After an authenticated Refresh, verified original saves are copied into managed
storage using the legacy catalog's explicit aliases and exact hash pins. Original
device IDs are retained in the migration manifest; absent catalog records remain
pending. Original files are retained separately from disposable managed cache.
Remove `--copy-win32-profile` on subsequent launches.

This is a copy-validation path, not an automatic production cutover. Never point
it at an everyday profile for testing. Do not delete the source or reset an
enrolled identity when its key is missing.

### Disposable native-audio verification

On Windows, from this directory:

```sh
cargo run --locked --example windows_audio -- <new-fixture-directory>
cargo run --locked --example windows_audio -- <another-new-fixture-directory> --serve
cargo run --locked -- --profile <another-new-fixture-directory>/desktop-profile
```

The first command checks synthetic Win32-format copy migration, authenticated
v5 acquisition, independent saves with one object, native decode/pause/resume,
and offline restart without the host or key. Playback is muted unless `--audible`
is passed. The serving mode advertises a disposable LAN host and defers legacy
save imports so that GUI saves actually fetch audio. Use Discover, select its
identity, Refresh, then save both `TRACK-A` and `TRACK-B`. Close the app and stop
the fixture host before reopening the same profile offline. The fixture contains
test credentials; do not publish its generated output. Engine progress and human
audibility are separate checks. See the [ASO-11 validation report](../../docs/validation/windows-shared-client.md).

## Build and test

On a development machine with sufficient disk space and the platform's native
build tools installed, run from this directory:

```sh
rustup toolchain install 1.99.1 --profile minimal --component clippy
cargo +1.99.1 build --locked
cargo +1.99.1 test --locked
cargo +1.99.1 clippy --locked --all-targets -- -D warnings
cargo +1.99.1 run --locked
```

The package uses edition 2024 and requires Rust 1.99 or newer. CI pins Rust 1.99.1
and builds/tests on `xcode-27` and `windows-2025`; Windows also runs Clippy.

Do not build or fetch dependencies on the resource-constrained implementation
machine. In particular, do not run Cargo build, check, test, fetch, or lockfile
generation there: fetching the Zed repository and compiling gpui can consume
several gigabytes. Do not use Simulator or Xcode builds there. Local validation
is restricted to `git diff --check` and file-specific checks such as
`rustfmt --edition 2024 --check src/model.rs`. Builds and tests first run in CI.

## Dependency pin and lockfile

Both `gpui` and `gpui_platform` use Zed revision
`4304dec732a75505066de5ce2dbbfb2bec369498`. Keep their adjacent git dependencies
in `Cargo.toml` on the same revision and update both together. The platform crate
provides application initialization for macOS and Windows. The crates.io gpui
release does not provide the accessibility APIs required by this scaffold.

The Windows backend is overridden by the repository-owned
[`vendor/gpui_windows`](vendor/gpui_windows/README.syncstr.md) crate from that
same revision. It includes the ASO-56 IME candidate-exclusion fix. Cargo applies
the override automatically during ordinary builds; no cache patching is needed.
When updating the two desktop pins, update the vendored crate and its four Zed
pins together. The vendor note records provenance, local changes and removal.

`Cargo.lock` records the dependency resolution generated by CI. Keep it under
version control alongside `Cargo.toml`. Build, test, Clippy, and run commands use
`--locked` to preserve that resolution. CI cache keys include the OS, Rust
version, and lockfile hash; CI no longer uploads lockfile artifacts. When
dependencies change, update the lockfile on a build-capable machine and review
it with the manifest changes.

## Keyboard and accessibility

- Tab and Shift+Tab cycle through the connection/save controls, collections,
  search, the track list, and Play/Pause (only the latter three in demo mode).
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

Windows launch, search, keyboard traversal, paging and button activation were
checked on the merged scaffold. See the [Windows validation report](../../docs/validation/windows-gpui.md)
for the build, evidence and IME findings. The scaffold's initial candidate-position
fix and the vendored Windows backend fix are both active in this branch.

macOS may be used for development, but it cannot establish Windows IME, UI
Automation, SMTC, or media-key behavior. Native visual and interaction checks on
both platforms remain separate from CI builds and tests.

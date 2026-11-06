# Syncstr's gpui Windows backend

This directory vendors `crates/gpui_windows` from Zed revision
`4304dec732a75505066de5ce2dbbfb2bec369498` under its original
[Apache 2.0 license](LICENSE-APACHE). The desktop manifest's
`[patch."https://github.com/zed-industries/zed"]` selects this copy for
`gpui_platform`'s Windows backend. No Cargo cache changes or setup step is needed.

## Local changes

- `events.rs` and `window.rs` preserve the caret rectangle through both IME
  position-update paths. Candidate windows receive `CFS_EXCLUDE` and an
  outward-rounded physical rectangle, at least one pixel wide/high. This keeps
  upward-opening candidates clear of the composing text at the display bottom.
  Composition-window placement remains at the caret center. The unused
  point-conversion helper is removed.
- `Cargo.toml` expands Zed's workspace inheritance. Dependency versions,
  features, default-feature flags, target conditions and lint settings match
  the original crate. Its four Zed dependencies use the same revision as the
  desktop's `gpui` and `gpui_platform` pins.
- `LICENSE-APACHE` contains the upstream license text in full, replacing its
  repository-relative symlink. All other upstream files, including shaders,
  are unchanged.

The [source patch](../../../../tools/windows-ime-probe/gpui-candidate-exclusion.patch)
applies to that Zed revision. The
[Windows report](../../../../docs/validation/windows-gpui.md) records the
reproduction, comparison builds and adopted-dependency verification.

## Updating or removing this override

Update the desktop's two pins and this crate's four Zed pins together. Copy the
new upstream crate, expand its inherited manifest values, and reapply/review the
source patch. Preserve upstream licenses and review the lockfile before running
the desktop's build, tests and Clippy on Windows and macOS. Repeat the IME checks
with Microsoft IME and Google Japanese Input at 125% and 150%.

Once a tested upstream revision contains the fix, update the desktop pins,
remove the patch table and this directory, regenerate the lockfile, and repeat
those checks. Do not advance unrelated dependencies as part of this workaround.

# Windows and Android review repairs

The five issues reviewed at `37e74c8` have code changes on the repair branch.
Automated checks and cross-builds support the implementation; physical Android
and native Windows interaction acceptance remains pending.

## Implemented changes

- Android replaces released players before rendering, guards old callbacks,
  disables unprepared controls, and reports setup failures without retaining
  a failed player.
- Connections renders from a worker-loaded snapshot. Startup and enrollment
  publish data on the UI thread; rendering never schedules nested native calls.
  Registration remains visible during loading and after Activity recreation.
- Android JNI derives album identity/title from canonical organization and
  membership choices. Concurrent memberships stay unresolved and visible as
  conflicts. Imported metadata and the shared wire catalog are unchanged.
- Album grouping uses identity rather than labels, preserves case variants and
  unresolved tracks, credits all contributing artists, and orders by
  `discNumber` followed by `track`, with stable tie-breakers.
- Windows executes client operations on a serialized worker with an owned
  runtime. UI commands capture object/endpoint values before dispatch; results
  return through an owned queue and a private window notification. Local
  pause/resume remains available while client work is pending. Closing stops
  delivery and aborts active work without joining the worker in the UI thread.
  The existing store recovery resets interrupted running jobs on reopen.

## Automated verification

Checks performed on macOS with Rust 1.99.0, JDK 21, and Gradle 8.13:

| Check | Result / boundary |
|---|---|
| Shared headless tests, `--features p2p --all-targets` | 60 passed, including real cluster/transfer contracts |
| Headless and Android JNI Clippy, warnings denied | Passed |
| Android JNI host test | Membership projection preserves raw metadata and camel-case field names |
| Android JVM tests | 6 passed; same-title/case groups, artist credits, and multidisc ordering covered |
| Android Lint and APK/test-APK assembly | Passed; does not execute device instrumentation |
| Android ARM64 JNI build | Passed with the pinned NDK |
| Windows-target Clippy, all targets, warnings denied | Passed for `x86_64-pc-windows-gnu` using LLVM-MinGW 20261006 |
| Windows executable cross-link | Not completed: GNU linking needs GCC runtime libraries; LLVM-target debug linking exceeds the dependency DLL export limit before linking the app |

The Windows cross-check compiles Windows API paths, but does not run DPAPI,
audio, discovery, cancellation, or the Windows message loop. The Windows app
guide retains native MSVC build instructions; rerun them on the Windows
workstation before reporting native acceptance. A successful cross-link is
also distinct from executing the resulting application.

The LLVM-target attempt used `x86_64-pc-windows-gnullvm`, the
[Rust target for LLVM-based Windows toolchains](https://doc.rust-lang.org/rustc/platform-support/windows-gnullvm.html).
Its debug build failed while linking the unchanged `iroh-relay` dependency:
79,434 exported symbols exceeded the PE limit of 65,535. No dependency or release
profile workaround was introduced for this local cross-build. Native MSVC
release linking and device execution remain target-machine checks.

## Remaining target-device checks

Use [the repair plan](../windows-android-review-repair-plan.md) for the full
acceptance scenarios. On Android, prepare at least one verified saved track in
an isolated test library or preserve the existing enrolled debug installation.
The instrumentation runner now has a `ui` phase that drives the real Activity:
it replays a saved track, checks prepared pause controls, recreates Connections,
and opens registration without changing the enrolled library.

```sh
adb shell am instrument -w -e phase ui \
  as.ason.syncstr.android.test/as.ason.syncstr.PlaybackCheck
```

Also confirm audible track A-to-B switching, offline reopen, preparation-time
switching, and recovery from unavailable files on the ARM64 device. The `ui`
phase alone does not establish audible playback or all failure classes.

On native Windows, verify large-file transfer while moving/repainting the
window and pausing existing playback, unreachable-host retry, row selection
changes during saving, and close/reopen during transfer. Confirm identity and
saved music survive restart, partial audio is never marked saved, and offline
playback is audible.

No physical device interaction, main integration, push, NAS deployment, or
distribution is recorded as completed for these repairs.

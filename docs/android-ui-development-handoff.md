# Android UI development on Windows

Status: the initial LAN playback client is implemented and physically verified.
The first user-facing Android interface and reproducible Windows build are
implemented. The refreshed interface still requires physical-device visual,
accessibility and playback verification.

## Start here

- [Android build guide](../apps/android/README.md): current toolchain and macOS
  build commands.
- [M5 acceptance record](cluster-android-m5.md): implemented behavior and actual
  device verification.
- [Windows application handoff](cluster-windows-m5.md): building a Windows
  playback application, a separate task from developing Android on Windows.
- [Design guidance](../DESIGN.md) and [coding standards](../CODING_STANDARDS.md):
  interaction expectations. Use platform-appropriate Android controls rather
  than copying macOS geometry.

## Current architecture

| Area | Source | Current responsibility |
|---|---|---|
| Screen and playback | [MainActivity.kt](../apps/android/app/src/main/java/as/ason/syncstr/MainActivity.kt) | Native Activity with connection management, album-grouped library, saved-only view, explicit save states, mini-player and now-playing view |
| LAN discovery | [LanDiscovery.kt](../apps/android/app/src/main/java/as/ason/syncstr/LanDiscovery.kt) | Android NSD, endpoint ID validation and address lifecycle |
| Secure identity | [DeviceKey.kt](../apps/android/app/src/main/java/as/ason/syncstr/DeviceKey.kt) | Device secret encrypted by an Android Keystore AES-GCM key; backups excluded |
| Native boundary | [Native.kt](../apps/android/app/src/main/java/as/ason/syncstr/Native.kt), [JNI implementation](../apps/android/native/src/lib.rs) | Synchronous JSON operations called on a serialized background worker |
| Shared behavior | [cluster_client.rs](../headless/src/cluster_client.rs) | Enrollment, trusted hosts, conflict-aware catalog, verified selective download and local-file lookup |
| Device check | [PlaybackCheck.kt](../apps/android/app/src/androidTest/java/as/ason/syncstr/PlaybackCheck.kt) | Real host enrollment/transfer and MediaPlayer checks; separate process for local restoration/playback |

There is no Compose implementation or external UI dependency in this baseline.
The package is `as.ason.syncstr`, application ID is `as.ason.syncstr.android`,
and the native library is `libsyncstr_android.so`. The app targets Android 9+
and currently packages only `arm64-v8a`. UI edits must preserve identity,
membership and saved audio across APK updates.

The application pastes an invitation and confirms the host ID. It
discovers addresses on the LAN, refreshes metadata without downloading every
track, and saves a verified original only when the user chooses Save. Saved
tracks play without contacting a host. Catalog conflicts remain visible while
unrelated tracks can be updated; a missing artist has a fallback label.

## Windows build preparation

The verified versions are JDK 21, Gradle 8.13, AGP 8.13.2, Kotlin 2.2.21,
Android SDK 36, Build Tools 36.0.0, NDK 28.2.13676358 and Rust 1.99. Android
Studio can open `apps/android`; select the matching SDK and Gradle JDK. The
repository currently does not contain a Gradle wrapper, so use the pinned
Gradle installation or add a verified wrapper as a separate build change.

The first Windows task is adapting [build-native.sh](../apps/android/build-native.sh).
It hard-codes the macOS NDK `darwin-x86_64` toolchain and cannot run unchanged
on Windows or WSL. For a native Windows PowerShell build:

1. Install the Android SDK/NDK and Rust toolchain, and add the
   `aarch64-linux-android` Rust target. Record the resolved compiler versions.
2. Locate the installed NDK's Windows LLVM toolchain. Set the target-specific
   C compiler, archiver and Cargo linker to its Android API 28 ARM64 tools;
   account for Windows executable/command-wrapper suffixes. Do not use the
   Windows host compiler to link the Android `.so`.
3. Build `apps/android/native/Cargo.toml` with `--locked --target
   aarch64-linux-android`, copy the resulting `.so` to
   `apps/android/app/src/main/jniLibs/arm64-v8a/`, and strip debug information
   with the same NDK. Verify this process before documenting it as a working
   PowerShell command or script.
4. Assemble the Kotlin APK and run Android Lint. Kotlin-only iterations can
   reuse that `.so` until Rust or the JNI contract changes.

From the repository root, after native-library preparation:

```powershell
gradle -p apps/android assembleDebug assembleDebugAndroidTest lintDebug
adb devices
adb install -r apps/android/app/build/outputs/apk/debug/app-debug.apk
adb install -r apps/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
```

These Windows steps have not yet been executed. Use an ARM64 device; an x86_64
emulator needs a separately built and packaged native library. Keep Windows and
WSL SDK/toolchain paths separate. WSL SSH is useful for repository work but does
not establish native Windows toolchain or attached-device access.

Android debug signing keys may differ between machines. If `adb install -r`
reports a signature mismatch, preserve the existing app and its data: use an
appropriately transferred development signing key or a separate development
application ID. Uninstalling to bypass the mismatch deletes the app's cluster
identity and saved library. Do not put signing keys in the repository.

## UI work to carry forward

The next UI iteration should make the existing flow understandable before
expanding transport features. Confirm the screen design before changing it.

| User task | Current presentation | Remaining verification or boundary |
|---|---|---|
| Register a library | Connections screen, invitation entry and host-ID confirmation | Verify first-run and unavailable-host states on a device |
| Browse music | Albums, artists and songs views backed by catalog metadata | Artwork is an explicit placeholder until the native contract supplies artwork |
| Save music | Separate remote, saving, saved and failed/retry states | Verify slow and interrupted transfers on a device |
| Play saved music | Mini-player and now-playing view with progress and seeking | Verify recreation, seeking and audible playback on a device |
| Recover from failure | Actionable offline and transfer messages with retry | Verify screen-reader announcements and recovery timing |
| Notice a conflict | Affected catalog title when identifiable, otherwise a shortened object reference | Resolution remains manual outside this Android contract; verify unrelated music stays usable |

Search, QR scanning, Android remote access, background playback service,
notification/lock-screen controls, upload and store distribution are not
implemented in this slice. Treat each as explicit follow-up scope, not as
behavior already guaranteed by this handoff. The current Activity pauses
playback when stopped.

Keep transfer work off the UI thread and serialize access to the native store.
Do not couple library refresh to automatic full-library downloading. Display
optional metadata defensively. Preserve late-start discovery cleanup when the
Activity is destroyed and release playback resources with its lifecycle.

## Verification during UI development

Use a disposable test cluster and a fresh invitation from its host; invitations
are single use. Do not copy a consumed token or production identity from a prior
development session into a fixture. Verify these public flows on the device:

- First enrollment, catalog refresh, explicit save and audible playback.
- Restart with Wi-Fi and mobile communication disabled, then play saved audio.
- Missing artist/artwork, an empty library, unavailable host, and retry.
- Conflict notification while unrelated tracks remain usable.
- Activity recreation and leaving/reopening the screen during discovery.
- Large text, system insets, scrolling, focus, and accessible button labels.

Retain the real Rust integration tests. Run device instrumentation against the
same native contract whenever it changes; changing Kotlin alone does not rebuild
the Rust library. A successful Gradle build is not audio or UI acceptance.
Record screenshots, physical audio confirmation and network conditions
separately, using sanitized documentation rather than personal device IDs or
temporary session paths.

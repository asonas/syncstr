# Syncstr for Android

The first Android client joins a cluster on the LAN, discovers headless library
hosts with Android NSD, downloads selected originals, and plays saved audio
offline. Its Kotlin interface calls the existing Rust membership, SQLite and
verified transfer implementation through JNI. Device secrets are encrypted with
an Android Keystore AES key; backup is disabled.

## Build

The current development build targets Android 9 or newer on ARM64. Use Java 21,
Gradle 8.13, Rust 1.99, Android SDK 36, Build Tools 36.0.0 and NDK 28.2.13676358.
Use `build-native.sh` for the macOS NDK toolchain or `build-native.ps1` on Windows.

```sh
mise install java@temurin-21.0.12+101.0.LTS gradle@8.13
mise exec -- rustup target add aarch64-linux-android
export ANDROID_HOME="/path/to/android-sdk"
sh apps/android/build-native.sh
mise exec gradle@8.13 java@temurin-21.0.12+101.0.LTS -- gradle -p apps/android assembleDebug
```

### Windows PowerShell

Install JDK 21, Gradle 8.13, Android SDK 36, Build Tools 36.0.0, NDK
28.2.13676358, and Rust 1.99.0. Accept the Android SDK licenses
through the official SDK manager, then install the Android Rust target. Keep
`ANDROID_HOME` pointed at the native Windows SDK rather than a WSL path.

Install these SDK package IDs: `platform-tools`, `platforms;android-36`,
`build-tools;36.0.0`, and `ndk;28.2.13676358`.

```powershell
rustup toolchain install 1.99.0 --profile minimal --target aarch64-linux-android
$env:ANDROID_HOME = 'C:\Android\Sdk'
./apps/android/build-native.ps1
./apps/android/gradlew.bat -p apps/android assembleDebug assembleDebugAndroidTest lintDebug
```

`build-native.ps1` resolves the NDK's `windows-x86_64` LLVM toolchain, builds
the ARM64 Android library with Rust 1.99.0 and the locked Cargo graph, copies it into
`app/src/main/jniLibs/arm64-v8a/`, and strips debug information. Pass
`-Configuration Release` only when a release native library is explicitly
needed. `-RustToolchain` can select another installed toolchain for diagnosis;
1.99.0 is the configuration verified for this Android client, not a Cargo
manifest MSRV declaration. Kotlin-only iterations may reuse the prepared native
library until Rust or the JNI contract changes.

The checked-in Gradle wrapper pins Gradle 8.13 and verifies the distribution
checksum. Set `JAVA_HOME` to the JDK 21 installation before invoking it.

The expected debug artifacts are:

- `app/build/outputs/apk/debug/app-debug.apk`
- `app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk`

Before replacing an existing installation, confirm that the APK is signed with
the same development key. Do not uninstall to work around a signature mismatch:
uninstalling removes the enrolled device identity and saved music.

Install `app/build/outputs/apk/debug/app-debug.apk` with `adb install -r`.
Keep the phone and the library host on the same LAN. Open **Connections**, paste
a playback-device invitation into **Register connection**, verify the displayed
host ID, and register. The host address is discovered locally; no IP address
needs entering. Use **Refresh**, then browse albums in **Library**. **Save** stores
a verified original on the device; saved tracks expose a separate **Play**
action and appear under **Saved**. The mini-player opens the full now-playing
screen. Saved audio remains available after restart without a network connection.

Remote relay configuration and Android distribution are subsequent slices. A build
does not establish Android playback acceptance; see the
[M5 checks](../../docs/cluster-android-m5.md).

For continued UI development on a Windows workstation, see the
[development handoff](../../docs/android-ui-development-handoff.md), including
device-update precautions. The [repair record](../../docs/validation/windows-android-review-repairs.md)
documents album presentation, repeated playback, and Activity recreation checks.

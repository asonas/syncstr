# Syncstr for Android

The first Android client joins a cluster on the LAN, discovers headless library
hosts with Android NSD, downloads selected originals, and plays saved audio
offline. Its Kotlin interface calls the existing Rust membership, SQLite and
verified transfer implementation through JNI. Device secrets are encrypted with
an Android Keystore AES key; backup is disabled.

## Build

The current development build targets Android 9 or newer on ARM64. Use Java 21,
Gradle 8.13, Rust 1.99, Android SDK 36, Build Tools 36.0.0 and NDK 28.2.13676358.
The native build script currently uses the macOS NDK toolchain.

```sh
mise install java@temurin-21.0.12+101.0.LTS gradle@8.13
mise exec -- rustup target add aarch64-linux-android
export ANDROID_HOME="/path/to/android-sdk"
sh apps/android/build-native.sh
mise exec gradle@8.13 java@temurin-21.0.12+101.0.LTS -- gradle -p apps/android assembleDebug
```

Install `app/build/outputs/apk/debug/app-debug.apk` with `adb install -r`.
Keep the phone and the library host on the same LAN. Create a playback-device
invitation with the headless CLI, paste its JSON into **Register connection**, and
register. The host address is discovered locally; no IP address needs entering.
Use **Refresh library**, then select **Play / Save on this device** for a track.
Saved audio remains available after restart without a network connection.

Remote relay configuration and Windows support are subsequent slices. A build
does not establish Android playback acceptance; see the
[M5 checks](../../docs/cluster-android-m5.md).

For continued UI development on a Windows workstation, see the
[development handoff](../../docs/android-ui-development-handoff.md), including
the native build-script portability gap and device-update precautions.

# Syncstr for Android

The Android client joins a cluster on the LAN, discovers headless library hosts
with Android NSD, downloads selected originals, and plays saved audio offline.
Its Kotlin interface calls Rust membership, SQLite and verified transfer through
JNI. Device secrets are encrypted with an Android Keystore AES key; backup is
disabled.

## Build

The development build targets Android 9+ on ARM64. The native script supports
macOS (Apple Silicon and Intel) and x86_64 Linux. Linux builds have been verified
on a remote host. Native Windows has a separate verified PowerShell build;
WSL execution remains unverified.

Use Java 21, Gradle 8.13, Rust 1.99, Android SDK 36, Build Tools 36.0.0 and NDK
28.2.13676358. The checked-in Gradle wrapper pins Gradle 8.13 and verifies
its distribution checksum. Install the SDK packages
`platform-tools`, `platforms;android-36`, `build-tools;36.0.0` and
`ndk;28.2.13676358`, then provision the development key below.

```sh
mise install java@temurin-21.0.13+9.0.LTS gradle@8.13 android-sdk@23.0
mise exec -- rustup target add aarch64-linux-android
mise exec android-sdk@23.0 -- sh apps/android/build-development.sh
```

For an SDK installed outside mise, set `ANDROID_HOME` and run
`sh apps/android/build-development.sh`. This builds the native library, both APKs,
and runs Android Lint, using four Cargo jobs and two Gradle workers. Set
`CARGO_BUILD_JOBS` to change native concurrency. A missing development key fails
before compilation. APKs are under `apps/android/app/build/outputs/apk/`:

- `debug/app-debug.apk`: `as.ason.syncstr.android.dev`, label **Syncstr Dev**.
- `androidTest/debug/app-debug-androidTest.apk`: development instrumentation.

The base application ID remains `as.ason.syncstr.android`. Debug builds have
their own data and enrollment, and can coexist with that everyday app. An
x86_64 emulator requires a separately built and packaged native library.

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

On Windows, provision the same development keystore described below. Set
`SYNCSTR_ANDROID_DEV_KEYSTORE` to its absolute Windows path.

## Stable development signing

The debug variant uses a dedicated keystore at
`$HOME/.local/share/syncstr/android-dev/development.keystore`, or the absolute
path in `SYNCSTR_ANDROID_DEV_KEYSTORE`. Provision the same key on authorized
build machines. Do not regenerate it when moving a checkout or changing hosts.
The alias is `androiddebugkey` and the development-only store/key passwords are
`android`; filesystem access and a protected backup safeguard this key. It is
not a store-release signing configuration.

For first-time setup only, after checking that no existing development identity
needs to be recovered:

```sh
umask 077
mkdir -p "$HOME/.local/share/syncstr/android-dev"
mise exec java@temurin-21.0.13+9.0.LTS -- keytool -genkeypair \
  -keystore "$HOME/.local/share/syncstr/android-dev/development.keystore" \
  -storetype PKCS12 -storepass android -keypass android \
  -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Syncstr Development,O=Syncstr,C=JP"
```

Keep the key out of Git, restrict its file to mode 0600, and establish a protected
backup before relying on retained app data. Record the expected certificate
SHA-256 and backup location privately. A signature mismatch requires restoring
the correct key; never uninstall to bypass it.

## Remote build and local device loop

Use one authoritative remote worktree and hand source changes between machines
through Git. The [remote plan](../../docs/android-remote-development-plan.md)
records ownership and acceptance; the repository skill
[`syncstr-android-dev`](../../.agents/skills/syncstr-android-dev/SKILL.md) guides
an iteration. General Herdr operations belong to the installed Herdr skill.

1. On the build host, run the build command above. Save the base revision and
   dirty-source patch, APK SHA-256, application ID, version, ABI and signing
   certificate alongside the artifact in private storage. Inspect identity with
   the SDK's `build-tools/36.0.0/aapt dump badging` and
   `apksigner verify --print-certs` (Java 21).
2. Retrieve the identified APK over SSH. Compare its local SHA-256 with the
   remote result before installing. Inspect its application ID and certificate
   against the configured development identity. Preserve these checks when
   automating retrieval; do not trust a filename alone.
3. Select the physical device explicitly. In the example below, replace the
   fictional serial and artifact path. Use `mise exec android-sdk@23.0 -- adb`
   if ADB is selected through mise. Check `adb devices -l` for authorization;
   an absent configured device leaves installation pending.

```sh
device_serial="example-device-serial"
adb -s "$device_serial" install -r /path/to/app-debug.apk
adb -s "$device_serial" shell am start -W \
  -n as.ason.syncstr.android.dev/as.ason.syncstr.MainActivity
adb -s "$device_serial" exec-out screencap -p > launch.png
app_pid=$(adb -s "$device_serial" shell pidof as.ason.syncstr.android.dev)
test -n "$app_pid" && adb -s "$device_serial" logcat -d --pid="$app_pid" > launch.log
```

Capture the screen after it settles and inspect the image, process logs and
launch result. Keep raw evidence private. The command sequence is not a claim
that the screen or playback succeeded.

Use a disposable cluster on the same LAN. Open **Connections**, paste a fresh
playback-device invitation into **Register connection**, verify the host ID, and
register. Use **Refresh**, then browse albums in **Library**. **Save** stores a
verified original; saved tracks expose **Play** and appear under **Saved**.
The mini-player opens the now-playing screen. Ordinary APK updates use
`install -r` and preserve enrollment and saved audio.

The existing `PlaybackCheck` instrumentation accepts `phase=online`, an object
SHA-256 and a base64 invitation; the `offline` phase restores and plays saved
audio without network operations. Install its APK with `adb install -r -t` and
invoke `as.ason.syncstr.android.dev.test/as.ason.syncstr.PlaybackCheck`.
Success requires `INSTRUMENTATION_CODE: -1`; ADB's exit status alone is
insufficient. Keep invitations out of logs. Verify physical audio and a restart
with device radios disabled separately. See the
[device flows](../../docs/android-ui-development-handoff.md#verification-during-ui-development).

Google Play internal testing and Android relay access remain separate work. A build does not establish playback acceptance; see the
[M5 record](../../docs/cluster-android-m5.md).

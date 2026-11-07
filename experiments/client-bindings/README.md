# Client binding experiment

Isolated [ASO-68](https://linear.app/asonas/issue/ASO-68) experiment, based on main `01d02f3`. This directory does not change production client dependencies, credentials or storage. The catalog and delayed work are synthetic; no network, audio or real profile migration is implemented.

## Reproduce on Windows

Install Rust with the MSVC toolchain, Swift for Windows (including its C/linker prerequisites), and Java. The repository's Android Gradle wrapper supplies Gradle 8.13; an Android SDK is not needed for this JVM probe.

From this directory in PowerShell:

```powershell
./verify.ps1
```

The script builds the Rust library and its own generator, generates both bindings, runs the direct Rust integration test, executes Kotlin/JVM against the DLL through JNA, then compiles and executes Swift against the same DLL. Generated files and build products stay ignored. Synthetic lock files live in temporary directories and are removed by the probes.

UniFFI runtime and generator both pin **0.32.2**; `Cargo.lock` pins the Rust dependency graph. Kotlin pins 2.2.21, JNA 5.17.0 and coroutines 1.10.2. No global generator installation is required. The native dependency versions are experimental, not an ASO-48 adoption decision.

Artifacts for `x86_64-pc-windows-msvc` are `target/debug/syncstr_binding_probe.dll`, its `.dll.lib` import library and the optional `.lib` static archive. Generated Kotlin is under `generated/kotlin`; Swift source, C header and module map are under `generated/swift`. The Swift executable is `build/swift-probe.exe`. Android ARM64 build, packaging and physical-device results are described below; Apple native/Simulator artifacts remain unverified. Debug artifacts are unsuitable for ASO-69 packaging comparisons.

## Executed results

On 2026-11-07, Rust/Cargo 1.99.1, Swift 6.3.3 for Windows x64 and Java 11.0.31 ran `verify.ps1` successfully:

| Check | Executed result |
| --- | --- |
| Rust direct interface | Integration test passed, including logical identity, explicit cancellation, shutdown and drop/reopen |
| Swift generated interface | Compiled, linked and executed against the Windows DLL |
| Kotlin generated interface | Compiled and executed on the JVM against the same DLL via JNA |
| Typed catalog/pin values | Revision 7 retained two distinct logical IDs with the same audio hash; returned pins compared equal |
| Typed errors | Duplicate profile and invalid pin rejected with specific generated error cases |
| Async executor return | Swift resumed under `MainActor.assertIsolated()`; Kotlin resumed on the named single-thread dispatcher |
| Cancellation and late work | Waited for operation entry, explicitly cancelled, then awaited delayed completion; it returned `Cancelled` instead of a pin |
| Lifetime | Explicit shutdown allowed immediate reopen while the old wrapper remained alive; Kotlin `use` and Swift ARC release also allowed reopen without shutdown |
| Closed client | Preparation failed with `Closed`; direct Rust also checked a retained operation after shutdown |
| Static checks | `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings` passed |

Swift executor checking here establishes concurrency isolation on Windows, not AppKit/UIKit main-thread behavior. Kotlin uses an explicit JVM dispatcher, not Android's Main dispatcher. Progress callbacks and real native UI delivery are not implemented. Work simulates a delayed result, not a cancellable network transfer. The single lazily initialized Tokio runtime is process-wide; `shutdown()` releases the synthetic profile, not that runtime. A production shutdown/drain policy still requires design.

## Binding findings and JNI comparison

The existing [JNI bridge](../../apps/android/native/src/lib.rs) accepts string operation names and JSON, opens a client and creates a Tokio runtime per call. This probe instead passes typed records/errors and retains a client and an operation across calls. Runtime work is scheduled on one shared Rust runtime while foreign futures drive the exported async method.

Kotlin adds JNA loading and coroutines as runtime dependencies; JVM success alone does not prove Android compatibility. The separate Android build below verifies `.so` packaging. Generated Kotlin wrappers implement `AutoCloseable` and reserve `close()` for wrapper disposal. Exporting a Rust `close()` produced duplicate Kotlin methods, so this probe uses `shutdown()` for the domain operation and leaves `close()`/`use` for generated disposal. Explicit shutdown and releasing a wrapper are different operations.

Swift uses generated async calls and ARC. The probe uses an explicit cancellation method and awaits the delayed result; it does not infer cancellation from `Task.cancel()` or coroutine disposal. Both wrappers can outlive profile shutdown, so operations check the closed state before returning a result. The exact release/cancellation policy needs to become part of the reviewed production interface.

Official references: [Rust scaffolding](https://mozilla.github.io/uniffi-rs/latest/tutorial/Rust_scaffolding.html), [async futures and cancellation](https://mozilla.github.io/uniffi-rs/latest/futures.html), [Kotlin lifetimes](https://mozilla.github.io/uniffi-rs/latest/kotlin/lifetimes.html).

## Android ARM64 build and packaging

The independent `android` project uses AGP 8.13.2, Kotlin 2.2.21, Java 17, SDK/target 36, minimum API 28, Build Tools 36.0.0 and Windows NDK 28.2.13676358. Install the Rust `aarch64-linux-android` target first. From this directory:

```powershell
$env:JAVA_HOME = 'C:/Toolchains/jdk-17'
./build-android.ps1 -AndroidHome 'C:/Android/Sdk'
```

This builds the Rust library with `--lib --no-default-features` so the host generator CLI is excluded from the ARM64 library. The default `bindgen` feature preserves the Windows generator workflow. It generates Kotlin directly from the ARM64 ELF using the matching host generator, copies/strips the native library, assembles app and instrumentation APKs, runs Lint, and checks native payload, ELF architecture/segment alignment, APK alignment and signatures. No device is selected or modified by this build command.

Android needs `jna:5.17.0@aar`, coroutines-android 1.10.2, AndroidX annotation 1.9.1 and `android.useAndroidX=true`. Using the ordinary JVM generation configuration produced three API-33 `Cleaner` Lint errors against minSdk 28. `android/uniffi.toml` enables UniFFI's Android cleaner mode; UniFFI 0.32.2's `--config` requires `[defaults.bindings.kotlin]`, rather than a flat `[bindings.kotlin]` override. Android sources are generated under `generated/android` separately from the JVM probe. The Android-specific API guards and `RequiresApi` annotations resolve the errors without suppressing Lint or raising the minimum SDK.

Executed on Windows on 2026-11-07 against a working-tree extension of `533c449`:

| Check | Result |
| --- | --- |
| Rust ARM64 shared library | Built with the API-28 NDK compiler; ELF machine AArch64 |
| Kotlin and test compilation | Android-specific generated Kotlin and the custom instrumentation runner compiled |
| APK assembly | App and test APKs assembled; app ID `as.ason.syncstr.bindingprobe`, distinct from both ordinary and development Syncstr apps |
| Native payload | Exactly `lib/arm64-v8a/libsyncstr_binding_probe.so` and `lib/arm64-v8a/libjnidispatch.so`; no other ABI packaged |
| 16KB compatibility checks | Both ELF libraries have 16KB LOAD alignment; `zipalign -c -P 16 4` passed on the app APK |
| Signatures | Both debug APK signatures verified with Build Tools |
| Lint | Passed with zero errors; seven warnings remain, including pinned dependency versions, ChromeOS ABI coverage and minimal probe presentation/backup metadata |
| Device execution | Passed on a physical Android 17 / API 37 ARM64 device: installation, instrumentation, cold Activity launch and local log/screenshot capture |

Artifacts are `android/app/build/outputs/apk/debug/app-debug.apk` and `android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk`. They use this machine's ordinary Android debug certificate, not the production or stable Syncstr development signing identity. Preserve that certificate when updating this probe; never uninstall an existing app to work around a signing mismatch. The build prints APK SHA-256 hashes. This is direct-install test packaging, not release/store validation or an AAR distribution contract.

When an explicitly selected physical ARM64 device is connected and USB debugging is authorized:

```powershell
./verify-android-device.ps1 -AndroidHome 'C:/Android/Sdk' -DeviceSerial 'serial-from-adb'
```

The helper verifies device state/ABI, signatures and app identity, installs both APKs with update semantics, runs instrumentation, and requires both the explicit PASS text and `INSTRUMENTATION_CODE: -1`. It then launches the probe and captures process logs and a screenshot under ignored `build/android-evidence`. On 2026-11-07 this full helper passed on a physical Android 17 / API 37 ARM64 device using the APKs built above. Instrumentation reported `PASS ARM64: typed values/errors, Main dispatcher, cancellation, disposal, shutdown/reopen` and result code `-1`; the cold launch reported `Status: ok`. The screenshot showed the minimal probe screen with its text overlapping the status-bar area; this is not product UI acceptance. Background service behavior, Activity recreation and audio playback are outside this synthetic probe. Earlier Android/API-28 execution and 16KB-page device execution remain unverified; ELF/APK alignment checks alone do not establish the latter.

Android packaging reference: [JNA on Android](https://github.com/java-native-access/jna/blob/master/www/FrequentlyAskedQuestions.md#jna-on-android).

## Remaining acceptance

ASO-68 remains open: execute the generated Swift interface on Apple targets, verify Apple native UI dispatch, cover any agreed Android lifecycle cases beyond this binding probe, and define callback and worker-drain behavior. Android ARM64 binding instrumentation passed on API 37; the declared API-28 baseline still needs runtime coverage. Feed these results into ASO-48 before adopting UniFFI or the proposed interface. ASO-69 owns Apple transport duplication/size/build measurements. This small synthetic library contains no iroh and cannot establish those costs.

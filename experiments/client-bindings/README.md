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

Artifacts for `x86_64-pc-windows-msvc` are `target/debug/syncstr_binding_probe.dll`, its `.dll.lib` import library and the optional `.lib` static archive. Generated Kotlin is under `generated/kotlin`; Swift source, C header and module map are under `generated/swift`. The Swift executable is `build/swift-probe.exe`. Only Windows x64 artifacts were built; Android ARM64 and Apple native/Simulator artifacts remain unverified. Debug artifacts contain generator-enabled dependencies and are unsuitable for ASO-69 packaging comparisons.

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

Kotlin adds JNA loading and coroutines as runtime dependencies; this JVM success does not prove Android `.so` packaging or Android compatibility. Generated Kotlin wrappers implement `AutoCloseable` and reserve `close()` for wrapper disposal. Exporting a Rust `close()` produced duplicate Kotlin methods, so this probe uses `shutdown()` for the domain operation and leaves `close()`/`use` for generated disposal. Explicit shutdown and releasing a wrapper are different operations.

Swift uses generated async calls and ARC. The probe uses an explicit cancellation method and awaits the delayed result; it does not infer cancellation from `Task.cancel()` or coroutine disposal. Both wrappers can outlive profile shutdown, so operations check the closed state before returning a result. The exact release/cancellation policy needs to become part of the reviewed production interface.

Official references: [Rust scaffolding](https://mozilla.github.io/uniffi-rs/latest/tutorial/Rust_scaffolding.html), [async futures and cancellation](https://mozilla.github.io/uniffi-rs/latest/futures.html), [Kotlin lifetimes](https://mozilla.github.io/uniffi-rs/latest/kotlin/lifetimes.html).

## Remaining acceptance

ASO-68 remains open: execute the generated Swift interface on Apple targets, verify native UI dispatch, build/package Android ARM64 and run its lifecycle cases, and define callback and worker-drain behavior. Feed these results into ASO-48 before adopting UniFFI or the proposed interface. ASO-69 owns Apple transport duplication/size/build measurements. This small synthetic library contains no iroh and cannot establish those costs.

# Synchronization core evaluation

Historical evidence from the initial validation. Commands and paths below refer to the evaluated commit; see the [current app guides](../../README.md#code-and-documentation-map) for present-day verification.

## Decision

**Do not adopt a shared Rust core.** Use Swift as the executable reference model for synchronization. Retain the Rust implementation only as a disposable JSON-vector conformance candidate.

Swift and Rust produced identical normalized JSON for three successful and four rejected vectors. However, calling Rust from Swift through FFI was not implemented. The adoption prerequisites for a minimal FFI call, error propagation, cancellation, and thread boundaries were therefore unmet. A reduction in test scope or failure surface from FFI could not be measured.

## Environment

- Execution: 2026-08-15T02:13:51+0900 (JST)
- Evaluated commit: `fe6c63c52611924531dd6bceaf412cb9b89a2fbe`
- OS: macOS 26.6.1 (Build 25G76)
- Swift: Apple Swift 6.3.3
- Rust: rustc 1.97.1, Cargo 1.97.1
- JSON comparison: jq 1.8.2

## Conformance

`make -C validation sync-test` exited with status 0. All 15 Swift library tests passed. Rust passed three engine unit tests and seven integration tests, for a total of 10.

The comparison target sent the same seven vectors to each runner individually. The three successful cases matched `state`, `events`, and `differences`. Both runners returned `{"error":"operation_rejected"}` for all four rejected cases.

The comparison script normalizes object keys and line breaks with `jq -S -c`. Only `state.playlist_tombstones.*` arrays are sorted, because they represent sets. Playlist and event arrays retain order because it affects state-transition semantics.

The comparison script reported a difference and exited with status 1 for differing fixtures. Reversed tombstone-set fixtures were equivalent and exited with status 0.

Rejected vectors exit with status 4 in the Swift CLI and 1 in the Rust CLI. The Makefile contract requires both to be nonzero and to emit the same JSON error classification; it does not require identical exit codes.

## Fixtures

Seven synchronization vectors:

- `sync-vectors/convergence-basic.json`
- `sync-vectors/convergence-conflicts.json`
- `sync-vectors/history-events.json`
- `sync-vectors/rejections/device-counter-regression.json`
- `sync-vectors/rejections/unknown-operation.json`
- `sync-vectors/rejections/missing-required-field.json`
- `sync-vectors/rejections/missing-server-seq.json`

Four comparison-script fixtures:

- `scripts/fixtures/compare-expected.json`
- `scripts/fixtures/compare-actual.json`
- `scripts/fixtures/tombstones-expected.json`
- `scripts/fixtures/tombstones-reversed.json`

Two Swift CLI error fixtures:

- `scripts/fixtures/invalid-json.json`
- `scripts/fixtures/expectation-mismatch.json`

Explicit failed cases: none.

## Swift CLI

`SyncValidationCLI` accepts one vector path and writes `state`, `events`, and `differences` as JSON to stdout on success. `VectorResult` is `Codable`.

Errors are distinguished by JSON on stdout and exit status:

| Condition | JSON | Exit status |
|---|---|---|
| Invalid arguments | `{"error":"invalid_arguments"}` | 2 |
| Missing path | `{"error":"vector_not_found"}` | 3 |
| Invalid JSON or rejected operation | `{"error":"operation_rejected"}` | 4 |
| Expectation mismatch | `{"error":"expectation_mismatch"}` | 5 |

CLI runs confirmed statuses 3, 4, and 5 for missing paths, invalid JSON, and expectation mismatches respectively.

## Measurements

Measured on 2026-08-15 with `/usr/bin/time -p` after the targets had already been built.

| Implementation | Tests | Elapsed time | Debug CLI size |
|---|---:|---:|---:|
| Swift | 15 | 2.54 seconds | 508,928 bytes |
| Rust | 10 | 0.07 seconds | 2,163,600 bytes |

These are local debug-build measurements, not a release-performance comparison.

## Reproduction commands

```sh
make -C validation sync-test
make -C validation sync-cli-test
make -C validation sync-compare-test
/usr/bin/time -p swift test --package-path validation/swift-sync --skip-build
/usr/bin/time -p cargo test --manifest-path validation/rust-sync/Cargo.toml
stat -f '%N %z bytes' validation/swift-sync/.build/arm64-apple-macosx/debug/SyncValidationCLI validation/rust-sync/target/debug/vector-runner
```

## FFI evaluation

| Item | Result |
|---|---|
| Minimal FFI call | Not implemented |
| FFI error propagation | Not verified |
| FFI cancellation | Not implemented |
| FFI thread boundaries | Not verified |
| Reduced test scope or failure surface | Not measured |

Without an FFI implementation, there is no evidence supporting migration to a shared Rust core.

## Distribution and packaging

Distribution and packaging were not measured. The debug CLI sizes above describe local validation executables, not product artifacts. No XCFramework, static library, or Swift Package binary target for integrating Rust into Swift was created.

iOS/macOS signing, notarization, release artifact size, startup time, update/rollback behavior, and bindings for Kotlin/C# clients were also not evaluated.

The adoption assessment covers the following items; only JSON-vector conformance was established:

| Item | Status |
|---|---|
| JSON-vector conformance | Verified with seven vectors in both Swift and Rust |
| Minimal FFI call | Not implemented |
| FFI error propagation | Not verified |
| FFI cancellation | Not implemented |
| FFI thread boundaries | Not verified |
| Reduced test scope or failure surface | Not measured |
| Release performance and size | Not measured |
| Artifact construction, signing, and notarization | Not measured |
| Client bindings and distribution | Not measured |
| Update and rollback operations | Not measured |

## Consequences for the implementation plan

The planned next stage makes the server's SyncService authoritative. Swift clients implement the machine-readable vector contract independently. Limit the Rust candidate to conformance checks; do not include it as a shared product core, FFI layer, or distributed artifact. Release performance, FFI, failure surface, distribution, and packaging remain unmeasured.

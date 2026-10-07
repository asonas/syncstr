# Technical validation reports

These reports preserve investigations performed before product implementation. Their commands refer to the evaluated commits, not necessarily the current main tree. Current app build and verification instructions are linked from the [README](../../README.md#code-and-documentation-map).

## Decisions

- [Synchronization core](sync-core-report.md): use Swift as the reference implementation; do not adopt a shared Rust core.
- [Apple playback](apple-playback-report.md): the macOS build succeeded; XCTest and physical iPhone playback results were BLOCKED.

## Interpreting results

BLOCKED means the execution prerequisites were unavailable and the behavior could not be observed. It is distinct from failure.

To change a BLOCKED case to PASS, add the reproduction command, environment, result JSON, and any failure reasons to the report. Do not reuse validation audio, credentials, or databases in production.

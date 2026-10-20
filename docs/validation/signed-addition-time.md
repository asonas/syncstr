# Signed addition-time compatibility

The shared [signed fixture](../../headless/fixtures/cluster-signed.json) contains
an unchanged legacy record without `addedAt` and a second Rust-signed record
with `addedAt = 1700000000123`. Both use the fictional identities and membership
proof already present in the fixture. The signing seed is test data, not an
operational credential.

The Rust `signed_addition_time_survives_replay_and_restart` contract test and
Swift `SignedAdditionCompatibilityTests` consume the same static bytes. They
verify signature acceptance, duplicate delivery, reopening the database,
preservation of the missing or exact millisecond timestamp, and rejection of
timestamp tampering without a valid replacement signature. The Rust check also
locks down the exact serialized signing payload, including legacy field omission.

The Swift suite runs in both Apple unit-test targets. The tests use real local
catalog databases and require no network or device credentials. Existing
`ClusterMembershipTests` continue to check exact signed-byte handling and
membership authorization.

This protects current Swift and Rust readers consuming older and current record
formats. It does not prove that an older executable accepts newly signed records
containing fields it did not know, and it does not establish mixed-version
physical-device interoperability. No production signature or persisted catalog
is rewritten by this change.

Verification on 2026-10-20 passed: all five Rust contract tests and contract
Clippy; both parameterized addition-time cases on macOS and iOS Simulator;
and the existing membership suites (12 macOS tests and 11 iOS tests).
The dedicated iOS Simulator was deleted after the run. No physical device,
production service, or installed application was changed.

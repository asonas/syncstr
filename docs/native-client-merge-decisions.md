# Native client merge decisions

Status: recommendations for owner review on 2026-11-07, against main `e214f9b`. D1–D4 are not yet accepted. This packet updates the [shared Rust proposal](shared-rust-client-design.md) and [playback support proposal](windows-android-playback-support.md) in PR #36. It changes no production code, dependency, profile or Issue status.

## Decisions needed to merge PR #36

Recommend accepting a staged Windows/Android contract while retaining explicit Apple adoption gates. Merging the design records that contract; implementation and platform acceptance follow in their existing issues.

| Decision | Recommendation | Alternative and consequence |
| --- | --- | --- |
| D1. Binding and interface | Use direct Rust calls for gpui and UniFFI for Kotlin, initially pinning generator/runtime 0.32.2 together. Use the same typed interface for the future Swift adapter, subject to Apple validation. Retain client/operation objects, typed errors, explicit cancellation and asset leases; use `shutdown()` separately from generated disposal | Retain handwritten JNI/C interfaces. This avoids JNA but adds separate ownership/error/cancellation glue; the Windows/Android experiment currently supplies no reason to prefer it |
| D2. Apple gate | Keep existing Swift/IrohLib production code. Require Apple execution in ASO-68 and ASO-69 A/B/C evidence before Apple adoption or IrohLib removal. These measurements do not block merging this conditional design or starting Windows/Android core work | Hold the entire design until Apple measurements finish, also blocking the demonstrated Windows/Android path |
| D3. Profiles and lifecycle | Validate copies first; preserve IDs, keys, receipts, pending intent and exact pins. Use one writer and an explicit cutover to a validated new profile. Stop native playback/release assets before a profile switch; await client shutdown/checkpoint/drain before releasing its writer | Replace profiles in place during initial integration. This has a smaller import step but a less reliable recovery path |
| D4. Delivery scope | ASO-70 catalog/projection, then ASO-71 acquisition/saves, then ASO-10/11 integration. Keep native queue/UI/audio in platform slices; ASO-72–79 deliver broader player/browse/import/OS behavior. Preserve the agreed daily-use gate and full macOS feature reference | Put queues, UI, OS lifecycle and Apple migration into the first core implementation, coupling native work to identity/save migration and enlarging ASO-10/11 |

The semantic interface is the decision, not a permanent ABI or every public field name. Transport, database and wire types remain private. Implementation may adjust names while preserving the reviewed identity, lifetime and persistence contracts.

## Evidence and limits

[The merged ASO-68 experiment](../experiments/client-bindings/README.md), delivered by PRs #37 and #44, executed direct Rust and generated Swift/Kotlin callers on Windows. Its Android ARM64 APK executed on a physical Android 17/API 37 device. Typed catalog/pin values, errors, async return to the caller executor, explicit cancellation with delayed-result rejection, disposal and profile reopen passed. Android packaging, JNA loading, signatures and ELF/APK 16KB alignment checks passed. This supports D1 as an initial implementation choice.

The experiment is synthetic and contains no iroh transport, production saves or migration. Swift on Windows does not establish Apple execution. API-28 runtime behavior, 16KB-page device execution, production callbacks and worker drain remain unverified. Its process-wide runtime and synchronous synthetic `shutdown()` are not the production lifecycle implementation. No Apple size/build/memory cost has been measured.

## Proposed lifecycle and migration contract

`shutdown()` is an asynchronous domain operation: reject new work, cancel transient operations, persist accepted save intent, drain/checkpoint the writer, then release the profile lock. It is idempotent and must not block a native UI executor. Wrapper disposal releases a handle; it does not cancel a durable save. Android Activity disposal must not close a client owned by the playback service. Generation/operation IDs prevent cancelled or superseded completion from changing native playback.

For profile cutover, first stop native playback and release its asset references, then await shutdown. Import from a consistent copy into a separate app-managed profile. Validate IDs, aliases, independent ownership, pending saves and exact playlist pins; reuse the existing OS-protected identity without silently generating a key. Only a validated import may become the selected profile through an atomic selection/checkpoint update. Originals remain untouched on failure; original audio never becomes evictable cache.

Rollback before new writes may select the preserved original profile. After new writes, rollback is not assumed lossless: it requires a reviewed reconciliation/reverse-import path. Never let an old writer open an incompatible new schema, or run two writers against one live profile. These rules authorize implementation against synthetic copies, not migration of the owner's production library.

## Merge and implementation gates

| Gate | Required evidence or decision | Tracking |
| --- | --- | --- |
| Merge PR #36 | Owner agrees D1–D4; documentation links/whitespace pass; pending evidence stays explicit | ASO-45/48 design review |
| Start Windows/Android core | Accepted typed/persistence contract; existing Rust wire semantics reused; isolated profiles | ASO-70, then ASO-71 |
| Ship v5 platform integration | Real acquisition/save/identity preservation and native UI/audio acceptance | ASO-10/11 and ASO-12 |
| Adopt on Apple/remove IrohLib | Apple binding execution, A/B/C measurements, legacy transport parity and separately scoped profile migration | ASO-68/69 and ASO-48 |
| Claim daily use/full macOS parity | Companion matrix, native/physical checks and all applicable feature follow-ups | ASO-45 platform slices |

After agreement, proposed dependency changes are:

- Remove ASO-48 as a whole-ticket blocker from ASO-70/71; ASO-71 retains ASO-70.
- Replace ASO-45/48 blockers on ASO-11 with ASO-70/71; add those core prerequisites to ASO-10.
- Link the accepted contract in each affected issue. Retain unrelated dependencies.
- Keep ASO-48 open for Apple evidence/migration decisions and ASO-45 open for full-parity follow-up scope. Do not mark either complete to unlock one accepted platform slice.

No dependency changes have been made by this proposal. ASO-68 remains open for its outstanding platform/lifecycle evidence; ASO-69 still requires its Apple experiment. These pending tasks are not implied to have passed by merging documentation.

## Playback scope decision

The owner already chose daily-use acceptance, both local audio and existing-library entry, and implemented macOS behavior as the target. D4 proposes the following delivery order without reducing that target:

1. v5 identity, independent saves and basic native playback integration: ASO-70/71, then ASO-10/11; retain ASO-12 cross-platform acceptance.
2. Queue/shuffle/repeat/restoration, browsing/save controls and standalone import: ASO-72–77.
3. Native media controls, background/lock playback and interruptions: ASO-78/79. Only after the daily-use matrix passes may either platform be called a supported daily player.
4. Settings, appearance, diagnostics and remaining macOS-reference details stay required for full parity; ASO-45 must scope their platform follow-ups before claiming that parity. These are not hidden additions to ASO-10/11.

Hosting, remote access and packaging/store release remain separate roles and acceptance. An early v5 milestone is not the full daily-use or macOS-parity milestone.

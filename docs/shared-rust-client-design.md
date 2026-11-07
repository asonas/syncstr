# Shared Rust client module

Status: Windows/Android contract and staged delivery accepted on 2026-11-07; see the [accepted decisions](native-client-merge-decisions.md). [ASO-48](https://linear.app/asonas/issue/ASO-48) remains open for Apple execution, linking/size measurements and migration decisions. The original inventory was assessed at `ecf8e4e` and prepared at `50d4d95`; this PR changes documentation only.

Use one Rust client module for authenticated protocol handling, logical catalog projection and offline-save ownership. Windows calls its Rust interface directly; Swift and Kotlin use generated bindings to that same interface. Keep native UI, credentials, file-access permissions, audio decoding/output and OS media integration on each platform. The existing macOS behavior is the functional reference, with [ASO-45](https://linear.app/asonas/issue/ASO-45) defining the Windows/Android acceptance scope.

This follows the direction already agreed in ASO-48. It does not move Apple off SwiftUI or make the gpui development target a replacement for the macOS app.

## Current merge decision packet

The [accepted decision packet](native-client-merge-decisions.md) refreshes this design against main `e214f9b` with merged Windows/Android ASO-68 evidence, four accepted choices, alternatives and separate adoption gates. The implementation inventory below retains its original dated assessment; it is not a current feature-completion claim.

## Original implementation inventory to preserve

| Implementation | Finding | Design consequence |
| --- | --- | --- |
| [Rust PlaybackClient](../headless/src/cluster_client.rs) | Reused by Win32 and Android, but operations and local-file lookup still use legacy object hashes. It exposes iroh types and legacy catalog data | Do not expose this interface unchanged through new bindings; translate the complete logical-track contract once inside the new module |
| [Android JNI](../apps/android/native/src/lib.rs) and [Native.kt](../apps/android/app/src/main/java/as/ason/syncstr/Native.kt) | Each operation opens a client, creates a Tokio runtime, dispatches a string operation with JSON arguments, and throws a generic Java exception on failure | Replace the operation bridge with a retained client object, typed results and explicit operation cancellation; preserve the installed profile and key |
| [Apple SharedAudio](../apps/macos/SharedAudio.swift) and [CatalogDatabase](../apps/macos/CatalogDatabase.swift) | Swift implements logical projection, exact ID/hash lookup, save ownership and incomplete-refresh retention | These are the first parity cases, not behavior to redesign during migration |
| [OfflineSaves](../apps/macos/OfflineSaves.swift) and [PlaybackCache](../apps/macos/PlaybackCache.swift) | Save intent and verified results survive restart; saves, original files and active playback have different retention rules | Core operations must own these rules, not merely return an audio path and leave bookkeeping to each caller |
| [ClusterTransport](../apps/macos/ClusterTransport.swift) and [PeerTransfer](../apps/macos/PeerTransfer.swift) | Both import IrohLib. The latter also supports legacy P2P use | Migrating v5 alone cannot remove the Swift package without losing another supported transport |
| [Headless manifest](../headless/Cargo.toml) | Client code currently shares a crate with HTTP/CLI/server dependencies and optional P2P/relay dependencies | Keep those implementation dependencies private; measure the linked result before claiming a small mobile footprint |

The Apple package pin is IrohLib 1.1.0 in [project.yml](../apps/ios/project.yml); Rust clients pin iroh 1.3.0. Package version numbers alone do not establish the embedded dependency versions or duplicate linked code. The [current Apple v5 record](validation/shared-audio-apple.md) supplies the behavioral baseline and its physical-device limits.

## Ownership and native adapters

| Responsibility | Rust client module | Native adapter |
| --- | --- | --- |
| Identity and membership | Validate supplied identity against the retained profile, authenticate hosts, check grants/revocation and reject baseline/protocol mismatch | Load/store the existing secret using Keychain, Android Keystore or Windows DPAPI. Preserve account/profile identity and expose recovery errors |
| Catalog | Validate and retain snapshots, project logical tracks/organization, keep aliases and exact playlist bindings, preserve unknown raw fields internally | Render immutable domain records; keep view selection, search text and scroll position |
| Incomplete/conflict state | Apply the existing unknown-scope fallback: retain the verified catalog and a persistent notice. Keep known conflicts scoped to the affected track | Display the appropriate notice and available playback actions; do not infer that an offline host deleted a track |
| Acquisition | Select authorized sources, enforce policy, verify complete bytes, stage/publish files, own cancellation and cache accounting | Supply network/execution policy changes and user playback intent |
| Saves | Own logical-track/hash receipts, album request snapshots, pending jobs, partial completion, retry/cancel and protected-byte references | Present save state and explicit user actions; do not remove files directly |
| Files and imported originals | Own files under supplied app-managed roots; preserve playback/save references before eviction | Supply permitted roots and local-import access. Maintain security-scoped/native permissions; original external files remain outside cache deletion |
| Playback | Return a verified playable asset with an active-use reference; expose stable logical identity and pinned bytes | Own AVFoundation, the Windows native engine and Android native engine, native format detection, seek/volume, timing and OS commands |
| Lifecycle | Persist accepted save intent and safe checkpoints; stop or retain work according to supplied execution policy | Report background-execution availability, network policy and shutdown; Android Activity lifetime is not the playback-service lifetime |
| Diagnostics | Emit bounded typed outcomes and operation IDs without leaking credentials or raw protocol payloads | Add native player errors, localize messages and expose user-controlled export |

Open retained local state before requesting an OS credential that may require interaction. Reading the catalog and already verified audio must not wait for a Keychain prompt. Attaching credentials enables authenticated network operations; a missing key for an enrolled profile must not silently generate a replacement identity.

The first module scope is client protocol, projection, acquisition and save state. Keep the existing Apple queue/player implementation intact during that migration. A later bounded player slice can move deterministic queue/transport intent into Rust and compare it with the existing Apple cases; decoding and audio output remain native. Do not force a queue rewrite into ASO-10/11's identity work.

## Interface proposal

Use a retained `Client` for one profile and explicit operation/save-job objects. Names below describe the agreed semantic contract, not a published ABI or an implementation skeleton.

| Caller intent | Interface result and contract |
| --- | --- |
| Open a profile, then attach its identity | Restore local catalog/save state first. Reject a profile/identity mismatch before network access. The client owns one serialized persistence writer |
| Read or refresh a library | Return a domain catalog with a revision and notices. Refresh is asynchronous and cancellable; rejected/incomplete input does not overwrite verified state |
| Read a playlist | Return ordered occurrences with their occurrence IDs and exact track/hash pairs; repeated occurrences stay distinct |
| Prepare playback | Accept a logical track plus an optional exact pin and operation ID. Return a verified local asset protected from eviction until the native player releases it |
| Save tracks/an album | Persist a request snapshot before acknowledging it. Return a durable job ID and per-track results; retry acquires only missing bytes |
| Cancel/remove a save | Cancel pending work while retaining verified successes, or remove the specified ownership. Another save or active playback reference still protects shared bytes |
| Observe changes | Deliver bounded typed status/progress updates with operation IDs/revisions. UI code dispatches updates onto its own UI executor; progress does not copy the entire catalog or expose per-frame playback events |
| Update policy or close | Apply current network/execution permission; stop workers and release the profile writer after pending state is durable |

Domain values crossing the interface include `TrackId`, `AudioHash`, `PlaylistOccurrence`, `PinnedTrack`, `CatalogView`, `SaveJobState`, `RefreshNotice`, `OperationId`, `VerifiedAudio` and actionable error categories. Wrappers may contain strings, but callers must never interchange track IDs and hashes or derive one from the other.

Keep iroh endpoints/connections/streams, Tokio handles, wire JSON, signed-record encoding, database connections, schema details, source-selection internals and server mutation requests inside the implementation. Neither a generic `request(JSON)` nor administrative credentials belong in the public client interface. Existing ASO-39/40/46/47 and mutation contracts remain authoritative; this module does not invent their missing behavior.

The playback asset needs a lifetime contract, not just a path. The native adapter retains its active-use reference until playback is stopped/replaced and the player releases the file. Save removal can drop one receipt without deleting bytes still referenced by another receipt or player. Format detection stays native, preserving Apple's hash-path MIME handling. Ordinary playback acquisition must not create an explicit save receipt.

## Bindings, execution and errors

Accepted D1 selects direct Rust calls for gpui and UniFFI for Kotlin, starting with matching generator/runtime 0.32.2. Swift adoption remains subject to the Apple gates in the decision packet. This design changes no production dependency. UniFFI supports async calls mapped to Swift/Kotlin futures; cancellation remains an explicit library contract, not an inference from dropping a task or coroutine. Provide operation cancellation and reject late results using the operation ID. [Swift bindings](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html), [async and cancellation](https://mozilla.github.io/uniffi-rs/latest/futures.html).

Reuse one Rust runtime for the client layer, with explicit ownership and shutdown; do not create one per command. Dispatch iroh work onto that runtime, serialize profile writes and move blocking verification/database work off UI executors. Never hold a store lock while invoking native code. Native callbacks marshal onto the required platform executor rather than assuming a Rust worker is a UI thread. UniFFI's runtime integration guidance describes retaining a runtime and bridging spawned work. [Runtime integration](https://mozilla.github.io/uniffi-rs/latest/internals/async-overview.html).

Separate temporary operation cancellation from durable save intent. Closing a view stops its observation; it does not erase an accepted save job. Cancelling a save is an explicit persisted command. App suspension may stop execution, while the job remains resumable under the same communication policy.

Use typed failures for identity attention, revoked membership, incompatible baseline, unavailable source, invalid pin, integrity failure, insufficient storage, cancellation and internal failure. Native code maps these to actions/localized text. Do not retry revoked/incompatible requests as generic connectivity failures or fall back to legacy writes after v5 activation. Panics are defects, not a normal user-error channel.

| Choice | Benefits | Costs and decision |
| --- | --- | --- |
| UniFFI for Swift/Kotlin; Rust directly for Windows | One typed domain interface and generated lifetime/error glue for both foreign callers | Accepted for Windows/Android; Swift remains gated. Kotlin JNA/coroutine packaging passed the probe; production and Apple lifetime behavior still need validation |
| Retain handwritten JNI; add a C interface for Swift | Reuses the Android loading path and avoids adopting generated Kotlin immediately | More handwritten marshaling, cancellation and ownership contracts in two languages; fallback only if the packaging experiment rejects UniFFI |
| Keep separate Swift and Rust clients | Smallest immediate Apple migration | Duplicated projection/save correctness remains; does not fulfill the agreed shared-core direction |

The official Kotlin integration uses JNA and coroutines; it is not a drop-in replacement for the existing JNI entry point. Generated Kotlin objects expose explicit disposal. Treat close/release behavior as part of the binding tests, particularly for playback references and profile locks. [Gradle integration](https://mozilla.github.io/uniffi-rs/latest/kotlin/gradle.html), [Kotlin lifetimes](https://mozilla.github.io/uniffi-rs/latest/kotlin/lifetimes.html).

## Packaging and the Iroh decision

Keep a Rust library interface usable without foreign bindings, with a binding feature producing Swift/Kotlin artifacts. First prove Windows direct use and Android ARM64 packaging, matching the current client targets. Apple artifacts must cover both supported native and Simulator targets. Generate bindings from the same source/build revision as the library, include matching headers/module maps for Swift, and preserve stable native library loading on Android. Do not broaden architecture support merely as part of this migration.

For the first bounded implementation, reuse existing Rust contracts behind the new interface. Before calling that artifact production-ready, inspect whether the monolithic headless dependency brings unnecessary server/relay code into the linked app. Extract only dependencies shown to be required by both the server and clients; do not create a speculative family of crates or a second wire model.

The target is one transport owner in Rust and eventual removal of Swift's IrohLib dependency. That removal must include the legacy `PeerTransfer` path or an explicit product decision retiring it. A v5-only switch leaves that import live. A temporary dual-transport build is a migration experiment, not evidence that the size/runtime cost is acceptable.

Measure the following with the same release settings and pinned dependency revisions on an Apple build environment:

| Variant | Purpose |
| --- | --- |
| A: current Swift client and IrohLib | Baseline app/framework sizes, clean and incremental build time, launch/idle memory and transport behavior |
| B: generated core plus retained Swift IrohLib | Determine actual duplicated transport/runtime code, linker behavior and migration overhead |
| C: core owns v5 and retained legacy transport; Swift IrohLib removed | Verify the proposed end state preserves both paths and removes the measured duplicate cost |

Retain linker maps, loaded-image information, framework/archive sizes and dependency revisions. Compare linked results rather than adding archive sizes or assuming similarly named crates are deduplicated. Record binding generation time separately from Rust and Swift compilation, using identical caches or explicitly cold runs. Exercise cancellation, shutdown and legacy reconnect in B/C, not only a no-op link.

These measurements were **not run** in this Windows design pass. There is no claimed byte count, time saving or proven duplication. This remains a required ASO-48 decision gate before committing to the Apple packaging transition. Do not remove IrohLib solely because the new core also mentions iroh.

## Migration and implementation slices

Start from current main and coordinate changes to `shared_audio_net.rs`, `shared_audio.rs` and `playlists.rs` with their active work. Do not carry old pre-merge instructions from ASO-10/12 into a new branch. Preserve the existing wire and storage contracts before extraction.

| Slice | Concrete scope | Required acceptance |
| --- | --- | --- |
| 1. Domain projection and native interface | Implement the typed Rust client projection/identity rules behind the proposed interface; reuse server contract types privately | Run the current Apple synthetic snapshot/pin/incomplete cases against the Rust public interface; retain distinct rows, organization, aliases and exact old playlist bytes |
| 2. Acquisition, ownership and persistence | Implement verified playback assets, shared-byte protection, durable save jobs and cancellation | Real disposable v5 host; save A/B sharing bytes, remove A while B stays saved/playing, offline restart and resumed partial saves. Reuse existing fixtures, not internal call-order mocks |
| 3. Generated-binding and packaging experiment | Prove Kotlin/Swift typed calls, explicit cancellation, callback dispatch, disposal and shutdown; perform the Apple A/B/C measurements | Native Windows and Android build checks; actual Swift/Kotlin execution and Apple linker/size evidence. A generated file or successful compile alone does not close the gate |
| 4. Windows and Android integration | ASO-11 and ASO-10 consume the shared module, keeping native credentials/UI/audio. Replace hash-keyed selection and generic JNI dispatch | Their existing v5 acceptance, preserved old saves/identity, responsive UI, exact pinned playback and isolated-profile native audio checks |
| 5. Apple migration | Replace projection first, then save/acquisition ownership and transport. Keep SwiftUI and native playback stable; retire duplicate Swift implementation after parity passes | Existing SharedAudio, OfflineSave, migration and player tests, then the same macOS/iOS UI cases. Actual device audio and lifecycle evidence stays separate |
| 6. Daily-player parity | ASO-45 follow-ups add deterministic queue/shuffle/repeat behavior, native OS controls/background lifecycle, browsing and standalone entry | Compare against existing macOS behavior; this is broader than ASO-10/11 v5 compatibility and ASO-12 identity acceptance |

Apple migration uses copied synthetic profiles first. Import current SQLite snapshots, aliases/save receipts, pending-save JSON and playback pins without changing IDs or reclassifying files. Only one implementation writes a given live profile at a time; comparison mode is read-only against copies. Before switching a real profile, define atomic import/checkpoint behavior, preserve originals and existing credentials, and demonstrate interruption/reopen without duplicated or lost save ownership. Rollback must not run an old writer against a newly incompatible schema.

The existing Swift tests become behavioral reference cases, not mocks of the Rust implementation. Move only assertions for behavior owned by the core; retain native player/UI/OS tests where the behavior still lives. ASO-12 continues to own the cross-platform shared-audio acceptance matrix.

## Published implementation issues

| Issue | Boundary | Prerequisite |
| --- | --- | --- |
| [ASO-68](https://linear.app/asonas/issue/ASO-68) | Swift/Kotlin binding experiment, cancellation, dispatch and lifetime behavior | Supplies evidence for ASO-48; does not migrate production clients |
| [ASO-69](https://linear.app/asonas/issue/ASO-69) | Apple A/B/C transport and packaging measurements | ASO-68 experiment and an Apple build environment |
| [ASO-70](https://linear.app/asonas/issue/ASO-70) | Shared logical catalog and exact playlist projection | Accepted D1–D4 contract |
| [ASO-71](https://linear.app/asonas/issue/ASO-71) | Verified audio acquisition, protected assets and durable save ownership | Accepted contract and ASO-70 identity/projection |

ASO-68 is In Progress with Windows and Android execution recorded; ASO-69–71 remain Backlog in the 2026-11-07 tracking snapshot. Existing ASO-10/11 own Android/Windows integration, and ASO-12 owns cross-platform identity acceptance. The [playback support contract](windows-android-playback-support.md#published-implementation-issues) links the separate daily-player follow-ups. Production Apple migration still needs an agreed import/rollback contract and a bounded implementation issue; the packaging experiment does not authorize that migration.

## Decisions and completion evidence still required

- The owner accepted the typed Windows/Android contract, initial UniFFI choice, copy-validated profile migration rules and staged delivery. Production implementation still needs its own focused parity and native acceptance.
- Complete the remaining Apple binding experiment and A/B/C measurements before deciding when IrohLib can be removed. Windows/Android probe execution has passed; it does not establish Apple packaging cost. Account for legacy `PeerTransfer`, not only v5.
- Implement the accepted profile import/rollback contract under ASO-10/11. Use the published follow-ups above, and scope production Apple migration separately rather than expanding the platform tickets implicitly.

This PR contains design documents only. The separately merged binding experiment is described in the decision packet; no production profile migration or device audio acceptance was performed by this design. ASO-48 remains open for its outstanding decisions and Apple evidence.

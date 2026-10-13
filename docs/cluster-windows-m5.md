# M5 Windows implementation handoff

Status: the initial native Windows playback client is implemented and builds on
Windows. Protocol integration tests and Windows identity-restoration tests pass.
Real LAN enrollment, firewall behavior, audible playback, offline restart and
screen inspection still require physical acceptance. The Android LAN slice is
recorded separately in [its acceptance record](cluster-android-m5.md).

## Product boundary

Start with a Windows playback client: enroll on the LAN, discover authorized
library hosts, browse the shared catalog, explicitly save selected originals,
and play them after restart without a network connection. A Windows desktop
may later become a library host and coexist with a NAS. Hosting is a cluster
role, not a separate library or an automatically granted privilege.

Do not require an operator-owned directory or relay. LAN setup requires no
manual peer IP or router port rule. Remote access remains optional and uses a
user-operated relay; adding it to Windows is a subsequent acceptance boundary.

See the [domain model](cluster-model-design.md),
[implementation plan](cluster-implementation-plan.md), and
[LAN protocol](cluster-lan-sync-m2.md) for the accepted cluster design.

## Existing implementation to reuse

| Concern | Current source and contract |
|---|---|
| Playback client | [PlaybackClient](../headless/src/cluster_client.rs): identity, trusted hosts, enrollment, catalog refresh, selected download, and verified local-file lookup |
| Enrollment | [Invitation and proof](../headless/src/enrollment.rs), [network enrollment](../headless/src/cluster_net.rs); expiring single-use invitation pins the host endpoint ID; enrollment requires LAN access |
| Cluster transfer | [Session](../headless/src/cluster_sync.rs), ALPN `syncstr/cluster/3`; signed membership and history are checked before verified original transfer |
| Discovery | [Rust discovery](../headless/src/cluster_discovery.rs); `_syncstr-cluster._udp.local.`, TXT `version=1` and full endpoint `id`, SRV port and IPv4 addresses |
| Persistence | [Store](../headless/src/store.rs); SQLite state, content-addressed objects, staging and exclusive data-directory locking |
| Behavior fixtures | [Client integration](../headless/tests/cluster_client.rs), [multi-host replication](../headless/tests/cluster_replication.rs), and [wire fixtures](../headless/tests/contracts.rs) |
| Concrete application example | [Android JNI](../apps/android/native/src/lib.rs) and [Activity](../apps/android/app/src/main/java/as/ason/syncstr/MainActivity.kt); these are Android-specific adapters, not a Windows API |

Discovery is an address hint, not authorization. Use signed, nonrevoked host
grants to choose candidates; authenticate the expected endpoint ID and verify
cluster membership. If one authorized source lacks an original, try another.
Do not persist the consumed invitation secret or automatically choose a winner
for conflicting metadata. Notify the user of conflicts and continue unrelated
catalog updates and playback.

## Windows work that is still required

The shared crate has Windows filesystem adapters in
[platform_fs.rs](../headless/src/platform_fs.rs), and the client uses Win32
controls, Windows multimedia playback, and per-user DPAPI identity protection.
The repair revision moves catalog/client work off the window thread. Verify
these behaviors on native Windows; cross-compilation does not prove filesystem
durability, discovery, audio output, or application lifecycle behavior.

The client persists a stable device secret through Windows-protected storage
for the current user and supplies its 32 bytes to `Identity::from_secret`.
The catalog and originals use the application's per-user data directory.
Verify directory access controls, locking, interrupted staging and atomic
replacement on Windows. A missing or unreadable identity must produce a recovery
error rather than silently create a replacement identity for an existing cluster.

Check the real discovery path and Windows firewall interaction. Retain the
tested Rust membership and transfer implementation. See the
[repair verification record](validation/windows-android-review-repairs.md)
for current checks and the remaining device acceptance.

## Development sequence on the Windows machine

1. Create a worktree from the repair branch and record the Windows,
   Rust and compiler versions. Run `rustc --version`, `cargo --version`, and
   `rustup show active-toolchain` in native PowerShell.
2. Follow [the Windows build guide](../apps/windows/README.md) and rerun native
   builds and Clippy. Resolve any target-specific failures at their boundaries.
3. Run the real client and multi-host integration tests natively. Retain the
   enrollment, revocation, integrity and conflict rejection contracts.
4. Verify discovery, invitation confirmation, catalog display, explicit save,
   local playback, pause/resume, and interruption/retry through the application.
5. Verify the acceptance path below with an actual headless host on the LAN.
   Record source revision, build, automated checks and physical playback results
   separately before main integration.

The following are focused verification commands for the native checkout; they
are not evidence that this revision already passes on Windows:

```powershell
cargo test --manifest-path headless/Cargo.toml --features p2p --test cluster_client --test cluster_replication --test contracts
cargo clippy --manifest-path headless/Cargo.toml --features p2p --all-targets -- -D warnings
```

## Native acceptance checklist

- Discover and enroll with a real LAN host without entering a peer IP. Confirm
  the expected host before redeeming the single-use invitation.
- Fetch the catalog without copying all originals. Display missing optional
  metadata safely and notify the user of unresolved conflicts.
- Explicitly save an original and verify its bytes before playback. Retrieve it
  from another authorized source when the first source cannot supply it.
- Close and reopen the application, then restart Windows: identity, membership,
  catalog and saved originals remain available.
- Disable network access and play saved audio audibly through the application.
  Unsaved tracks give a useful connection message.
- Reject revoked membership and corrupted transfers; unrelated nonconflicting
  music remains usable while conflicts await user resolution.
- Preserve Apple, Android and headless interoperability through the existing
  wire fixtures. Record remote-relay and library-host-role support separately.

WSL SSH access can assist with repository work, but native PowerShell builds and
Windows screen/audio checks must supply the acceptance evidence.

## Initial Windows implementation record

The client is implemented in [apps/windows](../apps/windows/). It uses native
Win32 controls, DPAPI scoped to the current Windows user, DNS-SD browsing through
the shared discovery contract, the existing Rust `PlaybackClient`, and Windows
multimedia playback. The per-user catalog and saved originals live under the
local application-data directory. A missing protected key beside an existing
catalog produces a recovery error rather than a replacement identity.

On the native Windows checkout, Rust 1.99 completed the following checks:

- headless `cargo check` with `p2p`;
- the playback-client, multi-host replication and wire-contract integration
  suites (nine tests total);
- Clippy with warnings denied for the headless crate and Windows application;
- three Windows tests covering DPAPI reopen, missing-identity recovery and
  invitation endpoint validation;
- an optimized Windows executable build and a launch/close smoke check whose
  top-level window title was `Syncstr for Windows`.

The Windows screen automation helper was unavailable during this run, so no
screenshot was captured. No disposable LAN host was available for enrollment,
transfer or audible playback. The Android ARM64 JNI library was rebuilt with NDK
28.2.13676358, then the debug APK, instrumentation APK, Lint and unit tests
completed with portable JDK 21 and Gradle 8.13. The same Gradle tasks also
completed offline from the populated task-local cache. These build checks do not
replace physical Android-device regression testing.

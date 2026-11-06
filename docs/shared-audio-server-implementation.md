# Shared-audio server implementation and verification

The opt-in v5 server preserves existing track addresses and signed playlist
history while allowing independent logical tracks to share an audio object.
Implementation and verification use disposable fixtures only. No production
database has been activated or migrated.

The [ASO-8 protocol and Mac handoff](shared-audio-v5-handoff.md) specifies the
QUIC contract, automatic LAN synchronization and disposable fixture commands.

## Persistence and compatibility

`headless/src/shared_audio.rs` implements a separate schema-5 store. Activation
adds `shared_baseline`, `shared_records`, `shared_requests`, `shared_cursors`,
`shared_playlists` and `shared_objects`; it leaves legacy table payloads intact.
The baseline retains canonical IDs, alias targets, album choices, addition times,
raw organization data and historical playlist ID/hash pins. Existing numeric
playlist source fields do not become approved source correspondences.

Activation requires a schema-4 database with an initialized cluster, its existing
membership proof, and exclusive ownership of `node.lock`. The expected baseline
is a SHA-256 fingerprint of the inspected snapshot. A stale baseline is rejected;
DDL and the schema-version change commit together. Repeated activation with the
same baseline preserves all new records. Opening a store never activates it.
Legacy binaries reject schema 5, and the dedicated v5 service returns 426 for
legacy routes after authentication.

New track UUIDs belong to registrations, not hashes. Metadata and album edits
address those UUIDs. Objects are verified by SHA-256 on upload and fetched copies
are verified before installation. Existing suffix paths remain valid; newly
stored objects use a hash-based `.audio` locator. No object garbage collection or
legacy-path consolidation is performed.

Track revisions retain all previously known bindings as playback pins. Changing
preferred audio, correspondence or retirement state does not retarget old
playlist pairs. Playlist changes require expected revision heads and explicit
confirmation when replacing a resolved pair; original signed revisions remain
byte-for-byte intact.

## Protocol and reference client

`headless/src/shared_audio_api.rs` serves these authenticated HTTPS endpoints.
The node bearer token authorizes administrative writes; it is not a read-only
client credential. The Rust client uses the existing certificate pinning.

| Endpoint | Contract |
| --- | --- |
| `GET /v5/membership` | Current signed enrollment grants and revocations |
| `POST /v5/membership` | Validate and merge a proof without removing known revocations |
| `POST /v5/revoke` | Sign a revocation for the supplied `member` using the active host authority |
| `GET /v5/catalog` | Logical tracks, frozen addresses, objects, retained pins, reusable correspondences, revision heads, conflicts and incomplete records |
| `POST /v5/commit` | `register`, `assign` or `edit-track`, with request ID, expected heads and review evidence |
| `GET /v5/records?after=0` | Up to 64 signed decisions with receiver cursor positions |
| `POST /v5/records` | Receive signed decisions without choosing conflict winners |
| `GET /v5/playlists` | Existing and new signed playlist projections |
| `POST /v5/playlists` | Explicit signed playlist revision with head checks and replacement confirmation |
| `GET /v5/playlist-records?after=0` | Up to four new signed playlist revisions |
| `PUT /v5/objects/{hash}` | Bounded streaming upload, verified against the requested SHA-256 |
| `GET /v5/tracks/{id}/audio/{hash}` | Exact retained ID/hash binding, including old aliases; supports byte ranges |

Types in `shared_audio.rs` define the JSON fields. Catalog payload `version: 1`
is the first v5 catalog shape. `Evidence.catalog` is the lowercase SHA-256 of the
exact compact catalog JSON response bytes. `snapshot` is the reviewed source
snapshot fingerprint; `reason` records the decision; `audio_eligible` is explicit
approval to attach playable bytes. A candidate match alone is not approval.
Source keys retain raw Music/iTunes library and track persistent IDs.

On re-import, consult `correspondences` and the target's retirement/conflict state
first. Reuse the approved logical ID; do not issue another `register`. Registration
of an already known source fails and requires review. `assign` with a target
approves or reassigns a correspondence; a null target revokes it. Distinct sources
cannot actively claim one target. Missing or protected sources can be registered
without audio. File upload alone never creates a logical track.

Each decision contains a host signature, grant, baseline, parents, request ID and
request digest. Identical retries return the original signed response, including
after replication to another host or subsequent revocation. Different content
under the same request ID is rejected. Disconnected proposals are retained as
conflicts; resolution references all current subject heads. Missing parents or
track dependencies remain incomplete. Replica records and cursors commit in one
transaction. Historical accepted records remain readable after grant revocation;
new incoming records require a currently valid host grant.

The Rust HTTPS reference client exposes `shared_catalog`, `shared_commit`,
`shared_playlists`, `shared_update_playlists`, `shared_pull` and
`shared_fetch_audio`. Pulling synchronizes decisions followed by playlist
revisions; audio is fetched separately through an authorized ID/hash pair.
Hosts must have the same cluster and exact activation baseline. The HTTPS client
performs explicit pulls. The v5 server also runs a separate authenticated QUIC
service and automatically pulls from discovered authorized v5 LAN hosts.

## Isolated activation commands

Build with the `p2p` feature. These commands are for an independently prepared,
consistent fixture copy with its own test identities, never a live data directory.
Stop the fixture's legacy process before inspection.

```text
syncstr-headless shared-audio-inspect --data fixtures/shared-node
syncstr-headless shared-audio-activate --data fixtures/shared-node --expected-baseline <printed-fingerprint>
syncstr-headless shared-audio-serve --data fixtures/shared-node --identity fixtures/tls --peer-state fixtures/peer --listen 127.0.0.1:8443
```

The automated tests prepare their own fixture snapshots and need none of these
manual commands. After schema-5 writes, downgrading the binary is unsafe; recovery
requires forward repair or coordinated restoration of the entire pre-activation
snapshot, accounting for later writes.

## Verification results

Verified on Windows with Rust 1.99.1:

- All eleven `headless/tests/shared_audio.rs` integration tests pass. They cover
  migration/reopen/repeat activation; old IDs, aliases, album choices and exact
  legacy payload preservation; two registrations sharing one object; independent
  metadata; multiple encodings with old playback pins; stale writes and retries;
  disconnected-host conflicts and explicit resolution; incomplete/tampered
  history; distinct source libraries and unavailable registrations; real pinned
  HTTPS replication, playlist confirmation, byte verification and range requests;
  migration rollback; competing sources claiming one legacy target; real QUIC
  synchronization and reconnect/reopen with one stored object; membership
  revocation on existing sessions and after replication; and old protocol,
  capability and baseline rejection.
- The Rust integration suite passes 73 tests with three existing Unix-specific
  process-shutdown tests excluded on Windows. Those tests invoke `/bin/kill`:
  `cli_processes_initialize_upload_restart_download_and_shutdown`,
  `separate_lan_hosts_catch_up_after_offline_import_and_restart`, and
  `cli_enrollment_discovers_the_pinned_host_without_an_ip_address`.
- Clippy passes with `--features p2p --all-targets -- -D warnings`.
- The fixture generator runs successfully, and the built server starts against
  its disposable database with a three-track HTTPS catalog and a loopback QUIC
  endpoint. This is a process startup check, not native-app playback validation.
- The Ubuntu verification workflow now includes the new shared-audio suite and
  playlist suite. Its existing CLI suite includes the first excluded test;
  the two LAN process tests still require a separate supported-platform run.
  CI has not been executed as part of this local verification.

Reproduce focused checks from the repository root:

```text
mise exec -- cargo +1.99.1 test --manifest-path headless/Cargo.toml --locked --features p2p --test shared_audio --test playlists
mise exec -- cargo +1.99.1 clippy --manifest-path headless/Cargo.toml --locked --features p2p --all-targets -- -D warnings
```

## Remaining acceptance gates

Server storage, identity preservation, signed correspondence and the reference
HTTPS path are implemented. The full design is not yet complete or ready for
production activation. These gates remain open:

1. Update Apple, Android and Windows clients to consume v5 without their old
   hash-based logical merge behavior. Verify both registrations on actual clients.
2. Implement and verify track-specific offline-save intentions, including removing
   one save while another track or active playback retains the shared object.
3. Complete native-client membership/onboarding interaction checks. v5 verifies
   and merges membership proofs, propagates signed revocations, requires its
   protocol capability and synchronizes authorized LAN hosts. Creating/redeeming
   new invitations remains the legacy pre-activation enrollment workflow;
   existing enrolled clients retain their grants. There is no v5 invitation UI.
4. Reconcile divergent legacy hosts into an agreed activation baseline, validate
   consistent backups and run the reviewed real-data pilot. The fixture tests do
   not prove that independently populated production hosts have equal baselines.
5. Run the remaining platform checks. Production activation and broad imports
   require a separate explicit instruction after these gates are satisfied.

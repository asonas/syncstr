# M1 persistence contract

Status: acceptance verified on 2026-10-11. The acceptance gate is defined in the
[cluster implementation plan](cluster-implementation-plan.md#m1-cluster-persistence-and-reversible-migration).

## Migration boundary

Cluster persistence is an additive projection beside the existing catalog tables.
It has its own schema version; it does not repurpose the catalog ID, track ID,
address-format version, or music-protocol version. Existing audio paths, metadata,
organization choices, private-key files, Keychain entries, and legacy JSON backups
remain intact. Schema creation and initial catalog projection commit together.
A failed transaction can be retried; opening an already migrated database must
not allocate another identity or duplicate records.

A new cluster ID is allocated only by an explicit cluster-creation operation.
Importing an existing pairing records a legacy peer, not cluster membership.
The member ID is the existing transport public key; private keys stay in their
existing secure storage. Legacy library access remains separate from cluster
replication until enrollment is implemented and verified in M2.

## Durable records

| Record | Identity and preservation rule |
| --- | --- |
| Cluster | UUID independent of library IDs; binds the local transport public key on explicit creation |
| Known peer | Legacy transport public key, display name, and bootstrap address; this table contains no membership grants or secrets |
| Audio object | Complete-file SHA-256 plus byte length; a repeated hash with a different length is rejected |
| Source location | Observed object, source library, original track ID, and optional member ID; one object can have multiple locations |
| Pending change | Immutable ID, author, causal parent IDs, and encoded operation; persistence is not authorization or application |
| Transfer job | Stable job ID, object, source, destination, and queued/running/complete state; interrupted running jobs return to queued during owner recovery |

Catalog projection preserves aliases and original metadata. A catalog observation
does not produce a storage receipt. New cluster mutation and replication are not
enabled merely because these tables exist. Verified membership, signed change
validation, tombstones, and conflict application belong to M2 before automatic
replication is enabled.

Cluster capability negotiation has its own version and explicitly covers
membership, deletion, and conflict support. An absent or incomplete capability
set cannot authorize automatic replication writes; legacy address/version fields
must never substitute for this check.

The `cluster-hello` request is separate from the legacy `hello` exchange. M1
responds with `upgrade-required` and its version-1 capabilities (all mutation
features false), without exchanging a catalog or applying organization changes.
It cannot be promoted to a writer by a peer advertising more capabilities.
M2 must validate both capabilities and signed membership before enabling writes.

Rust owns one exclusively locked store and recovers running jobs on open. Swift
opens connections per operation, so recovery is explicit and must run once before
a job executor starts, not on each database connection. No executor or completion
API is enabled in M1: verified receipts are an M2 requirement. The `complete`
state is reserved for that transaction; a catalog observation never sets it.

## CLI

With the node stopped, create an explicit cluster identity using its existing
transport key, or inspect the additive inventory:

```sh
syncstr-headless cluster-init --data ./data --peer-state ./peer-state
syncstr-headless cluster-info --data ./data
```

Run `peer-init --state ./peer-state` first only for a new node without an existing
transport identity. Repeating `cluster-init` retains the cluster UUID and rejects
a different local key. These commands use the store's exclusive lock; they do not
modify a running server's database. Creation does not enroll other devices.

## Required verification

- Reopen and repeat migration without changing identifiers, metadata, overrides,
  keys, pairings, or original files.
- Abort a migration transaction, then recover using the unchanged legacy catalog.
- Preserve offline file resolution after migration.
- Represent identical complete bytes at two locations as one object, retaining
  both original track aliases; keep different bytes distinct.
- Persist pending changes and transfer jobs across restart; reject inconsistent
  replay and do not mistake a pending change or observed location for authority.
- Reject automatic-writer capability negotiation for legacy and incomplete peers.

## Acceptance evidence

| Gate | Verification |
| --- | --- |
| Repeatable migration | Rust `tests/cluster.rs` and Swift `ClusterPersistenceTests` reopen pre-cluster fixtures, retain original catalog/audio/JSON, and keep the explicitly created cluster ID stable |
| Failure recovery | Both suites inject a SQLite transaction abort during projection, verify rollback, remove the fault, and retry against the original catalog; this is transaction-failure coverage, not a power-loss test |
| Key and pairing preservation | The CLI process test repeats cluster creation using the existing key file and allowlist; native peer restoration retains the original Keychain secret and restores/deletes the additive peer record |
| Multiple locations, one object | Both implementations retain two source aliases with one complete-file hash, reject inconsistent lengths, and deduplicate repeated observations |
| Durable pending state | Pending changes reject inconsistent replay; running jobs survive storage and return to queued during explicit owner recovery without granting membership or receipts |
| Offline playback | `LibraryCheck` removes the cluster projection from a real saved WAV fixture, migrates it, then observes muted AVPlayer playback advancing with no peer or source-folder registration |
| Protocol boundary | Rust P2P and Swift LAN tests request `cluster-hello`, receive `upgrade-required`, and continue to support the separately authorized legacy exchange |
| Cross-language records | Both suites decode and round-trip `headless/fixtures/cluster-state.json` |

The headless P2P suite passed 29 tests. Clippy passed with warnings denied for
both default and P2P builds. The macOS suite passed 42 tests with two optional
external-environment tests skipped (deployed directory and user-supplied audio).
The existing native-to-Rust test includes upload, retry, download, reconnection
after 125 seconds of inactivity, and preservation of saved files. The real
AVPlayer checks passed. The iOS application and test targets built successfully;
10 cluster and catalog migration tests passed on a disposable iPhone simulator.

These checks do not establish signed enrollment, two-host replication, physical
iPhone behavior, or power-loss durability. Those remain in M2 and later gates.
No original files or backups were removed, and no production state was migrated
by these tests.

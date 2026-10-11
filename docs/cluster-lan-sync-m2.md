# M2 LAN synchronization

Status: completed on 2026-10-11 after acceptance tests and review fixes.
The explicit `cluster-serve` command runs LAN replication.
Legacy music endpoints retain their separate authorization and cannot write the
cluster replication log.

## Implementation order

1. Persist expiring, single-use invitations. Bind redemption to the authenticated
   transport key in the same transaction as its resulting membership grant.
2. Define and verify signed membership history, host roles, revocation, and the
   causal boundary for records made by a subsequently revoked member.
3. Add a distinct encrypted enrollment protocol. Pin the inviting host from the
   invitation. Discovery advertises endpoint identity and protocol version only;
   invitations and grants must not enter discovery records or routine logs.
4. Reconcile bounded pages of signed changes and durable replica observations.
   Missing catalog entries never imply deletion. Represent explicit deletions,
   re-additions, metadata conflicts, and user resolutions before enabling writes.
5. Persist whole-file jobs, verify length and SHA-256, flush/publish storage, then
   commit the local receipt. Recover interrupted jobs without claiming success.
6. Connect two headless nodes over LAN discovery. Reconcile on connection and
   periodically; correctness must not depend on gossip delivery.

## Verification gates

- Wrong host identity, expired invitations, replay, unknown keys, and revoked keys
  cannot obtain library access. A grant issued by one host is verified by another.
- Import on either host replicates to the other, including after restart and an
  offline period. Replayed pages and retries do not duplicate objects or changes.
- Incomplete or corrupt audio creates no receipt. Existing original files remain
  intact. Availability reflects verified local copies rather than announcements.
- Tombstones prevent an ordinary stale replica from resurrecting deleted data.
  Concurrent edits or explicit re-addition preserve alternatives for user choice.
- A client can retrieve a replicated object while one of the two hosts is down.
- LAN discovery and transfer use no public relay, directory, or lookup service.

The signed membership and conflict rules must be recorded with their tests before
the automatic replication loop is enabled. The Apple UI and physical-device
acceptance are M3; production relay deployment remains M4.

## Enrollment implementation

`cluster-invite` writes a mode-0600 JSON invitation containing a random 256-bit
secret, the cluster ID, the pinned host key, and an expiry (10 minutes by default,
at most one hour). SQLite keeps only the secret's SHA-256. Redemption binds the
grant to the authenticated QUIC remote key, atomically consuming the invitation
and storing the signed grant. An expired, reused, or invalid invitation receives
no membership proof or library data. A failed commit retains the invitation.

The enrollment ALPN is `syncstr/enrollment/1`. It is separate from legacy music
access and does not add the member to a legacy file allowlist. The LAN endpoint
uses Iroh's Minimal preset, disables relays and port mapping, and accepts
enrollment from private, link-local, or loopback IP addresses only. Initial
DNS-SD discovery uses IPv4 and `_syncstr-cluster._udp.local.` with endpoint ID and
version TXT fields. Global-address-only LANs are not covered by this first flow.
The invitation secret is never included in advertisements or routine output.

A cluster root is a pinned historical identity, not an online central server.
The explicitly created cluster's first host signs its initial host grant. Each
subsequent grant references the issuing host's grant. Every signature binds the
cluster, issuer, member, role, and authority reference. A playback-only grant
cannot issue another invitation. A host invited by another host can invite
further members using its own private key; other nodes verify the chain.

## Revocation boundary

A signed revocation names a device key and the membership record IDs issued by
that key which the revoker had already observed. This freezes known approvals:
revoking an initial host does not require discarding all devices it previously
approved. A newly presented grant outside that boundary cannot acquire authority
through the revoked issuer, even if it claims an old date. Wall clocks do not
choose membership winners.

Grant, revocation, and change IDs are SHA-256 of their domain-separated signed
content. They are not caller-chosen revision UUIDs. Re-signing different content
with a compromised old key cannot reuse a revision already frozen by a
revocation. The M1 UUID-based pending table is staging only and is not the signed
replication log.

Revocations are themselves host-authorized signed records. A record issued beyond
an effective revocation boundary cannot override that revocation. Concurrent
revocations can form a cycle of disputed authority; the projection retains all
signed records, reports the affected keys as membership conflicts, and grants no
access through the disputed identities. It never silently picks a winner.
The application must expose these conflicts in M3; until an authorized resolution
is available, disputed membership stays denied.

Revocations also freeze the observed author's change-history heads. Because every
change binds its author predecessors by content hash, a receiver can verify old
history after learning the revocation. Signed records received out of order stay
in a bounded SQLite inbox until ancestry and authorization are established.
Changes outside the frozen boundary remain quarantined, not projected into the
library. Disputed authors cannot acquire authority through historical replay.

## Reconciliation and storage

The separate `syncstr/cluster/1` protocol exchanges membership proofs and explicit
cluster capabilities before any catalog or audio access. The peer identity comes
from the authenticated transport, not a request field. Existing local revocations
apply before accepting the peer's membership additions; received revocations can
then deny further access. Each subsequent request checks current authorization.

Each change page contains one bounded signed record and an append-only SQLite
sequence. Receivers persist the record or pending inbox entry before advancing a
per-peer cursor. Reconnect and periodic reconciliation resume from that cursor;
duplicate delivery is harmless. The first implementation does not require gossip.

Imports, metadata edits, explicit restorations, deletions, and resolutions retain causal parents.
An ordinary stale import cannot replace an explicit deletion. Concurrent explicit
operations remain competing heads; a resolution names the selected head. No clock
chooses a winner. Object-scoped organization metadata carries the relevant causal
choices and aliases, preserving user overrides when the replica is committed.

Downloads use persisted whole-file jobs. A receipt is written only after exact
length and SHA-256 verification, file flush, atomic publication, directory flush,
and catalog commit. The receipt and completed job commit together. A crash between
file publication and receipt commit can leave an unclaimed file; retry verifies
it again. Interrupted jobs return to queued state on reopen. Before serving a
file, the host verifies the current bytes; missing or corrupt copies lose their
local receipt. Deletion records hide cluster access but do not erase source files.

## Development CLI

These administrative commands require the data directory to be closed by the
server. M3 adds application onboarding and interaction flows; these commands do
not constitute the completed end-user UI.

```sh
syncstr-headless peer-init --state host-a/identity
syncstr-headless cluster-init --data host-a/data --peer-state host-a/identity
syncstr-headless cluster-invite --data host-a/data --peer-state host-a/identity --library-host --output invitation.json
syncstr-headless cluster-serve --data host-a/data --peer-state host-a/identity
```

On a second LAN machine, initialize its own key and redeem the invitation:

```sh
syncstr-headless peer-init --state host-b/identity
syncstr-headless cluster-join --data host-b/data --peer-state host-b/identity --invitation invitation.json
syncstr-headless cluster-serve --data host-b/data --peer-state host-b/identity
```

Omit `--library-host` when issuing an invitation for a playback-only member.
Never copy the host's private key to the joining device.

For a stopped host, `cluster-import --data host-a/data --peer-state
host-a/identity --entry entry.json --file song.mp3` imports a file with the existing
Entry JSON contract. Optional `--organization organization.json` preserves
organization choices. `--restore` explicitly re-adds a deleted object. This CLI
expects supplied metadata; it does not claim to extract tags. On first cluster
serve, existing legacy catalog entries with no cluster history are imported using
their stored metadata. Known tombstones are never converted to fresh imports.
Re-importing identical bytes with changed metadata creates a causal edit; unchanged
input remains idempotent. Metadata projection does not require another audio copy.
Receiving a later revocation also re-evaluates previously accepted history for
projection; the original signed records remain available for diagnosis.
Album titles are projected from selected metadata as well. If different objects
claim incompatible titles for the same album, projection reports a conflict and
keeps the signed alternatives. Editing the affected objects to a consistent title
resolves it. A verified file receipt describes durable bytes; it does not imply
that every metadata conflict has been resolved.

`cluster-status --data host-a/data` shows object heads, jobs, local receipts, and
membership conflicts. `cluster-delete --data host-a/data --peer-state
host-a/identity --object HASH` records a cluster deletion. `cluster-resolve` takes
the same arguments plus `--selected CHANGE_ID` to choose a competing revision.
`cluster-revoke` takes the data and identity arguments plus `--member MEMBER_ID`.

## Measured acceptance

- Enrollment tests cover expiry, restart, wrong secrets, concurrent redemption,
  transaction rollback, signature tampering, delegated host roles, replay,
  known-grant preservation, stale authority, and concurrent revocation conflicts.
- Change tests cover reordered history across restart, duplicate replay, stale
  import after deletion, explicit restoration conflict, user selection, and
  quarantine of post-revocation changes.
- Real encrypted transport tests copy audio in both directions between hosts,
  preserve classification choices, retrieve from the surviving host after the
  other endpoint closes, reject unknown/revoked peers and playback-only deletion,
  and refuse corrupt storage. Incomplete and corrupt staging creates no receipt.
- Separate CLI processes discover each other over mDNS without an IP argument,
  replicate a file, stop, import on the other host while offline, restart, and
  converge to two files with complete jobs and no duplicate changes.

These tests use disposable local data and keys. They do not establish Apple UI,
physical iPhone behavior, remote relay deployment, or production NAS verification.

The headless suite has 45 passing tests. Clippy passes with warnings denied for
both the default and P2P builds. Standards review has no unresolved hard findings;
specification review confirmed the revocation, metadata-edit, and album-title
corrections. Apple targets are unchanged in M2; their integration and verification
are the next milestone.

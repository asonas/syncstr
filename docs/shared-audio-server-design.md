# Independent library tracks sharing audio

## Status and evidence

Accepted server design, based on code revision `4dd46b3` and the
[Windows validation](validation/source-track-identity-windows.md). This document
does not implement or authorize a production migration. The product boundary is
accepted in [ADR 0006](adr/0006-preserve-source-track-identity-independently-of-audio.md);
the migration approach is accepted in [ADR 0007](adr/0007-preserve-track-addresses-when-sharing-audio.md).
The [implementation and verification guide](shared-audio-server-implementation.md)
distinguishes the implemented server contract from pending client and rollout work.

The inventory retained 7,554 source registrations: 7,100 exact-byte candidates,
3 metadata candidates, 352 unmatched and 99 unavailable. It found no invalid
source IDs or duplicate hashes among the 7,455 readable files. Six rows suggest
three common destinations, each pairing an exact-byte candidate with a
metadata-only candidate. This does not prove that the two registrations share
audio or that the server previously collapsed them. No candidate is approved.
The 85 protected entries remain evidence-only, even though their bytes were read.

The required behavior is nevertheless concrete: fictional source registrations
`LIB-A/TRACK-A` and `LIB-A/TRACK-B` can become logical tracks `T-A` and `T-B`,
both bound to audio `H`. Renaming T-A, moving it to another album or removing its
offline save must not change T-B. The server stores and transfers H once where
possible. A second encoding H2 can later be explicitly attached to T-A without
merging T-A and T-B or changing existing playlist playback.

## Current coupling to replace

| Boundary | Observed implementation | Required change |
| --- | --- | --- |
| Storage | `headless/src/store.rs` uses `tracks.id` and `UNIQUE(sha256, suffix)`; `commit_organized` reuses the existing entry | Deduplicate physical storage independently of logical-track creation |
| Organization | `Organization::Track` has one hash; `Organization::merge` may alias unique same-hash tracks | Preserve existing aliases; never infer new logical aliases from bytes |
| Native organization | `apps/macos/AlbumOrganization.swift` has the same hash-based merge behavior | Change shared Apple logic alongside the server before enabling writes |
| Replication | `headless/src/cluster_sync.rs` discovers, edits and projects objects by hash | Separate logical-track revisions from physical-object replication |
| Playlist acceptance | `headless/src/playlists.rs` checks canonical ID/hash pairs against catalog entries | Validate explicit bindings and retained historical references |
| Playlist history | Signed v1/v2 bodies retain IDs, source strings and ID/hash pairs | Keep original payloads and signatures byte-for-byte |
| Availability | `headless/src/cluster.rs` locations are keyed by library/track/member, with a hash | Resolve logical bindings to object availability, without collapsing tracks |
| Legacy HTTP | `/v4/catalog`, uploads and track-addressed downloads expose combined entries | Introduce a versioned contract; do not silently reuse its semantics |

Changing only the SQLite uniqueness constraint would leave replication and client
merge code capable of collapsing independent tracks. Changing only aliases could
redirect old playlist items, membership choices and cached references.

## Identity and persistence

The following are proposed logical tables/projections, not executable DDL. All
identities are scoped to the destination cluster; existing library IDs remain
valid addresses within that cluster.

| Record | Key and retained data | Cardinality and authority |
| --- | --- | --- |
| Logical track | Existing canonical track ID or a new opaque UUID; metadata provenance, album membership, overrides, revision heads, retired state | Independent of hash and physical presence |
| Legacy track address | Existing address scope and ID -> existing canonical track ID | Resolution is frozen by migration; never retarget an old alias during a split |
| Audio object | SHA-256, verified byte length, retained format evidence | Immutable content; equality reuses storage, not track identity |
| Audio replica | Object hash, host, local storage locator and verified availability | Several hosts/legacy suffix paths may retain the same bytes |
| Track/audio binding | Track ID + hash, format evidence and approval provenance | Many tracks per object; multiple objects per track; no exclusive hash constraint |
| Source registration | Source kind + raw library persistent ID + raw track persistent ID; snapshot observations and original metadata | Stable source identity; XML-local Track ID only joins a snapshot |
| Correspondence | Source registration -> logical track, approval/revocation/reassignment history and heads | At most one active target per source and one active source registration per track in this slice |
| Review evidence | Source snapshot, candidate catalog revision, basis, field differences, protection/eligibility facts | Evidence can exist without an approved binding or correspondence |

The source kind distinguishes Music/iTunes from any future identity namespace;
no new connector is part of this work. Raw persistent IDs are retained without
case folding or title-based repair. Duplicate/missing identities are quarantined
observations, not globally reusable registrations. Copies of one XML do not
create additional source libraries.

Different source keys, including keys in different libraries, remain distinct.
A future intentional cross-library identity merge would require a separate
product decision; there is no many-to-one correspondence shortcut here.
An existing legacy track may receive its first explicit source correspondence;
a second distinct source registration must receive a different track ID.
If ownership of a legacy track is uncertain, leave it unchanged and create a
new source-owned track. Do not allocate its identity arbitrarily to a candidate.

Tracks may have no playable binding: missing or protected registrations can be
retained without inventing hashes or invoking DRM bypass. Approval of source
identity, approval of audio correspondence and eligibility to use that audio
are separate decisions. A metadata candidate cannot attach a different existing
object without explicit confirmation and sufficient provenance.

A logical track owns display title, source-library metadata, album membership,
addition time and user choices. File tags remain object evidence. Editing one
track cannot rewrite the shared object or another track's metadata. Apply the
precedence in [ADR 0004](adr/0004-preserve-source-library-metadata-during-migration.md).
Existing overrides and their subject IDs are retained, never copied to all tracks
sharing a hash. Missing source metadata remains missing.

## Read, import and playback contracts

Use a new catalog/protocol version that returns logical tracks and bindings
separately from audio objects. One visible row represents one logical track,
including tracks whose audio is unavailable. Objects can be fetched by hash only
after ordinary cluster authorization. Existing track-addressed audio requests
resolve the preserved legacy address and binding, not the first entry with H.
Legacy data paths stay in place during migration; content-addressed consolidation
is not required to establish logical independence.

An import request names a source registration and an explicit decision:
retain unresolved, bind to an eligible existing object, or upload a new object.
First import allocates a logical UUID in the accepted operation; an exact retry
returns the saved result and UUID. Re-import of the same source key reuses its
approved correspondence. Another source key creates another track even when H
is already stored. Existing upload retries without source identity retain their
legacy behavior until the new protocol is enabled; they must not become an
implicit path for creating or merging source registrations after activation.

For an existing playlist occurrence, preserve its ID, position, repeats, source
fields and `(track_id, sha256)` pair. Resolve aliases using the frozen legacy
address map and require the exact binding. No fallback to another track merely
because its hash matches. Changing a track's preferred audio affects new queue
construction only; existing playlist occurrences and active queues remain pinned.
If pinned audio is absent, report unavailable rather than silently substituting
an encoding. Download H from another authorized replica without changing the pair.

A correspondence reassignment applies to future imports. It never rewrites
existing playlists. An explicit playlist update may replace selected pairs using
the existing signed revision workflow, expected-head checks and replacement
confirmation. Occurrence IDs and all unrelated fields remain unchanged. A
revocation stops future reuse but does not remove tracks, bytes or old references.

Old `sourceTrack` values are not all proven persistent IDs: the Swift importer
can fall back to the XML-local ID. Do not bootstrap durable correspondence by
copying every old playlist source field. Validate it against the exact original
snapshot and inventory, or leave it unresolved. Any proven association is stored
as external evidence without modifying the old signed document.

Offline-save intentions remain track-specific, but storage accounting and fetches
can coalesce by hash. Removing T-A's save cannot evict H while T-B has a save or
an active playback pin. Retiring a logical track must preserve its address and
playlist-reference resolution. Do not add automatic object garbage collection
in the first release; all legacy referenced objects remain retained. Future GC
must account for bindings, playlist pins, saves, history policy and sync lag.

## Approval, concurrency and synchronization

Use an authenticated host command with a durable idempotency key, request digest,
expected correspondence/track heads, evidence fingerprints and explicit decisions.
Only an authorized library host writes the shared decision. A member may submit
a review request, but local CSV or device caches cannot be the authoritative map.
Keep machine-specific source paths local; sync only required identity/metadata,
snapshot fingerprints and decision evidence under existing cluster access rules.

Within one SQLite transaction, validate expected heads, source-key uniqueness,
active-target exclusivity, current binding/eligibility evidence and destination
IDs; allocate new IDs; append a signed decision envelope; update projections;
and save the idempotent response. Reusing a key with different content fails.
The same accepted request returns its prior result even after later revisions.
A stale different request returns a conflict without partial changes. An uploaded
object may be staged before this transaction, but a failed approval creates no
visible track/binding; unused staging bytes can be cleaned independently.

Each signed envelope retains author, membership grant, source key, before/after
target, binding decisions, reason/evidence references and parent decision IDs.
Approval, reassignment and revocation append history. Do not use wall-clock
last-writer-wins. Preserve exact signed bytes and verify grants/signatures on
replication. Transport acknowledgement means durably received; it does not imply
that a conflicting or incomplete transaction is projected as usable.

Different hosts can accept proposals from the same old heads while disconnected.
They cannot enforce a cluster-wide uniqueness constraint with local SQL alone.
After replication, competing targets for one source, or different sources claiming
one target, are explicit conflicts. Block reuse of affected correspondences and
retain all proposals until a resolution references every conflicting head.
Locally allocated track IDs remain addressable even if their mapping loses; do
not delete or alias them automatically. Existing playlist playback remains pinned
through the conflict. A resolved projection revalidates all exclusivity rules.

Logical-track metadata and bindings need their own signed subject identities;
hash-keyed object records remain the source for physical availability and byte
integrity. Replicate decision envelopes atomically at the projection boundary:
buffer missing parents/track dependencies and expose an incomplete state, never
a partially applied mapping. Preserve existing object and playlist histories;
new records use explicit versioned payloads and independent cursors. No mutation
of previously signed payloads to add source metadata or logical identity.

## Additive migration with reference preservation

1. Back up the database and required objects using a consistent snapshot. In a
   copy, enumerate catalog IDs, organization IDs, alias chains, membership and
   artwork choices, current and historical playlist pairs, and signed records.
   Reject alias cycles, dangling targets, ID collisions and irreconcilable
   metadata before activation. Record missing bytes separately; do not invent data.
2. Build a deterministic migration manifest from this snapshot. Retain every
   existing canonical organization ID as a logical track. Retain a standalone
   entry ID when it has no alias; aliased entry IDs remain addresses for their
   original canonical target. Do not create one new UUID per hash or per alias.
   Multiple existing canonical IDs sharing a hash stay separate.
3. Add the logical tables and backfill explicit bindings from retained evidence.
   Preserve old `(ID, hash)` pairs as legacy playback pins, including historical
   pairs: a historical pin does not become an approved source correspondence or
   preferred current copy. Preserve physical paths, album IDs, addition dates,
   choices, signatures, playlist IDs and occurrences. No source approvals are
   backfilled from the 7,100 byte matches alone.
4. Compare old and new resolution for every retained `(ID, hash)` pair. Verify
   equality of target identity and byte locator, plus byte-for-byte signed record
   preservation and unchanged user choices. Missing legacy bytes must remain
   explicitly unavailable, not rebound. Run the migration twice on a fixture
   copy and compare IDs/projections; interruption must roll back a schema step.
5. Upgrade hosts and readers, keeping new identity writes disabled. The manifest
   carries a migration version and input fingerprint; replicas validate the same
   ID/address mapping. Reconcile divergent legacy histories first rather than
   allowing each host to choose a different canonical ID. The initiating host
   publishes the authoritative activation baseline under its existing grant.
6. Pause legacy catalog mutations, reconcile outstanding changes, revalidate the
   baseline and activate the new protocol in a committed schema/feature epoch.
   Migration must set a new schema version so old binaries refuse the database.
   Old hash-based metadata/upload/delete operations are rejected after activation;
   do not export a lossy one-track-per-hash writable view to old clients. Require
   capable hosts/readers for shared catalogs; paused/offline old members must
   upgrade before resuming. Existing compatible audio fetches can remain read-only.
7. Approve a fictional two-track/one-object fixture first, then a user-reviewed
   real selection. Verify another updated client shows both tracks and old
   playlists still play the original pinned bytes. Broad import follows this gate.

Before activation, rollback can discard unused shadow projections while leaving
legacy history intact. After new logical writes, binary downgrade is not safe:
use a forward repair or coordinated restore of the entire pre-activation snapshot
and its cluster state, explicitly accounting for later writes. Restoring one host
alone must not let peer replication silently reintroduce an incompatible epoch.
No production reset, alias retargeting or deletion is part of this proposal.

## Implementation slices and acceptance gates

| Slice | Work and smallest useful checks |
| --- | --- |
| A: preservation migration | Logical/address/object/binding projections and copied-database migration; IDs, aliases, user choices and all signed playlist payloads unchanged; rollback and repeated migration stable |
| B: independent writes | Separate track creation from object deduplication; stop new same-hash aliases in Rust and Swift; two source IDs/one path or hash yield two tracks/one object; metadata and album edits remain independent |
| C: shared correspondence | Preview/commit, signed approval/reassignment/revocation, idempotency and conflict projection; retries keep UUIDs, stale previews fail atomically, two-host races never silently merge |
| D: protocol and clients | Versioned catalog, logical metadata sync, binding-aware playback and offline saves across Apple, Android and Windows; second host/device retains both IDs; old writers rejected |
| E: controlled rollout | Snapshot comparison, capability/epoch gate, real reviewed pilot, exact old playlist playback and history checks; no bulk approval or production rollout inferred from fixture success |

Acceptance fixtures must also cover distinct libraries using the same persistent
track ID; one track/two encodings with old occurrences pinned; existing aliases
and conflicting overrides; an old numeric `sourceTrack`; missing/protected source
entries; independently approved remapping without playlist mutation; incomplete
replication histories; and deleting one offline save while another retains H.
Tests should exercise storage/protocol boundaries rather than internal call order.

The server implementation exercises migration, independent writes, signed
correspondence and HTTPS replication on disposable fixtures. It does not complete
the native-client, offline-save or production rollout gates above. Consult the
[verification guide](shared-audio-server-implementation.md) before activating any
database. UI presentation still needs the repository design guidance.

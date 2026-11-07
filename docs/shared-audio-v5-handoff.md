# ASO-8: v5 protocol and Apple handoff

This contract is the server prerequisite for ASO-9 (Apple), ASO-10 (Android) and
ASO-11 (Windows). ASO-12 tracks cross-platform acceptance. It does not authorize
production activation. Use the exact published revision recorded on ASO-8.

## Wire contract

The cluster protocol ALPN is `syncstr/cluster/5`. It uses the existing enrolled
Iroh endpoint identity and signed enrollment proof. Every JSON message is UTF-8,
preceded by a four-byte unsigned big-endian byte length. The maximum frame is
64 MiB; the handshake maximum is 4 MiB. Frames are not newline-delimited.

The first bidirectional stream carries a client frame
`{"version":5,"proof":<enrollment-proof>}`. The client finishes its send side.
The server authenticates the QUIC remote ID using the presented grant chain and
retained revocations, allowing a newly enrolled member to present a grant that
this host has not seen. It merges the full proof in memory, validates all records,
and requires live membership for the remote ID and live host authority for itself
before storing any presented grants or revocations. Validation, authorization and
storage share one store lock and transaction; a rejected Hello leaves membership
unchanged. The server replies with its current proof and
`"supported_operations":["edit-track","resolve-track","update-playlists","put-object","register-track","assign-source"]`, then finishes. A missing
operations field means no member mutations are supported. Clients must keep their known
revocations when merging the response, validate root and cluster equality, and
require a live host grant for the actual remote ID.
They must also verify their own live membership. A successful QUIC transport
handshake alone is not application authorization.

For a revoked member, the host may instead return this refusal on the first stream:

```json
{"version":5,"status":"rejected","reason":"revoked","member":"<QUIC-peer-id>","evidence":{"root":"<root-id>","grants":[],"revocations":[]}}
```

The arrays above stand for signed grants and revocations, not empty evidence.
There is no top-level `proof`: existing Apple and Rust Hello decoders require
that field and fail closed. An active member's Hello is unchanged. The host
discloses evidence only after verifying a grant chain for the actual QUIC peer
under the same root/cluster and its own live host authority. Outsiders and
non-revocation failures receive no evidence frame.

`evidence` contains retained membership, including the complete signed revocation
history and its authorities, plus only the peer's missing verified grant chain.
The host never persists rejected proof or uses unaccepted incoming revocations
as refusal evidence. A client must pin root/cluster to its enrollment, match
`member` to itself, verify host authority against the QUIC remote ID, and merge
evidence with its retained proof without dropping revocations or accepting
inconsistent replays. Verify every signature and grant/revocation dependency,
then evaluate the client's saved grant chain with effective revocations and their
`observed` boundaries. A dispute alone, or the unsigned reason string, does not
prove revocation.

The host finishes the refusal stream and closes the connection without serving
operations; delivery and acknowledgment are bounded to five seconds. The full
refusal frame must fit the 4 MiB Hello limit. Oversized or unverifiable evidence
produces an ordinary connection failure with no refusal frame; clients must not
treat that failure as verified revocation or mark queued edits rejected from it.

Every subsequent bidirectional stream contains one request frame; the requester
finishes its send side after any `put-object` body described below. The server
sends the indicated response and finishes.
Read/replication errors reset or close the stream or connection. Mutation requests
use the typed replies below. Do not replace retained state on an incomplete or
failed response.

| Request JSON | Response JSON, followed by optional bytes |
| --- | --- |
| `{"operation":"catalog"}` | `Snapshot { catalog, playlists, playlist_history }` |
| `{"operation":"records","after":0}` | Array of `[cursor, Signed]`, at most 64 |
| `{"operation":"playlist-records","after":0}` | Array of `[cursor, PlaylistSigned]`, at most four |
| `{"operation":"receive","records":[...]}` | `true`; only an authorized host may submit signed decisions |
| `{"operation":"audio","track":"T-A","hash":"<sha256>"}` | A JSON integer byte length, then exactly that many raw audio bytes until EOF |
| `{"operation":"mutation","mutation":<request>}` | `MutationReply`, tagged by `status` |

### Member track metadata edits

An enrolled member may send this request on an authenticated session:

```json
{
  "operation": "mutation",
  "mutation": {
    "request": "edit-example-1",
    "cluster": "cluster-example",
    "baseline": "<baseline-sha256>",
    "operation": "edit-track",
    "expected": {"track:T-A": ["<previous-record-id>"]},
    "payload": {"track": "T-A", "metadata": {"title": "Example Song"}},
    "confirmed": []
  }
}
```

`payload` accepts only `track` and a nonempty `metadata` object. Supplied metadata
keys overwrite the corresponding keys on this logical track; omitted keys remain
unchanged. There is no key-removal operation. Audio bindings, album membership,
addition time, retirement, other tracks and the retained organization stay
unchanged. Album visibility is an album-level setting and is outside this slice.
`confirmed` must be empty. `expected` names only the edited track's subject and
the heads the member observed; a baseline-only track has an empty head list.

An accepted reply is
`{"status":"accepted","request":"edit-example-1","record":"<record-id>","host":"<host-id>","heads":{"track:T-A":["<record-id>"]}}`.
The host signs the record and adds `origin: {member, grant}` to its body using the
authenticated member's identity and live grant. Older records omit `origin` and
remain readable. Later revocation of the origin does not invalidate an accepted
record; its host signature remains the authority. Record bodies deny unknown
fields, so a host without `origin` support cannot decode these records and stops
replicating at the first one. Upgrade every host in a cluster before members
submit edits.

A stale edit returns
`{"status":"needs-review","request":"edit-example-1","current":{"track:T-A":["<current-record-id>"]}}`
without storing any part of the edit. Invalid edits and reused request IDs with
different content return `rejected` with reason `invalid`. On an existing session,
a revoked member gets reason `revoked`; insufficient authority gets `unauthorized`.
These two replies are delivered before the connection closes. A revoked member's
new connection can receive the verifiable Hello refusal above before any mutation
request, with ordinary connection failure when evidence cannot be returned.
Other outcomes keep the session open.
Incomplete history returns `deferred` with reason `incomplete-history`; unavailable
storage returns `deferred` with reason `store-unavailable`. Operations other than
`edit-track`, `resolve-track`, `update-playlists`, `put-object`, `register-track` and `assign-source`
remain `unsupported`.

Persist the request ID and original envelope before sending. Retry only at the
same accepting host. Exact retries return the original record, host and heads,
including after later edits, and create no additional record. Another member
cannot reuse that request ID to claim the result. Request IDs retain their
cluster-wide namespace; this slice does not implement cross-host retry.

### Member track conflict resolutions

An enrolled member may select one current conflicting track revision:

```json
{
  "operation": "mutation",
  "mutation": {
    "request": "resolve-example-1",
    "cluster": "cluster-example",
    "baseline": "<baseline-sha256>",
    "operation": "resolve-track",
    "expected": {"track:T-A": ["<head-a-record-id>", "<head-b-record-id>"]},
    "payload": {"track": "T-A", "select": "<head-a-record-id>"},
    "confirmed": []
  }
}
```

`payload` accepts only the logical track ID and the selected record ID. The member
cannot supply a new Track value or override metadata, audio, preferred encoding,
addition time or retirement. `expected` must contain only this track's subject
and every current conflicting head, in the order returned by Catalog.
`confirmed` must be empty. A stale or partial head list, or a track that is no
longer conflicted, returns `needs-review` with its current heads. A selection that
is not one of those heads returns `rejected` with reason `invalid`. Correspondence
conflicts and resolutions that construct new values are outside this operation.

The host verifies the selected signed revision, copies its complete Track value,
and signs a new record with every conflicting head as a parent. It records the
authenticated origin member and grant, using the same acceptance, rejection and
retry rules as `edit-track`. For example, acceptance returns
`{"status":"accepted","request":"resolve-example-1","record":"<resolution-record-id>","host":"<host-id>","heads":{"track:T-A":["<resolution-record-id>"]}}`.
Selecting a revision whose Track has `retired: true` deletes shared music and
requires a live host grant for the submitting member. A playback-only member
receives `rejected` with reason `unauthorized`, and no record is stored. That
reply closes the session under the existing authorization rule; the member may
reconnect and select a non-retired head. An accepted resolution's exact retry
returns its original acceptance even after the conflict has disappeared.

### Member XML playlist updates

An enrolled member may submit `update-playlists` to a host advertising it. Its
payload contains only `documents`, using the existing playlist document shape:

```json
{
  "operation": "mutation",
  "mutation": {
    "request": "playlist-update-example-1",
    "cluster": "cluster-example",
    "baseline": "<baseline-sha256>",
    "operation": "update-playlists",
    "expected": {"playlist:source:mix": ["<previous-record-id>"]},
    "payload": {
      "documents": [{
        "id": "source:mix",
        "sourceLibrary": "source",
        "sourcePlaylist": "mix",
        "sourceFingerprint": "<source-xml-sha256>",
        "name": "Example Mix",
        "kind": "manual",
        "parent": null,
        "definition": {},
        "items": [{
          "id": "occurrence-example",
          "sourceTrack": "17",
          "title": "Example Song",
          "artist": null,
          "album": null,
          "trackId": "T-A",
          "sha256": "<audio-sha256>"
        }]
      }]
    },
    "confirmed": ["playlist:source:mix"]
  }
}
```

Each expected-head key is `playlist:<document-id>`. A new playlist has no heads.
Each string in `confirmed` explicitly approves binding replacements in that
selected playlist. Replacing an existing `(track_id, sha256)` binding requires
this confirmation; unknown, unselected, non-string or duplicate confirmations
are invalid. Do not send `expected` or `confirmed_replacements` inside the payload.

The host applies the existing playlist checks in one transaction: current parents,
replacement confirmations, unchanged source XML structure and occurrence IDs,
known track bindings, and valid folder ancestry. Updates to conflicted playlists
are rejected with reason `invalid`. Stale expected heads return `needs-review`
with current `playlist:<document-id>` heads for every selected playlist. Neither
failure stores a partial batch or a request receipt. Other member mutation
authorization and error rules apply unchanged.

An accepted batch returns one record ID per document in `heads`:

```json
{"status":"accepted","request":"playlist-update-example-1","record":"<first-document-record-id>","host":"<host-id>","heads":{"playlist:source:mix":["<first-document-record-id>"]}}
```

`record` is the signed record for the first document in the request's `documents`
array, even when a later document has a smaller record ID. `heads` includes every
document in the batch. Preserve the document order and original request envelope
on retry. `Session::update_playlists` uses Hello capability advertisement and
returns `unsupported` locally if the host does not advertise the operation.

Each member-authored playlist body adds optional `origin: {member, grant}`,
`request`, and `request_digest`. The origin comes from the authenticated session;
the accepting host signs the body. The digest binds the original request envelope
and origin member. Older playlist bodies omit these fields and remain readable;
host-only administrative updates continue to omit them, preserving their previous
signed representation and IDs. Later origin revocation preserves accepted history.
Playlist bodies deny unknown fields, so every host must be upgraded before members
update playlists; an older host cannot decode these new records and stops replication.

The accepting host reserves the ID and digest in the existing `shared_requests`
table, with `record` pointing to the first document's signed record. An additional
`shared_playlist_requests` table stores the ordered record ID array for that request.
It is created on the first member update without changing existing v5 records.
Both entries and all playlist records commit atomically. Replays load those
original records rather than current heads, including after restart or later
updates. A different envelope or another member reusing the ID is rejected as
invalid. Receipts are local to the accepting host; retries remain pinned to that
host under decision D3 A, without cross-host replay guarantees.

### Member audio addition (host support; D3 A)

Only clients implementing this wire contract may send the two advertised audio
operations. The current Apple client decodes only `version` and `proof` from
Hello, ignores `supported_operations`, and still blocks uploads on a v5 session
(`ClusterNetwork.requireLegacyMutations`, `ClusterSession.upload`, and
`LocalTransfer.permitsClusterMutations`). It does not send `put-object` or
`register-track`, and has no `object-stored` handling. Host capability advertisement
alone does not re-enable Apple audio addition. This slice changes no app clients.

Send `put-object` in the existing mutation envelope with `expected: {}`,
`confirmed: []`, and strict `payload: {"hash":"<sha256>","bytes":3}`. Immediately
after its length-prefixed JSON frame, write exactly that many raw bytes to the
same QUIC stream and finish the sending side. The frame limit is still 64 MiB;
the separate body limit is `crate::model::MAX_AUDIO` (20 GiB). The host validates
the declaration before reading the body, streams with bounded memory and SHA-256,
requires the exact declared length and EOF, and only replies after verified,
durable installation. Oversize declarations, truncation, excess bytes and digest
mismatch return `rejected` / `invalid`, discard staging files, and create no
record or success receipt. An unenrolled peer is refused during Hello. On an
existing session a revoked member receives `rejected` / `revoked` before any body
read, then the connection closes. Authorization is checked before reception and
again immediately before publication on blocking workers, without a database read
per upload chunk. Revocation during reception is rejected at publication. Other
rejection outcomes leave the session usable.

Success is a new recordless reply:

```json
{"status":"object-stored","request":"upload-example-1","hash":"<sha256>","bytes":3,"host":"<host-id>"}
```

It means only that the Audio Copy is stored, not that a logical track exists.
Bytes are stored once per hash. The host retains successful unreferenced uploads
without garbage collection. Exact retry verifies the bytes again and returns the
same durable receipt, including after restart. A local `shared_object_requests`
table holds the original digest and reply; its IDs share the existing mutation
namespace. Different content, another origin member, or another operation reusing
an ID is invalid. Uploading the same hash at another host is independently safe.
No signed record is invented for an upload.

Then send `register-track` without trailing bytes. Its strict payload is
`{"source":{"library":"example-library","track":"example-source-track"},"metadata":{"title":"Example Song"},"hash":"<sha256>"}`,
with `expected: {}` and exactly `confirmed: [{"audio":"<sha256>"}]`. That
confirmation explicitly approves using those bytes as audio; it is not inferred
from the upload. The Audio Copy must be present and verified and the source must
not already have a correspondence. The host assigns a fresh logical track UUID
and addition time, binds the supplied hash as audio/preferred, and signs the
correspondence and track in one record with authenticated D2 member/grant origin.
Other Track/Evidence fields cannot be supplied by the client.

Registration returns the existing `accepted {request, record, host, heads}` shape,
with original heads for both new subjects. Preserve the request ID and original
envelope and retry only at the accepting host under D3 A. Exact replay returns
the same record, host and heads after subsequent edits or restart. Different
source tracks with equal hashes remain independent logical tracks. This slice
does not add cross-host registration replay, member-scoped request IDs,
deterministic track IDs, or projection changes (D3 B).

### Member source correspondence approval

An authenticated live member can use advertised `assign-source` with payload
`{"source":{"library":"example","track":"17"},"target":"T-A"}` and exactly
`confirmed: [{"source":{"library":"example","track":"17"},"target":"T-A"}]`.
Target must be explicitly present; null confirms an unassignment. Missing,
duplicate, mismatched or extra confirmation fields are invalid. `expected` may
contain only the canonical source subject (`source:` followed by serialized
Source JSON), with every observed head. Missing/empty heads mean a new source.
The host validates target existence, retirement, track conflicts, and exclusive
source ownership using the existing `Action::Assign` rules.

The host signs the unchanged `Value::Correspondence {source, target, evidence}`
shape, with host-built Evidence and authenticated D2 origin. Evidence now has
optional `source_confirmation: {source, target}` recording the exact approved
assignment. Replication validates that it matches the signed correspondence;
Track values cannot carry a source confirmation. Older records omit this field
and retain their original bytes and IDs. No client-supplied Evidence is accepted.

Acceptance returns `accepted {request, record, host, heads}` for the source subject.
Stale heads return `needs-review` without a partial write. Reuse the original
envelope and accepting host under D3 A: exact replay returns the original result,
while altered content or another origin member reusing the ID is invalid.
Two hosts' competing correspondences remain conflicted after replication. A new
explicitly confirmed assignment resolves them only with every current head as
an expected head and parent. `resolve-track` is Track-only and is not a source
correspondence resolver. Equal audio bytes never choose a target, create an alias
or merge tracks; track metadata, bindings, pins and playlist occurrences remain
unchanged. ASO-41 can build reviewed migration on this operation; migration and
app client changes are outside this host slice.

Upgrade all hosts before emitting records containing `source_confirmation`.
Like D2 origin, the new field fails older `Evidence` decoders using
`deny_unknown_fields`. This does not merely discard one record: `Store::ingest`
decodes each record with `?` inside the page transaction, so failure rolls back
the entire page and leaves its cursor unchanged. `receive_page` propagates the
error, and `Session::reconcile` aborts that peer's pass before subsequent record
pages, playlist synchronization and audio download. `synchronize` logs the error
and continues serving other peers; future passes retry the same blocked page.
Previously committed pages remain stored. The service does not globally stop,
but that peer's replication cannot advance past the incompatible record until
upgrade. Direct `receive` requests also propagate the failure through the request
handler rather than acknowledging a partially accepted batch.

### Catalog snapshot

`Snapshot.catalog` is the same typed catalog as HTTPS `GET /v5/catalog`;
`version: 1` denotes its first schema, not the transport version. The exact types
are `Catalog`, `Track`, `Object`, `Source`, `Evidence`, `Edit`, `Body`, `Signed`
and `Request` in the shared-audio module. Rust structs use snake_case unless
their serde attributes say otherwise. Signed decision payloads retain the exact
`syncstr-shared-audio-v1\n` prefix and JSON text; hash and verify the original
payload bytes, never a decoded/re-encoded dictionary.

The snapshot includes all logical tracks, including unavailable, retired or
conflicted tracks. There is deliberately no conversion into a one-row-per-hash
legacy catalog. `tracks` is keyed by logical ID; `addresses` retains frozen
legacy aliases. `audio` and `preferred` are current bindings; `pins` includes
historical bindings. `objects` describes content independently. Physical
`locators` are server-local relative names, not download URLs or device paths.
Unknown byte lengths and missing replicas remain unavailable.

Track metadata retains supplied values. Migrated metadata has `organization`
and `legacyEntry` provenance; subsequent explicit metadata keys belong to the
logical track. Apply ADR 0004 precedence without inventing absent values. Never
infer a track alias from equal hashes. Conflicts/incomplete history must remain
visible as unresolved state and must not be selected by timestamp or iteration
order. A correspondence pointing to a retired track is not reusable for import.

`playlists` contains projected documents and revision/conflict state.
`playlist_history` contains the original signed envelopes, including baseline
v1/v2 history, so clients can verify and retain exact payloads. The snapshot is
read under one store lock. The incremental playlist endpoint returns new v5-era
records; initialize historical state from the snapshot first. Preserve
occurrence IDs, order, repeats and source fields. Download the occurrence's exact
`(track_id, sha256)` pair rather than a track's latest preferred encoding.

For audio, enforce the advertised size and 20 GiB maximum, stream to a temporary
file, check SHA-256 and install atomically. A missing binding never falls back to
another track with matching metadata. Store local save intentions by logical ID
and pinned hash; coalesce physical bytes by hash. Keep active queue pins stable.

## Membership, writers and synchronization

The dedicated service checks membership for every request and during audio
streaming. A revoked peer cannot start another operation on an existing session.
Signed revocations merge monotonically; replaying an older proof cannot restore
membership. New records from revoked authors are rejected; already accepted
signed history remains readable. Histories first received after their author was
revoked require explicit review rather than automatic acceptance.

HTTPS bearer tokens are administrative host credentials, not playback-member
tokens. Do not install them in ordinary native playback clients. Host approval
and explicit playlist revisions use the documented authenticated HTTPS endpoints.
The member QUIC service also accepts track metadata and conflict-resolution
requests; the accepting host validates and signs the resulting record. New
invitation issuance/redemption remains pre-activation; v5 recognizes existing
grants and accepts additional valid signed membership proofs. Do not reset
existing device identities to connect.

The v5 server advertises the existing cluster discovery service when bound to a
non-loopback IPv4 address. Discovered authorized hosts are retried every three
seconds. Each pass is bounded to 120 seconds, validates cluster/baseline equality,
pulls decision and playlist pages with atomic cursors, then retrieves missing
pinned objects. A newly installed object serves every logical binding sharing
its hash. Discovery is an address hint; membership and endpoint identity are the
authority. Each host pulls, so no automatic writer is inferred from discovery.
There is no new remote relay configuration in this slice.

Old cluster ALPNs and old HTTP mutations are rejected by the dedicated v5
service. Once a client retains a v5 baseline, it must not fall back to legacy
logical merging on a failed refresh. Independently populated hosts with different
baselines fail closed; this release does not reconcile divergent migrations.

## Disposable native-client fixture

From the repository root, generate a new output directory:

```text
mise exec -- cargo +1.99.1 run --manifest-path headless/Cargo.toml --locked --features p2p --example shared_audio_fixture -- tmp/v5-fixture
mise exec -- cargo +1.99.1 build --manifest-path headless/Cargo.toml --locked --features p2p
```

The generator refuses an existing directory. It creates one second of quiet
440 Hz PCM WAV audio, one legacy track/alias and signed playlist with repeated
occurrences, and two independent registrations sharing that object. It creates
two schema-5 fixture databases with the same activation baseline, generated test
host/reader identities, TLS credentials, `snapshot.json`, `records.json`,
`expected.json` and `reader-enrollment.json`. The replica initially has no audio
or new logical decisions, making catch-up observable.

For automated Apple tests, import the fixture reader identity from
`reader/device.key` and its corresponding `grant`/`proof` into an isolated test
credential store. Never import these into an everyday app profile. Generated
keys, bearer tokens, databases and outputs stay local and out of Git/Linear.
Tests can verify the exported signed history independently using the proof.

Start the host using the built binary (append `.exe` on Windows):

```text
headless/target/debug/syncstr-headless shared-audio-serve --data tmp/v5-fixture/host-data --identity tmp/v5-fixture/host-tls --peer-state tmp/v5-fixture/host --listen 127.0.0.1:8443 --peer-listen 127.0.0.1:8444 --peer-address-out tmp/v5-fixture/host-address.json
```

The default QUIC bind is loopback. For a separate Mac/device on a trusted test LAN,
replace `--peer-listen` with the fixture machine's LAN address and chosen UDP port;
keep HTTPS loopback. Use the exported endpoint address and proof, or LAN discovery.
Start the replica with `replica-data`, `replica-tls`, `replica` and different ports
on the same LAN to observe automatic convergence. A loopback-only setup uses
explicit addresses in the Rust tests because mDNS does not advertise loopback.

Run the contract tests:

```text
mise exec -- cargo +1.99.1 test --manifest-path headless/Cargo.toml --locked --features p2p --test shared_audio
```

They exercise real loopback QUIC, feed discovery events at the external address
boundary, test automatic scheduling/catch-up after restart, and verify legacy
pins, membership and protocol rejection. They do not establish multicast
reachability on the Mac's LAN, Apple UI behavior or physical audible output.

ASO-9 should report its tested server commit, app builds, focused tests,
Simulator/macOS interaction results and any device gaps. Keep ASO-12 open until
the cross-platform acceptance matrix is complete. No fixture result authorizes
production migration, broad source approval, deployment or object deletion.

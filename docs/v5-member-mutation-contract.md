# v5 member mutation contract

Status: design draft (ASO-38). The owner accepted the recommended option of every decision on 2026-11-06. This document does not change code or the wire protocol, and it does not authorize implementation. Each slice below is delivered under its own issue. The [v5 completion design](https://linear.app/asonas/document/v5-completion-design-and-delivery-boundaries-7bf03b53cfba) gives the surrounding plan.

## Problem

On v5, an ordinary device can read the catalog and play audio, but it has no way to change shared state. Today's journeys that change the library stop working once a cluster activates v5:

- Adding audio files from an Apple device.
- Editing metadata, including album visibility, which Apple, Android and Windows clients all send today.
- Resolving a conflict and choosing an album title.
- Updating an existing playlist from Music XML.

This contract defines how a member submits such a change to a library host, how the host accepts or refuses it, and what the device shows meanwhile. Ordinary playlist creation and editing (ASO-42), enrollment (ASO-39), migration (ASO-41), and XML performance and progress UX (ASO-6, ASO-7) stay with their own issues.

## Terms

The glossary terms apply: Library Track, Library Host, Playback Device, Audio Copy, Shared Audio, Track Correspondence, User Override, Playlist, Sync Conflict. This document also uses:

- **Member**: any enrolled device with a verified grant. A library host is a member whose grant has `host: true`.
- **Logical track**: a Library Track identified by its track ID, independent of its audio hash (ADR 0006).
- **Occurrence**: one appearance of a track in a playlist, with its own item ID.
- **Mutation request**: a member's durable intent to change shared state, identified by a request ID.
- **Accepting host**: the library host that validates a mutation request and signs the resulting record.

## Current state

### Server

Every v5 write is signed by a host with its own key. No path lets a member submit a change.

| Capability | Where | Notes |
| --- | --- | --- |
| Member QUIC requests | `headless/src/shared_audio_net.rs:10-26` | Catalog, Records, PlaylistRecords, Receive and Audio only. Receive is host to host. |
| Host commit | `headless/src/shared_audio.rs:668-884` | Actions Register, Assign and EditTrack. The host signs the record. |
| Idempotency | `headless/src/shared_audio.rs:689-718` | `Request.id` with a stored digest. Reusing an ID with different content fails. More than one record for one request ID fails with "request has competing host results". |
| Stale check | `headless/src/shared_audio.rs:797-801` | `expected[subject]` must equal the current heads, otherwise "stale preview". |
| New track IDs | `headless/src/shared_audio.rs:735-741` | Register always mints a new UUID on the accepting host. |
| Post-commit check | `headless/src/shared_audio.rs:869-876` | The projection after the insert must be complete and must not conflict on the edited subjects. |
| Playlist update | `headless/src/shared_audio.rs:523-635` | `PlaylistUpdate{documents, expected, confirmed_replacements}`. It has no request ID. |
| Administrative HTTPS | `headless/src/shared_audio_api.rs:23-63` | One node bearer token covers every route. Records do not identify who sent the request. |
| Errors | `headless/src/shared_audio_net.rs:197-201` | Any error closes the connection. There is no error response. |

### Clients

| Journey | Sender | Legacy behavior to preserve |
| --- | --- | --- |
| Add audio files | Apple `upload` (`apps/macos/ClusterTransport.swift:543-568`) | The batch is saved before sending, retried every 15 s while queued, and restored after restart. |
| Metadata and album visibility | Apple `metadata` (`:586-595`); Android and Windows through `cluster_client` (`headless/src/cluster_client.rs:139-163`) | A per-object queue in SQLite. A newer edit with the same parents is rebased onto the returned revision. |
| Resolve a conflict | Apple `resolve` (`:570-576`) | Parents must equal the current heads. Choosing a deletion requires a host. Not persisted or retried. |
| Choose an album title | Apple `album-title` (`:578-584`) | Not persisted or retried. |
| Update a playlist from XML | Apple `reconcile` (`apps/macos/Playlists.swift:128-160`) | `expected` holds the observed revisions. Success is shown only after the host replies. |

On a v5 session, only the playlist path refuses explicitly (`apps/macos/ClusterTransport.swift:333`). The other four senders have no v5 guard. The v5 host cannot decode them and closes the connection. See [Findings outside this contract](#findings-outside-this-contract).

## Requirements carried forward

- Ordinary clients never receive the administrative bearer token (`docs/shared-audio-v5-handoff.md:81-85`).
- Only an authorized library host writes a shared decision. A member may submit a request (`docs/shared-audio-server-design.md:139-140`).
- Only a library host may start a cluster-wide deletion (`docs/cluster-model-design.md:31`).
- Persist an intent before reporting success, and keep it across restart until a durable acknowledgment arrives (`docs/playlist-implementation-plan.md:92-95`).
- No clock or device role chooses a winner. Competing intent is kept until an explicit resolution names every competing head (`docs/cluster-model-design.md:41`, `docs/cluster-lan-sync-m2.md:109-112`).
- Source matches require explicit acceptance. Byte equality never creates an alias or merges tracks (ADR 0006, ADR 0007).
- The same accepted request returns its prior result. A stale, different request returns a conflict without partial changes (`docs/shared-audio-server-design.md:147-149`).
- Unsupported capabilities produce an explicit unavailable state, never a silent downgrade.

## Proposed contract

### Request

A member sends one mutation request per operation:

```json
{
  "request": "b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f",
  "cluster": "cluster-example",
  "baseline": "3f2a…",
  "operation": "edit-track",
  "expected": { "track:7d0c…": ["rev-41a…"] },
  "payload": { "track": "7d0c…", "metadata": { "title": "Example Song" } },
  "confirmed": []
}
```

- `request` is created on the device when the intent is first saved, and it never changes on retry.
- `expected` lists the heads the device observed for every subject it changes. For a new subject it is empty.
- `confirmed` carries explicit user approvals the operation needs, such as a correspondence or a playlist replacement.
- The member's identity comes from the authenticated QUIC session, not from the payload.

### Response

Every outcome is a typed reply. The connection stays open.

| Outcome | Meaning | Device state |
| --- | --- | --- |
| `accepted` | The host signed and stored a record. Carries the record ID, the accepting host and the new heads. | Accepted |
| `object-stored` | `put-object` verified and durably stored the Audio Copy. Carries `request`, `hash`, `bytes` and `host`; no record or heads are created. | Accepted (bytes only; registration still required) |
| `needs-review` | `expected` no longer matches, or the change would create a conflict. Carries the current heads of each subject. | Needs review |
| `rejected` | Not authorized, revoked, invalid, baseline mismatch, or the request ID was reused with different content. | Rejected |
| `deferred` | The host cannot decide yet, for example because its history is incomplete. Retryable. | Queued |
| `unsupported` | The host does not offer this operation. | Rejected, shown as unavailable |

An exact replay of an accepted request returns the same `accepted` reply, even after later revisions.

### Device states

| State | Promise to the user | Recovery |
| --- | --- | --- |
| Draft | Not submitted. Nothing shared has changed. | Edit or discard. |
| Queued | The intent is saved on this device. | Sent on reconnect and after restart. |
| Sending | The host's answer is not known yet. | A timeout returns to Queued with the same request ID. It is never shown as success. |
| Outcome unknown | Sent at least once, and the accepting host has not answered. | See [decision D3](#d3-cross-host-retry). |
| Accepted | The host's signed acknowledgment is stored on this device. | Done. |
| Needs review | Another change happened first. The device keeps its payload. | Show the current state. The user resubmits as a new request, or discards. |
| Rejected | The host refused the change. | Show the reason. The user discards it, or keeps it for later. |

Cancel removes a request only while it is Draft or Queued. Cancelling a request that was already sent does not undo it. The device first finds out the request's outcome.

### Operations

| Operation | Who may submit | Host checks | Legacy journey |
| --- | --- | --- | --- |
| `put-object` | Authenticated, live member | Strict payload `{hash, bytes}`, empty `expected` and `confirmed`; raw bytes follow the mutation frame on the same stream. Requires `0 < bytes <= crate::model::MAX_AUDIO` (20 GiB), exact length/EOF and streaming SHA-256 verification. Returns `object-stored` after durable storage; creates no record. | First half of adding audio |
| `register-track` | Authenticated, live member | Strict payload `{source: {library, track}, metadata, hash}`, empty `expected`, and exactly `confirmed: [{"audio": hash}]` for explicit audio eligibility. Requires a new source correspondence and a verified Audio Copy. The host generates the logical track ID and addition time and records D2 origin. | Second half of adding audio |
| `edit-track` | Any member (decision D1) | `expected` heads. Changes only this logical track. | Metadata and album visibility |
| `resolve-track` | Any member, except a resolution that deletes shared music, which needs a host | `expected` lists every competing head. | Resolve a conflict, album title |
| `assign-source` | Any member, with explicit confirmation | `expected` heads of the source subject. The confirmation is recorded. | Track Correspondence review |
| `update-playlists` | Any member | Today's `PlaylistUpdate` checks, plus a request ID. | XML playlist update |

Adding audio uses two steps. `put-object` is idempotent by hash and can be retried at any host. `register-track` creates the logical track. If registration never happens, the Audio Copy stays on the host. Automatic object garbage collection is deferred (`docs/shared-audio-server-design.md:131-133`), so this contract does not remove it.

The host advertises both operations in Hello. An upload consists of the existing
length-prefixed mutation JSON frame, then exactly the declared number of raw bytes
and FIN on that stream's sending side. The JSON frame limit remains 64 MiB;
the audio body uses `crate::model::MAX_AUDIO`, without buffering the whole object.
An unenrolled peer is refused during Hello; a revoked peer on an existing session
is rejected before reading its upload body. Authorization is checked before
reception and immediately before publication, on blocking workers, never per
upload chunk. Revocation during reception is rejected at publication. Invalid
length/hash/oversize uploads create no
receipt, record or installed object and discard their temporary files. Successful
unreferenced objects are retained. Other non-authorization failures keep the
connection usable; authorization rejection closes it after the typed reply.

`object-stored` has wire shape
`{"status":"object-stored","request":"upload-example","hash":"<sha256>","bytes":3,"host":"<host-id>"}`.
The host persists a recordless receipt in `shared_object_requests`, rejects request
IDs already used by signed mutations, and rejects a different digest for the same
ID. The digest binds the authenticated member and original envelope. Exact upload
replay verifies the supplied bytes again and returns the original receipt. A
different host may independently store the same hash; this does not register or
merge any logical tracks. Signed mutations also reject IDs reserved by uploads.

`register-track` uses D3 A: persist its original envelope and retry only at the
accepting host. Its `accepted` reply has both the new `track:<id>` and source
correspondence heads from the signed registration. Exact replay returns those
original heads and the original host/record after later edits or restart. Different
sources can register independent tracks with equal bytes; no alias is inferred.
Member-scoped IDs, deterministic track IDs and D3 B remain deferred. The existing
Apple client ignores Hello's operation list and continues to block v5 uploads;
advertising these host operations does not enable its audio addition UI or sender.

`update-playlists` keeps today's item IDs and the rule that only the original XML can update a playlist. ASO-6 and ASO-7 own changes to that behavior.

Two logical tracks that share one Audio Copy stay independent. Registering a second track with an existing hash creates a second logical track, and editing one never changes the other.

## Decisions

The owner accepted the recommended option of each decision on 2026-11-06.

### D1. May members edit metadata?

The accepted documents do not decide this. Apple, Android and Windows members already send album-visibility edits through the legacy path.

- **A (recommended).** Members may submit `edit-track`. The host validates and signs it. This keeps today's journeys.
- **B.** Only hosts may edit metadata. Phones and Windows clients lose album visibility editing on v5.

### D2. How is the origin member recorded?

Today the host signs every record, and the member who asked is not recorded anywhere. A rule for revoked members needs to know who asked.

- **A (recommended).** The accepting host adds `origin: {member, grant}` to the signed record body. Hosts are already trusted to sign, and the QUIC session proves the member's identity to the accepting host.
- **B.** The member also signs the request, and the record carries that signature. Any host can then verify the member's intent independently. This costs a second key operation per request and a larger record. It matters only if hosts are not trusted to report the origin honestly.

### D3. Cross-host retry

This is the riskiest case. Register mints a new track ID on each acceptance. Suppose host A accepts a registration but its reply is lost, and the device retries at host B before B has replicated A's record. B creates a second logical track. Two tracks sharing one Audio Copy is a legitimate state, so nobody can tell the duplicate from intent.

Request IDs also share one namespace across the cluster. Replication copies them with `INSERT OR IGNORE`, so if two members ever reuse an ID, the first one seen wins silently.

- **A. Stay with the accepting host.** After the first send, retry only at the host that received it. If that host is unreachable, the request becomes Outcome unknown. The user waits, or explicitly submits it again as a new request after a warning that it may duplicate the change. This needs no server change, but it can block a request for a long time.
- **B. Deterministic outcome (recommended).** Scope request IDs to the origin member, so the key is `(member, request)`. Derive new track IDs from that key instead of a random UUID. Two hosts accepting the same request then produce the same track ID and the same request digest. The projection treats records with the same key and the same digest as one outcome, and keeps the one with the smallest record ID. This replaces today's "competing host results" error. A request with the same key and a different digest is still rejected. The device can retry at any host.
- **C. Ask other hosts first.** Before accepting, the host asks its peers whether they already accepted the request. This fails when the first host is offline, which is the case that matters.

B needs a projection change, which affects ASO-43 and ASO-12. A works with today's projection and can ship first. Decision: ship A in the first slice, and adopt B before audio addition is offered from more than one host.

### D4. Edits from a member revoked later

- An edit accepted before the member was revoked stays in history and stays readable.
- A queued or sending request from a revoked member is rejected with reason `revoked`. The device keeps it so the user can see it and discard it.
- A host checks the origin's grant when it accepts. Hosts do not re-check accepted records against later revocations, because the host signed them while the grant was valid.

This follows from D2 A. Under D2 B, a host could also re-check the member's signature.

### D5. How do devices learn what a host supports?

- **A (recommended).** The host lists its supported operations in its Hello reply. The device hides or disables actions the host does not support and explains why.
- **B.** A new ALPN version for v5 with mutations. Simpler to detect, but every host must upgrade before any device can use the new version.

## Acceptance cases

Each case names the expected device state.

1. **Stale review.** Device 1 edits a track's title. Device 2, which has not refreshed, edits the same title. Device 2 gets `needs-review` with the current heads and keeps its text. No partial change is stored.
2. **Revoked membership.** A device queues an edit while offline, and a host revokes it. On reconnect, the request is rejected with `revoked`, and the device keeps the edit visible with a discard action. Edits accepted before the revocation stay in history.
3. **Restart.** A device queues an edit and two additions, then the app is terminated during Sending. After restart, all three are Queued with their original request IDs. Sending them again creates no duplicates.
4. **Two logical tracks sharing audio.** Register track A, then register track B with the same audio hash. Two logical tracks exist, the Audio Copy is stored once, and editing A's title leaves B unchanged.
5. **Lost acknowledgment at the same host.** Host A accepts a registration and the reply is lost. The device retries at A and receives the same `accepted` reply. One track exists.
6. **Lost acknowledgment, then another host.** Same as case 5, but A is unreachable. Under D3 A, the request is Outcome unknown and is not sent to host B without the user's confirmation. Under D3 B, host B accepts, and after replication both hosts show one track.
7. **Request ID reused.** A request ID is resent with a different payload. It is rejected, and the first result is unchanged.
8. **Deleting resolution from a playback device.** A non-host device chooses a deletion while resolving a conflict. It is rejected as unauthorized, and choosing a non-deleting head is still possible.
9. **Cancel after sending.** The user cancels a request in Sending. The device does not report the change as undone. It shows the result once the outcome is known.
10. **Unsupported host.** A host that does not offer `edit-track` gets an edit. The device shows the action as unavailable instead of failing in a retry loop.

## Implementation slices

Each slice needs design approval first and is delivered under its own issue.

1. **Gate legacy mutations on v5 sessions** (ASO-53). Show adding audio, metadata edits, resolution and album title as unavailable on v5, with an explanation. This is a client fix and does not depend on the rest of this contract.
2. **Transport and replies.** Add the mutation request and the typed replies to the member QUIC service, and advertise supported operations (D5). Add no operations yet. Errors stop closing the connection.
3. **Metadata and album visibility.** `edit-track` with origin recording (D2), the device queue and states, on Apple, Android and Windows. This restores the most widely used journey.
4. **Conflict resolution and album title.** `resolve-track`, with deleting resolutions limited to hosts.
5. **Audio addition.** `put-object` and `register-track`, first with D3 A, then D3 B before offering multiple hosts.
6. **XML playlist update.** `update-playlists` with a request ID and origin. Keep today's XML semantics.
7. **Source correspondence.** `assign-source` with recorded confirmation. Coordinate with ASO-41, which depends on this contract.

## Findings outside this contract

These came up while reading the code. Each has its own issue.

- **Apple sends legacy mutations on v5 sessions** ([ASO-53](https://linear.app/asonas/issue/ASO-53/disable-legacy-mutations-on-apple-v5-sessions)). `upload`, `resolve`, `album-title` and `metadata` have no v5 guard (`apps/macos/ClusterTransport.swift:543-595`). The v5 host closes the connection. Reading the code suggests that a queued upload is then retried every 15 seconds without end. This was not reproduced. Slice 1 fixes it.
- **The QUIC handshake stores proof before authorization** ([ASO-54](https://linear.app/asonas/issue/ASO-54/authorize-v5-quic-peers-before-storing-their-proof)). The host merges the caller's grants and revocations into its store before it checks that the caller is a member (`headless/src/shared_audio_net.rs:183-186`).
- **One playlist conflict blocks every playlist read** ([ASO-55](https://linear.app/asonas/issue/ASO-55/keep-v5-playlist-reads-working-during-a-conflict)). The projection fails with "playlist conflict requires resolution" (`headless/src/playlists.rs:206-209`). After that, every playlist read and update fails, and so does the QUIC Catalog snapshot. The comment at `headless/src/shared_audio.rs:661` expects conflicts to be kept and reported instead.

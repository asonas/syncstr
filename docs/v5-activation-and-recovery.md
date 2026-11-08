# v5 activation and recovery gates

Status: Accepted 2026-11-08: the owner accepted the recommended option for D1–D7. This document still authorizes no implementation or production operation; D5 destinations and custodian are confirmed before a rollout.

## Decisions

- **D1: authority.** Accepted: one owner-designated, currently authorized Library Host coordinates an activation, with signed readiness from every authorized host. A coordinator alone cannot override missing readiness.
- **D2: durable contract.** Accepted: a separate signed control journal bound to cluster, baseline, membership revision and a monotonic projection epoch. Do not add an activation kind to the existing music record streams.
- **D3: membership and old hosts.** Accepted: a maintenance freeze and unanimous host preparation. An offline or unknown authorized host blocks activation; exclusion requires verified revocation and operational isolation, not merely removing it from discovery.
- **D4: writer and client order.** Accepted: upgrade readers and hosts first, establish the common baseline, then release writes by feature. Keep old uncertain registrations on D3 A even after D3 B activation.
- **D5: backup custody.** Accepted: a complete encrypted backup on separate storage plus an offline copy; keep its decryption key separately under owner custody. Confirm the actual destinations and custodian before a rollout.
- **D6: repair and restore.** Accepted: forward repair after any new-epoch write; permit coordinated pre-activation restore only after all later writes and uncertain requests have an explicit disposition.
- **D7: lost authority.** Accepted: fresh identity for playback replacement; restore final-host authority only from verified recovery material with the original fenced. Without it, preserve evidence and propose a separately approved new cluster rather than fabricate continuity.

## Background and evidence

The [completion design, section 7](v5-completion-design.md#7-activation-and-recovery) separates design approval, compatible implementation, disposable rehearsal and explicit production authorization. Its originating Linear document has the same recovery boundary. The [server design](shared-audio-server-design.md) and [implementation guide](shared-audio-server-implementation.md) preserve addresses, aliases, signed playlist bytes and historical ID/hash pins. Host storage backup guidance is in [the headless guide](../headless/README.md#storage-and-recovery).

Static observations in this checkout:

- `Store::activate` in `headless/src/shared_audio.rs` checks the inspected baseline under exclusive `node.lock`, and commits migration tables and schema 5 transactionally. Repeating activation with the same baseline preserves new records. This is a local schema transaction, not cluster agreement.
- `headless/src/enrollment.rs` verifies grant chains and revocations. Any authorized host may issue membership decisions under the existing model; there is no existing globally serialized membership revision or projection activation journal.
- `Hello` in `headless/src/shared_audio_net.rs` carries membership proof and `supported_operations`. Reachable peers and a host's operation list do not establish readiness of every authorized host.
- Music `Body` and tagged `Value` decoding in `headless/src/shared_audio.rs` is strict. A new record kind can roll back an old receiver's whole page. Unchanged record shapes do not imply projection compatibility either.

ASO-98 host preparation, delivered by PR #54, scopes receipts, derives deterministic member registration IDs, collapses equivalent results and resolves duplicate parent aliases. It deliberately does not advertise or enable cross-host registration. The [member contract D3](v5-member-mutation-contract.md#d3-cross-host-retry) still requires this activation boundary. An old projection receiving equivalent registrations can fail immutable `added_at` validation without advancing its cursor, or retain conflicting heads if timestamps match. A per-host Hello token cannot protect that old host.

These are source and supplied design observations, not rehearsal or production results. Older current-state tables in earlier designs are historical. Enrollment (ASO-39), host lifecycle (ASO-44), platform acceptance (ASO-12) and client delivery keep their own implementation ownership.

## Terms

- **Baseline:** the exact inspected migration fingerprint and frozen identity/address mapping shared by participating hosts. It is not a mutable catalog digest.
- **Membership revision:** proposed content digest of canonical verified membership proof: cluster root, sorted grants and sorted revocations, retaining their signed bytes. Reject disputed authority before computing an agreed revision. It is not a wall-clock timestamp.
- **Projection profile:** a versioned compatibility contract naming required decoding, receipt and projection behavior. First example: `registration-equivalence-v1`; future new value kinds require their own profiles.
- **Epoch:** a monotonic control-journal generation with previous-entry digest. It does not replace existing record baselines or rewrite signatures.
- **Fence:** preventing an excluded process or identity from serving, signing or exchanging cluster data. Discovery absence and an expired readiness cache are not fences.
- **Recovery set:** consistent snapshots, signed manifests, control history, keys and later-write accounting needed to restore without hidden loss.

## Proposal and decisions

### D1. Who may activate?

- **A (recommended):** the owner explicitly selects a live host coordinator for one maintenance session. It signs a proposal under its existing host key; every live authorized host signs preparation; the coordinator signs the final activation referencing that complete set. Verify all signers against the agreed membership revision and preserve the owner's authorization in the restricted runbook evidence.
- **B:** any host activates after observing reachable peers. Less coordination, but missing hosts and split membership make this unsafe.
- **C:** require the cluster root key for every activation. Strong central authority, but creates an unnecessary root-availability dependency and differs from distributed host administration.

Trade-off: A adds downtime and operational coordination rather than a new online consensus service. A valid signature is necessary, not proof of owner approval or binary correctness. No ordinary Playback Device receives an administrative credential. Competing coordinators or two children of one journal head halt activation for review; neither time nor lexical digest elects a winner. Coordinators must not automatically retry a conflicting proposal.

### D2. What is the activation record, and where does it live?

- **A (recommended):** a dedicated, signed, versioned control journal in new local tables, replicated through a separately negotiated control protocol and included in backups. Store the canonical signed envelopes on each host; keep an export with the recovery set.
- **B:** a new shared-audio `Value` or playlist record kind. Old strict decoders may reject the page before learning the gate; reject this option for a compatible rollout.
- **C:** a local boolean or Hello token alone. It has no common authority, baseline binding or recovery evidence; reject it.

Trade-off: A needs separate persistence, verification and replication, but can gate future projection changes without polluting musical history. The journal must be available before gated data replication; it is not an optional cache.

Proposed signed content, finalized and pinned with byte vectors in implementation:

| Envelope | Required bindings |
| --- | --- |
| Proposal | Domain/version, cluster/root, baseline, previous journal head, next epoch, membership revision, complete authorized-host/grant list, cumulative required profiles, inventory/backup manifest digests, coordinator and maintenance-session nonce |
| Prepared acknowledgment | Proposal digest, host identity/grant, installed implementation/profile IDs, complete input-history digest, verified local baseline, persisted write/admission freeze and minimum-profile floor |
| Activation certificate | Exact proposal plus every required host acknowledgment, coordinator signature and content digest |
| Installation acknowledgment | Activation certificate digest and host's durable installed epoch; required before releasing writers |

Use domain-separated canonical signing bytes, bounded decoding and content IDs. Never rely on build version ordering alone: a profile names semantics and fixtures. A host acknowledgment is an authenticated assertion by a trusted host, not remote attestation of its executable. Operators verify installed builds separately.

An active certificate is immutable. Later epochs extend the profile floor and previous digest; they cannot clear it. An admission entry binds a new host to the active head and profile floor; a previously admitted host cannot serve from a stale local head without synchronizing control state. Missing, invalid, forked or unknown required profiles fail closed for signing and gated replication, while retaining verified local playback data.

### D3. How are every host and later membership changes constrained?

- **A (recommended):** freeze membership, admissions and mutations during preparation. Enumerate authorized hosts from the union of verified proofs collected from all known members, reconcile those proofs, and require one exact membership revision. Every host persists a prepare lock before signing. Any new grant/revocation invalidates preparation and requires a new proposal.
- **B:** use majority readiness. This improves availability but leaves an authorized minority on an unsafe projection; reject it.

Trade-off: A deliberately blocks on an offline host and cannot promise availability during a partition. It does not introduce a general membership consensus algorithm. The maintenance window and single coordinator are preconditions; code must detect observed forks and changes rather than claim to prove an unseen offline grant never existed.

All authorized hosts, including those that issued invitations elsewhere, must participate or be explicitly excluded. Reconcile outstanding invitations and disable redemption before the proof cut. Unknown host identity, disputed revocation, missing proof or unreachable authorized host means blocked. Do not quietly shrink the set to reachable LAN peers.

An owner may separately authorize exclusion of a host, but revocation propagation alone is insufficient: an old isolated host can still trust stale peers and sign records. Stop and isolate its process and prevent its clients from using it; distribute the revocation to every remaining host before reproposing. If isolation cannot be established, wait. Retain its unique data before exclusion. Records signed after the exclusion boundary are quarantined for review, not automatically imported as valid continuation.

After activation, compatible hosts serialize enrollment and promotion through the control coordinator: no grant is usable until admission is journaled against the active epoch and all serving hosts install that entry. New playback members require supported reading/writing behavior; host promotion additionally requires profile readiness and caught-up control/data history. A partition pauses admission. This changes today's independent host enrollment and must be implemented with ASO-39/44 before activation.

Every admitted host needs a startup guard outside the old executable: a maintained launcher and durable minimum-profile marker, with supervised service configuration preventing direct old-binary restart. Schema 5 only fences schema-4 binaries; PR #54's additive tables do not fence an earlier schema-5 projection. A new local compatibility floor must make unsupported startup refuse, and deployment controls must enforce it for binaries unaware of that floor. A journal flag cannot make such binaries obey. If direct old execution cannot be prevented, activation remains unauthorized. Recoveries and host replacements use the same guard; a downgrade requires D6, never just replacing the executable.

### D4. Baseline agreement, rollout order and Apple D3 B

- **A (recommended):** separate initial schema-5 activation from each subsequent profile activation. Upgrade host understanding and client readers before releasing affected writes. Advertise raw implementation support separately from active eligibility.
- **B:** advertise D3 B as soon as one host supports collapse. Simpler, but exposes every still-authorized old host to incompatible results; reject it.

Trade-off: A requires two distinct gates even when one deployment contains both implementations. Already-v5 clusters keep their existing baseline and use only the profile gate; do not reactivate or mint a new baseline to enable D3 B.

Hello should add optional activation evidence referencing the signed certificate, baseline and epoch, plus a separate implemented-profile list. Preserve existing fields for older clients. New clients validate the certificate and bindings on the live destination session, not a union of other hosts' capabilities. If proof is fetched separately, no gated mutation may precede its validation. A host advertises `register-track-cross-host-v1` only after durable certificate installation and writer release; raw implementation support must not use that token. Mutation acceptance independently checks the gate, including administrative registration entry points. A cached Hello is insufficient after session or control-state changes.

Apple delivery must preserve these restrictions:

1. Before the first registration send, persist a durable D3 B eligibility marker only when the current host proves active support. Save its cluster, baseline and profile evidence with the original envelope. A legacy Outcome unknown request never gains eligibility from a newer destination.
2. For eligible uncertain additions, try the original host first, then compatible active hosts. Keep member identity, registration/upload request IDs, source, payload and uncertainty across restart and cancellation.
3. Re-upload staged audio at the new host and durably store its ObjectStored receipt before registration. Another host's receipt does not prove destination bytes. Failed replacement upload does not erase the previous uncertain registration.
4. Accept a canonical reply naming another accepting host only for eligible D3 B registration, after matching a verified signed registration, origin, request and digest. Persist acceptance before refresh or staging cleanup. Legacy registrations and ordinary metadata retain their existing host check.
5. A missing token or invalid activation proof means D3 A/unavailable as appropriate, never an administrative-token or legacy-write fallback. Other operations retain their own retry policy; this profile grants no playlist or metadata cross-host retry guarantee.

No layout or product copy is specified here. Any subsequent wording change must follow DESIGN.md.

### D5. What does a consistent backup contain, and who holds it?

- **A (recommended):** stopped, consistent snapshots with encrypted separate-storage and offline copies; owner-controlled decryption material stored separately. Name a custodian and test access before the rollout.
- **B:** a same-disk database copy only. Cheap, but loses objects and authority on disk failure; reject it.
- **C:** hosted key escrow. It may improve availability but introduces another authority and service; defer pending a separate custody decision.

Trade-off: A adds storage and manual custody work. Possession of the backup can clone host authority, so manifests must not contain plaintext secrets or be published as fixtures. Confirm destinations, access, retention and key recovery in a private operational checklist; this document uses fictional values only.

Stop writers and host processes before copying. Verify process exit and exclusive directory ownership; retaining `node.lock` alone proves nothing. Copy the whole consistent database set, including any SQLite sidecars needed by the chosen snapshot method, rather than copying a live main database. Capture:

| Component | Required contents and comparison |
| --- | --- |
| Catalog and history | Legacy and v5 tables, exact signed music/playlist payloads, receipt tables including scoped/legacy reservations, projection inputs, cursors and schema version |
| Identity and membership | Node/library identity, complete grants/revocations, peer signing key/state, TLS identity and administrative secret material; preserve each host's distinct identity |
| Objects | Original audio, hash/suffix locators, artwork assets and their metadata; enumerate missing bytes and unreferenced published objects separately |
| Identity mapping | Canonical track/album IDs, aliases, organization choices, addition times, correspondences, exact historical playlist ID/hash pins and occurrence IDs |
| Operation and control | Required configuration, trust pins, relay settings, installed build/profile IDs, control journal, minimum-profile floor, maintenance state and manifests |
| Client intent | Per-member durable queues, staging and receipts: operation, original request/digest, target host, baseline, never-sent versus Outcome unknown versus Accepted; collect without publishing keys or user payloads |

Use relative-path manifests with sizes and SHA-256 for every file, plus semantic counts and digests for retained mappings and signed bytes. Compare object hashes, not just file counts. Missing/protected source files remain explicit exceptions, never substituted with equal-title or equal-hash tracks. Test decryption and a stopped restore before calling the backup verified. Originals and source replicas remain retained; no automatic GC or permanent purge is introduced.

### D6. What happens after failure?

- **A (recommended):** resume safely before the point of no return; use forward repair after new-epoch writes. A coordinated restore is an explicitly reviewed exceptional operation with later-write accounting.
- **B:** restore one old database and resume peer sync. Peers can reintroduce incompatible history and acknowledged writes can disappear; reject it.

Trade-off: A can require extended maintenance. It preserves evidence and avoids presenting data loss as successful rollback.

| Failure | Required outcome |
| --- | --- |
| Local schema activation interrupted | Reopen under the compatible build and inspect committed schema/baseline; transaction rollback or committed migration is authoritative. Repeat only with the exact approved baseline. Do not guess from CLI output. |
| Preparation interrupted, no certificate | Keep durable prepare locks. Coordinator reconciles every host and journal; only an explicit signed abort of that proposal may release locks after proving no certificate exists across the full host set. Unavailable host means wait. |
| Certificate persisted on only some hosts | Treat the epoch as potentially active. Keep writes frozen; retrieve and install the same certificate everywhere, then collect installation acknowledgments. Do not roll back one host's flag. |
| Host unavailable before activation | Block, or use the separately authorized exclusion/fencing path in D3. |
| Host unavailable after activation | Existing admitted compatible hosts can continue already-enabled operations; the returning host synchronizes control first. No admission/promotion while the required coordination is unavailable. |
| Stale writer or wrong baseline | Reject without changing shared state; preserve local queued intent for upgrade/review. Never reinterpret a legacy hash edit as a logical-track edit. |
| Bad projection or damaged replica | Stop affected writes, preserve snapshots and later history, repair forward with the active profile. Rebuild a replica only from verified inputs; never rewrite signed bytes to make projection pass. |

Before any pre-activation restore, stop and fence every host, client sender and replication path. Export all post-snapshot signed records, accepted receipts, pending/uncertain intents, new audio/artwork and control/membership changes. Build a disposition ledger keyed by member/request and record IDs: retained for forward recovery, explicitly reapplied after review, unresolved, or owner-approved loss. A lost reply is not evidence that no write occurred. If any host or device holding unique outcomes is unavailable, lossless restore cannot be claimed; block or obtain a separate explicit decision accepting the enumerated uncertainty.

Restore every affected data/identity/configuration/control snapshot from the same approved cut; do not mix hosts from different recovery sets. Preserve later revocations and compromised-key exclusions as security constraints: if an old implementation cannot enforce them, restore may be inspected offline but must not serve. Keep all later history quarantined and prevent old peers or durable client queues from automatically replaying into the restored cut. If retained new-epoch writes cannot be represented by the old projection, continue forward repair rather than import them into it. Only release a restored cluster after renewed membership/baseline agreement, compatible-client validation and separate owner authorization. This is not an automatic rollback command.

### D7. Playback replacement versus loss of the final host

- **A (recommended):** replace a Playback Device with a fresh key and grant from a surviving authorized host; recover the final host only from a verified authority-bearing recovery set with the previous process fenced.
- **B:** clone a lost playback identity or mint a replacement final-host key inside the old history. Cloning risks concurrent writers; a new key alone has no authority to continue the old chain. Reject both shortcuts.

Trade-off: A preserves verifiable continuity but cannot promise recovery if every valid host key and its backups are gone. A surviving non-root host may still authorize enrollment under its valid chain; distinguish this from loss of every usable host authority, not just loss of one NAS.

For playback replacement, retain recoverable local saves and unsent intent, explicitly revoke the replaced member, and verify new enrollment/catalog/audio access. Do not replay the old member's uncertain requests under the new member ID: deterministic registration identity is member-scoped. Resolve or retain them as evidence for review.

For final-host restoration, verify decryption, grant chain, active profile floor, journal and later revocations before starting one restored instance. Never run an original and cloned signing identity concurrently, even for rehearsal. If the original may return, establish an operational fence first. If no valid authority can be recovered, retain the old signed history and bytes read-only; propose a new cluster with explicit reviewed import and fresh grants under a separate authorization. Do not reset identity, silently re-sign history or label that process a continuation. A known compromised key requires a separate security recovery decision, not routine restore.

## Activation runbook gates

These are proposed gates, not commands to execute against production.

1. **Design:** owner confirms D1–D7. Resolve ASO-39/44 admission dependencies; record required profiles and supported reader revisions. Keep ASO-12 acceptance separate from deployment approval.
2. **Inventory:** enumerate every host, membership proof, build and baseline; compare canonical IDs, aliases, organization, signed history, conflicts, incomplete parents, playlist pins and audio/artwork availability. Inventory every member's pending requests and staging. Explicitly resolve divergent intent and invalid mappings; do not choose a host merely because its catalog is newer or larger.
3. **Quiesce:** stop legacy and administrative writers, pause durable client delivery, freeze enrollment/invitations and collect unknown outcomes from accepting hosts. Never-sent requests stay durable for later revalidation; uncertain legacy registrations stay pinned. An offline playback client may remain offline only if all serving hosts reject its stale writes on return and its local intent is retained; unique unaccounted data blocks a lossless cut.
4. **Agree and back up:** converge the complete legacy input snapshot and mapping, inspect identical baseline fingerprints, reconcile membership and sign the inventory. Differences in per-host identity/location state are expected and backed up separately, not copied between hosts to force equality. If common baseline cannot be achieved without identity forgery or hidden loss, stop for a dedicated migration design. Verify D5 backups and disposable restore.
5. **Upgrade without new writes:** install compatible host binaries/startup guards and readers on every serving platform. Complete schema-5 migration on stopped hosts using the inspected expected baseline; verify the same result on each before enabling replication. Existing-v5 hosts skip migration. Keep new profile writes disabled.
6. **Prepare and activate:** collect D2 readiness from the exact D3 host set, persist the signed certificate, install it everywhere and collect installation acknowledgments. Membership or input changes before commit invalidate the proposal. Reads may continue only where their state is verified and supported; write release is still withheld.
7. **Release by profile:** enable compatible clients and host mutation entry points only after all installation acknowledgments are durably recorded. Persist that release evidence so restart cannot advertise early. Run a separately authorized small pilot: two logical registrations sharing bytes, exact historical playlist playback, lost-reply retry and unrelated saved playback. Preserve all recovery material and record actual results. Broad import requires its own instruction.

For initial schema migration and later profile activation, record both their independent completion states. No automatic release follows a successful local migration or a single passing test.

## Disposable restore and rehearsal matrix

Use newly generated fictional cluster identities and isolated directories from the outset. Tests restoring a fixture identity must stop its original process first and block discovery/relay access to any other instance. No production identity is launched in a clone. Record build IDs, manifest digests, expected/observed results and remaining failures; missing fixtures fail the gate rather than count as a skip.

| Case | Required result |
| --- | --- |
| Membership and custody | Restored grants, root chain and revocations verify; wrong key, corrupt backup, missing peer key or disputed proof blocks serving. Decryption succeeds using the documented separate custody path. |
| Signed history | Every retained music/playlist signature and exact payload digest matches; tampering fails. Rebuilt receipt and cursor state neither drops records nor advances over a rejected page. |
| Aliases and logical identity | Canonical IDs, alias targets, addition times and album visibility survive. Two tracks sharing one hash stay independent; alias cycles/dangling targets block the cut. |
| Exact playlist pins | Every historical ID/hash pair resolves to the same logical target and bytes, including old encoding and repeated occurrences; missing bytes remain unavailable without retargeting. |
| Artwork and audio | SHA-256 and sizes match for present assets; unavailable artwork/audio is explicitly listed. Unreferenced objects remain retained. Corruption is detected before restored data is advertised as verified. |
| Divergent hosts and pending clients | Different baselines, unknown hosts and unresolved accepted/unknown requests prevent readiness; never-sent requests survive restart and revalidate after the cut. |
| Interrupted stages | Kill before/after local migration commit, prepare persistence, certificate persistence and writer release. Reopen gives exactly the committed state; no host advertises D3 B before release. |
| Old-host fence | Earlier schema-5 binary cannot start via the guarded service; direct unsupported execution is operationally prevented. Offline old host blocks preparation; excluded host cannot rejoin or contribute post-exclusion writes. |
| Control validation | Wrong cluster/baseline/revision, missing acknowledgment, replayed old epoch, membership change and competing journal branch all block activation. Restart retains profile floors and prepare locks. |
| Future admission | Old enrollment/promotion/recovery attempts fail; a compatible new host catches up control first and is admitted at the active profile floor. A downgraded executable is refused. |
| D3 B convergence | Lost acknowledgment, two hosts, both arrival orders, restart and pagination converge to one registration outcome; children of losing records remain complete and supersede the canonical parent. Different digest under one member/request is rejected atomically. |
| Apple eligibility | Marker persisted before first send survives restart; cross-host upload precedes registration; upload failure preserves uncertainty; verified canonical prior-host reply is saved. Legacy uncertain registration and ordinary metadata reject the relaxed host case. |
| Repair and restore | Post-cut writes and revocations enter the disposition ledger; restoring one host alone cannot resume replication. Forward repair retains signed bytes; coordinated restore cannot silently lose accepted/uncertain intent. |
| Replacement/final host | Fresh playback enrollment succeeds without cloned identity. One restored final host proves authority and profile floor; absent recovery authority yields read-only evidence, never fabricated continuity. |

## Bounded implementation and verification tickets

These are proposed ticket boundaries for lead/owner planning, not created issues or delegated implementation. Each slice requires its own approval and evidence.

| Slice | Deliverable and focused acceptance | Dependency |
| --- | --- | --- |
| S1: inventory and recovery manifest | Read-only host/client inventory, deterministic comparison and stopped-backup manifest; detect divergence, missing assets and unresolved requests. No activation side effects. | D4–D6 |
| S2: control persistence | Canonical signed proposal/ack/certificate/release journal, membership revision digest and durable floors/locks; tamper, replay, fork and crash fixtures. No Hello D3 B token. | D1–D3 |
| S3: coordinated gate and admission | Maintenance freeze, full host-set collection, control-first replication, guarded startup, enrollment/promotion/recovery checks and fail-closed mutation paths. Prove old schema-5 fencing. | S2, ASO-39/44 coordination |
| S4: host D3 B activation | Bind `registration-equivalence-v1` to PR #54 semantics; active Hello evidence/token and host acceptance checks. Prove mixed-version/offline refusal, restart and two-host convergence. | S3, host preparation |
| S5: Apple D3 B delivery | Durable first-send marker, live-session gate, host-specific upload receipt and narrow canonical-acceptance validation. Ordinary metadata and legacy retry regressions remain pinned. | S4; DESIGN.md before wording work |
| S6: disposable recovery acceptance | Execute the full matrix, including isolated authority restore, asset hashes, exact pins and later-write accounting. Attach reproducible evidence and failures to ASO-12/recovery follow-ups. | S1–S5 and compatible platform readers |
| S7: owner-reviewed pilot runbook | Private destinations/custodian, named revisions, inventory, freeze/fencing evidence, backup/rehearsal results, abort points and release checklist. No production action until separately authorized. | Owner decisions and S6 |

This design phase changes only this document. It performs no migration, identity reset, deployment, rollback, object GC, permanent purge, build, Simulator run, commit or push.

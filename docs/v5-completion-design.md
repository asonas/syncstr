# v5 completion design and delivery boundaries

Status: design draft for review. The product-gap audit and its sequencing were approved as the basis for design and issue planning on 2026-11-06. Detailed choices below are proposals unless identified as existing requirements. No implementation, production activation or deployment is authorized by this document.

## Scope and evidence

Main is `eda12d8af132624c8df9bcc7d1f047b3356bf0be`. Draft [PR #15](https://github.com/asonas/syncstr/pull/15) is `c2a7df31a8e62098524ddf60a5840f64e25db68e`; it contains the ASO-8 server prerequisite and Apple read/play/save work. The current milestone remains experimental until its own acceptance passes. A later production-ready v5 baseline must preserve existing addition, playlist update, enrollment and optional remote journeys.

Update (2026-11-06): PR #15 was merged into main as `1d2d569`, and ASO-9 is Done. Its CI passed on iPhone, iPad and macOS. Physical-device audio output and the ASO-12 cross-platform matrix are not yet verified. The evidence links below stay pinned to the audited revisions.

Existing requirements remain binding: original files are untouched; distinct source registrations retain logical identity; hashes identify bytes; source matches require explicit acceptance; local save removal is distinct from shared deletion; unrelated playback continues during conflicts; offline intent is durable; ordinary clients do not receive administrative credentials.

Initial NAS-authoritative/passkey/OpenAPI plans remain historical. Current cluster requirements, ADR 0006, the player/save contracts and the specific migration/playlist plans take precedence. The audit distinguishes code in main, draft code, prior verification and unverified behavior.

## 1. Mutation contract

Propose a versioned member-to-host submission boundary shared by audio addition, metadata changes, existing XML playlist updates and later ordinary playlist edits. Use separate operation kinds; do not reinterpret legacy hash-based writes as logical-track writes.

A durable request contains a stable request ID, cluster and activation-baseline identifiers, originating member, operation kind, logical target IDs, observed revision heads, payload and any explicit correspondence/replacement approval. A host authenticates the member, validates operation-specific authority and expected heads, and signs the accepted change. Host acceptance must retain the originating intent and causal base.

| State | User-visible promise | Recovery |
| --- | --- | --- |
| Draft | Not yet submitted; no shared change | Edit or discard |
| Queued | Intent persisted locally | Restore on restart and retry under network policy |
| Sending | Host outcome not yet established | A timeout returns to retryable/unknown outcome, not success |
| Accepted | Durable signed acknowledgment retained locally | Replay of the identical request returns the same result |
| Needs review | Stale heads or competing intent | Retain payload and alternatives; rebase only after explicit review |
| Rejected | Authorization or validation failed | Explain the reason; preserve local intent for review/discard |

Cancel before submission removes queued intent. Cancel after an uncertain submission does not undo a possibly committed operation; reconcile the request outcome first. Reusing a request ID with different content must fail. Cross-host retry must not sign a second independent mutation merely because the first response was lost; specify receipt/history reconciliation and its unavailable-host behavior before implementation.

Authorization matrix to finalize: playback-device read, explicit addition and playlist submission; host-mediated metadata/correspondence decisions; host-only enrollment, revocation and shared deletion. Unsupported capabilities must produce an explicit upgrade/unavailable state, never silent downgrade or administrative-token fallback.

Acceptance examples: lost reply followed by another-host retry; stale preview after an independent edit; two logical tracks sharing bytes; a pending request surviving restart; revoked membership before acknowledgment. Keep ASO-6/7's existing XML performance/UI ownership.

## 2. Library projection and incomplete state

ASO-9 owns preservation of album membership, artist credit, compilation/edition distinctions, artwork and explicit visibility choices when projecting v5 into Apple views. Keep raw signed data separately, but provide a complete typed presentation keyed by logical IDs. Editing metadata for A must not modify B solely because they share audio.

Propose distinct availability reasons: local verified audio, remotely obtainable audio, no reachable source, no eligible audio, affected conflict and incomplete dependency. Preserve the last verified unrelated subjects. For an incomplete record whose affected subjects cannot be safely determined, retain the prior verified snapshot and report refresh incomplete rather than publishing a partially trusted catalog or making every saved track unavailable.

ASO-9 must settle and verify the projection rule before closing. ASO-12 adds one affected subject plus one unrelated playable saved track to the common fixture. Required UI/interoperability tests must fail their acceptance gate when fixtures are absent, rather than allowing a skip to count as success.

## 3. Enrollment and replacement

Propose retaining LAN-only, host-approved, expiring, single-use invitations on activated v5 hosts. Redeeming pins the expected host and binds a fresh member key to the current cluster/baseline and signed grant. New devices must not require a legacy host or downgrade. Replay, revocation during redemption and disputed authority need explicit rejected outcomes.

A replacement device receives a new identity and grant; it does not silently reuse the lost identity. Keep locally retained audio/profile recoverable until reattachment is verified. Revoke the replaced member explicitly. Distinguish routine replacement with a surviving authorized host from loss of the final signing authority; the latter belongs to the recovery contract and must not create a fabricated continuation of signed history.

## 4. Remote continuity

Reuse the M4 user-operated relay and authorization model in v5: explicit configured relay, direct preference, LAN operation during relay outage, no public-default fallback. Enrollment remains LAN-only. Specify authenticated relay-setting rotation for existing devices, how a stale device rediscovers the setting on LAN, and when a fresh invitation is required.

Keep transport reachability separate from music access and storage durability. A path indicator describes an observed path, not proof of all traffic. Acceptance requires forced relay download, relay-off LAN transfer, interruption/retry and live revocation on the v5 build. Earlier M4 device results do not satisfy this gate.

## 5. Reviewed migration

Extend the existing Windows inventory/prepare/import/resume flow. Propose persisting reviewed source identity, correspondence decision and destination logical ID separately from object transfer. Reuse an approved correspondence only while its revision and target remain valid; changed/ambiguous evidence returns to review.

Preserve distinct registrations sharing audio, unavailable registrations, source provenance and later explicit Syncstr edits. A progress result separates audio durability, metadata application, artwork completeness and source correspondence. Lost acknowledgment must be recoverable without another registration. The existing helper's legacy `cluster-import` and direct schema assumptions must be replaced or version-gated for v5.

Automated source-application acquisition and artwork extraction need a capability proposal based on the actual Windows application. Missing artwork is partial completion, not failed audio or invented artwork. Do not broaden this slice into subscription migration, source deletion, ratings or listening history.

## 6. Ordinary playlists

Propose the first implementation slice as offline create/add/play, followed by rename/move/remove/reorder and folder management. Persist each edit and its local projection atomically. Use stable playlist IDs and independent occurrence IDs; intentional repeats remain separate. The active playback queue is a snapshot and does not change when the playlist changes.

The design issue must settle deterministic ordering of independent insertions, concurrent moves/renames, delete-versus-unseen-edit, folder cycles/descendant deletion and temporary conflict presentation. Do not silently resolve these with device clocks. Acknowledged historical edits by a later-revoked writer need a rule distinct from unaccepted new edits.

Fixed imported smart snapshots stay labeled as snapshots. Smart evaluation, arbitrary rule translation, favorites and history are outside this first slice.

## 7. Activation and recovery

Propose separate gates: design accepted; implementations verified on compatible revisions; isolated activation/restore rehearsal passed; production change explicitly authorized. ASO-12 remains the shared-audio acceptance gate, not a production deployment ticket.

Before activation, inventory host baselines and pending client writes; reconcile divergence with explicit decisions. Take a consistent snapshot of database, originals, organization/artwork, signed history, aliases/pins, identities and required configuration. Preserve source replicas and recovery material until isolated verification succeeds. Do not run an original and cloned signing identity concurrently.

The runbook must define activation order, stale-client rejection, one unavailable host, interrupted activation, forward repair and coordinated pre-activation restore with later-write accounting. Decide backup destination/key custody and the final-host-key-loss procedure before a real rollout. Automatic GC and permanent purge remain deferred; local eviction must protect saved and active playback pins.

## 8. Setup and platform baseline

Propose local-only playback and joining an existing cluster as the initial supported setup paths; keep host creation explicit through the existing CLI until the GUI design is accepted. A library host targets the complete library and reports capacity-constrained replication as incomplete. Promotion/demotion must preserve identity and prevent a role change from accidentally deleting the final usable copy.

For additional-platform daily use, propose verified save/offline restart, continuous album queues, seek/pause/resume, retained catalog, interruption recovery and clear unavailable states. Android additionally needs background/lock-screen/media-control behavior before daily-use parity is claimed. Windows library hosting is separate from playback support. Remote access, packaging/signing and distribution require named acceptance gates.

These are recommendations for owner review, not a declaration that all proposed features are now release requirements. Smart lists, cross-device playback handoff, favorites/history, gapless/transcoding and application licensing remain later decisions.

## Issue and delivery rules

- ASO-5 owns actual XML E2E/phase measurements; merged fixture timing is partial.
- ASO-6/7 remain blocked by ASO-5's technical results.
- ASO-8 remains complete for its documented branch/server boundary.
- ASO-9 owned Apple v5 projection and acceptance. It is Done. The owner merged PR #15 on 2026-11-06 without verifying physical-device audio.
- ASO-10/11 retain Android/Windows v5 implementation ownership.
- ASO-12 owns cross-platform identity/save verification and required-case execution evidence.
- New design issues cover mutations, enrollment, remote continuity, migration, offline playlists, recovery, host lifecycle and platform support. They are Backlog/needs-triage, with no implementation delegated.
- A design issue closes when a reviewable contract, alternatives, decision record and bounded implementation tickets are ready and required product choices are confirmed. Writing a draft alone does not close it.
- Design dependencies constrain finalization, not independent research. Enrollment and remote design can proceed together; migration and playlist transport contracts use the mutation contract.
- Do not infer task completion from a merged supporting PR or an aggregate CI pass. Preserve unrelated labels, existing ownership and evidence.

## Evidence links

- [Accepted cluster behavior](https://github.com/asonas/syncstr/blob/eda12d8af132624c8df9bcc7d1f047b3356bf0be/docs/cluster-model-design.md)
- [Track identity boundary](https://github.com/asonas/syncstr/blob/eda12d8af132624c8df9bcc7d1f047b3356bf0be/docs/adr/0006-preserve-source-track-identity-independently-of-audio.md)
- [Existing migration tool](https://github.com/asonas/syncstr/blob/eda12d8af132624c8df9bcc7d1f047b3356bf0be/tools/music-migration/README.md)
- [Playlist scope](https://github.com/asonas/syncstr/blob/eda12d8af132624c8df9bcc7d1f047b3356bf0be/docs/playlist-implementation-plan.md)
- [v5 server boundary](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/docs/shared-audio-server-implementation.md)
- [Apple projection](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/apps/macos/SharedAudio.swift)
- [Apple transport](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/apps/macos/ClusterTransport.swift)
- [Apple validation](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/docs/validation/shared-audio-apple.md)

## Published tracking — 2026-11-06

[Linear design document](https://linear.app/asonas/document/v5-completion-design-and-delivery-boundaries-7bf03b53cfba)

| Issue | Design scope | Finalization dependency |
| --- | --- | --- |
| [ASO-38](https://linear.app/asonas/issue/ASO-38/design-v5-client-mutation-contracts) | Design v5 client mutation contracts | No blocking design dependency |
| [ASO-39](https://linear.app/asonas/issue/ASO-39/design-enrollment-after-v5-activation) | Design enrollment after v5 activation | No blocking design dependency |
| [ASO-40](https://linear.app/asonas/issue/ASO-40/design-v5-remote-access-continuity) | Design v5 remote-access continuity | No blocking design dependency |
| [ASO-41](https://linear.app/asonas/issue/ASO-41/design-v5-source-correspondence-migration) | Design v5 source-correspondence migration | ASO-38 mutation contract |
| [ASO-42](https://linear.app/asonas/issue/ASO-42/design-durable-offline-playlist-editing) | Design durable offline playlist editing | ASO-38 mutation contract |
| [ASO-43](https://linear.app/asonas/issue/ASO-43/design-v5-activation-and-recovery-gates) | Design v5 activation and recovery gates | No blocking design dependency |
| [ASO-44](https://linear.app/asonas/issue/ASO-44/design-cluster-setup-and-host-role-lifecycle) | Design cluster setup and host-role lifecycle | No blocking design dependency |
| [ASO-45](https://linear.app/asonas/issue/ASO-45/define-windows-and-android-playback-support) | Define Windows and Android playback support | No blocking design dependency |

All eight design issues are Backlog with needs-triage, without an assignee or implementation delegation. ASO-41/42 have native blocked-by relations to ASO-38. Enrollment, remote access and recovery are linked for coordination, not made into an artificial sequential chain.

ASO-5 was reopened to Backlog and ASO-9 to In Progress, with needs-triage replacing ready-for-agent during design review. Existing assignees and other ownership were preserved. ASO-12 retains its existing blockers and adds explicit projection and required-test evidence criteria. ASO-8 remains Done for its published server boundary. No PR was promoted, merged or deployed at that point. Later the same day, the owner marked PR #15 ready and merged it. Nothing was deployed.

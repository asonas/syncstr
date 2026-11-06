# Product gaps and proposed design work

Follow-up (2026-11-06): the owner authorized proceeding with design and issue planning after this audit. See the [completion design and published issue index](v5-completion-design.md#published-tracking--2026-11-06). Eight design issues (ASO-38–ASO-45) are now registered; ASO-5/9 statuses and ASO-12 evidence criteria were reconciled. The audit below preserves its original observation snapshot; statements about issue counts/statuses and no writes describe that earlier audit, not the follow-up. No application code was changed. Later the same day, the owner merged PR #15 and ASO-9 was closed, so the recommendation below to keep PR #15 Draft no longer applies. Physical-device audio output and the ASO-12 cross-platform matrix are still unverified.

Syncstr has working playback, verified local copies, cluster replication, and an initial playlist import flow. The next priority is to complete the transition to logical-track identity without losing existing user journeys. The v5 draft implements important playback and storage foundations, but does not yet connect enrollment, remote access, client mutations, and library presentation into a complete replacement for the current product.

This is a design audit and a proposal for subsequent issue planning. It does not approve implementation, change accepted requirements, or create issues. Proposed priorities below are review recommendations.

## Evidence boundary

- Reviewed on 2026-11-06. Local main and GitHub main both resolve to `eda12d8af132624c8df9bcc7d1f047b3356bf0be`.
- The Syncstr Linear project contains eight issues, ASO-5 through ASO-12. Read every issue's description, comments and relations; the issue list and comment responses had no remaining pages.
- GitHub has one open PR: Draft [#15](https://github.com/asonas/syncstr/pull/15), head `c2a7df31a8e62098524ddf60a5840f64e25db68e`. Read its metadata, changed-file list, implementation, design and validation records. Its four reported CI checks are successful; there are no submitted reviews. This is not a completed acceptance gate.
- Inspected the initial roadmap/interview, subsequent decisions and ADRs, cluster and player contracts, playlist and migration plans, platform guides, relevant source paths, and existing verification records. Historical GitHub issue #12 is still open; other issues #1–#11 are closed.
- Findings are based on source and recorded evidence. No new app execution, benchmarks, device tests, production inspection, Figma visual review, or deployment was performed. Previously recorded physical-device success is attributed to its original milestone, not the current v5 build.
- Source links outside the v5 evidence table refer to the audited main revision. v5 evidence is pinned below so later PR changes do not silently change this audit's basis.

## Which goal is authoritative?

| Layer | Treatment in this audit |
| --- | --- |
| [Initial interview](grill-me.md) and [August roadmap](plans/2026-08-15-syncstr-implementation-plan.md) | Preserve the long-term ambition: owned audio, multiple native platforms, durable personal-library data. NAS authority, passkeys, server sequencing and the old OpenAPI layout were superseded; do not restore them as mandatory work. |
| [Local product specification](design-spec.md) | Preserve original files, explicit trust, verified offline copies, and a usable local path. Its statements that playlists, multiple peers, remote access and other platforms are wholly deferred no longer describe all current implementation. |
| [Cluster model](cluster-model-design.md) and [ADR 0002](adr/0002-local-first-connectivity-with-user-operated-remote-access.md) | Accepted direction: one library, multiple hosts, any-device additions, optional user-operated remote access, retained offline state, explicit conflict resolution and separate local removal/library deletion. |
| [ADR 0006](adr/0006-preserve-source-track-identity-independently-of-audio.md) and v5 design | Distinct source registrations stay distinct even when bytes match. The older cluster model's hash-based item-merging wording needs amendment. Shared storage is not permission to merge tracks. |
| [Player contract](player-interaction-spec.md), [save contract](cluster-ui-review.md), [playlist plan](playlist-implementation-plan.md), [migration plan](music-library-migration-plan.md) | Apply their specific accepted behavior. Device-local playback restoration is implemented scope; cross-device handoff is separate. Ordinary playlist editing is accepted scope but unfinished. Music migration excludes ratings, favorites and play counts from its current slice. |

The documents currently disagree even within a single file: the playlist plan's opening says persistence/import/presentation do not exist, while later sections describe their implementation. README says music migration is pending, while `tools/music-migration` already provides inventory, preparation, import and resume. The cluster plan's opening says M3 is next, while its later sections record M3 integration and M4 acceptance. These are documentation gaps, not evidence that the underlying features are absent.

## Existing work: retain ownership instead of duplicating issues

| Existing issue | Live status | Evidence and remaining work |
| --- | --- | --- |
| [ASO-5](https://linear.app/asonas/issue/ASO-5) XML latency | Done | PR #13 is merged, but its scope is fixture/API-call timing. The latest comment and [validation record](validation/playlist-latency.md) explicitly leave UI E2E timing, operation correlation, phase attribution, representative data and history batching assessment open. Reconcile status/acceptance and finish here. |
| [ASO-6](https://linear.app/asonas/issue/ASO-6) lightweight matching | Backlog | No PR. Avoiding artwork reads is already scoped. Its baseline dependency on ASO-5 remains technically unmet despite ASO-5's Done state. |
| [ASO-7](https://linear.app/asonas/issue/ASO-7) XML progress/retry/completion | Backlog | No PR. Already covers the proposed Figma flow, retained review, stale-preview recovery, accessibility and cross-Apple verification. Do not create another import-progress issue. |
| [ASO-8](https://linear.app/asonas/issue/ASO-8) v5 server | Done | Description explicitly defines delivery as the published server branch, not main integration or deployment. PR #15 includes this prerequisite. Remaining enrollment/activation constraints are documented; Done is not a production-readiness claim. |
| [ASO-9](https://linear.app/asonas/issue/ASO-9) Apple v5 | Done | PR #14 merged only a save-intent repair. Draft #15 contains the broader work. The latest comment explicitly says In Progress and lists final iOS/UI gaps, contradicting the current status. Keep acceptance and projection repairs with this issue/PR. |
| [ASO-10](https://linear.app/asonas/issue/ASO-10) Android v5 | Backlog | Scope includes identity, offline saves, refresh and device verification. No issue comments or open PR establish completed delivery. |
| [ASO-11](https://linear.app/asonas/issue/ASO-11) Windows v5 | Backlog | Scope includes identity, offline saves, responsiveness and native verification. No issue comments or open PR establish completed delivery. |
| [ASO-12](https://linear.app/asonas/issue/ASO-12) combined acceptance | Backlog | Already owns the compatible two-host/four-client acceptance matrix. Depends on ASO-9/10/11. Explicitly excludes production migration and leaves rollout as a separate decision. |

The audit does not infer who changed issue states or why. Recommended follow-up: reconcile ASO-5 and ASO-9 against their unmet criteria, preserve ASO-8's explicit branch-delivery boundary, and record which later ticket owns production readiness. No statuses or comments were changed during this audit.

## Pinned v5 source evidence

All entries below refer to PR #15 head `c2a7df3`.

| Reference | Relevant implementation |
| --- | --- |
| [Apple transport](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/apps/macos/ClusterTransport.swift) | `playlistRequest` rejects shared-audio sessions; upload, metadata and resolution methods still send legacy operations. v5 catalog and exact-pin downloads have dedicated paths. |
| [v5 QUIC requests](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/headless/src/shared_audio_net.rs) | Request variants are Catalog, Records, PlaylistRecords, Receive and Audio. There are no ordinary client upload/edit/playlist submission requests. Receive requires host authority. |
| [v5 service startup](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/headless/src/main.rs) | `SharedAudioServe` uses `cluster_endpoint`, starts v5 serving and LAN discovery, and exposes administrative HTTPS. It does not configure the legacy service's remote relay or enrollment path. |
| [Apple projection](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/apps/macos/SharedAudio.swift) | `localCatalog` builds entries without AlbumOrganization; `entry` returns `artwork: nil` and does not copy coverArt. Any nonempty `incomplete` list marks every projected track unavailable. |
| [Apple persistence](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/apps/macos/CatalogDatabase.swift) | `clusterCatalog` uses the v5 projection when retained. `save` returns without legacy catalog/organization writes for logical-audio catalogs. Raw snapshot preservation therefore does not prove preserved UI semantics. |
| [Server design](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/docs/shared-audio-server-design.md), [implementation](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/docs/shared-audio-server-implementation.md) | Exact activation baseline, preserved addresses/pins, independent metadata, explicit correspondence and no automatic object GC. Invitation issuance/redemption remains pre-activation. Schema-5 writes prevent a simple binary downgrade. |
| [Apple validation](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/docs/validation/shared-audio-apple.md) | Reports passing Mac/Rust checks and partial Mac interaction checks, with final iOS and broader visual acceptance open. |

## Design work before implementation

### 1. Complete the v5 library projection and bound incomplete state

**Classification:** concrete gaps in the draft; extend ASO-9 and its ASO-12 acceptance, rather than creating a second Apple-v5 issue.

The server retaining organization data is insufficient when the client does not project it. Album artwork, artist credit, compilation membership choices and visibility depend on the organization consumed by `Library.preparedAlbums` and related UI. The v5 projection omits that structure and artwork. Separately, a missing history dependency anywhere sets every track unavailable, whereas the accepted conflict policy says unrelated playback and synchronization continue.

**Proposed contract:** preserve library presentation by logical track ID, including prior choices and artwork references. Associate incomplete/conflicting decisions with affected subjects; retain last verified usable state for unrelated subjects. Distinguish missing audio, conflicting metadata and incomplete history instead of reducing all three to an unexplained unavailable flag. Resolution must reference observed heads, and preserve pending intent until acknowledged.

**Acceptance:** upgrade a fixture with a compilation, distinct editions, artwork, explicit album/visibility choices, and two tracks sharing audio. Compare browse/search/detail after restart. Introduce an incomplete revision affecting one subject and verify an unrelated saved track remains playable. These are source-derived review findings; visual reproduction remains to be done.

### 2. Preserve user mutations when switching to v5

**Classification:** implementation/contract gap not covered by the playback-focused v5 tickets. Candidate: **Define and implement v5 client mutations without losing existing flows**.

Current Apple clients can submit XML playlist imports/updates and cluster audio imports. PR #15 can read/play v5 but rejects playlist requests and retains legacy upload/metadata/resolution operations that the v5 QUIC server does not accept. Administrative HTTPS write endpoints exist, but giving their bearer token to a playback device would cross the documented authorization boundary. The migration helper also still invokes legacy `cluster-import` and reads the old tables/object layout.

**Proposed contract:** authenticated members submit bounded operations to an authorized host, which validates and signs accepted changes. Define capabilities for read, audio addition, metadata edits, playlist updates and conflict resolution. Persist request IDs and observed heads; retry without duplicates and preserve rejected/pending edits. Explicitly gate unsupported actions until their end-to-end path exists. Do not silently downgrade after v5 activation.

**Acceptance:** import audio and update an existing XML playlist from each supported Apple entry point; lose the acknowledgment and retry; reconnect to another host; preserve occurrences, old ID/hash pins and shared-byte ownership. Test a reader that cannot obtain administrative privileges. General playlist creation/editing remains item 6, not an implied addition to this compatibility slice.

### 3. Define enrollment and device replacement after activation

**Classification:** documented v5 limitation; new design candidate beyond ASO-8's completed boundary. Candidate: **Support enrollment and replacement devices after v5 activation**.

New invitations currently depend on pre-activation enrollment. That is adequate for a prepared fixture but cannot support adding a new phone after every host has activated v5. Existing relay-URL rotation also uses fresh LAN invitations. Device-key loss and replacement must be considered alongside ordinary enrollment, not handled by resetting an existing catalog or copying one identity to several live devices.

**Proposed contract:** retain host-approved, expiring, single-use LAN enrollment with identity pinning; issue it from an active v5 host. Specify grants, revocation propagation, role authorization, and replacement-device handling. Keep a recoverable original profile and local audio until reattachment has been verified. Separate recovery of a playback device from recovery of the final host authority.

**Acceptance:** after all hosts activate, enroll a fresh device, restart it, revoke another, reject invitation replay, and rejoin with a replacement key. Show what remains accessible locally and what requires renewed authorization. No downgrade or enrollment reset is a normal recovery mechanism.

### 4. Preserve optional remote access in the v5 service

**Classification:** concrete capability gap in the draft; new candidate linked to ASO-8/12. Candidate: **Carry user-operated remote access into v5**.

[M4](cluster-remote-m4.md) records successful physical cellular relay transfer and relay-off LAN operation for the earlier service. `SharedAudioServe` instead calls `cluster_endpoint`, whose implementation delegates to `cluster_remote_endpoint` with no relay. Passing Apple relay settings does not add a relay to the server. Existing M4 results must not be attributed to v5.

**Proposed contract:** preserve the explicit user-operated relay, direct preference, LAN independence, admission and music authorization boundaries; include relay-configuration rotation in the enrollment design. No implicit public fallback.

**Acceptance:** v5 download over a forced relay, direct LAN operation with the relay stopped, interruption/retry, revocation during a session, and visible connection state. Reuse M4 fixtures and deployment controls rather than designing a separate connectivity stack.

### 5. Finish migration around durable source correspondence

**Classification:** partial implementation plus compatibility/acquisition gaps. Candidate: **Connect reviewed Windows migration to v5 source correspondence**.

[The existing CLI](../tools/music-migration/README.md) already supports inventory, reviewed selection, preparation, NAS import/resume, and binding a stopped existing library. It preserves source files and verifies transferred bytes. Do not rebuild this pipeline. Remaining boundaries include automated library-only artwork extraction, embedded/folder fallback, empirical cloud-acquisition integration, and migration into schema 5. Its [NAS helper](../tools/music-migration/nas_import.py) still validates legacy hash-based entries and invokes `cluster-import`; source evidence in a local manifest is not automatically a reusable server correspondence.

**Proposed contract:** use the reviewed `(source library persistent ID, source track persistent ID)` mapping to register or reuse a logical track; store bytes independently. Separate eligibility, acquired audio, metadata/artwork completeness, correspondence approval and destination durability. Retain unknown/protected records for review and preserve later explicit Syncstr edits. Prefer a separate acquisition follow-up if artwork/application automation expands the scope.

**Acceptance:** rerun a reviewed subset without duplicate logical registrations; preserve two registrations sharing one object; change source metadata without overwriting explicit edits; resume after lost acknowledgment; import unavailable records without invented audio. Compare selected ordinary, multi-disc and compilation albums before broader migration. Full-library transfer remains a later user-controlled operation.

### 6. Implement ordinary playlist editing as an offline-capable feature

**Classification:** accepted design, unfinished implementation; new candidate independent of ASO-6/7. Candidate: **Define offline playlist edits and deliver create/add/play**.

The current [Apple browser](../apps/macos/PlaylistViews.swift) and [host persistence](../headless/src/playlists.rs) support imported lists, reconciliation, hierarchy, repeated occurrences, playback and retained signed history. They do not complete the accepted create/rename/add/remove/reorder/folder-edit journey or a durable offline edit queue. Existing XML UX tickets do not own this work.

**Proposed contract:** finalize the playlist plan's operation IDs, occurrence identity, causal base, deterministic independent insertion ordering, concurrent move/rename handling, folder deletion/cycles, and rejected-author recovery. A local success means a durable pending edit; shared success means host acknowledgment. A revoked writer's accepted historical records need a separate rule from its newly submitted edits. Do not rewrite an active playback queue when a list changes.

**Acceptance:** offline create/add/play, restart, reconnect, duplicate retry, two-device independent additions, concurrent moves, deletion versus unseen edit, and selected repeated-occurrence removal. Deliver this vertical slice before the full menu/grid design. Smart-rule execution is a later phase, not a prerequisite.

### 7. Specify recovery and activation as a product operation

**Classification:** operational design gap; new candidate. Candidate: **Design v5 activation, backup and recovery with preserved identities**.

v5 requires identical activation baselines across hosts and rejects old writers; binary rollback alone is unsafe after schema-5 writes. ASO-12 deliberately excludes production activation. The [headless guide](../headless/README.md#storage-and-recovery) provides stop-and-copy instructions, and the migration tool requires rehearsal on a restored copy, but the old [operations plan](plans/operations-plan.md) is explicitly historical. There is no established current end-to-end recovery/rollout contract in the reviewed artifacts.

**Proposed contract:** inventory host divergence and pending client writes, establish a reviewed baseline, snapshot database/audio/organization/artwork/history and necessary identities/configuration consistently, validate an isolated restoration, then activate in a compatible order. Define forward repair and coordinated pre-activation restore, including how later edits are preserved or reconciled. Do not run a copied host identity concurrently with its original. Treat replicas and backups as different protections.

**Acceptance:** restore to a disposable location and verify membership, aliases, playlists, exact audio pins, artwork and hashes; simulate one unavailable host, stale clients and a failed activation. Define recovery when the final host key is lost and clear incomplete-replication/capacity reporting. Keep automatic object GC and permanent purge deferred until reference retention and recovery rules are specified.

### 8. Complete cluster setup and library-host roles

**Classification:** accepted direction with deliberately deferred UI; new design candidate. Candidate: **Design cluster creation and library-host lifecycle**.

The cluster model permits a storage-rich Windows desktop to act as a host, while the [Windows guide](../apps/windows/README.md) explicitly excludes library hosting. [The Apple interaction contract](cluster-ui-review.md) also excludes new GUI cluster creation and role assignment. Existing CLI setup is real functionality; a self-contained consumer setup journey is not finished.

**Proposed contract:** offer local-only use and joining an existing cluster first; separately design creation and choosing a complete-library host. Specify promotion, demotion, disk-full/partial replication state, and removal of the final usable replica. A playback-only device must not accidentally gain cluster deletion authority. Defer implementation until the target audience and supported setup path are confirmed.

**Acceptance:** a fresh install can reach playback through the selected supported path; changing roles preserves identity/library references and reports incomplete replicas; users can distinguish freeing this device's space from deleting shared music.

### 9. Define what “supported” means on Windows and Android

**Classification:** product parity decision beyond ASO-10/11's v5 contract. Candidate: **Set the daily-playback baseline for additional platforms**.

Both platforms have working initial implementations, not absent clients. However, they are not equivalent to the Apple player. In [Android MainActivity](../apps/android/app/src/main/java/as/ason/syncstr/MainActivity.kt), `onStop` pauses playback and completion only updates presentation; it is not a background queue player. [Windows](../apps/windows/src/main.rs) provides saved-track play/pause, while its guide excludes remote access, hosting and distribution. ASO-10/11 will not automatically deliver these additional behaviors.

**Proposed contract:** choose whether the first supported release requires background/lock-screen playback, continuous album queues, media controls, automatic acquisition and relay access. Separate Windows host capability from playback support. Add platform-specific work only after that baseline is agreed; keep packaging/signing/store release as separate delivery gates.

**Acceptance:** common user-journey matrix plus explicit platform exceptions, with real audio, restart and interruption checks. Do not label protocol conformance or an APK/build as complete daily-use parity.

### 10. Make acceptance evidence match the delivered feature

**Classification:** extend existing ASO-5/9/12; create only a separate release/rollout ticket if needed.

PR #15's four CI checks are green. Its new [v5 UI test](https://github.com/asonas/syncstr/blob/c2a7df31a8e62098524ddf60a5840f64e25db68e/apps/ios/UITests/SharedAudioFlowTests.swift) explicitly skips without `SYNCSTR_V5_FIXTURE_ROOT`, and its real-server Swift test is enabled only when Rust fixture binaries exist. The workflow does not provision those prerequisites in the Apple jobs. The Simulator runner checks for some passing tests, not execution of each required v5 case. CI success alone therefore does not close the recorded v5 interoperability/UI gaps; individual final-revision test outcomes still need confirmation.

**Proposed contract:** required acceptance cases must report executed/passed, skipped, or blocked by exact build. Keep fixture generation reproducible and fail the relevant acceptance gate if required fixtures are missing. Preserve targeted regression CI while making the broader release matrix explicit.

**Acceptance:** ASO-5 real-operation baseline, ASO-9 final iOS and library presentation, ASO-12 cross-platform shared audio, and the [M3 remaining manual cases](cluster-apple-m3.md#verification-record-and-outstanding-gates) have named owners and evidence. Integration, distribution, production activation and physical-device acceptance remain separate states.

## Explicitly deferred or requiring a new product decision

| Feature | Decision needed before making an implementation ticket |
| --- | --- |
| Native smart playlists / full iTunes smart-rule compatibility | Already sequenced after ordinary playlists. Define supported typed predicates, missing values, shared evaluation completeness, relative dates/time zones, limits and dependency cycles. Preserved blobs and fixed snapshots are implemented building blocks, not an evaluator. |
| Favorites, ratings and listening history | Present in the original ambition, excluded from current migration/playlist slices. Reconfirm scope and conflict/retention semantics; do not infer them from old server plans. |
| Cross-device playback handoff | Current queue/position/shuffle/repeat are explicitly device-local. Decide whether handoff is wanted and how concurrent playback should behave. |
| Gapless playback, transcoding, progressive playback, queue editing | Deferred by current contracts. Whole-file verified acquisition is intentional. Measure startup limitations and establish codec/platform requirements before changing this boundary. |
| Application license and public distribution | License is still undecided in README. Resolve before open-source release and review actual distribution prerequisites separately; bundled dependency notices are not an application license choice. |

## Recommended sequence and review decisions

1. Reconcile the product document hierarchy and ASO-5/9 statuses against evidence. Retain ASO-6/7 and ASO-10/11/12 as existing work. Do not close historical GitHub #12 solely because a local-transfer milestone once passed.
2. Keep PR #15 Draft while finishing ASO-9's acceptance and the projection/incomplete-history repairs. Decide whether v5 is a read/play-only experiment or the next full product baseline. Recommendation: keep it experimental until existing mutation, enrollment and remote-access paths have explicit coverage.
3. Design the v5 mutation, enrollment, remote and recovery contracts; connect the existing migration CLI. These define whether production activation can preserve today's use, and should precede a rollout ticket.
4. Deliver ordinary playlist create/add/play with durable offline edits. Complete the already scoped XML performance/UX work once ASO-5 supplies its actual baseline.
5. Choose the supported setup/host-role and Windows/Android daily-use baseline. Schedule smart rules and the remaining long-term features afterward.

The decisions needed from the owner are the next release boundary, the first-class setup/platform baseline, and the priority of ordinary playlist editing versus later listening-history features. Existing preservation rules and explicit source-match approval do not need to be reopened. Each new candidate above should become a design issue with its stated acceptance boundary; implementation tickets can follow once the remaining choices are settled.

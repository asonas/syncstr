# Shared playlists and Music XML migration

Status: implementation plan with a server-catalog review tool. Product scope and
offline behavior were agreed on 2026-10-21. Storage and protocol details below
are proposals requiring the Phase 1 contract checks. Playlist persistence,
destination import, and application presentation have not been implemented.

## Agreed scope

- Deliver ordinary playlists and XML migration first. Add smart-rule
  compatibility incrementally afterward.
- Let the user select which source playlists to migrate. Whole-library playlist
  import is not the default.
- Playlists belong to the shared library and synchronize across devices.
  macOS, iPhone, and iPad can create and edit them.
- Use the existing server catalog as the migration destination. A device's
  downloaded or cached subset is not the matching baseline. Existing audio is
  reused; playlist restoration does not acquire or copy it again.
- Save edits locally while offline and synchronize after reconnecting.
- Preserve independent additions from different devices. Retain concurrent
  renames and conflicting moves for explicit resolution; wall-clock timestamps
  do not silently choose a winner.
- Keep recently used addition destinations local to each device, ordered by
  the most recent successful local addition, including an offline addition.
- Keep library browsing (Recently Added, Artists, Albums, Songs) separate from
  the Playlists sidebar section.

The supplied playlist research memo is feasibility input. A subsequently supplied
Windows iTunes XML has been parsed read-only for structural inventory, and a
recovered audit report has undergone exploratory smart-rule decoding. Semantic
correctness and source-application equivalence remain unverified. The existing
[music migration policy](music-library-migration-plan.md) still governs audio
eligibility and metadata precedence. This feature adds playlist migration; it
does not automatically include ratings, play counts, favorites, or listening
history. Source-library mutation and deletion are outside scope.

## Design references

These are editable proposals, not implementation or device-verification evidence.

| View | Figma |
| --- | --- |
| Sidebar sections and rule editor | [Parts](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=166-43) |
| All playlists | [Grid](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=170-145) |
| Smart detail | [Detail](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=170-476) |
| Ordinary detail | [Detail](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=170-681) |
| Add and reveal menus | [Menus](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=170-892) |

Use native platform controls and the current [design guidance](../DESIGN.md).
Wide details align Shuffle, Play, and Save with the artwork bottom. Mobile
adaptation, migration results, and conflict resolution need additional design
states before their UI implementation.

## Existing implementation and boundaries

| Boundary | Source and implication |
| --- | --- |
| Catalog identity | `headless/src/model.rs`, `apps/macos/Track.swift`: catalog track IDs and audio hashes have different roles |
| Album organization | `headless/src/organization.rs`: track aliases exist; playlist references must survive canonicalization without changing album membership |
| Persistence | `headless/src/store.rs`, `apps/macos/CatalogDatabase.swift`: add migrations and playlist projections without rebuilding existing catalogs |
| Signed records | `headless/src/cluster_changes.rs`, `apps/macos/ClusterChanges.swift`: current records describe audio objects and require a host author |
| Offline edits | `headless/src/cluster_client.rs`, `apps/macos/ClusterTransport.swift`: existing metadata queues provide a host-submission pattern, not a playlist protocol |
| Presentation | `apps/macos/Library.swift`, `apps/ios/Sources/PhoneRoot.swift`: extend destinations and shared catalog presentation |

Do not encode a playlist as fake audio metadata or grant phones host privileges
merely to permit playlist edits. The proposed path is a durable client edit
queue, authenticated submission to an authorized host, and replicated host-
accepted playlist records. Local pending edits overlay accepted state.

## Proposed data contract

| Entity | Required information |
| --- | --- |
| Playlist | Stable ID, name, manual/smart kind, parent folder, revision/deletion state |
| Folder | Stable ID, name, parent folder; cycle-free hierarchy |
| Playlist item | Independent stable occurrence ID, playlist ID, track reference, ordering information |
| Edit | Stable operation ID, originating member, causal base, target, operation payload |
| Source mapping | Source library ID plus source track/playlist identity mapped to Syncstr identity |
| Import record | Source fingerprint, original definition, exported membership, unresolved references, import baseline and outcomes |
| Smart definition (later) | Versioned condition tree, selection/order, limits, update policy, execution support state |

Select the logical track-reference contract in Phase 1 against catalog IDs,
organization aliases, and replicated object identity. A content hash is file
evidence, not a universal logical identity. Playlist names are not identifiers.
Two appearances of the same track have different occurrence IDs. Playback and
removal must address the selected occurrence, not only the track ID.

## Synchronization and conflict behavior

Implement and fixture-test these contracts before building the full UI:

- Persist an edit and its local projection atomically before reporting success.
  Retain it across restart and retry until a durable acknowledgment is recorded.
- Deduplicate by operation ID across retries and different hosts. The host must
  retain the submitted causal base; acceptance order must not disguise a
  concurrent edit as a later intentional edit.
- Distinct additions survive merging, including two intentional additions of
  the same track. Define deterministic ordering for simultaneous insertions at
  the same position without depending on device clocks.
- Concurrent renames and competing moves of the same occurrence retain both
  alternatives. A resolution references the competing revisions and itself
  synchronizes. Pending conflicts must not cause different devices to render
  unrelated arbitrary states; specify the temporary projection in Phase 1.
- Recommended deletion behavior: deletion versus an unseen edit is retained
  as a conflict, not silent resurrection or silent loss. Folder deletion must
  disclose its affected descendants. Confirm these details in Phase 1.
- Revoked/unauthorized edits remain visible as failed local changes with an
  explanation and discard/retry path; they are not accepted into shared state.
- Add a version/capability boundary. Old clients must neither erase playlist
  data nor lose ordinary catalog synchronization on unknown playlist records.
  Determine the actual upgrade behavior in mixed-version tests.
- New devices fetch the accepted playlist catalog independently of downloaded
  audio. A partial local audio library must not prune playlist membership.

Recent addition destinations are device-local UI history, not replicated
playlist mutations. Resolve displayed names by stable ID, remove deleted
destinations, and do not promote a destination merely because XML was imported.

## XML migration behavior

### Selective import tool

Provide a list/select/preview/import flow rather than importing every playlist.
The initial CLI should produce a reviewable selection manifest; an eventual GUI
can use the same selection contract. Identify selections by source library and
playlist persistent IDs, not display names, and bind the manifest to the source
fingerprint. A changed export requires a refreshed preview before execution.

- List ordinary playlists, smart snapshots, and folders with names, hierarchy,
  counts, and migration/support state. Start with nothing selected; offer Select
  All as an explicit action, not an implicit default.
- Selecting a folder expands to its descendant playlists and shows that list
  before import. Preserve the minimum ancestor hierarchy of selected lists;
  importing one child does not implicitly import its siblings. Allow individual
  descendants to be deselected. Exclude system-generated collections by default.
- Preview selected list counts, occurrence counts versus unique referenced
  tracks, matched and unresolved tracks, and fixed-snapshot warnings. Selecting
  a playlist does not authorize downloading or importing its missing audio.
- Import only the confirmed selection and retain per-playlist outcomes so failed
  items can be retried. Reimporting a subset does not delete previously imported
  but currently unselected playlists. Existing explicit Syncstr edits remain
  protected by the import-baseline policy below.
- Show smart-list dependencies in the preview. Do not silently add unselected
  dependencies; preserve the list as a snapshot until dependencies and rule
  semantics can be supported explicitly.

This tool depends on playlist persistence and the destination import boundary.
The recovered audit tool remains read-only and is not relabeled as an importer.

The initial preparation commands are implemented in
[`tools/playlist-audit`](../tools/playlist-audit/README.md#server-catalog-review).
They export a consistent server metadata snapshot read-only, list selectable
playlists, and offer metadata candidates for explicit review in CSV files.
Unique metadata candidates are not verified file matches and are not accepted
automatically. Prepared data retains the server library and cluster identities,
logical track IDs, content hashes, source fingerprint, unsupported smart blobs,
and unresolved occurrences. This preparation output is not itself an import
request; the native app reads the original XML and obtains a fresh server catalog.

The initial native import path is implemented in `apps/macos/Playlists.swift`
and `PlaylistViews.swift`, with host persistence in `headless/src/playlists.rs`
and the authenticated `syncstr/playlists/1` protocol in `playlist_sync.rs`.
Accepted records are signed by a library host, stored transactionally, and
replicated separately from audio. Native clients verify signatures before
persisting their cache and cursor together. Host-to-host reconciliation and the
Rust playback client also retain these records. Older peers can continue using
the audio protocol; playlist migration requires an upgraded host.

In the Apple apps, open **Playlists → All playlists → Import from XML**, choose
lists (initially none), then explicitly accept metadata candidates. Unresolved
occurrences retain their source position. Parent folders, duplicate occurrences,
and opaque smart definitions are preserved. No source audio is read or uploaded.
The host verifies every accepted logical-track ID and content hash against its
current catalog before committing the whole selection. Repeating the identical
import is a no-op. Different content for an existing source playlist is rejected
instead of overwriting it. Competing host records remain stored and are flagged
in the Apple UI, which disables playback of that conflicted list.

This initial slice does not implement playlist editing, rule execution, conflict
resolution, or reconciliation of a changed XML export. The review draft is kept
in the open sheet, not in a durable offline edit queue. The server acknowledgment
is required before success is shown; retrying the same selection is safe. Cached
lists remain available offline, while the migration itself requires a host.
Android and Windows retain synchronized records through the shared Rust client;
their playlist presentation is not included in this slice. A revoked author
causes signature authorization to fail closed rather than silently discarding
the affected records. Historical-author recovery is a separate follow-up.

Do not write directly into a running server database. Deployment and a selected
production import are separate steps from local build and fixture verification.

### Verification of the initial import slice

- Rust integration tests cover atomic selection, stale destination references,
  idempotent retries, overwrite rejection, retained unresolved occurrences,
  signature tampering, authenticated transfer, and restart persistence.
  Existing cluster-client and replica tests also pass (nine tests together).
- Native XML tests cover explicit selection and candidate acceptance, ambiguous
  candidates, minimum folder ancestry, smart bytes, and repeated/missing tracks.
- The native/Rust interoperability test obtains a server catalog, imports a
  snapshot containing resolved and unresolved occurrences, retries it, and
  verifies the signed cache after reopening SQLite without downloading audio.
- Playback interaction tests cover selecting the last occurrence of a repeated
  track and navigating backward/forward without jumping to its first occurrence.
- The macOS suite passes (96 XCTest cases, two environment-specific skips, and
  31 Swift Testing cases). Focused checks after the final changes also pass.
  macOS and iOS Simulator builds pass; the audit/review Python suite has 11
  passing tests. Rust Clippy passes with warnings denied.
- Production rollout, real-device playback, and visual inspection of migration
  states in narrow/wide windows, appearance modes, and accessibility settings
  remain unverified. The initial browser is a grouped native list; the full
  Figma grid and editing/context-menu interactions remain Phase 4 work.

Start with a read-only inventory and preview. The XML references audio; this
feature must not imply it transfers audio automatically. Use the existing
owned-music migration policy for audio acquisition and source correspondence.

1. Inventory folders, manual lists, smart lists, ordered occurrences, missing
   source IDs, and unsupported or malformed definitions. Parse with external
   entity resolution disabled and explicit input/resource bounds.
   Classify folders and system-generated lists before inspecting smart blobs:
   the inspected export includes smart data and membership on folder records.
   Preserve that source data without importing folder membership as a second
   editable playlist. System markers and names require separate handling;
   absence of a system marker does not establish that a list is user-created.
2. Resolve source references using recorded source mappings and verified file
   correspondence. Never guess from title alone. Report eligible-but-unmatched,
   unavailable, excluded, and ambiguous tracks separately.
3. Preview counts and exceptions, then import transactionally into an isolated
   test library. Preserve folder hierarchy, repeated occurrences, and missing
   item positions. A later verified audio import can resolve a missing item.
4. Make reruns idempotent using source identities and the previous import
   baseline. Source updates must not silently overwrite Syncstr edits. Reordering
   repeated source tracks requires explicit occurrence matching; surface
   ambiguity rather than deleting or duplicating occurrences by guesswork.
5. Preserve smart definitions and exported membership separately. Before rule
   translation is supported, label the result as an imported fixed snapshot
   with unsupported-rule information, not as an automatically updating list.
   An ordinary editable copy can be offered without overwriting the source
   definition. Do not pretend snapshot edits modify executable smart rules.

The first migration entry point is proposed as a headless/CLI inventory,
preview, and import flow usable alongside the Windows migration work. A GUI
file picker is not a dependency of ordinary playlist editing. Actual source
application and export compatibility remain to be checked with a sample.

## UI and playback acceptance

- All playlists separates folders, smart lists, and ordinary lists. Folders
  navigate into their contents and have sidebar disclosure where appropriate.
- Ordinary details support creation, rename, move to folder, delete, add/remove
  occurrences, reorder, search, play, shuffle, and save through existing paths.
  Playlist deletion/removal does not delete library audio.
- Add to Playlist shows New Playlist, recent device-local destinations, then
  ordinary destinations with folder navigation. Smart lists are not manual
  addition destinations. Provide the same action for multi-selected tracks.
- Show in Playlist includes ordinary and supported smart memberships. Navigate
  to the target and reveal/select the track. For repeated occurrences, reveal
  the first occurrence in the displayed order and preserve the others.
- Treat fixed imported snapshots as such in both destination lists and details.
  Clearly indicate unavailable tracks and pending synchronization/conflicts.
- Building a queue from a playlist preserves repeated occurrences. Subsequent
  edits do not silently rewrite the active queue. Test this against the existing
  playback contract before claiming support.
- macOS, iPhone, and iPad receive equivalent operations with native platform
  interactions. Android and Windows protocol compatibility is part of the
  rollout; playlist-editing UI on those clients is not yet committed scope.

## Delivery phases and gates

| Phase | Deliverable | Completion gate |
| --- | --- | --- |
| 1. Contracts and sample inventory | Resolve logical identity, order/merge projection, deletion conflicts, host submission, capability boundary; inspect a representative XML read-only | Rust/Swift fixture examples cover duplicate occurrences, concurrent edits, retries, and source matching; unresolved product decisions are explicit |
| 2. Shared manual-playlist core | Persistence migrations, edit queue, host acceptance, replication, conflict resolution | Two devices converge after restart/reconnect; independent additions survive; unauthorized writes fail; old catalog data and signatures remain valid |
| 3. XML import | Inventory/preview/import/resume and fixed smart snapshots | Hierarchy/order/duplicates preserved; unresolved items retained; repeat import creates no duplicates and protects explicit edits |
| 4. Apple UI | Figma lists/details/menus, folder navigation, editing, playback/save, migration status and conflict states | Core journeys pass on macOS, iPhone, iPad; keyboard, touch, narrow layout, long names, and offline indicators are checked |
| 5. Native smart lists | Versioned evaluator for supported typed fields and operators | Shared-library evaluation has defined completeness, missing-value, relative-date, and time-zone semantics; partial clients do not replace authoritative results |
| 6. Smart XML compatibility | Decode real exported definitions and translate supported semantics | Compare complete translations against source settings and exported membership; unsupported rules/limits/dependencies remain explicit and preserved |

Phase 4 can start with the minimal create/add/play journey after Phase 2 to
validate the core, while XML work proceeds in sequence. Do not delay this
feedback until all screens have been implemented.

For Phase 5, begin with title, artist, album, and shared addition time only after
their typed semantics are fixed. A source library's historical addition date
must remain distinct from Syncstr's shared-library addition date. Missing
ratings/history are unknown, not zero. For Phase 6, inventory nested all/any,
limits and selection, live updating, and playlist dependencies; detect cycles.
Do not promise full iTunes compatibility from successful predicate decoding.

## Focused verification and next action

The [recovered audit and smart-rule investigation](validation/playlist-recovery-and-smart-rules.md)
records the recovered tool, passing tests, pinned exploratory decoder, and
compatibility limits. Structural decoding has progressed; source UI and evaluated
membership equivalence remain open. Preserve source addition dates and nested
all/any groups as early smart-migration requirements.

Use shared serialized fixtures for Rust/Swift contracts and signed compatibility.
Use real persistence/replication boundaries for restart, retries, disconnection,
conflict resolution, and old-schema migration. Test import twice, interrupt and
resume it, then import changed source data after a local edit. Exercise duplicate
track playback, stale destinations, folder cycles, missing audio, malformed XML,
and preservation of unsupported smart data. Use a small UI suite for the core
journeys rather than mirroring every model branch in E2E tests.

The next implementation task is Phase 1. A subsequent Windows audit report
describes successful local byte-read checks, missing referenced files, and
protection/subscription evidence. This is supplied report evidence, not a scan
rerun on this Mac. The Windows export was newer than the planning export;
matching totals do not establish record-level equivalence. Keep the source
fingerprint with every result rather than joining reports by track count.

The audit did not establish migration eligibility, complete file integrity, or
playback. Windows UI automation and iTunes COM access were unavailable, leaving
the active library, application version, displayed order, and smart-rule dialogs
unverified. Ordinary playlist contract and importer development can proceed;
source UI comparison and actual audio eligibility remain gates for sample
migration acceptance, not prerequisites for all development. The Windows audit
tool has been recovered under `tools/playlist-audit`; reuse it for inspection.

Read-only structural inventory of the
supplied Windows export confirms repeated track occurrences, folder smart blobs,
Windows file URLs, and records with no file location. Preserve those cases in
fictional fixtures. A Windows file URL is source correspondence evidence, not
proof that audio exists on this Mac or remains available on Windows. Binary
rule semantic validation, source-settings comparison, audio availability, and correspondence
with the destination Syncstr catalog remain open. Do not access the personal
Music database as a substitute. Keep raw exports,
paths, device identities, and private logs outside published docs and fixtures.
Commit only fictional fixtures. Full-library import, production rollout, and
physical-device verification remain separate from this plan.

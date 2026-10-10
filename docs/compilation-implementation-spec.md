# Compilation album implementation

Status: approved and implemented locally. See the [verification record](validation/compilation-albums.md) for completed checks and remaining limits.

This specification implements the [agreed retention policy](compilation-data-design.md). It covers local import, native catalog persistence, Mac-to-iPhone transfer, and the headless catalog and P2P transfer. Playlists, source-tag editing, deployment, and distribution are excluded.

## Data and persistence

- Preserve existing track IDs. Store imported album title, artist, album artist, compilation assertion, and external release identifiers independently of effective organization. Missing compilation assertions remain unknown; retain unrecognized raw values without treating them as false.
- Create an album record with a random UUID, source-qualified external release identifiers, and former-ID aliases. A track's imported release identifier is not its Syncstr album ID.
- Store imported membership evidence separately from explicit track membership choices. Store an album compilation override separately from each track's imported assertion. Clearing an override returns to imported interpretation.
- Persist organization separately from currently available entries. Keep unavailable track identities and their last known evidence; exclude unavailable files from playback and file-serving operations.
- Persist explicit choices as identifiable revisions, including their parent revisions. Clearing a choice is a retained revision, so an older peer cannot silently restore it. Identical revisions are idempotent; a descendant supersedes its ancestors; concurrent incompatible revisions remain unresolved. Wall-clock time is not a conflict resolver.
- Make schema migration transactional. Preserve legacy JSON, audio objects, artwork, existing track IDs, and received-file records. A failed migration must leave the previous catalog intact. Do not backfill absent tags with invented values.

## Import and membership

1. Verify the pinned metadata dependency's actual output using MP3, FLAC, and M4A fixtures before implementing adapters. Read album artist, compilation, and MusicBrainz release ID where supported. Do not confuse release-group or recording IDs with edition identifiers. Unsupported fields remain unknown and are documented.
2. Match an existing track by the existing saved source association, or by a unique exact content digest when it moves. A changed file at the same path is not sufficient evidence to attach explicit choices: preserve the old organization and offer explicit reassociation. Metadata-only file changes that cannot be proven to be the same track also require reassociation.
3. Assign new tracks with a shared source-qualified release ID to one album unless explicit choices prevent that assignment. Distinct release IDs remain separate even when titles match. One release ID spans discs.
4. Without release evidence, retain existing album boundaries during migration and give them stable IDs. For newly imported tracks, use provisional groups within one source directory with matching album titles and compatible concrete album artist credits (otherwise matching track artist credits). Directory changes never change an established album ID.
5. Propose joining provisional groups when folder and album-title evidence suggests a compilation. Show the tracks and evidence before confirmation; do not silently combine the groups. Multi-disc candidates require confirmation when no release ID establishes their membership. Retain accepted and dismissed proposals with their evidence so unchanged rescans do not repeat them.
6. Rescans refresh imported metadata, preserve choices, and retain missing identities. An empty or unavailable source must not erase organization. Return a scan error without replacing the catalog when scanning fails.

## Classification and display

Without an override, expose imported evidence as unknown, positive with incomplete metadata, explicit true, explicit false, negative with incomplete metadata, or conflicting. Mixed true and false remains conflicting. Multiple artists never infer a compilation flag. An override supplies the effective classification while leaving the evidence inspectable.

Use a concrete album artist only when participating tracks share that credit. Otherwise list distinct track artist credits in disc/track order. Retain Various Artists in imported metadata, but do not use it as the album label when actual participating credits are available. Reuse existing text wrapping/truncation and provide the complete credits to accessibility and search. Each track row and player keeps its own artist credit.

## Native interactions

Use native sheets reached from album and track menus on both platforms; follow [DESIGN.md](../DESIGN.md).

- Album organization: show members, unavailable members, imported classification evidence, and a three-way override control (use imported tags, compilation, not a compilation).
- Track organization: choose an existing album or create an album from selected tracks. Confirmation records explicit membership; cancellation writes nothing. Do not offer arbitrary artist or source-tag editing.
- Membership proposals: show candidate albums, tracks, and evidence; accept or dismiss. Acceptance explicitly assigns membership and keeps former album references resolvable when complete albums are merged.
- Conflicts: show local and incoming organization. Keep local behavior until the user chooses local, incoming, or a manual membership. Resolution creates a revision descending from all resolved choices.
- Reassociation: let the user select an unavailable track identity and its replacement, confirm the association, and preserve the original identity and choices. Do not select a replacement automatically from similar titles.
- Removing a membership override restores current imported assignment; if that evidence cannot determine membership, retain a provisional album and offer a proposal. Removing an album classification override leaves membership unchanged.

Saving updates grouping and selection atomically and returns to the originating view. Cancelling returns without changes. Organization changes do not interrupt active playback or reorder its existing queue. All operations persist across restart and work offline on the iPhone.

## Transfer and reconciliation

- Add an explicitly negotiated organization-capable protocol version to Bonjour, P2P, and the headless API. Transfer album records, aliases, imported evidence, memberships, choice revisions, proposal decisions, and unresolved choices alongside entries; never rewrite audio. Do not transfer host source paths.
- An older peer must produce a clear compatibility error when organization would be lost. Do not silently downgrade a catalog with explicit choices. Retain existing saved catalog and files on failure.
- Validate bounded payloads, unique IDs, alias cycles, revision relationships, and member references before a transactional catalog merge. Preserve referenced unavailable identities without requiring an audio entry.
- Adopt incoming explicit choices when there is no competing local revision. Preserve local effective organization and incoming revisions for concurrent incompatible choices. Refresh imported information even when the corresponding audio is already saved.
- Reconcile independently created album IDs only with matching source-qualified release evidence and no conflicting explicit choices. Choose a deterministic surviving ID and retain aliases for former IDs. Without release evidence, require confirmation. Conflicts must be resolved before merging.
- Headless ingestion may retain its own track IDs, but must preserve incoming album identity and maintain the track-reference mapping for organization. Duplicate audio uploads must merge organization rather than discard it or clear album IDs.
- Catalog refresh, upload, and album copy must all preserve organization. The phone retains organization for unsaved or temporarily unavailable tracks, independently of downloaded audio.

## Delivery and verification

Implement these stages in one feature branch; a stage passing tests does not mean the complete feature is implemented.

1. Metadata fixtures, organization model, SQLite migration, and legacy restoration.
2. Rescan identity, retained unavailable organization, membership proposals, and album labels.
3. Versioned native/headless transfer, reconciliation, revision conflicts, and former-ID references.
4. Native organization, confirmation, reassociation, and conflict-resolution sheets.

Verify observable contracts with real temporary catalogs and files:

- Each agreed example in the retention document, including missing versus false assertions and multi-disc editions.
- Migration rollback and reopening; old track IDs and original audio digests remain unchanged.
- Rescan, move, replacement at the same path, unavailable source, restart, and explicit reassociation.
- Clear-override transfer, duplicate and out-of-order revisions, competing membership and classification choices, repeated catalog refresh, and alias resolution.
- A real Mac-to-phone catalog round trip and headless upload/download round trip, including saved audio receiving updated organization and rejection of incompatible peers.
- Existing transfer, catalog migration, and playback checks; macOS and iOS builds/tests and headless tests.
- Native sheets on both platforms: confirm, cancel, override removal, proposals, conflicts, narrow layout, long credits, and accessibility text sizes. Record screen checks separately from automated tests and physical-device transfer/playback.

Do not update the retention document or README to claim implementation until all required behavior is delivered. Report any unsupported tag format or verification gap explicitly.

# Compilation album data

Status: agreed data-retention policy, implemented locally through the [implementation specification](compilation-implementation-spec.md). This document records the policy; the [verification record](validation/compilation-albums.md) distinguishes verified behavior from remaining limits.

See the [glossary](../GLOSSARY.md) for terminology.

## Agreed directions

- Preserve original artist tags, including an existing Various Artists value. Do not synthesize Various Artists when an album artist is absent. Keep track artist credits independently.
- Scope compilation albums to multi-artist collections released or distributed as one album. Personal selections belong to the playlist concept; this does not authorize implementing playlists.
- When tags cannot establish album membership, allow the user to identify tracks as belonging to one album and retain that choice in Syncstr's catalog without rewriting the original files.
- Retain imported compilation classification as explicit true, explicit false, or unknown. Missing tags mean unknown. Preserve disagreements between tracks rather than silently replacing them with an album-wide value. Multiple track artists alone do not establish compilation status; user corrections are allowed.
- Transfer album membership and compilation classification with the catalog, including user choices, so an album grouped on the Mac remains grouped after copying to the iPhone. This information accompanies the audio without rewriting it.
- Treat one released or distributed edition as one album. Standard and deluxe editions remain separate; discs within a multi-disc release belong to the same album. Matching titles alone do not establish membership.
- Keep imported tag values separate from user overrides. A rescan updates imported values without discarding explicit user choices; overrides take precedence until removed. Removing an override restores tag-based interpretation. The implementation specification defines track matching and album membership changes.
- Use a shared, concrete album artist credit when present. If the album artist is absent or is Various Artists, show actual participating track artists, such as Artist A, Artist B, and others, while retaining the imported tags. Track lists continue to show each track's own artist credit. This agrees the display policy, not a particular layout or truncation threshold.
- Assign a Syncstr album ID even when no external release ID is available. The internal ID identifies the album independently of its title, artist tags, or folder location and accompanies the album on transfer. Independently importing the same release on two devices may initially produce different internal IDs; reconcile them using the policy below.
- Use a shared external release ID as evidence for automatic grouping within the agreed edition boundary, subject to explicit user overrides. Without an external release ID, use folder and album-name similarities to propose compilation membership for user confirmation rather than silently combining albums. Persist confirmed membership so a rescan does not ask the same question again.
- Apply user corrections to compilation classification at album level while retaining each track's imported classification. With no override, an album with some tracks marked true and the rest untagged retains the distinction between positive evidence and incomplete metadata. Do not pretend that every track has an explicit true tag.
- When transferring organization data, adopt a peer's explicit choice where there is no competing local choice. If explicit choices conflict about membership or classification, preserve the existing local organization and retain the incoming choice for user resolution. Arrival time alone must not choose a winner.
- Reconcile independently created albums automatically when their external release identifiers match, including the identifier source, and there are no conflicting explicit user choices. Retain one album identity while keeping references through the former IDs resolvable. Without external release evidence, propose a merge for user confirmation; resolve conflicting explicit choices before merging.
- Retain album membership and user choices when source files are unmatched or temporarily unavailable. Restore the association when the same track is identified again. If identity cannot be established, require explicit reassociation rather than attaching choices to a guessed match. File absence alone must not delete organization data.

These directions preserve [D-004](decisions.md), which protects original audio. Corrections apply to catalog organization and do not rewrite source tags.

## Retained information

This is a conceptual data model, not a database schema or transfer protocol.

| Information | Purpose |
|---|---|
| Syncstr album ID | Stable internal identity for one album across naming changes and transfers |
| Former album ID references | Keep existing references resolvable after independently created albums are merged |
| External release ID and its source | Optional evidence for matching imported tracks and releases; distinct from internal identity |
| Imported track metadata | Preserve original artist credits, album artist credits, album information, and per-track compilation assertions independently of user choices |
| Album membership and its basis | Record which album a track belongs to and distinguish automatic assignments from explicit user choices |
| Album-level compilation override | Apply the listener's classification without overwriting imported track assertions |
| Unresolved peer choices | Retain conflicting explicit organization choices until the user resolves them |
| Organization for unavailable tracks | Preserve membership and user choices independently of current file availability |

Catalog schema 2 stores this organization independently of currently available audio entries. Migration preserves existing track identity and original audio. See [the decision on imported metadata and user choices](adr/0001-preserve-imported-metadata-and-user-choices.md).

## Verified tag conventions

Compilation status can be embedded in each audio file. The metadata format determines the field:

| Format | Field indicating membership in a compilation |
|---|---|
| MP3 with ID3v2 | `TCMP=1` |
| FLAC with Vorbis comments | `COMPILATION=1` |
| M4A/MP4 | Boolean `cpil` |

The field is a classification flag, not an album identifier: two unrelated compilations can both have the value true. Classification and album membership therefore require separate decisions. An absent field supplies no explicit classification; see the agreed policy above for missing and conflicting values.

Sources: [Navidrome tagging guidelines](https://www.navidrome.org/docs/usage/library/tagging/), [Mutagen MP4 metadata documentation](https://mutagen.readthedocs.io/en/latest/api/mp4.html).

## Current implementation

The shared [organization model](../apps/macos/AlbumOrganization.swift) retains imported assertions, stable album identities, revision histories, aliases, and unavailable tracks. [Native import and upload](../apps/macos/LocalCatalog.swift) read compilation, album artist, and MusicBrainz release tags. Native album views consume effective catalog organization while track rows retain their own artist credits. The [headless model](../headless/src/organization.rs) preserves the same transfer contract. External release matching currently supports MusicBrainz release IDs; additional providers are not implemented.

## Agreed examples

| Situation | Required behavior |
|---|---|
| A compilation has different artists on each track and no album artist | Retain the individual credits; do not synthesize Various Artists |
| Three tracks are marked as compilation and seven are untagged | Preserve positive evidence and missing assertions separately; allow an album-wide user correction |
| Some tracks explicitly say true and others explicitly say false | Retain the disagreement, even when a user override supplies the effective album classification |
| Standard and deluxe editions share an album title | Treat them as separate albums; title equality alone is insufficient |
| Disc 1 and Disc 2 belong to one released edition | Keep one album membership spanning both discs |
| The same release has different internal IDs after independent imports | Reconcile on matching external release evidence when explicit choices do not conflict; keep former ID references valid |
| A compilation has no external release ID | Propose membership from available evidence and retain the user's confirmation |
| Source tags change after a manual grouping | Refresh imported metadata while retaining the explicit grouping until the user removes it |
| Peers send conflicting manual groupings | Keep the existing organization and retain the incoming choice for user resolution |
| The source folder is temporarily unavailable | Retain organization data; reconnect only when track identity is established or the user explicitly reassociates it |

## Implementation follow-up

The approved [implementation specification](compilation-implementation-spec.md) defines database migration, supported release evidence, matching, wire format, membership changes, and native interactions. Artist ordering and truncation remain presentation details, not additional storage policy. See the [verification record](validation/compilation-albums.md) before treating local implementation as distribution or physical-device proof.

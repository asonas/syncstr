# Compilation membership and artwork policy review

Status: agreed product policy. All interview decisions, including the cluster-aligned revisions, are confirmed. This review supersedes the external-ID-only automatic compilation grouping rule in the previous [retention policy](compilation-data-design.md). Membership stage A is implemented as recorded in [its verification](validation/compilation-membership-repair.md); artwork stage B is implemented locally as recorded in [its verification](validation/compilation-artwork.md); cluster stage C is implemented locally as recorded in [its verification](validation/compilation-cluster.md). The existing [implementation specification](compilation-implementation-spec.md) describes the earlier implementation. See [the decision record](adr/0003-infer-album-membership-from-retained-import-evidence.md).

## Problem and verified observations

A local compilation with twenty tracks is displayed as separate artist groups in Syncstr while Music displays one album with artwork. Reading the source files through the same AudioTags adapter used by Syncstr finds the same album title and an explicit positive compilation assertion on every track. No album artist or MusicBrainz release identifier is present. Neither AudioTags nor an independent media probe finds embedded artwork; there is no image file in the album directory. Music's library-provided image is accessible through the public API as verified below.

The current implementation reads compilation assertions but does not use them to establish membership. Without external release evidence, it creates provisional groups using directory, album title, and artist credit, and requires confirmation before joining different artist groups. Existing provisional boundaries also survive migration and rescanning.

The review must distinguish album identity, membership evidence, classification, artist credits, and artwork. None is a substitute for the others. External catalog coverage must not be a prerequisite for representing a locally owned release.

## Music library artwork investigation

Music's local scripting dictionary exposes file-track location and artwork raw data. The Apple Events route requires Automation consent in the investigated environment; no consent request or Music mutation was performed.

A separate ad-hoc-signed, non-sandboxed read-only fixture application using the public iTunesLibrary framework successfully matched the first compilation track by its exact file URL. The matching library item reports compilation true, no album artist, and available artwork. Its `artwork.imageData` returns a 125,721-byte, 400-by-400 JPEG matching the cover shown in Music. This is library-provided artwork rather than an embedded image found in the original audio. The framework's underlying storage location, highest available image resolution, and distribution-sandbox behavior are not established by this check.

A second ad-hoc-signed fixture application with App Sandbox and the read-only Music-files entitlement also matches the same file and reads the same artwork byte count, without exporting an image file. App Store signing and the production distribution app remain unverified; the sandbox check does not establish distribution delivery.

This makes Music library artwork a demonstrated acquisition source, without requiring source-tag rewriting, an external release identifier, or a title-only match. It does not make Music a required dependency for standalone folder import.

## Agreed decisions

### Local compilation membership

Tracks in the same source directory with the same nonempty album title and explicit positive compilation assertions form one album regardless of individual artist credits. An external release identifier is not required. Contradictory release evidence and explicit user choices take precedence over this automatic rule.

This changes the previous requirement to confirm every cross-artist merge without an external release ID. The compilation assertion remains classification evidence; the directory and title supply the additional membership boundary. Artist presentation still uses concrete participating credits rather than synthesizing Various Artists.

### Existing catalog repair

Apply the agreed local membership rule to existing automatically created provisional groups as well as new imports. Preserve explicit membership, decisions to keep albums separate, classification overrides, track identities, former album references, and original files. Source metadata may need to be reread before evaluating old catalog entries that lack retained assertions.

### Incomplete positive classification evidence

Within the same directory and album title, at least one explicit positive compilation assertion is sufficient for automatic membership when all other assertions are absent or positive and no release evidence or explicit choice contradicts the assignment. Preserve each track's missing assertion as missing. Explicit negative, unrecognized, or internally conflicting values stop this automatic rule and require review.

### Multi-disc membership

Automatically combine tracks in sibling disc directories beneath one parent when they have one matching nonempty album title, positive and non-overlapping disc numbers consistent within each directory, and either one shared concrete album artist or compatible positive compilation evidence. An external release identifier is not required. Preserve explicit separations and contradictory release IDs; broader or ambiguous layouts remain proposals. Missing discs do not block import: a later compatible disc joins the established album without replacing its identity.

### Music artwork supplementation

When embedded artwork is absent, acquire artwork from the Music library item corresponding to the exact source file. Retain the acquired image in Syncstr's catalog/storage and transfer it for offline iPhone display. Music integration is optional: lack of availability or permission must not block standalone import, and title similarity alone must not select a Music library image.

### Artwork priority and refresh

Use explicit listener selection first, then embedded artwork, recognized album-folder images such as `cover.jpg` or `folder.jpg`, and finally Music library artwork. When participating tracks have different embedded images, select the first available image in disc and track order as the album cover while retaining individual track images. Removing the manual selection restores automatic selection.

Rescanning updates automatically acquired artwork while retaining manual selection. Temporary acquisition failure or unavailable Music access never removes the last stored image. Retained images remain available for offline display on the iPhone.

## Alignment with the cluster model

The [cluster model](cluster-model-design.md) already establishes one shared library, optional partial storage on playback devices, complete-library aims for every library host, retained offline catalog information, and listener-resolved conflicts without device-role or wall-clock winner selection. The following applies those decisions to this review; it does not claim that cluster replication is implemented.

### Artwork is shared library information

An album cover selection belongs to the shared album, not permanently to the Mac or iPhone that selected it. A nonconflicting selection or causally subsequent correction propagates with its image to other members. Concurrent incompatible manual selections produce a visible sync conflict, preserve both images and intentions, and keep an already displayed image as a temporary fallback until the listener resolves the conflict. Resolution propagates as a shared choice; permanently different per-device winners are not the goal. Playback and unrelated synchronization continue.

The agreed source priority applies to known candidates for the shared album, not to device roles. A member without Music access must not discard a library-provided image received from another member. A genuinely higher-priority automatic source may replace a lower-priority automatic source; an incoming automatic candidate never replaces a manual selection. Acquisition failure is not image deletion. Incompatible automatic updates with no supported causal/evidence-based reconciliation retain candidates and require review rather than selecting a winner by arrival time or host role.

Persist image content and acquisition provenance separately from source audio. Library hosts should retain shared image assets with the library; playback devices should cache images needed for retained album presentation without requiring the associated audio to be downloaded. Catalog receipt alone is not proof of durable host storage of an image. Image replacement and cluster-wide deletion must follow the cluster change/deletion model rather than using file absence as deletion evidence.

### Repair can use the cluster, not only the original Mac

Use retained catalog evidence first. If additional embedded metadata is needed, an available, verified replica of the exact same complete audio file on any authorized member can supply it. Automatically select an available source; do not require the listener to choose a host or return to the original importing Mac. Different encodings, masters, or tag-modified files are distinct items under the cluster's exact-content policy and must not inherit choices by title similarity.

Directory-based membership evidence must be retained and shared as import evidence with its source context, without depending on a personal absolute path. Equivalent relative folder names from independent imports are not by themselves shared identity. A host's object-store directory, a playback cache, or a transferred file's new location is not evidence that unrelated source albums belong together. A byte-identical replica can supply embedded tags but cannot recreate missing original-directory evidence. Automatic repair needs enough retained evidence for the agreed membership rules, not merely access to some audio bytes.

When no reachable member or retained metadata supplies sufficient evidence, retain the cluster catalog, grouping, choices, and images. Locally saved audio remains playable; unsaved audio reports that no source is reachable. Resume repair when evidence becomes available or allow explicit organization. Repair changes propagate with album identities and former-ID references; they do not delete original files or reset user decisions. Metadata-only recovery should not require full automatic audio downloads on cellular networks; any necessary audio transfer follows the existing cellular policy.

## Acceptance scenarios

| Situation | Required result |
|---|---|
| Twenty different artists share a source directory, album title, and positive compilation assertions; no release ID exists | One stable album, actual participating credits, original tags preserved |
| Some assertions are positive and the rest absent | Same album; missing assertions remain distinguishable from explicit true |
| Negative or uninterpretable assertions contradict automatic compilation evidence | Retain evidence and offer review; no silent automatic compilation merge |
| Matching titles carry different release IDs or a listener chose to keep groups separate | Preserve their boundaries |
| Sibling disc directories have compatible evidence and distinct valid disc numbers | One album; a later arriving disc joins the established identity |
| Disc layout or numbering does not meet the rule | Offer a membership proposal instead of guessing |
| An older catalog split the compilation automatically | Repair from sufficient evidence while preserving track identities, aliases, and explicit choices |
| Music has artwork for the exact local file but the file has no embedded image | Acquire and retain the library image, subject to higher-priority candidates |
| Another Music track only has a matching title | Do not use its image as an exact-file match |
| Another member supplies higher-priority automatic artwork | Update the shared automatic cover; do not overwrite a manual selection |
| Members make incompatible concurrent manual selections | Warn, retain images and intentions, propagate the listener's eventual resolution |
| Music access fails or all hosts go offline | Keep catalog and stored images visible; locally saved music remains playable |
| Original import source is absent but another member has identical audio and retained import context | Recover evidence and repair without requiring the original Mac |
| Only managed storage paths or similar titles are available | Preserve the existing grouping until sufficient evidence or explicit organization is available |

## Implementation follow-up

No product-policy questions remain open from this interview. The [revision implementation plan](compilation-revision-implementation-plan.md) covers catalog migration, retained import context, image assets and provenance, causal updates and conflict resolution, Music permission handling, native image selection, and integration with the cluster work. Preserve the distinction between implemented single-peer behavior and planned cluster behavior.

Specify deterministic candidate selection within one image source, recognized folder image names/formats, payload bounds, protocol compatibility, and migration rollback during implementation planning. These details must preserve the agreed priorities and user choices. Verify the scenarios above through real catalogs and transfers, plus Music access allowed/denied/unavailable and production sandbox builds. The successful fixture probes do not establish TestFlight or App Store behavior.

## Sources

- [Add artwork to content in Music on Mac](https://support.apple.com/guide/music/add-artwork-mus1c6803257/mac): Music supports artwork in its library; the guide does not establish that every displayed image is embedded in the source audio.
- [iTunesLibrary framework](https://developer.apple.com/documentation/ituneslibrary), [ITLibrary](https://developer.apple.com/documentation/ituneslibrary/itlibrary), and [media item location](https://developer.apple.com/documentation/ituneslibrary/itlibmediaitem/location): public read-only library access, usage-description and authorization requirements, and sandbox music-file access requirements. Framework access was verified separately from the production app's distribution configuration.
- Local source-file probes and the checked-in AudioTags adapter establish the observations above. Personal source paths and original source-file contents are intentionally omitted from this document.

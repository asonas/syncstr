# Incremental Music library migration

Status: design decisions agreed; Windows handoff prepared and feasibility
checks pending. No migration implementation or library mutation has been
performed during the interview.

## Confirmed requirements

- Gradually copy the listener's own music into Headless Syncstr.
- Exclude tracks added through the Apple Music subscription catalog.
- Preserve audio and album/track information, including available artwork.
- Do not migrate play counts.
- Use Windows for audio acquisition and migration, with the NAS as the
  destination library host. The Mac is used for planning and need not hold all
  audio. A rolling download/import/delete cycle is not required.

## Findings

Music on Mac can explicitly export library information as XML through File >
Library > Export Library. The export contains information, not the audio files.
An absent automatically maintained XML file does not preclude explicit export.
See [Apple's export guide](https://support.apple.com/guide/music/save-a-copy-of-your-playlists-mus27cd5060f/mac).

The installed Music scripting dictionary exposes cloud status categories,
including subscription, purchased, matched and uploaded. The SDK's iTunesLibrary
cloud flag also covers matched/cloud items, so it cannot by itself identify
subscription-only tracks. Availability on disk and eligibility for migration
must be assessed separately. Actual data access and classification coverage
still require a read-only sample against the user's library.

Cloud downloads are not necessarily the listener's original encoding. Apple
documents matched downloads as 256 kbps DRM-free AAC. Prefer surviving original
files where available; accepted cloud replacements retain their provenance.
See [Apple's cloud library guide](https://support.apple.com/en-ca/guide/music/musa3dd5209/mac).

Windows iTunes and the newer Apple Music app are different integration targets.
Installing Apple Music changes which application manages music; inspect the
actual Windows installation before selecting automation or export mechanisms.
See [Apple's Windows transition guide](https://support.apple.com/en-ie/guide/itunes/itns5ecc4f3c/windows).

## Implementation starting point

Existing Syncstr components provide partial building blocks:

- `apps/macos/ArtworkAcquisition.swift` can read library-only artwork through
  iTunesLibrary, matching a unique local file URL. Cross-machine matching and
  cloud-only artwork extraction are not established by that implementation.
- `headless/src/main.rs` exposes `cluster-import` for one audio file plus an
  Entry and optional Organization. A new library inventory/batch importer is
  still needed. Transfers verify size and SHA-256.
- Retain source album evidence and organization independently from destination
  hash storage. See the [album membership decision](adr/0003-infer-album-membership-from-retained-import-evidence.md).
- Existing same-content behavior does not establish deduplication across
  encodings or tag changes. Cross-machine Music identifiers are not assumed
  stable. These need explicit matching and repeat-import policies.
- The [historical migration plan](plans/migration-plan.md) includes playback
  history and ratings; it does not define this interview's scope.

1. Inventory library records without downloading all audio. Retain eligibility
   evidence and distinguish eligible, excluded and unresolved entries.
2. Preview counts and representative albums, including compilations, multi-disc
   releases, cloud-only items and subscription tracks.
3. Acquire eligible audio on Windows, preferring existing originals.
   Verify actual file availability and protection state before transfer.
4. Collect library metadata and artwork alongside embedded file metadata.
   Treat library-only artwork as a separate extraction requirement.
5. Import to a test destination, verify audio and metadata, and record progress
   so interrupted or repeated runs can resume without duplicate imports.
6. Repeat against the authorized destination after sample acceptance. Source
   deletion and library modification are outside the initial proposed flow.

Inventory, acquisition and migration should use the Windows source library so
cross-machine Music identifiers are not required in the MVP. Artwork coverage,
destination authorization and repeat-import behavior still require validation.

## Agreed decisions

The listener accepted the following recommendations and topology correction:

- Include personally imported, purchased, matched and uploaded music when
  obtainable as unprotected files. Exclude subscription-catalog entries and
  hold uncertain classifications or protected files for review.
- Prefer surviving original files. When unavailable, accept cloud-retrieved
  copies while recording their origin; do not claim original fidelity was
  recovered. Migration does not require transcoding the acquired file.
- Prefer Music/iTunes library metadata and artwork over conflicting embedded
  values. Retain the source distinction and use embedded values as fallback.
  Play counts are excluded. Source-import precedence remains subordinate to
  explicit edits subsequently made in Syncstr.
- Run acquisition and migration on Windows and retain the migrated collection
  on the NAS library host. Do not build source-audio deletion or a rolling
  disk-reclamation mechanism. Resumable transfer is useful for interruptions,
  independently of any disk-space limit. Downloading the entire eligible
  collection first is possible if measured Windows capacity permits it, but
  is not a prerequisite for starting imports.
- Preserve titles, album and track artists, track/disc order, compilation
  information, year, genre, composer, sort names and artwork. Preserve fields
  not currently displayed by Syncstr in the migration data. Exclude play
  counts, last-played time, ratings, favorites and playlists from this slice.
- Prefer source-library artwork, then embedded artwork, then an album-folder
  image with established album association. Missing artwork does not block
  audio import: retain an explicit missing-artwork result for later completion.
  External artwork search is outside this slice.
- Repeated runs must not duplicate an already migrated item. Preserve explicit
  Syncstr edits when source metadata changes. Do not merge different audio
  files merely because their track names match.
- Deliver a Windows command-line MVP for inventory/preview, import and resume.
  Use the installed Music/iTunes application for acquisition; determine its
  automation capabilities empirically. A dedicated GUI is outside this slice.
  The eventual goal is a Syncstr product feature. Refine the migration behavior
  through this MVP before designing that integration; do not introduce a
  speculative cross-platform adapter framework now.
- Hold ambiguous duplicates and album assignments for review while allowing
  unambiguous records to proceed. Names alone do not merge recordings or
  editions. Identical content and a repeated source record must be distinguished
  from different encodings, tag changes and competing album assignments.
- Implement repeatable migration runs, not continuous two-way synchronization.
  Subsequent runs may import newly added tracks; source deletions do not delete
  NAS content.
- Validate representative albums before full import: ordinary releases,
  multi-disc albums, compilations and library-only artwork. Show sample results
  to the listener before proceeding to the complete eligible collection.

See the [source metadata precedence decision](adr/0004-preserve-source-library-metadata-during-migration.md).

## Verification and handoff

All three interview rounds are resolved. Continue with the
[Windows handoff](music-library-migration-windows-handoff.md), starting with a
read-only capability check when that session is requested. Full-library import
follows sample acceptance; automatic source deletion is excluded.

Windows application capabilities, available storage, and the destination's
actual build and enrollment state are facts to inspect before implementation,
not assumptions established by accepting this plan. Verify extraction of track
origin and library-only artwork on the actual Windows application before
committing to that adapter. macOS scripting support does not establish Windows
support, and WSL access does not establish native Windows application access.

1. Inspect the actual Windows application, version, library, download locations
   and available disk. Inspect the NAS build, cluster and import entry point.
   Keep hostnames, identifiers and raw library exports outside published docs.
2. Perform a read-only sample inventory. Demonstrate subscription exclusion,
   eligible cloud/local records and unresolved states without guessing from
   filenames. Demonstrate extraction of a library-only image. If a required
   capability is unavailable, report that precise gap before choosing an
   alternative application or weakening the design.
3. Implement the smallest command flow that carries source evidence, audio,
   metadata, artwork and progress records into the authorized destination.
   Verify size/hash before marking audio transferred; separately report
   metadata and artwork results. A missing image is not a failed audio copy.
4. Verify selected albums in an isolated test destination: track/disc order,
   edition boundaries, artwork and playback. Repeat the same run, interrupt
   and resume a transfer, and verify existing Syncstr edits are retained.
5. Present eligible/excluded/unresolved counts and sample evidence. After the
   listener accepts the results, run against the intended NAS library and
   retain progress and exceptions for subsequent runs.

A command implementation, successful copy, or parsed XML alone is not proof of
complete migration. Preserve acquired audio bytes; image normalization for
Syncstr's existing constraints must retain traceability to the extracted image.
The Windows handoff includes this plan, the glossary and the source precedence
ADR. Current documents are planning artifacts, not an operational run record.

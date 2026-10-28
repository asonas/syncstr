# Windows implementation handoff: source track identity

## Objective and authority

Build a read-only source identity inventory and correspondence review using the
Windows Music/iTunes XML and original media. The destination is the shared
Syncstr server catalog, not a playback device's partial cache. This document
authorizes the first implementation slice below; it does not authorize rewriting
the production catalog, changing source files, or automatically accepting matches.

The user accepts substantial architecture changes if needed. Do not assume a
catalog reset is necessary: retain existing IDs and mappings until a separately
specified migration can preserve references and user edits.

## Read first

- Repository `AGENTS.md`, [README map](../README.md#code-and-documentation-map)
  and [glossary](../GLOSSARY.md).
- [Accepted identity boundary](adr/0006-preserve-source-track-identity-independently-of-audio.md).
- [Source metadata precedence](adr/0004-preserve-source-library-metadata-during-migration.md).
- [Existing Windows audit](../tools/playlist-audit/README.md) and its implementation.
- [Playlist plan](playlist-implementation-plan.md) and [implemented reconciliation](playlist-reconciliation.md).
- [Earlier Windows migration handoff](music-library-migration-windows-handoff.md)
  for environment checks, not as authorization to start bulk audio migration.

At authoring, `8ec119a` implements selective XML import and updating existing
playlist mappings. Inspect the actual Windows checkout and server revision
before relying on that baseline. Older planning documents describe some shipped
features as pending; inspect current code rather than repeating those claims.

## Agreed identity rules

1. A source library registration is distinct from an audio file. Retain the source
   library identity and each track's persistent identifier separately.
2. Separately registered source tracks remain separate, including registrations
   in different libraries. Identical titles, bytes, paths, or filename suffixes
   do not authorize merging them. Copied XML exports are not automatically new
   libraries: report duplicate or conflicting library identifiers for review.
3. MP3/AAC copies may represent one library track, but codec or title equality
   cannot establish that relationship. Separate source registrations still take
   precedence. Different album releases, live versions, remixes and remasters
   remain separate tracks.
4. Persist confirmed correspondence for reuse across imports and devices.
   The server will ultimately own shared correspondence; no device-local CSV is
   the final source of truth.
5. Preserve unresolved and protected source entries as references. Existence,
   readability, protection evidence, ownership eligibility and Syncstr playback
   availability are separate facts. Do not bypass DRM or infer eligibility from
   a readable file or a filename extension alone.

## Current implementation boundaries

`apps/macos/Playlists.swift` reads XML source IDs and generates metadata candidates.
`headless/src/playlists.rs` retains source library/track references in playlist
occurrences alongside destination track IDs and hashes. Updates preserve those
occurrences, but this is not yet a general source-to-track correspondence registry.

`headless/src/model.rs`, `store.rs` and `organization.rs` describe catalog entries,
content hashes and canonical track aliases. Before changing them, investigate how
the same hash uploaded twice is represented and how aliases affect playlist
playback. Never assume an existing content hash is a suitable logical track ID.

## Slice 1: implement on Windows

Work in a standard task worktree. Verify the runtime and whether execution is
native Windows or WSL. Confirm the XML and local media paths by inspection;
macOS paths and WSL connectivity do not establish Windows file access.

Extend the existing Python audit tools where their behavior fits. Keep existing
commands compatible. Add a distinct inventory command with a versioned report
format; do not silently change the exploratory audit report into an import API.
No iTunes COM integration is required for this XML/local-file slice.

### Inventory contract

Produce one private manifest retaining one row per XML track registration, not
one row per title, path or hash. Include:

| Area | Required evidence |
| --- | --- |
| Run | Report schema version, tool revision, timestamp and XML SHA-256 |
| Source identity | Raw library persistent ID, track persistent ID and XML-local Track ID |
| Metadata | Original title, artist, album, album artist, duration, track/disc numbers and compilation flag when present; missing values stay missing |
| Location | Original file URL, decoded local path, explicit root remapping if used, and resolution status |
| File | Observed size, modification time, streaming SHA-256 when safely readable, and independent read/hash status |
| Provenance | Original protection/cloud/purchase evidence and unknown classifications |
| Relationships | Playlist IDs, order, repeated occurrences and broken references, reusing existing audit output where practical |

Use `(source library persistent ID, source track persistent ID)` as the proposed
stable source key. Validate it against the actual exports: missing/duplicate IDs
must be reported, not repaired with title-derived IDs. XML-local Track ID is only
a join within that export. An export hash identifies a snapshot, not a library.
Records without a valid stable key remain inspectable but cannot receive a
cross-export correspondence automatically.

Decode file URLs without converting literal `+` into spaces. Do not strip `-1`
or `-2`. Do not guess paths by title, scan arbitrary drives or access network
shares automatically. If the exported drive/root moved, allow an explicit root
mapping and retain both original and effective paths. Reject ambiguous mappings.

Avoid hydrating cloud placeholders. A local protected file may be hashed as
opaque bytes without decoding; retain its protection status. Unavailable files
still get inventory rows. Compare file stat information before/after hashing,
mark changed files unstable, and recheck XML bytes at completion. Record that
these checks detect ordinary concurrent edits but are not an atomic filesystem
snapshot. Stream hashes with bounded memory and report progress.

Write to a new private output outside media and the repository. Publish completed
reports atomically. Interrupted runs must not leave an apparently complete
manifest; a safe full rerun is sufficient for this slice. Do not infer successful
hashing from a prior report based solely on path or file size.

### Correspondence review contract

Consume a fresh, read-only export from `export_server_catalog.py`. Record the
destination library ID and snapshot fingerprint. Do not query SQLite across a
network-mounted live database or require production write credentials.

For each source registration, emit one of:

- `exact_bytes_candidate`: source and destination SHA-256 match; include all
  matching destination entries and their canonical aliases, not an arbitrary first.
- `metadata_candidate`: byte equality is unavailable or absent; retain matching
  and differing fields as evidence. Never describe this as confirmed identity.
- `unmatched`: no useful destination candidate.
- `source_unavailable` or `source_identity_invalid`: evidence is insufficient;
  retain the reason and any separately obtained metadata suggestions.

Preserve independent source rows when several point to the same destination
object. Flag this as `shared_audio_requires_distinct_tracks`: it is evidence of a
storage/model requirement, not a command to map all registrations to one logical
track. A unique byte match may settle file correspondence without settling the
logical track assignment. No candidate is pre-accepted, even an exact match.

Reuse existing metadata review logic as a fallback and report its limitations.
Do not expand heuristic matching, introduce acoustic fingerprint dependencies,
transcode audio or design a universal music database in this slice.

## Acceptance checks

Use fictional XML and tiny local files in tests. Verify public commands, output
content, exit status and unchanged input bytes. Cover:

- Two persistent IDs with the same title and identical audio remain two rows.
- Two IDs pointing to one path, and separate `Song.mp3` / `Song-1.mp3` files,
  retain separate source identity regardless of whether hashes agree.
- Equal track persistent IDs in different source libraries remain distinct.
- Re-exporting unchanged registrations retains source keys; changed XML-local
  Track IDs do not break playlist joins or become new persistent identity.
- Missing/duplicate persistent IDs are reported without silently merging rows.
- Unicode, spaces, percent escapes, literal plus signs and explicit root remaps.
- Missing files, placeholders, protected files, read failures and files changing
  during hashing produce distinguishable outcomes without source mutations.
- Exact matches, multiple destination candidates and multiple registrations for
  one audio object retain all evidence and require review.
- Interrupted runs cannot be mistaken for complete manifests; reruns do not
  overwrite earlier reports or modify source/library data.

Run existing audit/review tests as well as focused new tests. Then inventory a
small representative private selection before scanning the full library. Full
read-only enumeration can follow after validating output and resource use; report
coverage gaps rather than inventing missing examples.

## Return to the macOS/server design session

Return code revision, test results, commands, sanitized aggregate counts, format
documentation with fictional examples, and private report locations. Highlight
invalid source identities, duplicate registrations, exact-byte coverage, missing
files, protected entries and cases where the server currently collapses distinct
source registrations. Keep real XML, names, file paths, hashes, media and report
contents out of commits/issues.

The next design decision is how separate logical tracks share audio copies while
preserving existing playback, album membership, playlist references and user edits.
Specify server mapping persistence, approval/reassignment history, synchronization,
concurrent edits and migration of existing IDs after inspecting these results.
Do not preempt those decisions with a destructive schema change on Windows.

## Suggested skills and starting request

Use `coding` for implementation and the repository's testing rules. Use
`grill-with-docs` / `domain-modeling` if actual evidence contradicts an agreed
identity rule; distinguish facts from decisions. Use `commit-style` when committing.

> Read this handoff and its linked ADR. Implement only Slice 1: a read-only Windows
> source identity inventory and server correspondence review using the existing
> playlist audit tools. Preserve separate registrations even when file hashes
> agree. First verify the checkout and local source paths, then implement and test
> with fictional fixtures, inspect a small real sample, and return sanitized
> findings. Do not mutate the source library, accept mappings, upload audio or
> change the production server catalog.

This file must be committed and delivered to the Windows checkout before the
handoff is considered transferred. A file only present in a macOS worktree cannot
be obtained by pulling `main`.

# Music Player Migration Implementation Plan

**Goal:** Non-destructively import DRM-free iTunes/Music XML metadata, playlists, and local files into the NAS catalog.

**Architecture:** XML and audio inventory are independent inputs. LibraryImporter records candidates and decisions; it never moves or deletes source files. WAV/AIFF metadata is preserved through DB and sidecar boundaries.

**Dependencies:** server CatalogService/MetadataStore migrations; fixture manifest; design spec migration scenario.

## Boundaries and outputs

| Component | Input / output | Acceptance evidence |
| --- | --- | --- |
| XMLReader | XML → normalized import rows | malformed/unknown-field fixtures |
| FileInventory | source paths → size/hash/duration candidates | no-write scan test |
| Matcher | XML rows + candidates → accepted/ambiguous/unmatched | deterministic scoring fixtures |
| MetadataWriter | accepted row → tags or sidecar | WAV/AIFF sidecar and no-audio-mutation tests |
| ImportReport | decisions → JSON/CSV | DRM, cloud-only, ambiguity, failure counts |

## Implementation order

1. Define import staging tables and an immutable run ID; test rollback leaves audio unchanged.
2. Parse exported XML without network calls; classify cloud-only and DRM-protected entries as excluded.
3. Inventory staging audio by normalized path, size, SHA-256, and duration.
4. Match exact paths first, then deterministic candidates; require user confirmation for multiple matches.
5. Import rating, play count, last played time, playlists, and artwork only after confirmed track mappings.
6. Write taggable formats through MetadataStore; write WAV/AIFF and tag-write failures to sidecar without overwriting originals.
7. Produce reviewable failure report and require explicit finalize before catalog activation.

## Test cycles and acceptance

- Fixtures cover XML-only, missing path, duplicate candidate, DRM, cloud-only, WAV, AIFF, and playlist ordering.
- No migration test may rename, delete, or modify source audio bytes; verify pre/post SHA-256.
- Finalize is rejected while ambiguous candidates remain; report enumerates each excluded item and reason.

## Risks / decisions

- Music XML export variants and artwork references need real-library samples with personal data removed.
- Legacy encoded paths require a user-visible confirmation workflow, never heuristic silent selection.

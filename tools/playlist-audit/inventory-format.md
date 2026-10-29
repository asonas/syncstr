# Source identity report format, version 1

Both commands emit UTF-8 JSON with `schema_version: 1`, `complete: true`, a UTC
`created_at`, and `tool`. The tool records the checkout's Git revision and SHA-256
of `inventory.py`, `audit.py` and `review.py`; these fingerprints identify local
implementation edits even before a commit. Final filenames appear only after
successful publication. Reports contain private identifiers, metadata and paths.

## Inventory

`kind` is `source_inventory`.

| Field | Meaning |
| --- | --- |
| `sources` | Input index, local XML path, XML fingerprint, raw library persistent ID and exported application version |
| `tracks` | One row per XML dictionary entry, without deduplication |
| `playlists` | Source index, original playlist metadata, ordered occurrence records |
| `protected_output_roots` | Source/media/repository roots excluded from both commands' output destinations |
| `file_attempt_limit` | Requested sample limit, or null for full inspection |
| `xml_unchanged_at_end` | Byte equality against every XML read at startup |
| `summary` | Registration, invalid identity, file status, protection evidence and broken-reference counts |

A track's `row_id` is `source_index:xml_dictionary_key`, a join within this
report only. `xml_track_id`, `library_persistent_id` and `track_persistent_id`
preserve the raw values. `identity.proposed_key` is the library/track persistent
ID pair. `identity.stable_key` is null when either ID is missing/invalid, when
the pair is repeated, or when input exports repeat the library ID. The reason
list distinguishes these cases. Invalid rows remain inspectable.

For example, these fictional registrations remain independent even when their
locations and SHA-256 agree:

```json
[
  {"row_id": "0:17", "identity": {"status": "valid", "reasons": [], "proposed_key": ["LIBRARY-A", "TRACK-A"], "stable_key": ["LIBRARY-A", "TRACK-A"]}},
  {"row_id": "0:23", "identity": {"status": "valid", "reasons": [], "proposed_key": ["LIBRARY-A", "TRACK-B"], "stable_key": ["LIBRARY-A", "TRACK-B"]}}
]
```

`metadata` and `provenance` retain original XML field names and values; absent
fields are omitted. Provenance covers Kind, Track Type, Purchased, Matched,
Protected, Apple Music, Cloud Status, iCloud Status and Purchase Date.
`protection: flagged` means a true Protected field or a `.m4p` URL suffix;
otherwise protection remains `unknown`. `eligibility: unresolved` and
`playability: not_tested` are independent of those observations.

`location` retains the original URL, decoded/effective paths, any explicit
`root_mapping`, and `resolved`, `no_location` or `invalid` status. Percent escapes
are decoded without changing literal plus signs or removing filename suffixes.

`file.status` distinguishes `available`, `missing`, `not_file`, `not_inspected`,
`read_failed`, `unstable`, `not_sampled`, `no_location` and `invalid`.
`not_inspected` includes a reason such as `placeholder_not_read` or
`reparse_point_not_followed`. `read_status` and `hash_status` separately record
whether reading was attempted, succeeded or failed. Only `hash_status: complete`
includes `sha256`. Size and nanosecond modification time are retained when
observed. A changing file never yields a usable hash. XML/stat rechecks detect
ordinary concurrent changes; they do not create an atomic filesystem snapshot.

Each playlist preserves its original metadata, including IDs and parent IDs.
An item's one-based `position`, raw `xml_track_id`, `row_id` and
`resolved_in_xml` preserve order, repeated occurrences and broken references.
Broken references have null row IDs. Opaque plist data is represented as
`{"base64": "..."}`; dates become ISO strings. Smart rules are not executed.

## Correspondence review

`kind` is `source_correspondence_review`. The report records inventory/catalog
fingerprints, destination library and cluster IDs, and one row per registration.
The exporter must run locally against the shared server database in a read-only
transaction. An offline review cannot independently establish catalog freshness.

Status precedence is invalid identity, unavailable source hash, exact bytes,
metadata candidate, then unmatched. Thus a row without a usable hash is
`source_unavailable`, even if it has metadata suggestions; inspect `candidates`
and `source_file_status`. Sampled-out files also use that status, not `missing`.

Each candidate retains the entry ID, canonical track ID, all aliases resolving
to that canonical ID, content hash and `basis` (`exact_bytes` or `metadata`).
`fields` retains source/destination metadata and `equal`, `different` or `missing`
comparisons. Source duration is milliseconds, destination duration seconds;
equality converts units. Comparisons are raw evidence, while candidate discovery
uses the existing NFC/whitespace-normalized metadata criteria.

`decision` is always null. `shared_audio_requires_distinct_tracks` flags rows
where multiple registrations suggest the same canonical destination and hash.
This can include metadata-only suggestions, so it does not establish equal
source bytes. Consult candidates and source hashes before concluding that a
particular pair shares audio. No command accepts or persists mappings, changes
the production catalog, or decides how future logical tracks share audio.

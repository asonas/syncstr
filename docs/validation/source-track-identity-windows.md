# Windows source identity validation

## Scope and revision

Slice 1 of the [handoff](../source-track-identity-windows-handoff.md) was exercised
on native Windows on 2026-10-29 with Python 3.10.11 through mise. The task branch
is `codex/source-track-identity`, based on `6a87cd1465a379d42fa8e0ccbbfe6df59c0f99fd`.
Each private report records this base and exact implementation file fingerprints
in `tool`; the implementation was exercised before commit. Runtime environment
paths, source IDs, media metadata, content hashes and report contents are private.

The active shared server image identified application revision `8ec119a`; its
host checkout reported `db28dc165a889741f318ef37412d652a4b5761c0`, so the host
checkout was not assumed to describe the running image. The existing exporter
was streamed over the authorized SSH connection into server Python 3.14.8.
It opened the database locally using SQLite read-only mode, `query_only` and one
transaction. The resulting fresh snapshot contained 7,122 audio entries and
7,100 aliases, with 4,592,641 bytes of JSON. No production writes were performed.

## Automated verification

```powershell
mise exec -- python -m unittest discover -s tools/playlist-audit -p 'test_*.py' -v
git --no-pager diff --check
```

The suite contains 20 passing tests: 11 existing audit/review tests and 9 focused
inventory tests. Public CLI checks use fictional plist fixtures and tiny files,
verify exit status/output and unchanged input bytes, and reject report overwrite.
They cover independent registrations sharing bytes or paths, filename suffixes,
separate library scope, re-exported XML IDs and playlist joins, duplicate/missing
persistent IDs, copied exports, Unicode/percent escapes/literal plus, explicit
remapping, unavailable/protected files, all exact candidates and aliases,
unaccepted metadata suggestions, and a bounded sample retaining every row.

Filesystem-boundary tests inject placeholder attributes, permission errors and
concurrent file changes. Publication interruption and changed XML leave no final
manifest. Output inside a media root is rejected by both commands. These tests
do not modify real source files or depend on production services.

## Private real-data run

Commands used the forms below, with private paths substituted at execution:

```powershell
mise exec -- python tools/playlist-audit/inventory.py inventory --library '../input/Library.xml' --file-limit 64 --output '../private-audit/inventory-sample.json'
mise exec -- python tools/playlist-audit/inventory.py review --inventory '../private-audit/inventory-sample.json' --catalog '../private-audit/server-catalog.json' --output '../private-audit/review-sample.json'
mise exec -- python tools/playlist-audit/inventory.py inventory --library '../input/Library.xml' --output '../private-audit/inventory-full.json'
mise exec -- python tools/playlist-audit/inventory.py review --inventory '../private-audit/inventory-full.json' --catalog '../private-audit/server-catalog.json' --output '../private-audit/review-full.json'
```

The first pass retained every XML row but read only 64 files (424,111,433 bytes).
All 64 were exact-byte candidates. Output/resource inspection preceded the full
pass. Full hashing read 66,974,507,987 bytes in 1 MiB blocks. The full inventory
was 14,591,331 bytes and its review 9,951,563 bytes. Full inventory and review
finished within three minutes of the sample review. This is an operational
observation, not a benchmark or a peak-memory measurement.

| Full inventory observation | Count |
| --- | ---: |
| Source registrations | 7,554 |
| Invalid source identities | 0 |
| Repeated effective paths | 0 |
| Safely read and hashed | 7,455 |
| Missing files | 5 |
| No Location field | 94 |
| Protection evidence flagged, all hashed opaquely | 85 |
| Duplicate source SHA-256 groups | 0 |
| Playlists | 193 |
| Playlist occurrences | 37,969 |
| Broken playlist references | 0 |

| Correspondence status | Count |
| --- | ---: |
| Exact-byte candidate | 7,100 |
| Metadata candidate | 3 |
| Unmatched | 352 |
| Source unavailable | 99 |
| Source identity invalid | 0 |
| Multiple destination candidates | 0 |
| Unavailable rows with metadata suggestions | 0 |

XML bytes were unchanged at completion. All decisions remain null. The five
missing files and 94 absent locations remain separate outcomes; 85 protection
flags are evidence, not eligibility or playback verdicts. No audio was decoded,
uploaded or changed. No library or server correspondence was accepted.

## Evidence for subsequent model design

Six rows carry `shared_audio_requires_distinct_tracks`: three exact-byte rows
and three metadata-only rows suggest three shared canonical destination/audio
pairs. All successfully hashed source files have distinct hashes. Therefore this
run does **not** demonstrate that equal source bytes were collapsed, and the
metadata suggestions do not prove the same recording or logical track. They
identify cases for explicit review before any shared mapping is persisted.

At the inspected code revision, `headless/src/store.rs` enforces uniqueness on
`(sha256, suffix)` and reuses the existing entry on repeat uploads.
`Organization::merge` in `headless/src/organization.rs` can alias an incoming
logical ID when exactly one existing canonical track and one incoming track
share its hash. Those boundaries require deliberate design for independent
registrations sharing audio; this slice makes no schema changes. Fictional
fixtures cover the same-byte/separate-registration cases absent from this run.

The real run did not exercise cloud placeholders, read failures, changing files,
invalid IDs, root moves or multiple exact candidates; fixtures cover those paths.
It did not test playback, ownership eligibility, actual cloud hydration behavior,
or an export from a second real library. Junctions/reparse points and network
media are intentionally refused. Metadata fallback retains the existing narrow
criteria and cannot resolve differing releases, remasters or codec copies.

The [format reference](../../tools/playlist-audit/inventory-format.md) documents
fields and fictional examples. Private report locations were returned directly
in the task conversation; none of the real reports are repository artifacts.
Server-owned mapping persistence, approval/reassignment history, synchronization,
concurrent edits and reference-preserving migration remain the next design slice.

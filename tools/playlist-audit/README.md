# Read-only Windows playlist audit

For recovery provenance and exploratory smart-rule findings, see the
[validation record](../../docs/validation/playlist-recovery-and-smart-rules.md).

Run with Python 3.10 or later from the repository root:

```powershell
python tools/playlist-audit/audit.py --library '../input/Library.xml' --output '../private-audit/run-001.json'
python -m unittest discover -s tools/playlist-audit -p 'test_*.py' -v
```

The output must be a new private file outside source library and media directories.
It contains personal playlist names, IDs, file paths and opaque smart definitions;
do not commit it. The console prints aggregate findings only. The tool does not
change the XML or audio, connect to iTunes, download tracks, or import into Syncstr.

Entries retain their original order, duplicate occurrences and broken references.
Folders take classification precedence over smart data; distinguished system
playlists are separated from user playlists. Original smart bytes are retained
as base64, without claiming to decode or execute their rules. Parent IDs are
retained for subsequent hierarchy comparison.

Local file URLs are percent-decoded without converting literal plus signs.
Remote shares are not contacted. Offline/recall placeholders are not read.
Other files are checked for size and one-byte readability. File existence,
ownership, protection and playback are separate observations: readability never
proves eligibility or DRM freedom. Absence of Location is not a missing-file verdict.
Subscription evidence is flagged; other eligibility remains unresolved.

The snapshot hash and end-of-run comparison detect changed XML bytes; they do
not lock media or establish that an export is the currently open library.
App version here means the version recorded in XML, not the installed version.
UI comparisons and smart-rule semantics require separate iTunes verification.

This is an inspection tool, not a migration interchange format. It does not
implement playlist storage, synchronization, import, deduplication or resume.

## Server catalog review

`export_server_catalog.py` reads the headless server's SQLite database in a
single read-only transaction. It exports matching metadata and identity aliases,
without artwork bytes, credentials, or audio. Run it where the server database
is local; do not mount live SQLite files over a network share.

```sh
python3 tools/playlist-audit/export_server_catalog.py \
  --database ./private/server-data/node.sqlite > ./private/server-catalog.json
python3 tools/playlist-audit/review.py review \
  --library ./private/Library.xml --catalog ./private/server-catalog.json \
  --output ./private/playlist-review
```

For a remote server, stream the exporter over an existing authorized SSH
connection, and save its stdout privately on the workstation. The exporter does
not need to be installed or run as the server's application process. The
destination must be the shared server catalog, not a device's partial cache.

The review directory contains:

- `playlists.csv`: enter `yes` in `decision` to select a list or folder. Selecting
  a folder includes descendants; enter `no` on individual descendants to exclude
  them. System collections are omitted. Nothing is selected initially.
- `tracks.csv`: enter `accept` in `decision` only after reviewing a proposed
  source/destination correspondence. For ambiguous matches, set
  `destination_track_id` to one of the listed candidates before accepting it.
  Leave undecided rows blank or mark them `skip`.
- `source.json`: source/server fingerprints and library identities. Keep it
  unchanged and alongside the CSV files.

Candidates require nonempty title, artist, and album equality after NFC and
outer-whitespace normalization, duration within two seconds, and source track
and disc numbers when present. An absent destination disc number means disc 1.
These are metadata candidates, not evidence of byte equality. Every acceptance
is explicit, including a unique candidate. Source files are not accessed, and
unmatched audio is not copied, downloaded, or inferred from title alone.

Prepare the reviewed selection:

```sh
python3 tools/playlist-audit/review.py prepare \
  --library ./private/Library.xml --catalog ./private/server-catalog.json \
  --review ./private/playlist-review --output ./private/prepared-playlists.json
```

Re-export the server catalog before preparing if the server may have changed.
A changed XML or catalog requires a fresh review. Output files are never
overwritten. The prepared JSON retains minimum ancestor folders, original item
order, independent repeated occurrences, unresolved positions, server logical
track IDs and content hashes, and opaque smart definitions. Smart lists are
marked as fixed snapshots; their rules are not executed. Occurrence IDs are
stable for the exact reviewed source fingerprint only; changed exports still
require the later import-baseline and occurrence-matching implementation.

Preparation does not import playlists into Syncstr. Shared playlist storage,
authenticated server acceptance, repeat-import handling, and client replication
are subsequent implementation work. Neither command modifies the server or XML.
Keep review files and prepared output private; they contain real library data.

## Source registration inventory

`inventory.py` implements the read-only evidence collection slice of the
[source identity handoff](../../docs/source-track-identity-windows-handoff.md).
It keeps one row per XML registration, even when paths, titles or bytes match.
It is separate from the existing audit and playlist preparation commands.

Create a private output directory outside the repository and media first. Start
with a small file limit; every XML registration and playlist occurrence remains
in the report, but only the first N resolved file locations are inspected.

```powershell
mise exec -- python tools/playlist-audit/inventory.py inventory --library '../input/Library.xml' --file-limit 64 --output '../private-audit/inventory-sample.json'
mise exec -- python tools/playlist-audit/inventory.py review --inventory '../private-audit/inventory-sample.json' --catalog '../private-audit/server-catalog.json' --output '../private-audit/correspondence-sample.json'
```

Obtain `server-catalog.json` freshly using the read-only exporter described
above. After checking the sample and resource use, omit `--file-limit` for a
full scan and use new filenames. Repeat `--library` for distinct libraries.
Duplicate library IDs are reported as invalid, including copied XML exports.

If a local root moved, explicitly pass `--root-map 'D:\OldMedia=E:\Media'`.
Both paths must be absolute; the destination must exist on a local fixed drive.
Overlapping source roots are rejected. No automatic path search is performed.
The tool refuses network shares, cloud recall/offline placeholders, symbolic
links and all Windows reparse points, including junctions. Protection evidence
does not prevent opaque hashing of a safely local file, and hashing does not
establish ownership eligibility or playability.

Each hash streams in 1 MiB blocks. Progress contains counts only. Input bounds
are 32 MiB per XML, 64 MiB for a catalog and 256 MiB for an inventory consumed by
review. Completed reports are published through an atomic, non-replacing hard
link on the output filesystem. Choose a filesystem supporting hard links
(NTFS on Windows). A failed run publishes no final report; a forced process
termination can leave a `.partial` file, which is not a completed manifest.
Existing reports are never overwritten. A rerun reads the source files again.

All correspondence decisions remain `null`. Exact byte matches retain every
matching catalog entry and canonical aliases. Separate registrations sharing
a candidate are flagged for the later logical-track design; they are never
merged or automatically mapped. Metadata suggestions use the existing review
criteria, including its rejection of cyclic/dangling aliases and competing
hashes for one canonical destination identity.

See the [version-1 format](inventory-format.md) for field meanings and the
[Windows validation record](../../docs/validation/source-track-identity-windows.md)
for coverage and remaining design questions. These reports are private evidence,
not an upload, import API or shared correspondence registry.

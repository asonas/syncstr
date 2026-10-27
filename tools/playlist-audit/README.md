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

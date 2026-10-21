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

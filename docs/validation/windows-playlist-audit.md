# Windows playlist audit

The read-only [audit tool](../../tools/playlist-audit/README.md) checks an exported
iTunes XML against local files. It preserves playlist order and repeated entries
in a private inspection report, without importing or modifying source content.

This historical record describes the earlier inspection run. Its counts and
verification gaps do not establish the current state of the source library.

## Verified source observations

The inspected export reports iTunes 12.13.11.1 and 7,554 tracks. Its timestamp is
newer than the October 18 export used for the planning baseline; matching counts
do not establish byte-for-byte or track-by-track equivalence with that export.

| Observation | Count |
|---|---:|
| Ordinary playlists | 77 |
| Folders | 10 |
| User smart playlists | 96 |
| System playlists | 10 |
| Non-folder playlists containing smart definitions, including system entries | 103 |
| Playlists with repeated track references | 3 |
| Extra repeated occurrences | 5 |
| Broken XML track references | 0 |
| Missing parent references | 0 |
| Ambiguous playlist persistent IDs | 0 |
| Local files readable for at least one byte | 7,455 |
| Referenced local files not found | 5 |
| Tracks without Location | 94 |
| Tracks with a protection flag or protected-file suffix | 85 |
| Tracks with Apple Music subscription evidence | 125 |

Protection and subscription counts are independent and may overlap. No track
was established as migration-eligible by this audit. Absence of Location does
not prove that audio is lost. A missing referenced path does not prove that no
other copy exists. Readability does not establish full-file integrity, decoding,
playback or lack of DRM. Source XML bytes were unchanged across the completed scan.

## Verification and remaining gates

At the time of inspection, three automated tests covered folder/system precedence, opaque smart data,
ordered duplicates and missing references, percent-encoded paths, unchanged
fixture bytes, unknown eligibility, missing locations and remote-share rejection.
They do not verify UI behavior or real audio playback.

The inspection environment could not launch the Windows UI helper and denied
iTunes COM access. Installed/running application version, active library identity,
displayed ordering, smart-condition dialogs and source information dialogs remain
unverified. The XML version alone does not satisfy those checks.

Next, compare representative ordinary, repeated-entry, nested and smart
playlists in iTunes against the private report. Capture complete smart rules,
including all/any matching, limits, selection order, live updating and checked
items. Investigate missing paths without changing the source library.

Small-sample playlist import requires the Mac-side importer and an isolated
test destination. Import, repeat import, interruption/resume, preservation of
Syncstr edits and cross-device synchronization have not been verified here.
No app UI or shared Apple implementation was changed.

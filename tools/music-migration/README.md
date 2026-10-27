# Windows music migration MVP

Inventory and preview an iTunes XML export, prepare a reviewed local selection,
and import/resume it into an isolated or explicitly bound NAS library. Python 3.10 or later is required;
preparation also uses FFmpeg/ffprobe, and transfer uses OpenSSH. The NAS requires
Python 3, Docker, and a compatible headless image already installed. No source
audio or library metadata is changed, and no downloads are requested.

Reviewed tracks without an album name retain the empty source metadata. Each
gets a stable album membership ID derived from its source track ID, preventing
unrelated unnamed tracks from becoming one album. Audio keeps the existing
hash-based object path. The shared Apple client uses the track title to display
missing or empty album names without storing that label as source metadata. Missing
artwork remains a reported partial result.

`init-test` creates a fresh independent library. `bind-existing` explicitly binds
an existing, stopped library to its expected ID and one reviewed bundle. Rehearse
this operation on a restored copy before authorizing production writes. Do not
use unrelated M4 or Android fixtures as migration targets.

From the repository root, using paths to your XML and private output directory:

```powershell
python tools/music-migration/migration.py inventory --library '../migration-input/Library.xml' --output '../private-migration-runs/run-001'
python tools/music-migration/migration.py preview --inventory '../private-migration-runs/run-001/inventory.json' --status review --limit 20
```

Use the XML belonging to the Windows library, as reported by iTunes COM's
`LibraryXMLPath`, or an explicit iTunes export. The output directory must be new
and outside the source library and referenced audio directories. Store it outside
the repository: the result contains personal library metadata and paths. No
live private iTunes database is opened. The inventory does not connect to iTunes
COM or the NAS, start an application, or request downloads.

## Reading the result

- **candidate:** the XML explicitly says Purchased or Matched, and does not
  identify subscription/protected content. A candidate can have no local file.
  Candidate is an ownership finding, not verified migration eligibility.
- **excluded:** Apple Music subscription evidence or a video record. Subscription
  evidence takes precedence even when purchase evidence is also present.
- **review:** missing ownership evidence, protected content, invalid flags,
  playlist-only records, missing/unreadable/empty files, invalid locations, or
  multiple records pointing to the same file. All source records remain in the
  manifest, including excluded and unresolved cases.

The observed English/Japanese Apple Music/video Kind labels provide additional
exclusion evidence. Other localized labels are not a validated ownership rule.
Purchased/matched Kind labels without a positive boolean remain unresolved.
There is no inferred Uploaded state, and an absent boolean does not mean false.
If a platform or export exposes insufficient evidence, keep the record for review.

The inventory records one-byte readability and file size separately from
ownership. It does not decode audio, verify all bytes, establish DRM freedom, or
infer cloud download availability from a missing Location. A protected flag or
`.m4p` suffix holds a record for review, but their absence does not prove that
audio is unprotected. File observations can change after the scan.

Console output and `inventory.json` use UTF-8; generated JSON uses LF newlines.

`source_id` combines the XML Library Persistent ID and track Persistent ID.
Missing/malformed or duplicate IDs stop inventory because correspondence is
ambiguous. The namespace applies to this source library; cross-machine identity
is not established. File URLs are decoded as URLs, including escaped characters,
rather than matched by title. A shared file path is reported, not deduplicated.
Different files with the same title are retained separately.

`source_metadata` preserves library title/artist/album information, composer,
genre, year, compilation, track/disc order, and sort names. Raw XML and playback
history, ratings, favorites, and playlists are not copied into the manifest.
The XML hash identifies the read snapshot; `unchanged_at_end` reports whether
the XML still had those bytes after file inspection. Reinventory before import
if it changed. Even an unchanged XML is not a lock on the media files.

Embedded metadata is explicitly `not_read`. Artwork is
`not_checked_with_com`: XML Artwork Count absence is not evidence that iTunes has
no image. The read-only Windows capability check established ID-matched COM
artwork export, including images absent from the audio, but that extraction is
not automated by this command. Source-library and embedded evidence must remain
separate when the next slice collects them.

Preview supports `--status all|candidate|excluded|review` and `--limit`. It shows
source track/album observations and disc/compilation fields, without assigning
Syncstr album membership or merging releases by title.

## Verification

```powershell
python -m unittest discover -s tools/music-migration -p 'test_*.py' -v
```

Tests invoke the real CLI with fictional XML and temporary files. They verify
subscription exclusion and unknown states, metadata/ID/path retention, filtered
preview, unchanged source bytes, output collision/source-directory protection,
and ambiguous source identity/path handling. The byte fixtures test readability,
not audio decoding. Production data and artwork do not belong in fixtures.

Before NAS work, follow the [migration plan](../../docs/music-library-migration-plan.md)
and the existing-library rehearsal procedure below.

## Prepare a reviewed selection

Inventory does not select every candidate automatically. Create a private JSON
selection containing only reviewed source IDs and the SHA-256 of their verified
local audio. For example:

```json
{
  "format_version": 1,
  "library_persistent_id": "0123456789ABCDEF",
  "tracks": [{
    "source_id": "0123456789ABCDEF:0000000000000001",
    "audio_sha256": "<64 lowercase hexadecimal digits>",
    "cloud_observation": {
      "status": "uploaded",
      "observed_at": "2026-01-01",
      "method": "iTunes iCloud status, exact persistent-ID correspondence"
    },
    "artwork": {
      "path": "../private-artwork/0000000000000001.jpg",
      "sha256": "<64 lowercase hexadecimal digits>"
    }
  }]
}
```

`cloud_observation` is optional for XML Purchased/Matched candidates. It can
resolve missing ownership evidence only; it cannot override subscription,
protected, duplicate-location, video, or unavailable-file exclusions. Enter it
only after observing the actual source item. The tool validates its structure,
not the truth of a human observation. File Kind is not current cloud status.

`artwork` is an optional exact-item source-library export. Paths resolve from
the command's working directory; absolute private paths are also supported.
Automated COM extraction, embedded/folder artwork fallback, and downloads remain
separate acquisition work. Omitting artwork records a partial result, not an
audio failure. Do not put personal paths or exports into the repository.

```powershell
python tools/music-migration/migration.py prepare --inventory '../private-migration-runs/inventory/inventory.json' --selection '../private-migration-runs/selection.json' --output '../private-migration-runs/bundle'
```

Preparation requires an unchanged XML snapshot and reviewed audio hashes. It
copies audio unchanged, verifies full audio decoding, retains library and
embedded evidence separately, and generates source-library JPEG assets bounded
to 400 pixels and 512 KiB without upscaling. Library metadata drives Entry and
Organization; composer/year/genre/sort fields remain in the evidence sidecar.
Folder context and source IDs are retained independently of the NAS object path.
Different files with identical bytes are held for review within one selection.

For an independently confirmed PNG-declaration/JPEG-content cover mismatch,
`"artwork_decoder_hint": "mjpeg"` permits a strict audio decode using a JPEG
input hint for that cover stream. It does not rewrite audio or source tags.
Other decode failures stop preparation. An incomplete preparation directory has
no valid manifest and is not importable; use a fresh output after resolving it.

## Initialize, import and resume

Resolve the deployed image's immutable digest first. The example placeholder
must be replaced with the full `sha256:` digest. The SSH host must already have
trusted host keys and noninteractive authentication.

```powershell
python tools/music-migration/migration.py init-test --host library-test --root /srv/music-migration/test-001 --image 'sha256:<64 hexadecimal digits>' --output '../private-migration-runs/destination.json'
python tools/music-migration/migration.py import --bundle '../private-migration-runs/bundle' --destination '../private-migration-runs/destination.json' --run '../private-migration-runs/import-001'
python tools/music-migration/migration.py resume --run '../private-migration-runs/import-001'
```

The parent of the NAS test root must exist. `init-test` records a private token
before connecting; repeating the exact command can recover an interrupted
initialization. Keep the descriptor private. The helper creates independent
library/peer identities and runs the pinned CLI in disposable, network-disabled
containers. It mounts only the marked test root and does not start a server.

Each record is transferred with SCP. The helper checks staged hashes, uses the
real `cluster-import` command, and rechecks stored audio, imported metadata,
source context and artwork before returning a receipt. Evidence sidecars stay
in the test staging directory. Source and NAS staging copies are retained.

`progress.json` is atomically replaced only after verification. `resume` binds
to the original bundle, destination descriptor and library ID, reverifies
completed records, and retries unconfirmed items. A reply lost after a server
commit does not mark the item complete; replay uses server content identity.
Changed prepared files or destinations stop the run. An interrupted SCP retries
the current item from its start; byte-offset resume is not implemented.

To check a later reviewed source update, prepare a new bundle and use `import`
with the same destination descriptor and a new run directory. Existing explicit
organization choices are merged by the server. Do not modify a completed bundle
in place. Concurrent local use of the same run and concurrent helper operations
on the same destination are locked; no helper bypasses the server's store lock.

The protocol tests replace only SSH/SCP process boundaries to exercise lost
replies and binding checks. Audio preparation tests use real FFmpeg when
installed. Real NAS sample checks remain necessary for server compatibility,
album grouping and edit retention. CLI success does not prove client playback
or visual presentation; verify those separately before production work.

## Existing-library rehearsal and import

Take and verify a complete current backup before using an existing library.
Restore a copy first and keep its copied peer identity offline. The root layout
must be `data/node.sqlite` with the existing peer key in `data/peer/device.key`.
The helper never creates a replacement peer key. Binding writes a marker and
may initialize the cluster only when `--initialize-cluster` is explicit.

```powershell
python tools/music-migration/migration.py bind-existing --host library-host --root /srv/music-migration/restored-copy --image 'sha256:<64 hexadecimal digits>' --library-id '<expected library UUID>' --bundle '../private-migration-runs/bundle' --output '../private-migration-runs/existing.json' --initialize-cluster
python tools/music-migration/migration.py import --bundle '../private-migration-runs/bundle' --destination '../private-migration-runs/existing.json' --run '../private-migration-runs/rehearsal-001' --approve-existing-library '<expected library UUID>'
python tools/music-migration/migration.py resume --run '../private-migration-runs/rehearsal-001' --approve-existing-library '<expected library UUID>'
```

The destination descriptor and remote marker bind the canonical path, image,
library ID, manifest hash and every selected record. Resume requires the same
explicit library-ID approval. A different bundle or record is rejected. Retrying
the exact binding command recovers a lost reply; changing a bound selection
requires a separately reviewed operation, not editing the marker in place.

Keep the server stopped for the entire bind/import/resume operation. The helper
checks the store lock, and each runtime command acquires its own store lock. It
does not stop/restart services or reserve the store between commands. Operators
must prevent a deployment controller from starting a writer during maintenance.
All helper CLI containers use `--network none`; do not start a copied peer on the
network. Cluster initialization preserves the library identity but is a catalog
mutation, so it belongs in the reviewed operation and backup boundary.

Compare existing entries, explicit organization choices and artwork before and
after rehearsal; inspect album membership and repeat the import before approving
production. The approval argument is an operator guard, not authentication.

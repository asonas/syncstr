# Preserve the existing NAS library during migration setup

Status: historical pre-v5 migration preparation. The schema and `/v4` API
references below describe that earlier runtime, not an activated v5 host.
For current v5 work, start with the [server implementation](shared-audio-server-implementation.md),
[activation inventory](../headless/activation-inventory.md) and
[backup manifest](../headless/backup-manifest.md). Do not use this earlier plan
as a v5 activation or deployment procedure.

The selected migration destination is the listener's existing NAS library,
updated to a cluster-capable runtime. This document prepares the operation; it
does not record a deployment, backup, restore, or completed migration. Operational
paths, container identifiers, library IDs, and credentials belong in private
run records. Do not reuse the existing M4 or Android fixtures as import targets.

The Windows read-only check found a legacy schema-1 library and a separate
schema-4 cluster fixture. The running legacy executable did not expose
`cluster-import`, even though both executables reported version `0.1.0`. Pin the
source revision and image digest, and verify CLI capabilities instead of relying
on that version string. Updating a checkout alone does not update a container.

## Backup and rollback preparation

1. Identify the deployment controller, current image digest, command, mounts,
   data owner, API clients, and the complete data/TLS/peer-identity directories.
   Keep private keys on the NAS. Record library ID, catalog schema, track count,
   metadata and object hashes in private storage. Inspect actual current state
   again rather than reusing capability-check counts.
2. Arrange a maintenance window and stop the service through its deployment
   controller, preventing an automatic replacement from reopening the catalog.
   Confirm the data-directory lock is released. Do not open a second runtime
   against an actively served catalog or share a live SQLite file over SMB.
3. Create a consistent backup of data, identities, and deployment configuration
   on NAS-local storage, retaining file ownership and restrictive permissions.
   Include any SQLite journal files. Pin and retain the old image. A copied
   database alone is not a backup of the audio or identity.
4. Verify a restore into a separate directory and compare catalog IDs, every
   referenced object's size/hash, and catalog metadata with the baseline. Keep
   the backup immutable during rehearsal. Backup/restore is not verified merely
   because an archive command succeeded.
5. Rollback means stopping the upgraded runtime and restoring the complete
   pre-upgrade backup plus old deployment/image. Do not point the old binary at
   a database already migrated in place. Once new imports exist, preserve them
   separately before any rollback; the initial backup does not contain them.

## Upgrade rehearsal

Build the pinned candidate with the `p2p` feature using the
[headless Dockerfile](../headless/Dockerfile). Verify `cluster-import --help`
and the expected protocol before using any real library copy. The current
`Store::open` supports schema versions 1 through 4 and writes schema 4, but that
source inspection does not prove the listener's catalog will upgrade successfully.

Rehearse against the restored copy with networking disabled. Never start a copied
peer identity on the network alongside its live original. Exercise the actual
schema upgrade and cluster initialization on the copy; verify library identity,
all existing entries, object bytes, retained metadata, and artwork. Confirm
legacy-to-cluster bootstrap behavior and record any identity decisions before
production. Merely changing the container command is not verified enrollment.

The newer headless API is `/v4`; old API clients receive an upgrade response.
Inventory existing clients and update compatible clients as part of the cutover.
Do not silently remove the existing access path without an accepted replacement.

## Independent migration test area

Use a new NAS-local directory such as `migration-test/run-001/` with separate
`data/`, `peer/`, and `staging/` subdirectories. These are illustrative relative
paths, not a selected operational directory. Generate a fresh test identity and
cluster; do not copy production identity or join it to the listener's cluster.
Keep test networking disabled until a particular connection test is needed.

Start with accepted representative owned albums: ordinary, multi-disc,
compilation, and library-only-artwork cases. Inventory/preview comes before
acquisition. Stage exact audio bytes and source metadata separately; the original
Windows library is never the staging area. Hash audio before transfer and verify
length/hash on the NAS before declaring a durable copy.

Administrative `cluster-import` requires exclusive access to the destination data
directory. Stop the test server before imports; do not attempt an import against
the running production directory. Exercise restart, interruption/resume,
unchanged repeat imports, differing source metadata, and preservation of explicit
Syncstr edits. Verify playback separately from byte-integrity checks.

Map retained source metadata and album evidence to Entry/Organization explicitly.
The inventory JSON is not an Entry and must not be passed directly to
`cluster-import`. Preserve unsupported display fields in migration records.
The source-artwork samples were 600-pixel JPEGs; current Syncstr images require
normalization to at most 400 pixels per axis and 512 KiB. Retain the extracted
original and transformation provenance; never rewrite source-audio tags.

## Cutover gate

Present the rehearsal and sample-import results, unresolved classifications,
missing-file/artwork results, rollback evidence, and client compatibility before
deploying the update. The destination choice does not itself authorize the
cutover. Full-library import follows the listener's acceptance of sample results.

See the [migration plan](music-library-migration-plan.md),
[headless guide](../headless/README.md), [cluster CLI](cluster-lan-sync-m2.md), and
[artwork constraints](validation/compilation-artwork.md).

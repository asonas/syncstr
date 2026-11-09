# Stopped backup manifest

`activation-inventory backup-manifest --input backup-input.json` inventories an
already-created stopped backup. It writes canonical JSON to stdout, never to the
backup. It neither copies nor encrypts files, initializes identities, activates
schemas/profiles, restores data, starts a host, or contacts a peer.

It uses the [offline inventory](activation-inventory.md) read-only inspection
path and compares the collected hosts and client intent. Its `backup_verified`
field is always `false`: actual decryption and a stopped disposable restore must
be tested separately before calling a backup verified. No result authorizes
production activation or recovery.

Stop/fence writers and original host processes before copying, and retain each
host's distinct identity. Verify process exit and exclusive directory ownership;
a free `node.lock` alone is insufficient. Never launch a backup's signing
identity alongside its original. Provide a consistent recovery cut rather than
mixing snapshots or discarding later requests/writes.

## Input

The descriptor is version 1 with these required fields:

| Field | Meaning |
| --- | --- |
| `cluster` | Expected cluster identity |
| `root` | Operator-created backup root, relative to the working directory or absolute; never emitted |
| `stopped_and_fenced` | Required `true` operator assertion |
| `expected_hosts`, `expected_members` | Complete explicit roster; collected verified proof can extend it |
| `hosts` | Map of stable labels to host descriptors; all nested paths are relative to `root` |
| `clients` | Set of client-export JSON paths relative to `root` |
| `components` | Explicit D5 content declarations listed below |
| `custody` | Operator assertions and digest of the private custody checklist |
| `expected_files` | Optional map of relative file paths to earlier `{ "bytes": integer, "sha256": digest }` expectations |

Each host descriptor has `host`, `data`, `build`, `profiles`, and `evidence` as in
the inventory command. Unlike the standalone host command, `data` and every
evidence path must be inside the backup root. Client queue/staging paths resolve
beside their export and are validated against actual retained file bytes. Missing
device evidence is never interpreted as an empty queue.

All retained files are listed with relative paths, sizes and SHA-256, including
unreferenced objects, staging, private identity/configuration files and SQLite
sidecars. Symlinks, path escapes and special files are rejected. Snapshot hashes,
mtimes and directory entries are compared before and after inspection; an observed
change aborts generation. As with inventory, this does not replace operational
fencing, and reading may update filesystem access times.

Semantic host inspection rejects SQLite sidecars rather than risking SQLite
creating/changing files. A backup with sidecars still gets its complete file
manifest plus `uninspectable-host:<label>` and missing-host blockers. Preserve the
whole database set and prepare a consistent stopped snapshot separately; never
delete WAL/SHM/journal files to make a manifest pass. Other host inspection
failures similarly retain file evidence and block completeness; the standalone
host command can diagnose the failing descriptor.

## D5 declarations

Every following component must be declared. Missing declarations, explicit
absence, empty path sets and missing declared paths are blocking findings.

| D5 category | Required declaration names |
| --- | --- |
| Catalog and history | `catalog-history`, `sqlite-sidecars` |
| Identity and membership | `identity-membership`, `peer-state`, `tls-identity`, `administrative-secrets` |
| Objects | `audio`, `artwork` |
| Identity mapping | `identity-mappings` |
| Operation and control | `configuration`, `trust-pins`, `relay-settings`, `installed-build-profiles`, `control-journal`, `minimum-profile-floor`, `maintenance-state`, `manifests` |
| Client intent | `client-intent` |

Each declaration is one of:

```json
{"state": "present", "paths": ["hosts/host-a/data/node.sqlite"]}
```

```json
{"state": "absent"}
```

```json
{"state": "not-applicable", "reason_digest": "<SHA-256 of private explanation>"}
```

Only `sqlite-sidecars`, `relay-settings`, `control-journal`,
`minimum-profile-floor`, and `maintenance-state` may be not-applicable without a
blocker. Document why in the private checklist, for example because that control
material has not yet been implemented. Essential authority, original data and
device intent cannot be omitted by a not-applicable assertion. An empty object
directory can be declared present for a library with no audio; this never erases
database references to missing objects.

Paths can name a file or directory, and one database can satisfy multiple
declarations. These declarations describe operator-selected contents; they do
not cryptographically prove that a file contains the right key/configuration or
that a recovery set is complete. Inspect schema/proof/asset findings and perform
the separate recovery acceptance checks. Unknown declaration names are rejected.

## Example descriptor

This fictional example needs the actual authorized host key, baseline, valid
client exports, private checklist and retained files before use. Repeated zero
digests below stand for private checklist/explanation digests, not verified
evidence. Keep the descriptor and generated manifest outside `root`.

```json
{
  "version": 1,
  "cluster": "00000000-0000-4000-8000-000000000001",
  "root": "backup-cut",
  "stopped_and_fenced": true,
  "expected_hosts": ["<authorized-host-public-key>"],
  "expected_members": ["<authorized-host-public-key>"],
  "hosts": {
    "host-a": {
      "host": "<authorized-host-public-key>",
      "data": "hosts/host-a/data",
      "build": "fixture-build-a",
      "profiles": [],
      "evidence": {
        "identity": "hosts/host-a/identity",
        "peer-state": "hosts/host-a/peer-state",
        "configuration": "hosts/host-a/configuration.json",
        "executable": "hosts/host-a/syncstr-headless"
      }
    }
  },
  "clients": ["devices/host-a/intent.json"],
  "components": {
    "catalog-history": {"state": "present", "paths": ["hosts/host-a/data/node.sqlite"]},
    "sqlite-sidecars": {"state": "not-applicable", "reason_digest": "0000000000000000000000000000000000000000000000000000000000000000"},
    "identity-membership": {"state": "present", "paths": ["hosts/host-a/data/node.sqlite", "hosts/host-a/identity"]},
    "peer-state": {"state": "present", "paths": ["hosts/host-a/peer-state"]},
    "tls-identity": {"state": "present", "paths": ["hosts/host-a/identity"]},
    "administrative-secrets": {"state": "present", "paths": ["hosts/host-a/identity"]},
    "audio": {"state": "present", "paths": ["hosts/host-a/data/objects"]},
    "artwork": {"state": "present", "paths": ["hosts/host-a/data/node.sqlite"]},
    "identity-mappings": {"state": "present", "paths": ["hosts/host-a/data/node.sqlite"]},
    "configuration": {"state": "present", "paths": ["hosts/host-a/configuration.json"]},
    "trust-pins": {"state": "present", "paths": ["devices/host-a"]},
    "relay-settings": {"state": "not-applicable", "reason_digest": "0000000000000000000000000000000000000000000000000000000000000000"},
    "installed-build-profiles": {"state": "present", "paths": ["hosts/host-a/syncstr-headless", "hosts/host-a/build.json"]},
    "control-journal": {"state": "not-applicable", "reason_digest": "0000000000000000000000000000000000000000000000000000000000000000"},
    "minimum-profile-floor": {"state": "not-applicable", "reason_digest": "0000000000000000000000000000000000000000000000000000000000000000"},
    "maintenance-state": {"state": "not-applicable", "reason_digest": "0000000000000000000000000000000000000000000000000000000000000000"},
    "manifests": {"state": "present", "paths": ["private-checklist.json"]},
    "client-intent": {"state": "present", "paths": ["devices/host-a"]}
  },
  "custody": {
    "process_exit_and_exclusive_ownership": true,
    "encrypted_separate_storage": true,
    "encrypted_offline_copy": true,
    "key_held_separately_by_owner": true,
    "custodian_and_access_confirmed": true,
    "checklist_digest": "0000000000000000000000000000000000000000000000000000000000000000"
  },
  "expected_files": {}
}
```

```sh
syncstr-headless activation-inventory backup-manifest --input backup-input.json > backup-manifest.json
```

Custody flags are **assertions**, not measured encryption/access/decryption
results. False custody assertions block the result; process-exit/exclusive
ownership must be asserted before inspection can begin. The separate private
checklist names destinations, custodian, access, retention and key recovery.
Do not put destinations, key material or secrets into labels or file names.

## Output and limits

`files` lists every retained regular file. `semantics` records per-host category
counts/digests for mappings, exact signed history, proof and schema/baseline.
Table evidence uses row counts; other map/array evidence uses top-level entry
counts. `comparison` retains host-specific availability, unreferenced objects,
staging, and collected intent; `blocking` combines D5/custody/file expectations
with the inventory/comparison findings. Accepted and unknown requests remain
unresolved until separately reconciled. Missing/corrupt original audio/artwork
is never substituted by a similar title or another logical track with equal
bytes.

No private file contents, keys, raw request envelopes or configuration bytes are
emitted. Checklist/explanation digests bind the private records without copying
their contents. Manifests still contain relative file names, public identities
and intent summaries; keep them private. There are no wall-clock timestamps,
absolute source paths or mtimes in canonical output. The existing 32 MiB JSON
input bound applies.

Exit status 0 means evidence generation succeeded. Always inspect `blocking`;
even an empty set leaves `backup_verified: false`. Missing root files, unreadable
source entries, unsafe descriptors or observed source changes can abort with a
nonzero error instead of emitting an incomplete manifest. Native exporters,
encrypted backup creation, decryption tests, disposable restore and later-write
disposition remain separate work.

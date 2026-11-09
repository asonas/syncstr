# Offline activation inventory

`activation-inventory host` and `activation-inventory compare` collect evidence
for the [Inventory gate](../docs/v5-activation-and-recovery.md#activation-runbook-gates).
They require the `p2p` feature. They never activate a schema/profile, send network
requests, migrate databases, clean staging, or write shared history. A report is
not a readiness certificate or permission to release writes.

Stop and fence host processes, client senders, enrollment and replication before
collecting a cut. Keep all originals. A free directory lock does not establish
that every writer exited; `stopped_and_fenced` records the operator's assertion.
The tool opens the existing lock file read-only and refuses busy/unsupported
locking. It opens SQLite read-only with `query_only` and immutable mode, only
after rejecting **all** WAL, SHM and journal sidecars. If sidecars exist, retain
them and prepare a consistent stopped snapshot separately; deleting sidecars is
not a recovery procedure. Live database inspection is unsupported.

## Collect each host

Create an operator descriptor outside the inspected directories. This fictional
example uses paths relative to the command's working directory:

```json
{
  "version": 1,
  "host": "<authorized-host-public-key>",
  "cluster": "00000000-0000-4000-8000-000000000001",
  "data": "recovery/host-a/data",
  "build": "fixture-build-a",
  "profiles": [],
  "evidence": {
    "identity": "recovery/host-a/identity",
    "peer-state": "recovery/host-a/peer-state",
    "configuration": "recovery/host-a/configuration.json",
    "executable": "recovery/host-a/syncstr-headless"
  },
  "stopped_and_fenced": true
}
```

```sh
syncstr-headless activation-inventory host --input host-a-input.json > host-a.json
```

Write stdout outside every inspected source. The tool hashes all files before
and after inspection and compares sizes, digests, mtimes and directory entries.
It rejects symlinks, nonregular sources, unsafe relative paths and observed
changes. This detects observed instability; it cannot replace operational
fencing against a concurrent process changing and restoring a file between
observations. Reading can update filesystem access times.

The JSON contains public membership proof, schema, baseline, operator-declared
installed build/profiles, semantic categories, file hashes and findings. Schema
4 uses the same pure legacy-baseline calculation as migration inspection;
schema 5 retains its stored baseline and checks its payload digest. It never
reactivates an existing v5 host. Missing required schema data or unsupported
schemas fail with an error rather than inventing empty evidence.

Music/playlist signature validation, exact retained row hashes, canonical
IDs/addition times, aliases, organization, correspondences, conflicts and missing
parents are included. Playlist evidence retains every historical document,
occurrence order and ID/hash pin. Audio locators and artwork include expected or
observed size/hash and missing/corrupt findings. Unreferenced objects and staging
remain listed and retained. Invalid v5 projections still emit file/history
evidence and blocking findings; no projection is repaired.

Only digests of private files, request/receipt rows and cursor state are emitted.
No keys, tokens, raw request envelopes or configuration bytes are emitted.
Reports still contain library metadata and public membership details; keep them
private. File labels, input IDs and build names must also avoid secrets.
Installed build/profile declarations are operator evidence, not attestation.

## Collect device intent

Each member needs a version-1 JSON export and a separately retained complete
queue/receipt snapshot. Native exporters are a follow-up; this slice implements
the format and ingestion, not device UI or queue mutation. Do not claim complete
inventory until every member's original durable intent has been collected.
Never substitute an invented empty queue for an unavailable device.

The export has these required fields:

| Field | Meaning |
| --- | --- |
| `version`, `cluster`, `member`, `baseline`, `build` | Export format and original device bindings |
| `queue_path`, `queue` | Relative path to complete private queue/receipt snapshot; `{ "bytes": integer, "sha256": lowercase SHA-256 }` |
| `requests` | Durable intent summaries, including accepted outcomes awaiting reconciliation |
| `staging` | Map of relative file paths to size/hash evidence; include unreferenced staging too |

Each request requires `operation`, `id`, `digest`, `target_host`, `state`,
`eligibility` (nullable evidence digest), `receipts` (evidence digests), and
`staging` (paths present in the staging map). States are `never-sent`,
`outcome-unknown`, and `accepted`. Preserve original IDs/digests, host, baseline,
uncertainty and any existing eligibility evidence. A legacy uncertain request
must keep `eligibility: null`; collection never upgrades its eligibility.

Paths resolve beside the export, independent of the command's working directory.
The comparison checks actual queue/staging bytes against their size/hash and
rejects unsafe paths. Missing/corrupt files are blocking findings. The complete
snapshot must retain the original envelopes and receipts privately; summaries
alone are not recovery material. No native queue contents are read or rewritten
by these commands.

## Compare a collection

```json
{
  "version": 1,
  "cluster": "00000000-0000-4000-8000-000000000001",
  "expected_hosts": ["<host-a-public-key>", "<host-b-public-key>"],
  "expected_members": ["<host-a-public-key>", "<host-b-public-key>", "<device-public-key>"],
  "hosts": ["host-a.json", "host-b.json"],
  "clients": ["devices/host-a/intent.json", "devices/host-b/intent.json", "devices/player/intent.json"]
}
```

```sh
syncstr-headless activation-inventory compare --input collection.json > comparison.json
```

Collection report/export paths resolve against the working directory. The tool
unions verified grants/revocations and the explicit roster; reachable hosts are
never the roster. Missing authorized hosts, missing members' intent, disputed or
invalid proof, baseline mismatch and shared category divergence block agreement.
Revoked members remain in the intent roster for explicit disposition. Unknown
offline grants cannot be disproved by this collection.

`differences` maps differing shared categories to per-host semantic digests;
inspect the corresponding host category for the affected records/IDs. Audio and
artwork availability, staging, receipts/cursors, build evidence and private file
hashes are retained separately under `availability`, since host identity and
location state legitimately differ. Host findings still block when assets are
missing/corrupt. Different builds/profiles remain operator review evidence;
version ordering does not prove semantic compatibility.

`availability_differences` explicitly lists audio/artwork categories with unequal
per-host digests, without treating a location difference alone as history loss.

All `outcome-unknown` and `accepted` request summaries conservatively block
agreement pending manual receipt/outcome reconciliation. Never-sent requests
remain retained for later revalidation. This command performs no disposition,
host exclusion, signing, receipt reconciliation or automatic restore decision.
Missing device evidence remains a blocker even when its host report is present.

Outputs use recursively sorted JSON keys, sorted set-like evidence and one final
newline; order-sensitive signed bytes and playlist occurrences remain intact.
Absolute paths, timestamps, mtimes and random capture IDs are excluded. Identical
content and bindings produce identical bytes across source roots and input order.
Treat reports as trusted operator-collected evidence: they are not signed
attestations and comparison cannot authenticate a fabricated report.

Exit status 0 means evidence generation succeeded, **not** that `blocking` or
`findings` is empty. Malformed inputs and unsafe/unreadable sources return a
nonzero error; never interpret an absent report as a clean inventory.
Each JSON input is limited to 32 MiB; an oversized collection/report requires a
separately reviewed format change rather than silently truncating evidence.

`backup-manifest`, backup copying/encryption/custody, decryption and restore
verification are deferred to a second PR after this slice merges. Do not use
these reports as D5 backup verification.

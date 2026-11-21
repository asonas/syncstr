# Headless Syncstr

A standalone HTTPS node that accepts original audio from multiple clients, persists a catalog in SQLite, and serves verified downloads. It is intended for an always-on NAS. The first implementation targets Linux/amd64 and also runs locally on macOS.

This milestone includes the node API and a command-line client. Native macOS/iPhone NAS connection and upload controls, folder scanning, automatic uploads, Bonjour announcements, per-device pairing, Internet rendezvous, and relays are not implemented. The existing Mac-to-iPhone transfer path is unchanged. Any client with the node token can upload, list, and download; no device is assigned a permanent source role.

## Local development

The separate opt-in cluster commands require `cargo build --locked --features
p2p`. They add one-use enrollment, mDNS discovery, and verified LAN replication
between library hosts. See [M2 setup and protocol](../docs/cluster-lan-sync-m2.md).
The HTTPS-token commands below remain a separate legacy access path.

Rust 1.99 or later is required. From this directory:

```sh
cargo build --locked
target/debug/syncstr-headless init --identity identity --host localhost
target/debug/syncstr-headless serve --data data --identity identity
```

`init` creates a random 256-bit access token and a self-signed TLS certificate valid for the supplied DNS name or IP address. Identity files are private and never overwritten. The certificate expires after one year. The server listens on `127.0.0.1:8443` by default. Keep `tls.key` on the node; transfer only `tls.crt` and `token` to authorized clients over a trusted channel. Treat the token as a credential. The CLI checks the supplied certificate and the hostname, and rejects redirects.

In another terminal, from this directory:

```sh
target/debug/syncstr-headless upload --file ../apps/macos/Tests/Fixtures/untagged.mp3 \
  --title 'Example track' --artist 'Example artist' --album 'Example album'
target/debug/syncstr-headless catalog
target/debug/syncstr-headless download --id '<track-id-from-catalog>' --output ./received.mp3
```

All client commands accept `--url`, `--cert`, and `--token-file`. The default URL is `https://localhost:8443`; the default trust and token files are under `identity/`. Uploads use the filename as the title unless supplied explicitly. The CLI does not extract embedded tags or artwork yet; the API accepts metadata and artwork in the native `LocalEntry` JSON shape. Downloads verify size and SHA-256 before publication and refuse to overwrite existing files.

## Docker on a NAS

Keep the data directory on a local filesystem attached to the NAS. One process owns it using an OS file lock. Do not share a live SQLite database over NFS/SMB or mount an app's `LocalMusic` directory here. The node has its own schema and exchanges JSON with clients.

Create dedicated `data` and `identity` directories, owned by the UID/GID that will run the container. Compose defaults to UID/GID 1000; set `SYNCSTR_UID` and `SYNCSTR_GID` if needed. Run these commands from this directory on the host:

```sh
mkdir -p data identity
chmod 700 data identity
docker compose build
docker compose run --rm --no-deps --volume "$PWD/identity:/identity:rw" \
  syncstr init --identity /identity --host music.example.test
docker compose up -d
```

Replace `music.example.test` with the hostname clients actually use, or supply the NAS's LAN IP instead. Compose binds port 8443 to host loopback by default. To make it reachable on the LAN, set `SYNCSTR_BIND_ADDRESS` to the host's LAN address and recreate the container. The certificate name must match the client URL. `SYNCSTR_PORT` changes the host port.

The container uses its own TLS endpoint, a read-only root filesystem, a writable data mount, and a read-only identity mount. It does not need privileged mode or host networking. Both staging and published objects live under the same data mount. A Debian runtime image contains the Rust executable and dependency notices at `/usr/share/syncstr/licenses`. Build for the NAS's architecture; `docker build --platform linux/amd64` targets an x86-64 NAS.

This does not configure router forwarding or make a NAS behind NAT reachable from outside its network. Internet connectivity is a separate milestone. No existing music directories are scanned or modified; files enter through authenticated uploads.

## Version 1 HTTP contract

For opt-in QUIC transport and native macOS/iPhone clients, see [P2P music transfer](../docs/p2p-music-transfer.md). The default build and Docker command remain HTTPS-only.

Every endpoint of this contract requires `Authorization: Bearer <token>` over HTTPS. The node token currently authorizes all operations. There is no anonymous catalog endpoint, deletion endpoint, or credential query parameter in it. The separate read-only `/api/v1` listener that `serve --api-listen` adds is plain HTTP on loopback without a token; see [Host API design](../docs/host-api-design.md).

| Method and path | Contract |
|---|---|
| `GET /v2/catalog` | Returns `{id, name, entries, organization}` using the native catalog JSON field names |
| `POST /v2/tracks` | Multipart body: an `entry` JSON part followed by an `audio` binary part; returns the stored entry |
| `POST /v2/organization` | Merges bounded, validated organization JSON; retains competing explicit choices |
| `GET /v2/tracks/{id}/audio` | Returns original bytes by opaque track ID; supports one HTTP byte range and a SHA-256 ETag |

The entry contains `track`, `sha256`, and optional Base64 `artwork`. Track metadata uses the fields documented in the [local entry fixture](fixtures/local-entry.json). IDs and album grouping IDs from uploaders are not authoritative: the node assigns a track UUID and adjusts `coverArt` to that ID. Filesystem paths and multipart filenames are ignored. The node uses a separate HTTP transport; existing Bonjour/TLS-PSK clients cannot connect to it without a native client integration.

Limits are 1 MiB of encoded entry metadata, 512 KiB of decoded artwork, 20 GiB per audio file, and four simultaneous uploads. Accepted suffixes are MP3, M4A, AAC, FLAC, WAV, AIFF/AIF, and ALAC, expressed in lowercase. Size, digest, and suffix validation do not prove codec playability; clients remain responsible for decoding support. Originals are never transcoded or retagged.

The node deduplicates exact byte content with the same suffix. A retry from any client returns the existing track ID and metadata. Different metadata on a duplicate upload does not overwrite the first entry. A changed file hash creates a new entry; metadata editing, deletion, and conflict resolution are not implemented.

## Storage and recovery

For stopped, read-only host inventory and offline comparison with device intent
exports, see [Offline activation inventory](activation-inventory.md). These
commands collect evidence only; they do not activate or verify a recovery set.

### Maintenance freeze on a v5 host

A v5 host can refuse new writes while an activation is prepared. Run these on a
stopped host; each prints the control journal state as JSON.

```sh
target/debug/syncstr-headless shared-audio-control --data data init
target/debug/syncstr-headless shared-audio-control --data data freeze
target/debug/syncstr-headless shared-audio-control --data data status
target/debug/syncstr-headless shared-audio-control --data data release
target/debug/syncstr-headless shared-audio-control --data data designate \
  --coordinator <coordinator-host-key> --nonce <64-hex-digits>
```

- `init` creates the control journal. A host that has never run it accepts writes as before. `init` also raises the schema generation of `node.sqlite` from 5 to 6. Builds from before this guard refuse such a store, so after `init` the executable cannot be replaced by an earlier one; going back means restoring a backup taken before `init`. The [inventory comparison](activation-inventory.md) blocks with `divergence:schema` while some hosts ran `init` and others did not, so run it on every host before taking the inventories that an activation request names.
- `freeze` survives restarts. A frozen host refuses member mutations, administrative commits, playlist updates, new object uploads from members or the administrative route, revocations and imported membership. Members receive `deferred` with reason `maintenance-freeze` and keep their request queued.
- A frozen host still serves the catalog and audio, replicates records and audio with other hosts, and answers requests it accepted earlier with their original reply. Answering an earlier object upload publishes nothing and records nothing.
- A host signs a prepared acknowledgment, stores a certificate, or installs one only while frozen. It prepares or installs the next epoch only after the installation acknowledgment of every host that epoch still authorizes is recorded for the installed one.
- `release` is refused while a preparation or certificate is pending, including a preparation another host is known to hold, after an installation until every host's installation acknowledgment is recorded, and when membership has changed since the installed certificate was proposed. It records the release against the installed certificate.
- A halted or unreadable control journal refuses the same writes with reason `control-review-required` until it is reviewed. `freeze` remains available in that state.
- `designate` records the maintenance session the owner authorized: the coordinator's host key and a session nonce. The coordinator must be an authorized host. A pending activation keeps its session, and `release` removes the designation.
- A host acknowledges only its own input history, a digest of the signed music and playlist records it holds. From its prepare lock until the proposal is installed or aborted it refuses replicated records it does not hold; records it holds, audio and membership still replicate.
- A certificate for a proposal the host prepared installs even if membership changed afterwards to another revision that verifies. A membership that cannot be read or is disputed refuses both storing and installing it. `release` still refuses until a later epoch certifies the new membership. The next epoch excuses a missing installation acknowledgment only from a host its membership revokes.
- A signed abort, built from a withdrawal by every host of the proposal, resolves a proposal that has no certificate. `status` lists `aborted` and `withdrawn` proposals, `unacknowledged_hosts` and the `session`.

`shared-audio-serve` exchanges control records with other hosts before data:

- A host with a designated session fetches the control envelopes a peer holds and records those of that session. Without a designation it records none.
- Data then reconciles only with a peer at the same installed head, and with neither journal halted. A peer that has no control journal, or does not list the control protocol in its authenticated reply, reconciles only while this host has no installed head and nothing pending. If a peer lists it and the control exchange fails, data with that peer waits.
- Records pushed by another host are accepted only by a host with no control journal, or with no installed head and nothing pending.
- A host that never ran `init` reconciles as before.

It synchronizes with the hosts that local discovery reports, and with the hosts
whose address the owner gives:

```sh
# On host A, with a listen address that host B can reach, and B's file once it exists:
target/debug/syncstr-headless shared-audio-serve --data data --identity identity \
  --peer-state peer --peer-listen 192.0.2.10:7000 --peer-address-out host-a.json \
  --peer-address "$HOST_B_ID=host-b.json"
# On host B, the same with A's file:
target/debug/syncstr-headless shared-audio-serve --data data --identity identity \
  --peer-state peer --peer-listen 198.51.100.20:7000 --peer-address-out host-b.json \
  --peer-address "$HOST_A_ID=host-a.json"
```

- `--peer-address` is repeatable, once per host: two files for the same host are refused. The file is read once at startup. It is refused unless it names that host and lists between 1 and 32 IP addresses. This endpoint uses no relay, so the address must be reachable directly.
- A given address is added to what discovery reports for that host and is never replaced by it.
- A host reached this way passes the same membership check, control exchange and data gate as a discovered one.
- Every host fetches from the others, so both sides need a listen address the other can reach and the other's file. A host writes its file when it starts; start it once without the other's file to obtain it.
- With the default `--peer-listen 127.0.0.1:0` a host listens only on loopback and its port changes at every start. Use a fixed listen address. After an address changes, copy the file again and restart the hosts that read it.
- The host ID in the file is checked against the connection. The IP addresses are not: a host tries to connect to whatever the file lists.

After each pass a frozen host reacts to the records of its designated session:

- It withdraws from a proposal its coordinator withdrew from.
- It installs a certificate it holds and signs its installation acknowledgment.
- It prepares a proposal that extends the installed head. This build implements no projection profile yet, so it does not prepare a proposal that requires one.

A step that is refused is logged once and tried again after the next pass. A host
without a designation, or with a halted or unreadable journal, does nothing.

The designated coordinator drives the session. The owner records a request on
the stopped coordinator, and the serving host carries it out:

```sh
target/debug/syncstr-headless shared-audio-control --data data start \
  --inventory <64-hex-digits> --backup <64-hex-digits> [--profile <name>]...
target/debug/syncstr-headless shared-audio-control --data data abort
```

- `start` is refused unless the host is frozen and is the coordinator of its designated session, and while the proposal signed for an earlier request is neither aborted nor installed on this host. A request that signed nothing yet is replaced. `status` shows the `request`.
- The coordinator signs the proposal only after every host of the membership answered in the same pass and is frozen, designated for the session, and at the same installed head, membership revision and input history. A host that discovery does not report keeps it waiting, unless its address is given with `--peer-address`.
- It signs the certificate once every host prepared. It does not sign one after a membership change or after any host withdrew; such a proposal needs an abort.
- `abort` drops a request whose proposal was not signed yet. Otherwise the coordinator first synchronizes with every host of the proposal, withdraws only if none is halted or may hold a certificate, and signs the abort once every host withdrew. `abort` is refused once a certificate exists: the session then goes forward.
- An aborted proposal cannot be proposed again under the same session. Once every host holds the abort, designate a new session with another nonce on every host; the hosts can stay frozen.
- The coordinator logs each step and what it waits for as `Activation session ...`, once per change. Completion is logged too; `release` stays a command on each host.

`shared-audio-serve` checks the store before it opens its endpoint or its
listener, and refuses to start:

- when a profile of the stored floor is not implemented by this build. The floor holds the profiles of installed certificates and of unresolved prepare locks.
- when control storage exists and the schema generation is still 5. Run `init` again with this build.
- when the schema generation is above 6. A later build wrote the store.

`shared-audio-control` stays available in the first two cases. A store above
generation 6 needs the build that wrote it, also for `status`. A halted journal
does not stop the host from serving; it refuses writes.
The [control protocol design](../docs/v5-activation-control-protocol.md) describes
the rules above and the parts that follow.

- `node.sqlite` stores the node library UUID and track entries. Its schema version is 4, including organization records and verified artwork assets independent of audio entries.
- `objects/<sha256>.<suffix>` stores original bytes. Only committed catalog entries are accessible through the API.
- `staging/upload-*` holds incomplete uploads, removed on failure or at the next exclusive startup.
- `node.lock` prevents a second process from opening the same data directory. The OS releases the lock when the process exits; the lock file can remain.

Audio is streamed to staging, checked against the declared size and hash, flushed, and renamed into the object store before the catalog transaction commits. A failure after publication but before commit may leave an unlisted object. Retrying the upload replaces it with verified bytes and completes the catalog transaction. Garbage collection is deferred; the server does not delete published objects automatically. Missing or size-mismatched objects return a storage error; download clients verify the full digest before publishing a local copy.

To back up the node, stop it and copy both `data` and `identity`. To replace an expired certificate, create a separate identity directory, distribute the new certificate and token, stop the node, and update its identity mount. This deliberately revokes the old shared token. Per-device revocation and streamlined enrollment are future work.

## Verification

To exercise cluster enrollment on explicit loopback endpoints, `cluster-serve --peer-listen 127.0.0.1:0 --peer-address-out host.json
--no-discovery` publishes an atomic address file. `cluster-join --host-address
host.json --peer-listen 127.0.0.1:0` pins enrollment to the host ID in the
invitation. A second host uses `--no-discovery --peer-address ID=host.json` to
replicate from the specified member; normal membership checks still apply.
Without these options, cluster enrollment and discovery keep their LAN behavior.
The legacy service advertises enrollment, cluster v3, and playlist protocols;
`shared-audio-serve` supplies v5.

The Apple clients use the host read API. To exercise the optional macOS host interoperability test, set `SYNCSTR_HEADLESS_TEST_BINARY` to the headless executable in the test environment. The macOS CI job uses its protocol tests without building Rust fixture tools.

The [Verification workflow](../.github/workflows/verification.yml) runs every
P2P test target with `cargo test --locked --features p2p --tests`, followed by
library Clippy. New files under `tests/` join it without a workflow change.

Real multicast discovery and host-restart replication live in `lan_process`.
Its tests are `#[ignore]`d so the regular run skips them. Run them serially on a
network permitting mDNS when changing LAN discovery:

```sh
cargo test --locked --features p2p --test lan_process -- --ignored --test-threads=1 --nocapture
```

The manual [LAN verification workflow](../.github/workflows/lan-verification.yml)
runs these checks on Linux and macOS and retains its log for seven days, including
failed runs. It does not run on every pull request. A local discovery timeout also
reproduced on the baseline; separation does not resolve that failure or convert it
into a successful check. A hosted-runner pass is not proof of discovery between
physical devices on the listener's network.

Enrollment timeouts identify the current phase and number of resolved candidates.
Failed LAN subprocess tests include bounded server stdout/stderr and process
status; replica timeouts name the expected object and destination. Test identity,
invitation, and database files remain temporary and are not uploaded as artifacts.
The regular P2P suite lists the `lan_process` tests as ignored rather than
silently omitting them.

For a macOS timeout with no resolved candidates, see the
[LAN investigation](../docs/validation/lan-discovery.md). Check the launching
application's Local Network access before treating the timeout as a protocol bug.

```sh
cargo fmt --all -- --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
docker build --platform linux/amd64 -t syncstr-headless:check .
docker compose config --quiet
sh scripts/check_container.sh syncstr-headless:check
```

Tests exercise real TLS and SQLite: additions from two clients, retry identity, concurrent duplicate uploads, catalog restart, byte-identical downloads and ranges, corrupt/partial uploads, invalid credentials and trust, failed database writes, and exclusive directory ownership. A subprocess test runs the actual CLI through initialization, upload, restart, download, and SIGTERM shutdown. The [shared JSON fixture](fixtures/local-entry.json) round-trips through both Rust and the native Swift model tests. Container build/run, NAS deployment, and native device playback remain distinct verification steps.

The container check requires Python 3 and Docker. It creates dedicated temporary data and identity directories, runs under the invoking user's numeric UID/GID with the production filesystem restrictions, and removes its own container and temporary data afterward. It does not touch existing libraries or deploy to a NAS.

## Dependencies

The service uses Axum/Tokio for HTTP and asynchronous I/O, rustls for TLS, and rusqlite with bundled SQLite. Database operations run in Tokio's blocking execution pool and serialize through one connection; uploads stream directly to staging rather than being buffered in memory. Dependencies are pinned in `Cargo.lock`.

The Docker build runs [collect_licenses.py](scripts/collect_licenses.py), collecting packaged license and notice files for the target platform's dependency graph, plus available Rust toolchain notices. Its generated inventory records package names, versions, and declared licenses. Syncstr's own release license remains undecided.

The current API is `/v4`; `/v1`, `/v2`, and `/v3` return HTTP 426 and request a client update. Native protocol version 4 adds verified image frames separate from organization metadata and audio. Catalog schema 4 retains image assets, provenance and causal choices alongside the source-scoped membership evidence. Update both the node and native clients together; existing deployments are not updated by a local build. See [artwork verification](../docs/validation/compilation-artwork.md) for bounds and remaining limits.

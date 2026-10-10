# Headless Syncstr

A standalone HTTPS node that accepts original audio from multiple clients, persists a catalog in SQLite, and serves verified downloads. It is intended for an always-on NAS. The first implementation targets Linux/amd64 and also runs locally on macOS.

This milestone includes the node API and a command-line client. Native macOS/iPhone NAS connection and upload controls, folder scanning, automatic uploads, Bonjour announcements, per-device pairing, Internet rendezvous, and relays are not implemented. The existing Mac-to-iPhone transfer path is unchanged. Any client with the node token can upload, list, and download; no device is assigned a permanent source role.

## Local development

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

Every endpoint requires `Authorization: Bearer <token>` over HTTPS. The node token currently authorizes all operations. There is no anonymous catalog endpoint, deletion endpoint, credential query parameter, or plaintext listener.

| Method and path | Contract |
|---|---|
| `GET /v2/catalog` | Returns `{id, name, entries, organization}` using the native catalog JSON field names |
| `POST /v2/tracks` | Multipart body: an `entry` JSON part followed by an `audio` binary part; returns the stored entry |
| `POST /v2/organization` | Merges bounded, validated organization JSON; retains competing explicit choices |
| `GET /v2/tracks/{id}/audio` | Returns original bytes by opaque track ID; supports one HTTP byte range and a SHA-256 ETag |

The entry contains `track`, `sha256`, and optional Base64 `artwork`. Track metadata uses the fields documented in the [local transfer contract](../docs/local-music-transfer.md). IDs and album grouping IDs from uploaders are not authoritative: the node assigns a track UUID and adjusts `coverArt` to that ID. Filesystem paths and multipart filenames are ignored. The node uses a separate HTTP transport; existing Bonjour/TLS-PSK clients cannot connect to it without a native client integration.

Limits are 1 MiB of encoded entry metadata, 512 KiB of decoded artwork, 20 GiB per audio file, and four simultaneous uploads. Accepted suffixes are MP3, M4A, AAC, FLAC, WAV, AIFF/AIF, and ALAC, expressed in lowercase. Size, digest, and suffix validation do not prove codec playability; clients remain responsible for decoding support. Originals are never transcoded or retagged.

The node deduplicates exact byte content with the same suffix. A retry from any client returns the existing track ID and metadata. Different metadata on a duplicate upload does not overwrite the first entry. A changed file hash creates a new entry; metadata editing, deletion, and conflict resolution are not implemented.

## Storage and recovery

- `node.sqlite` stores the node library UUID and track entries. Its schema version is 2, including organization records independent of audio entries.
- `objects/<sha256>.<suffix>` stores original bytes. Only committed catalog entries are accessible through the API.
- `staging/upload-*` holds incomplete uploads, removed on failure or at the next exclusive startup.
- `node.lock` prevents a second process from opening the same data directory. The OS releases the lock when the process exits; the lock file can remain.

Audio is streamed to staging, checked against the declared size and hash, flushed, and renamed into the object store before the catalog transaction commits. A failure after publication but before commit may leave an unlisted object. Retrying the upload replaces it with verified bytes and completes the catalog transaction. Garbage collection is deferred; the server does not delete published objects automatically. Missing or size-mismatched objects return a storage error; download clients verify the full digest before publishing a local copy.

To back up the node, stop it and copy both `data` and `identity`. To replace an expired certificate, create a separate identity directory, distribute the new certificate and token, stop the node, and update its identity mount. This deliberately revokes the old shared token. Per-device revocation and streamlined enrollment are future work.

## Verification

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

The former `/v1` API returns HTTP 426 and requests a client update. Version 2 preserves imported metadata, album identity, former references, and explicit organization revisions without rewriting audio. Update both the node and native clients together; existing deployments are not updated by a local build. See [compilation verification](../docs/validation/compilation-albums.md).

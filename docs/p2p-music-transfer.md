# P2P music transfer

> [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md), accepted on 2026-11-18, replaces the design that this document describes. This guide covers the optional headless transport. See [Syncstr on a private network](private-network-architecture.md).

The headless node can serve a catalog and transfer audio to compatible peers over iroh QUIC when built with the `p2p` feature. Current Apple apps read a host's `/api/v1` over HTTPS.

## Start a node

From `headless/`:

```sh
cargo build --locked --features p2p
target/debug/syncstr-headless init --identity identity
target/debug/syncstr-headless peer-init --state peer
target/debug/syncstr-headless serve --data data --identity identity \
  --listen 127.0.0.1:8443 --peer-state peer --peer-address-out address.json
```

For an existing node, retain its `data` and HTTPS `identity` directories and omit `init`. `peer-init` creates a separate device key and prints its public ID. It never overwrites a key. Keep the peer directory private and writable. Only one process can use a peer identity or a data directory at a time.

`--peer-mode direct` is the default and disables relays. The address file contains the node's public ID and current UDP addresses. Firewalls must permit the node's UDP socket. This mode does not solve arbitrary NAT traversal. For remote networks, `--peer-mode auto` enables iroh's default public relays for connectivity and encrypted fallback while preferring direct paths. `relay-only` is available for diagnostics. No self-hosted relay or Cloudflare login service is added by this feature.

For a continuously running node, set `--peer-listen 192.0.2.10:58024` to bind P2P to a fixed UDP address. Keep the host's LAN address stable, persist the peer state directory, and allow that UDP port through the firewall. Saved connection JSON can then be reused after restart. Binding fails if the address is unavailable or the port is occupied; it does not select another port. Without this option, the node chooses an available port on startup. A fixed listen address cannot be combined with `relay-only` mode. When migrating an existing node, choose its currently advertised LAN port to preserve saved client connection information.

The address file is routing information, not an access credential. Share it and the node's independently verified public ID with the user. Restarting updates an existing address file only when it belongs to the same node; old direct addresses can become stale. The file does not update automatically after subsequent interface changes. Re-export it by restarting the node and replace the saved app connection when necessary.

### Direct access from cellular networks

Repeat `--peer-listen` to retain the LAN IPv4 socket and add an IPv6 socket on the same fixed UDP port:

```sh
target/debug/syncstr-headless serve --data data --identity identity \
  --listen 192.0.2.10:8443 --peer-state peer --peer-address-out address.json \
  --peer-listen 192.0.2.10:58024 --peer-listen '[::]:58024' \
  --peer-directory https://directory.example.com
```

The IPv6 wildcard socket advertises available IPv6 interface addresses, including a global address when the host has one. The directory republishes current candidates every 60 seconds, so directory-based app registrations do not need a new JSON record when addresses change. Direct-only mode still disables relays.

The host and upstream router must allow inbound UDP on this port to the NAS's global IPv6 address. Keep HTTPS restricted to the LAN. A cellular client must have a usable IPv6 route; an IPv4-only client instead needs a public IPv4 address and UDP port forwarding. Announcing an address does not configure either firewall or forwarding. For IPv4 forwarding, use the existing `--peer-public-address` option to publish the external UDP address alongside the local candidates.

Verify both LAN and an independent cellular network. Inspect the live address record and UDP sockets, then connect from a compatible peer on cellular, retrieve the catalog, and download a previously unsaved track. A local dual-stack test does not prove Internet reachability.

## Authorize a peer

Use the peer's public ID to authorize it on the node, then export the node address for the peer. Compare the exported node ID with the trusted node identity.

```sh
target/debug/syncstr-headless peer-pair --state peer --peer <device-public-id>
target/debug/syncstr-headless peer-info --state peer --address address.json --ip 192.0.2.10
```

Each authorized peer has catalog, download, and upload access. Revoke access on the node with `peer-pair --state peer --peer <device-public-id> --revoke`.

## Docker and deployment

```sh
docker build --build-arg SYNCSTR_FEATURES=p2p -t syncstr-headless:p2p headless
```

The normal Docker build remains HTTPS-only. A P2P deployment additionally needs a private writable peer mount, P2P serve arguments, and reachable UDP transport. A Linux host-network container is one way to expose its advertised addresses; a bridge-mode container needs explicit UDP routing and appropriate advertised addresses. The existing Compose/Coolify deployment is not changed by the implementation. Do not assume its HTTPS TCP mapping also exposes QUIC.

## Protocol and storage

ALPN is `syncstr/music/1`. QUIC authenticates the remote Ed25519 endpoint ID and encrypts application data. The server checks its allowlist before accepting requests and during chunk transfers. A device shares the node's existing SQLite store with the HTTPS API in the same process.

One bidirectional stream carries four-byte big-endian lengths and JSON `MusicMessage` frames, matching the native transfer fields. Frames use message version 2 and are capped at 2 MiB. Older message versions require upgrading both peers. Catalog and upload messages carry organization records. The ALPN name remains unchanged; the first framed message enforces the organization-capable version. A `hello` receives `catalog`, `entry` frames, then `ready`. `get` takes an opaque track ID and returns `data` frames with Base64 chunks of at most 64 KiB, followed by `end`. `put` supplies an entry, waits for `accept`, sends `data` and `end`, and receives `saved` with the canonical node entry. There is no remote filesystem-path argument.

Audio is staged and checked against the exact size and SHA-256 before publication. Metadata and audio limits match the HTTPS service. The node allows four P2P connections and applies handshake, frame-read, and session timeouts. Invalid, corrupt, partial, or revoked transfers cannot publish an incomplete object. Exact hash/suffix retries preserve the first node ID and refresh metadata from the newly uploaded record. Album membership and classification choices are retained and reconcile with catalog refreshes, including conflicts. Automatic collection, source-tag editing, deletion, and multi-library ownership remain deferred.

## Verification

```sh
cargo test --manifest-path headless/Cargo.toml --locked --features p2p
cargo clippy --manifest-path headless/Cargo.toml --locked --features p2p --all-targets -- -D warnings
```

The Rust suite exercises the optional headless transport. The Apple apps no longer use the iroh Swift bindings or run the former Swift/Rust P2P interoperability suite.

# P2P music transfer

The macOS and iPhone apps can explicitly connect to a headless node over iroh QUIC, browse its catalog, save albums, and upload selected audio files. The HTTPS API and Bonjour transfer remain available. P2P is an opt-in headless build feature; enabling it does not migrate the database or change existing pairing credentials.

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

The address file is routing information, not an access credential. Share it and the node's independently verified public ID with the user. Restarting updates an existing address file only when it belongs to the same node; old direct addresses can become stale. The file does not update automatically after subsequent interface changes. Re-export it by restarting the node and replace the saved app connection when necessary.

## Register an app

1. Open Settings → P2P music sharing. On a new iPhone installation the same controls are available on the initial setup screen.
2. Copy the app's device ID. On the node, explicitly authorize it:

   ```sh
   target/debug/syncstr-headless peer-pair --state peer --peer <device-public-id>
   ```

3. In the app, enter a name, the independently confirmed node ID, and the contents of `address.json`. Connect. A mismatch is rejected before connecting.
4. Open an album and save it. iPhone retains the existing album/track download controls; macOS provides an album save button and a track context-menu save action. Completed files remain playable offline.
5. Use **Add audio files to the connected device** to select files through the native file picker. Uploads preserve original bytes and use the filename as the title. Embedded tag extraction for this picker is not implemented. Reconnect to refresh the catalog after additions.

The app stores its private device key and registered node record in separate Keychain services. Removing a P2P connection retains downloaded files, the app's device identity, and Bonjour pairing. Removing an app-side record does not revoke access at the node. Revoke explicitly:

```sh
target/debug/syncstr-headless peer-pair --state peer --peer <device-public-id> --revoke
```

Every allowed device currently has catalog, download, and upload access. There is no read-only permission or automated enrollment. Keep the iPhone app in the foreground during transfer; backgrounding cancels it. Retry verifies completed downloads and skips them. An interrupted upload can be retried without creating a duplicate track. Playback and audio background operation retain their existing behavior.

## Docker and deployment

```sh
docker build --build-arg SYNCSTR_FEATURES=p2p -t syncstr-headless:p2p headless
```

The normal Docker build remains HTTPS-only. A P2P deployment additionally needs a private writable peer mount, P2P serve arguments, and reachable UDP transport. A Linux host-network container is one way to expose its advertised addresses; a bridge-mode container needs explicit UDP routing and appropriate advertised addresses. The existing Compose/Coolify deployment is not changed by the implementation. Do not assume its HTTPS TCP mapping also exposes QUIC.

## Protocol and storage

ALPN is `syncstr/music/1`. QUIC authenticates the remote Ed25519 endpoint ID and encrypts application data. The server checks its allowlist before accepting requests and during chunk transfers. A device shares the node's existing SQLite store with the HTTPS API in the same process.

One bidirectional stream carries four-byte big-endian lengths and JSON `MusicMessage` frames, matching the native transfer fields. Frames are capped at 2 MiB. A `hello` receives `catalog`, `entry` frames, then `ready`. `get` takes an opaque track ID and returns `data` frames with Base64 chunks of at most 64 KiB, followed by `end`. `put` supplies an entry, waits for `accept`, sends `data` and `end`, and receives `saved` with the canonical node entry. There is no remote filesystem-path argument.

Audio is staged and checked against the exact size and SHA-256 before publication. Metadata and audio limits match the HTTPS service. The node allows four P2P connections and applies handshake, frame-read, and session timeouts. Invalid, corrupt, partial, or revoked transfers cannot publish an incomplete object. Exact hash/suffix retries preserve the first node ID and metadata. Automatic collection, metadata editing, deletion, and multi-library merging remain deferred.

## Verification

```sh
cargo test --manifest-path headless/Cargo.toml --locked --features p2p
cargo clippy --manifest-path headless/Cargo.toml --locked --features p2p --all-targets -- -D warnings
```

Build the Rust binary with `p2p` before running the macOS suite. `PeerTransferTests` runs the actual Rust executable with temporary identities and tests the native Swift client through upload, deduplication, reconnect, download, offline storage, and revocation. It skips explicitly if the executable is absent. Existing LAN tests protect prior pairing and saved music behavior. iPhone Simulator builds/tests, physical-device transfers, independent-network NAT traversal, and NAS deployment are separate checks.

The app uses the official [iroh Swift bindings](https://github.com/n0-computer/iroh-ffi/tree/v1.1.0), pinned to 1.1.0. The node pins iroh 1.3.0; cross-version interoperability is covered by the macOS/Rust test. App dependency notices are bundled in each `Licenses/IrohLib.txt`. Regenerate them using a source checkout at the pinned Swift release:

```sh
mise exec -- python3 apps/macos/scripts/collect_iroh_notices.py ./iroh-ffi
```

# Device connectivity probe

An isolated Rust experiment for persistent device identity, explicit mutual pairing, and authenticated peer-to-peer QUIC connectivity. It sends 64 KiB of synthetic data and verifies the receiver's SHA-256 response. It does not expose the music catalog, modify the headless database, or replace the deployed HTTPS node.

The question is whether keyed QUIC can provide a direct path between a native client and a Linux NAS, while retaining an encrypted relay alternative. This experiment uses [iroh 1.3.0](https://docs.rs/iroh/1.3.0/iroh/), pinned separately from the production headless dependency graph. The native music transport is described in [P2P music transfer](../../docs/p2p-music-transfer.md); independent-network and physical-device verification remain pending.

## Run

From this directory, with Rust 1.99 or later:

```sh
cargo build --locked
python3 scripts/check_modes.py target/debug/syncstr-connectivity-probe --mode direct
```

The script creates two temporary device identities, explicitly pairs their public keys, runs a listener and probe, and removes its private state afterward. No relay or address lookup service is contacted in `direct` mode.

To exercise relay behavior with disposable identities and synthetic data:

```sh
python3 scripts/check_modes.py target/debug/syncstr-connectivity-probe --mode auto --relay-url https://relay.example.com
python3 scripts/check_modes.py target/debug/syncstr-connectivity-probe --mode relay-only --relay-url https://relay.example.com
```

`auto` requires an explicit user-operated relay and attempts direct UDP paths. `relay-only` requires that same configuration and disables direct IP transports for a deterministic relay-path check. Both fail without `--relay-url`; neither falls back to public default relays. The minimal endpoint preset avoids public DNS address publication and lookup, and the Rust probe disables automatic router port mapping. Relays receive endpoint IDs and connection metadata and forward encrypted application traffic. Remote probes use the approved ID plus relay URL without importing the listener's address file. Supply an accessible test relay whose access policy admits the disposable test devices; the script does not configure that service.

## Two devices

On each device, create a dedicated experimental state directory and obtain its public ID:

```sh
target/debug/syncstr-connectivity-probe --state .probe-state init
target/debug/syncstr-connectivity-probe --state .probe-state id
```

Compare each ID through a trusted channel and explicitly approve the other device on both sides:

```sh
target/debug/syncstr-connectivity-probe --state .probe-state pair --peer '<approved-peer-id>'
```

On the accepting device:

```sh
target/debug/syncstr-connectivity-probe --state .probe-state listen \
  --mode direct --address-out address.json
```

Transfer `address.json` to the initiating device. It contains public routing information, not the private key. It may disclose IP addresses, so treat it as private operational metadata. Use a fresh output filename on each listener start. Never transfer `device.key`.

On the initiating device:

```sh
target/debug/syncstr-connectivity-probe --state .probe-state probe \
  --mode direct --require-direct --peer '<approved-peer-id>' --address address.json
```

Use `auto` on both devices when checking different networks. A report with a selected `direct` path verifies the observation at the beginning and end of the probe. It does not prove every packet used that path during an automatic migration. Only relay-disabled tests rule out relay traffic entirely. If direct establishment is required, add `--require-direct`; a timeout is a failure, not evidence of direct connectivity.

For relay bootstrap, pass `--relay-url https://relay.example.com` to both commands. The probe can omit `--address` when given a relay URL. An address file containing a different relay is rejected. `paths_connected` captures the path immediately after connection; `paths_before` and `paths_after` surround the payload transfer, after any `--require-direct` wait.

For revocation:

```sh
target/debug/syncstr-connectivity-probe --state .probe-state unpair --peer '<approved-peer-id>'
```

The listener checks the allowlist for each new connection before reading any application data. Revocation does not cancel an already accepted probe. Both peers authenticate cryptographic endpoint IDs; an IP address or an address file alone does not authorize a device. Address-file IDs must match the explicitly supplied approved ID.

`device.key` is created with mode 0600, never overwritten, and remains stable across restarts. An exclusive file lock prevents concurrent endpoints using one device state. Pairing records persist as public-key-named markers. Initialization and pairing fail rather than silently overwriting existing files. The command exits on SIGINT/SIGTERM. The experiment currently supports macOS and Linux, not Windows.

## Verification and limits

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --all -- --check
```

The default suite exercises persistent identity, pairing/revocation, CLI lifecycle, explicit relay configuration, local relay transfer, and direct-path establishment through relay bootstrap. Its relay binds only to loopback and admits only the two disposable endpoint IDs. It uses pinned `iroh-relay` 1.3.0 over loopback HTTP, not a public relay or a production TLS deployment.

`tests/relay_tls.rs` additionally verifies HTTPS/WebSocket admission, rejection of unknown keys and untrusted certificates, and hash-checked transfer after a relay restart with the same endpoints. The fixture generates an ephemeral certificate and explicitly trusts only that certificate; it does not disable TLS verification or install certificates into the OS. Endpoint IP transports and port mapping are disabled. The relay restarts at the same URL, and the second transfer opens a new QUIC connection. Run it independently with `mise exec -- cargo test --locked --test relay_tls`. A successful handshake and transfer do not validate reverse-proxy configuration, a deployment health endpoint, or uninterrupted in-flight transfers.

### Apple interoperability experiments

The [disposable Linux lab](network-lab/README.md) verifies actual UDP blocking and restoration, WAN-isolated LAN discovery, and a pinned relay process behind a TLS/WebSocket proxy. These privileged, ignored tests run only inside a dedicated VM; ordinary `cargo test` does not alter network rules.

The standalone Swift probe pins the same IrohLib 1.1.0 release as the apps. It does not launch Syncstr, use its Keychain, or touch its library. On an Apple Silicon Mac with Swift 6 or later:

```sh
mise exec -- swift build --package-path apple
env SYNCSTR_APPLE_PROBE="$PWD/apple/.build/debug/AppleConnectivityProbe" \
  mise exec -- cargo test --locked --test relay apple_client -- --ignored --nocapture
env SYNCSTR_APPLE_PROBE="$PWD/apple/.build/debug/AppleConnectivityProbe" \
  mise exec -- cargo test --locked --test lan -- --ignored --nocapture
```

These explicit tests fail if the executable is missing; ordinary `cargo test` reports them as ignored. The LAN test requires an IPv4 LAN interface and multicast permission. It advertises a disposable `_syncstr-probe._udp.local.` DNS-SD service using pinned `mdns-sd` 0.21.5. Its SRV/A records supply the UDP destination; TXT carries `version=1` and the full public `id`. Apple's Bonjour resolves it, checks the expected ID and version, then connects using that cryptographic identity. Discovery alone does not authorize the device. This experimental service is independent of the existing product's Bonjour protocol.

The Rust listener disables IP transports for the Swift relay test, so the payload must traverse the loopback relay. The LAN test disables relays on both sides. Each transfers 64 KiB of synthetic bytes and checks the SHA-256 response. Neither test changes firewall rules. Read [M0 observations](../../docs/cluster-connectivity-m0.md) before interpreting these results as external-network or offline-LAN proof.

Manual checks on 2026-10-07 verified a Mac-to-Linux-NAS direct probe with relays disabled, an `auto` probe, and a forced relay probe using fresh experimental identities. The NAS check used a temporary host-network container, removed afterward. These checks do not establish connectivity through independent NATs, a mobile carrier, or a physical iPhone/Android client. No production service configuration or credentials were changed.

Cluster enrollment, production relay deployment, music replication, resumable downloads, and background operation are not implemented here. Before product integration, verify independent network paths and native platform lifecycle behavior. Keep account authentication separate from peer cryptographic identity.

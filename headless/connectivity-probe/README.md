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
python3 scripts/check_modes.py target/debug/syncstr-connectivity-probe --mode auto
python3 scripts/check_modes.py target/debug/syncstr-connectivity-probe --mode relay-only
```

`auto` uses iroh's default public relay servers to establish connectivity and attempts direct UDP paths. `relay-only` disables direct IP transports for a deterministic relay-path check. These servers receive endpoint IDs and connection metadata, and forward encrypted application traffic. Neither mode uses Cloudflare. The minimal endpoint preset avoids public DNS address publication and lookup; an address file is exchanged explicitly.

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

Three tests exercise real QUIC and CLI processes: persistent private identity and pairing; mutually approved direct communication with unpaired/revoked peers rejected; and CLI initialization, probing, revocation, and SIGTERM shutdown. All automated tests disable relays and external address lookup.

Manual checks on 2026-10-07 verified a Mac-to-Linux-NAS direct probe with relays disabled, an `auto` probe, and a forced relay probe using fresh experimental identities. The NAS check used a temporary host-network container, removed afterward. These checks do not establish connectivity through independent NATs, a mobile carrier, or a physical iPhone/Android client. No production service configuration or credentials were changed.

Cloudflare login, user-to-device key registration, QR enrollment, rendezvous, a self-hosted relay, native bindings, file transfer, resumable downloads, and background operation are not implemented here. Before product integration, verify independent network paths and native platform lifecycle behavior. Keep account authentication separate from peer cryptographic identity.

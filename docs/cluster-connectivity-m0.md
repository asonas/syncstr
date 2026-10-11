# M0 connectivity experiments

Status: local interoperability verified; the full [M0 acceptance gate](cluster-implementation-plan.md#m0-verify-connectivity-choices) remains open.

The isolated [connectivity probe](../headless/connectivity-probe/README.md) extends the existing experiment. Production applications, saved pairings, deployed headless nodes, and router rules are unchanged.

## Observations

Measured on an Apple Silicon Mac on 2026-10-11 with Rust 1.99 and Swift 6.4:

| Experiment | Result | Limit |
| --- | --- | --- |
| Rust 1.3.0 endpoints, custom Iroh relay 1.3.0, endpoint ID plus relay URL, no direct addresses | 64 KiB transfer and SHA-256 match; selected relay path | Both endpoints and relay were on one machine. IP transports were disabled, not interrupted dynamically. |
| Rust automatic mode, same bootstrap, no stored IPs | Selected relay path on connection, then selected direct path before and after the verified payload | Not independent NATs or evidence of every transition under packet loss. |
| IrohLib 1.1.0 Swift initiator to Rust listener through custom relay | 64 KiB transfer and SHA-256 match; selected relay path | macOS executable, not physical iPhone. Listener IP transports were disabled. |
| Rust DNS-SD advertisement to Apple Bonjour, both endpoints relay-disabled | Service resolved and verified payload used a direct path | Same machine on a live IPv4 LAN; WAN was not disabled. Reverse discovery and network changes are untested. |
| Rust relay client over HTTPS/WebSocket | Allowed key connected; unknown key was explicitly denied; a different certificate trust anchor failed certificate validation | Loopback fixture with an ephemeral self-signed certificate explicitly trusted by the test; no public certificate authority or reverse proxy. |
| Existing Rust endpoints across TLS relay shutdown and restart | Connection failed while the relay was stopped; the same endpoints and IDs transferred and hash-checked 64 KiB before and after restart | A new QUIC connection was opened for the second transfer. This does not prove continuity of an in-flight stream or process-level service supervision. |

All relay fixtures listen only on loopback and restrict admission to explicit disposable public keys. The original interoperability fixtures use HTTP. The Rust TLS fixture uses real HTTPS/WebSocket connections with certificate validation enabled and an explicit test trust anchor. Proxy handling, public certificate issuance, operational health checks, process supervision, and production admission configuration remain unvalidated. Do not deploy these fixtures as public services.

Initial verification: all eight probe integration tests passed with `--include-ignored`, including the Swift relay and Bonjour cases. Swift package build, Rust Clippy with warnings denied, and formatting checks passed. After the TLS extension, all eight Rust tests passed, with the two unchanged native Apple experiments explicitly ignored; Clippy and formatting also passed. This is the isolated probe suite, not the production application's test suite.

## Integration implications

The measured relay transfer supports endpoint-ID-plus-custom-relay bootstrap without making the signed directory mandatory. The DNS-SD experiment supports using a small shared record contract with native Bonjour on Apple and `mdns-sd` on Rust. These are candidate integrations, not changes to the production protocol or final platform support claims.

The checked IrohLib 1.1.0 surface exposes `RelayMode.customFromUrls`, `presetMinimal`, and connection path snapshots. Its endpoint builder does not expose Rust's portmapper configuration, clear-IP-transports operation, or an mDNS lookup configuration. Native Bonjour can supply addresses independently, as the experiment demonstrates. A narrow binding extension or a verified upstream release is needed to give Apple the same explicit local-only portmapping control before claiming complete network isolation. Do not silently use the public default preset to fill this gap.

## Remaining acceptance work

1. Block and restore direct UDP in an isolated test network; measure fallback and upgrade on an established connection.
2. Disable WAN access in that test environment; verify cross-device LAN discovery and transfer. Audit actual network traffic, including the Swift binding's router discovery behavior.
3. Extend the local TLS, WebSocket, admission-rejection, and server-restart checks to a pinned deployment: verify public certificates, reverse-proxy behavior, process restart, and health checks. Keep the template private until its deployed access controls are validated.
4. Exercise the native iPhone client on cellular without relying on the existing manual home-router permission rule, in an explicitly authorized setup.

The local results do not close these gates or establish Android/Windows behavior. M1 data-model migration and production connectivity changes are not included in this experiment.

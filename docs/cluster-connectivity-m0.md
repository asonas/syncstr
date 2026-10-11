# M0 connectivity experiments

Status: M0 experiment gates satisfied on 2026-10-11. Production application and physical cellular acceptance remain in M3 and M4 of [the implementation plan](cluster-implementation-plan.md#implementation-sequence-and-acceptance-gates).

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
| Linux firewall drops IPv4 and IPv6 UDP on an established connection, then removes the rules | Selected direct, relay, and direct paths in that order; each phase transferred and hash-checked 64 KiB on the same QUIC connection; 34 UDP packets were dropped | Disposable VM, not independent home/carrier NATs. Recovery includes Iroh's periodic direct-path upgrade interval. |
| Two Linux network namespaces connected only by a veth LAN | IPv4 and IPv6 WAN route lookups failed; DNS-SD discovery and 64 KiB verified direct transfer succeeded between separate processes | Logical nodes in one VM. Apple record interoperability was measured separately on macOS. |
| Separate pinned relay process behind nginx TLS/WebSocket proxy | Health reported `ok` and version `1.3.0`; unknown keys and untrusted certificates failed; process termination produced HTTP 502; restart restored verified relay transfer and still rejected unknown keys | Ephemeral test CA, loopback listeners, manual test-process restart. Not ACME issuance, production supervision, or uninterrupted in-flight transfer. |

All relay fixtures listen only on loopback and restrict admission to explicit disposable public keys. The original interoperability fixtures use HTTP. TLS fixtures use real HTTPS/WebSocket connections with certificate validation enabled and an explicit test trust anchor. The [Linux lab](../headless/connectivity-probe/network-lab/README.md) additionally validates proxy handling, process restart, admission, and health. Public certificate issuance and production supervision remain deployment work. Do not deploy these fixtures as public services.

Initial verification: all eight probe integration tests passed with `--include-ignored`, including the Swift relay and Bonjour cases. Swift package build, Rust Clippy with warnings denied, and formatting checks passed. After the TLS extension, all eight Rust tests passed, with the two unchanged native Apple experiments explicitly ignored; Clippy and formatting also passed. This is the isolated probe suite, not the production application's test suite.

## Selected integrations

Select Iroh 1.3.0 with an explicitly configured Iroh relay 1.3.0 for remote bootstrap and encrypted fallback. Endpoint ID plus custom relay URL worked without a directory or stored peer IP. Keep the signed directory optional. Use native Bonjour on Apple and `mdns-sd` 0.21.5 on Rust, sharing the experimental SRV/A/AAAA plus `version` and full `id` TXT contract. Authentication still pins the expected endpoint ID; discovery does not grant membership. These decisions do not change production behavior or establish Android/Windows support.

The tested proxy configuration requires a TLS TCP frontend and a loopback-only HTTP TCP backend. WebSocket upgrades and long-lived connections must pass through the proxy. The relay's optional QUIC discovery service was disabled; no relay UDP listener was required for these experiments. Peer-to-peer direct paths use UDP. A public port number, certificate issuance, and operational limits belong to the M4 package.

The checked IrohLib 1.1.0 surface exposes `RelayMode.customFromUrls`, `presetMinimal`, and connection path snapshots. Its endpoint builder does not expose Rust's portmapper configuration, clear-IP-transports operation, or an mDNS lookup configuration. Native Bonjour can supply addresses independently, as the experiment demonstrates. A narrow binding extension or a verified upstream release is needed to give Apple the same explicit local-only portmapping control before claiming complete network isolation. Do not silently use the public default preset to fill this gap.

## Acceptance mapping

1. Custom relay and ID-only bootstrap: Rust and native Apple probe interoperability passed with explicit custom relay configuration and the minimal preset.
2. Path observation and fallback: the Linux lab proved actual UDP loss, same-connection fallback, and direct upgrade after restoring UDP, with verified payloads throughout.
3. WAN-independent LAN: separate namespaces with no WAN routes discovered and transferred successfully. The separate native Apple experiment proves compatibility with the advertised DNS-SD record contract. The Swift binding surface was audited; its portmapper-control gap is recorded above for application integration.
4. Pinned test-host relay configuration: the Linux VM ran relay 1.3.0 as a separate process behind a TLS/WebSocket proxy, with health, restart, certificate validation, and restrictive endpoint admission verified.

The three Linux lab tests passed together in 68 seconds. TLS and firewall phases verified the known fixture SHA-256 `4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2`; LAN transfer verified the probe's per-run payload digest.

## Later acceptance work

M3 must integrate the selected mechanisms into the apps, address the binding gap, and verify platform lifecycle behavior. M4 must test a physical iPhone on cellular without the existing manual router permission rule, inspect traffic for implicit external services, and validate the public deployment package. Existing manually permitted 4G connectivity is not evidence for that gate. No production router rule was changed by M0. M1 persistence work can proceed independently of these later application/deployment gates.

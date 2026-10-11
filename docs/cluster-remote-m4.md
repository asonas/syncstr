# M4 optional remote access

Status: M4 acceptance passed in an isolated user-operated NAS test setup.
Physical cellular relay transfer and relay-off LAN direct transfer were verified
separately. The limits of that evidence are recorded below.

## Transport and registration

Use a user-operated Iroh relay 1.3.0. No shared Syncstr service, signed directory,
or public Iroh default is required. Endpoints use the Minimal preset and an
explicit custom relay map, or disable relays when remote access is unconfigured.
The existing signed cluster protocol and membership checks apply to both paths.

`cluster-relay --data ./data --url https://relay.example.net/` saves a single
transport hint in the host's SQLite catalog. The additive table does not replace
cluster identity, membership, catalog rows, receipts, or managed files. A fresh
invitation includes the optional `relay` field. Apple apps and `cluster-join`
persist that URL beside enrollment; invitation secrets remain single-use and
are not retained in client registration.

Production relay URLs require HTTPS and a root URL without credentials, query,
fragment, or port zero. HTTP is accepted only for numeric loopback fixtures.
TLS certificate verification is not disabled. Invitations and enrollment remain
LAN operations. Configuring remote access permits authenticated cluster traffic
from external IP or relay paths, but does not allow Internet enrollment.

On Apple, authorized library-host IDs plus the saved relay URL provide bootstrap
without stored IP addresses. Bonjour addresses are included when discovered,
and discovered hosts are tried first. A relay outage does not prevent a known
LAN direct path. Headless replication includes authorized hosts known from
membership even when no LAN advertisement is available. Port mapping stays
disabled in the Rust endpoint; direct upgrades and encrypted relay fallback use
Iroh's explicit custom relay. No automatic public-default fallback is added.
When remote access is configured, a global IPv6 address on the selected LAN
interface is also bound when available. The TCP-only relay package does not
promise direct traversal across every IPv4 NAT; encrypted relay fallback remains
necessary when usable direct candidates cannot be established.

The existing IrohLib binding does not expose portmapper control. Its Minimal
preset and explicit relay selection avoid public lookup defaults, but that API
limit is not proof of complete WAN isolation. Physical traffic inspection remains
part of acceptance; see the [M0 binding audit](cluster-connectivity-m0.md).

## Deployment package and operation

The [deployment package](../headless/remote-access/README.md) pins Iroh 1.3.0 and
Caddy 2.11.7, retains HTTPS certificate volumes, and keeps the backend private.
Only TCP 80 and 443 are published on the user-owned relay host. The relay's QUIC
discovery service is not enabled. An existing Coolify TLS/WebSocket proxy can
replace Caddy after verification.

`cluster-relay-ids` exports currently authorized endpoint IDs, excluding revoked
or disputed members. The relay reads an explicit bounded JSON admission list;
missing or invalid admission fails closed. Admission is separate from music
authorization. Updating the file permits new connections; removing a member
also requires a relay restart to drop existing relay connections and cluster
revocation to deny music access. No password or private device key is stored by
the relay package.

`relay-health` checks actual HTTP health and the pinned relay version, including
failure when the process stops. Upgrade and URL rotation instructions preserve
device identity and require verified client compatibility. Existing Apple
devices receive a rotated URL through a fresh LAN invitation from the same host
and for the same role. A LAN-only invitation clears the optional URL.

## Local checks and remaining acceptance

The implemented tests cover:

- CLI setting persistence, invitation export, invalid URL rejection without
  overwriting a working setting, and disabling remote access.
- Apple registration restoration without saving the invitation secret.
- A real private relay with no direct IP transport on the serving host, verified
  original-file download, observed relay path, endpoint admission rejection,
  membership-based admission export, and process health before and after stop.
- Native Apple enrollment over LAN followed by relay-only catalog and audio
  download, registration restoration, hash verification, and observed direct
  LAN reconciliation after stopping the relay.

An isolated Linux NAS image built successfully and includes the reachable
dependency license inventory. A private relay backend and a separate fixture
library started through Docker Compose. A user-managed Tunnel HTTPS frontend
passed the real `relay-health` version check from both macOS and the NAS.
LAN enrollment of a separate physical iPhone test app succeeded, and its verified
endpoint was added to relay admission. The library can run with `--relay-only`
for cellular checks without depending on an existing home-router UDP rule.
These checks preserve the existing library service and device registrations.

The user confirmed a previously unsaved audio file downloaded on the physical
iPhone over 4G while the serving endpoint had all direct IP transports disabled.
This verifies the public relay transfer without a home-router permission rule.
Physical playback also succeeded. The user could not confirm the displayed
path; playback alone does not verify that UI state. The relay was then stopped,
the host's LAN transport restored, and another previously unsaved audio file
was downloaded and played on the physical iPhone over Wi-Fi. Successful transfer
with the sole configured relay stopped separately verifies the LAN direct path.
The corresponding on-screen path label remains unconfirmed.

A physical iPhone packet capture covered approximately 17 seconds including app
reopening and LAN catalog refresh. PKTAP process attribution was matched to the
separate test application's installed executable. Attributed traffic consisted
of direct NAS UDP, local DNS responses, and attempts to reach the explicitly
configured relay's resolved addresses over HTTPS and QUIC discovery. DNS
questions in that capture named only the configured relay. No implicit
Syncstr-operated or public Iroh endpoint was observed in that interval. This is
bounded runtime evidence, not a guarantee about every future network state.
Raw device captures and operational identifiers are not published here.

The authorized setup used an existing user-managed HTTPS Tunnel rather than
deploying the supplied Caddy frontend. The Caddy configuration passed validation,
but the complete Caddy Compose deployment was not exercised. Direct WAN traversal
across independent networks and physical transfer interruption remain unverified;
remote reachability was demonstrated through encrypted relay fallback. Preserve
the [M3 manual checks](cluster-apple-m3.md) in TestFlight validation.

The shared registration screen shows the configured relay and the most recent
observed transfer path. Both Apple targets compile; visual inspection of these
states on macOS and iPhone remains a manual verification gap.

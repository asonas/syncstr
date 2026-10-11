# Optional user-operated remote relay

This package runs Iroh relay **1.3.0** behind Caddy **2.11.7**. Build the
headless image from the same pinned Syncstr commit as the clients. The relay
does not store a music catalog, receive music files, or grant cluster membership.
It routes end-to-end encrypted traffic and helps peers find direct UDP paths.
There is no Syncstr-operated service or public-default relay fallback.

Run it on a publicly reachable machine you control, separate from the home LAN
when home-router changes are undesirable. LAN-only users do not need this
package. A relay on a private NAS still needs a reachable HTTPS frontend; simply
starting the container does not make it Internet-accessible.

## Admission and deployment

1. Enroll devices on the LAN first. Record the endpoint IDs displayed by Syncstr
   and the headless CLI. Create `config/allowed-ids.json` containing a JSON array
   of the exact permitted public endpoint IDs, including every library host and
   playback device that will use the relay. A stopped library host can export
   the currently authorized members with `cluster-relay-ids --data ./data`;
   redirect that command's JSON output to this file. Empty, malformed, or missing files
   fail closed. No username, password, invitation secret, or private key belongs
   in this file. Make the directory readable and the file readable by UID 1000.
2. Copy `.env.example` to `.env` and replace the example domain. Its DNS must
   reach this machine. Allow TCP 80 and 443 on this relay machine for HTTPS and
   certificate issuance; do not open music-serving ports on the home router.
3. From this directory, run:

   ```sh
   docker compose build --pull
   docker compose up -d
   docker compose ps
   docker compose exec relay syncstr-headless relay-health --url http://127.0.0.1:8080/
   ```

Only the TLS proxy has public ports. Do not publish backend port 8080. The relay's
QUIC discovery listener is disabled; the frontend exposes TCP only. Caddy handles
WebSocket upgrades and obtains certificates. Persist its named volumes across
upgrades. [Caddy's proxy documentation](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
describes WebSocket handling.

For an existing TLS reverse proxy, deploy only the `relay` service and route the
public HTTPS hostname to its private HTTP port. Preserve WebSocket upgrades and
long-lived bidirectional connections. Coolify can provide that frontend instead
of the supplied Caddy service; check the actual proxy configuration and public
certificate before registering the URL. Do not put a browser-login page in front
of the relay endpoint.

## Library hosts and invitations

Stop each headless library process before using CLI commands against its data
directory. The catalog has an exclusive process lock. Configure the same HTTPS
relay URL on the library hosts:

```sh
syncstr-headless cluster-relay --data ./data --url https://relay.example.net/
syncstr-headless cluster-invite --data ./data --peer-state ./identity --output ./invitation.json --qr
syncstr-headless cluster-serve --data ./data --peer-state ./identity
```

The invitation carries the URL but remains a single-use LAN enrollment secret.
Apple apps and a headless `cluster-join` save the URL beside their registration.
They do not save the invitation secret. Knowing the URL does not authorize music
access: the relay checks endpoint admission, and library hosts independently
verify cluster grants and revocations. QR registration remains on the LAN.

Permit a new endpoint ID before attempting remote access. Membership changes do
not automatically update this separate relay's admission file. Updating the
directory-mounted JSON file affects new connections. To terminate connections
already admitted after removing an ID, restart the relay as well as revoking
cluster membership at a library host.

## Health, upgrades, and configuration rotation

`relay-health` checks `/healthz`, its `ok` status, and its pinned `1.3.0` version.
Check the public URL from a different network too:

```sh
syncstr-headless relay-health --url https://relay.example.net/
```

Back up the admission file and Caddy volumes. Check out the selected Syncstr
release or commit, build the image with `--locked`, and recreate the services.
An Iroh upgrade requires matching client interoperability tests before changing
the pin. The health check fails on a mismatched version. Keep the old image for
rollback; do not delete catalog or device identity directories.

To rotate the URL, reconfigure each library host while stopped, create new
single-use invitations, and enroll existing Apple devices again with the same
issuing host and role while on the LAN. On a registered Apple device, choose
the connection-settings update action, then paste or scan that fresh invitation
and confirm the host identity. The existing library registration and saved
audio are retained; cancellation does not change the current setting.
Keep the old relay reachable until all
devices have received the new configuration. To disable remote access, issue
fresh LAN-only invitations after:

```sh
syncstr-headless cluster-relay --data ./data --disable
```

## Verification limits

Local relay tests do not prove Internet reachability. Verify a physical iPhone
with Wi-Fi disabled, a previously unsaved track, and no manual home-router rule.
Observe relayed and direct paths separately. Stop the relay and verify LAN
discovery, download, and saved offline playback still work. Public certificate
issuance, the target reverse proxy, and physical cellular transfer are separate
deployment acceptance checks.

# Peer rendezvous

Cloudflare exchanges short-lived endpoint candidates, not catalogs or audio. It does not relay QUIC. Nodes retain existing Ed25519 identities and allowed-device records. A directory entry is not pairing authorization.

Requests are JSON envelopes with `payload` (an exact JSON string) and `signature` (base64 Ed25519 signature over UTF-8 `syncstr-rendezvous-v1\n` followed by the payload). Payloads include a lowercase hexadecimal node `id` and Unix millisecond `time` within 60 seconds of server time.

`POST /v1/announce`: `kind: "announce"`, `expires` at most 300 seconds after `time`, `address` (version 1, matching ID, 1–32 IP socket candidates, null relay), and up to 256 authorized `peers`. Updates require strictly increasing timestamps. Expired records are deleted.

`POST /v1/lookup`: `kind: "lookup"`, `target`. Only the owner and its allowed peers can retrieve its original signed announcement. Clients verify signature, target ID, expiry, and candidates before dialing. Unknown or expired records return 404; unauthorized lookup returns 403. Responses are never cached.

Implementation order: validate directory signature/authorization/expiry/replay in workerd; publish current candidates and allowed peers from headless; resolve saved IDs in native apps; verify LAN direct transfer; repeat with physical iPhone Wi-Fi disabled.

A LAN address is not reachable from cellular networks. External IPv6, a reachable UDP mapping, or successful NAT traversal must provide a usable candidate. Candidate exchange does not prove reachability. Router/firewall changes and relay deployment require separate authorization. Direct-only transfer remains enabled.

## Deploy the directory

From `rendezvous/`, run `mise exec -- npm ci`, `mise exec -- npm run typecheck`, and `mise exec -- npm test`. Authenticate with `cf auth login`, then run `mise exec -- npm run deploy`. The generated `cloudflare.config.ts` declares a SQLite Durable Object export; no audio bucket or relay is provisioned. Deployment prints the service's HTTPS origin.

## Connect a headless node

Build with `cargo build --features p2p`. Add `--peer-directory https://directory.example.com` to the existing `serve` command with `--peer-state` and direct mode. The node publishes current socket candidates and allowed peers at startup and every 60 seconds, with a 180-second expiry. Temporary directory failures are logged and retried; direct P2P service remains available. Peer authorization still happens on the headless node, and revocation is enforced there immediately.

Generate enrollment information with:

```sh
syncstr-headless peer-info --state ./data/peer --address ./data/peer/address.json \
  --directory https://directory.example.com --qr
```

This emits a QR code and copyable JSON containing the node ID and directory origin, without a fixed IP. Paste it into the native app's existing connection form, or scan it on iPhone. Keep existing authorized-device records. Each reconnect resolves the node's latest signed candidates before opening a direct QUIC connection. Existing IP-based enrollment records continue to work; regenerate enrollment once to opt into discovery.

For CLI diagnosis, use `peer-resolve --state ./client-peer --directory https://directory.example.com --peer '<node-id>'`. The client must already be authorized by the target. If a reachable external UDP socket has already been configured, `serve --peer-public-address 192.0.2.10:58024` includes it in announcements; this option does not configure NAT or open a firewall.

## Verify connectivity

First verify native uploads, automatic catalog refresh, downloads, retries, and revocation on the LAN. For the deployed-directory integration test, set `TEST_RUNNER_SYNCSTR_DIRECTORY_TEST_URL` to the deployed HTTPS origin when running the macOS `PeerTransferTests`; Xcode forwards it as `SYNCSTR_DIRECTORY_TEST_URL` to the test runner. The test uses fresh identities, temporary files, and direct QUIC; only discovery touches Cloudflare.

Then disable Wi-Fi on a physical iPhone and repeat a download. If discovery succeeds but QUIC times out, examine external candidates, UDP forwarding, and firewall reachability before changing the transport. A build or LAN test does not establish cellular reachability.

# Tailscale device spike

This is the protocol and the record of the ASO-159 spike. A throwaway iOS build downloads and plays tracks from a host over Tailscale on a physical iPhone. It answers by observation what the documentation behind [ADR 0008](../adr/0008-one-primary-host-over-a-private-network.md) leaves open. The owner runs it and fills in the result tables in this file. The Simulator does not answer these questions.

No production host or library is changed. This protocol authorizes no production operation.

Status: the physical iPhone runs are pending. Q7 records the read-only NAS inspection on 2026-11-18. Both spike hosts use legacy `/v4` bearer authentication. The first-release read API uses tailnet policy and needs no Syncstr token.

## Questions

Q1 to Q7 come from ASO-159. Q8, Q9, the resume check in Q3, and the other cases in Q4 cover iOS and Tailscale behavior that the documentation leaves open.

| ID | Question | Why it matters | Issue |
| --- | --- | --- | --- |
| Q1 | Does a foreground download from `https://<machine>.<tailnet>.ts.net` work, and does the file play, with no App Transport Security key in `Info.plist`? | ADR 0008 assumes that a device reaches the host like any web service, with a public certificate and no exception. | ASO-165 |
| Q2 | Does a background `URLSession` download continue over the tunnel while the app is suspended, and after the phone locks? | Today, transfers stop when the iPhone app goes to the background. Background downloads are planned. | ASO-166 |
| Q3 | What happens when the phone moves between Wi-Fi and cellular during a download? Does the download continue, resume at its offset, or restart? | Decides whether the app needs its own retry logic. | ASO-165, ASO-166 |
| Q4 | What does the app see when Tailscale is off, when the host machine is offline, when the host process is down, when the tailnet policy refuses this phone, and when another VPN takes over? How quickly does it see it? | Decides the "host unreachable" state and the probe timeout. | ASO-167 |
| Q5 | How long does one album take over the tailnet, compared with the same host over the LAN? | Decides whether whole-file download before playback stays acceptable. | ASO-165 |
| Q6 | Does a direct `100.x` address with the host's self-signed certificate work, with the certificate pinned? Is it worth supporting? | Provides a direct-IP comparison with the Serve hostname. | ASO-163, ASO-165 |
| Q7 | How does the existing sidecar publish the legacy host through Caddy? Does it rejoin after a NAS restart, and how long does each container take to update? | Records recovery and update times for the existing NAS layout. | ASO-163 |
| Q8 | Does `allowsCellularAccess = false` stop a download through the tunnel when the phone is on cellular? | Decides how a Wi-Fi-only download setting works. | ASO-166 |
| Q9 | With VPN On Demand set to **Always**, does the tunnel come up without opening the Tailscale app, after a phone restart and after a network change? | Decides what the first launch and the unreachable state tell the listener. | ASO-167 |

## Rules

- Read only. The `/v4` token also authorizes `POST /v4/tracks` and `POST /v4/organization` ([`api.rs`](../../headless/src/api.rs)). The token still grants those writes on the NAS's LAN listener. The build sends only `GET`, including through the sidecar.
- Use a throwaway build with its own bundle identifier. It never opens the everyday app's container or profile.
- Paste each token at run time and send it only to its host. Keep tokens and session logs out of the repository.
- Leave the owner's library, sidecar configuration, and everyday app profile untouched. Use the Mac fixture for host and policy changes.
- Record no addresses, machine names, account names, or device identifiers. Use the path labels below or placeholders such as `music.example.ts.net`, `mac.example.ts.net`, `100.x`, `192.0.2.20`, and "the owner's NAS".
- Run on a physical iPhone.

## Prepare

### The throwaway build

Create a minimal SwiftUI app outside the product targets, for example under `experiments/tailscale-device-spike/`. It needs these parts:

- A path selector with separate credentials and trust settings for N and the fixture paths. Bind the N token to the exact HTTPS origin `https://music.example.ts.net` (scheme, host, and port). In both sessions, attach it only to `GET /v4/catalog` and `GET /v4/tracks/{id}/audio` on that origin. Never fall back to the NAS's LAN address.
- Assume neither route on N redirects. Refuse redirects in the foreground. A background session follows redirects on its own, as the [host API redirect rule](../host-api-design.md#connecting-by-host-address) explains.
- Use the fixture's token on its three paths. Use system trust on N and A-name. Use the fixture pin for A-ip and A-lan when the step calls for it.
- On the Mac, read each catalog with its own token. Give the phone the selected track IDs, SHA-256 values, and sizes for each host.
- One foreground session from `URLSessionConfiguration.default`, and one background session from `URLSessionConfiguration.background(withIdentifier:)`. The app recreates the background session at launch and implements `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
- Download tasks for `GET /v4/tracks/{id}/audio`. In `didFinishDownloadingTo`, the app moves the file, computes its SHA-256, and compares it with the catalog value.
- A probe: `GET /v4/catalog` with no token. A `401` answer means that the host is reachable. The probe keeps the default `timeoutIntervalForRequest` of 60 seconds, so that the log shows when each failure arrives on its own.
- A range check: `GET` of one track with `Range: bytes=0-99`. Record the status and the `Content-Range` header.
- Playback of a verified file with `AVPlayer`.
- An optional server trust handler for A-ip and A-lan. It accepts the challenge only when the server's public key equals the public key in the bundled `tls.crt`, and it ignores the name in the certificate. This handler exists only for the comparison paths. The first-release [host API](../host-api-design.md) has no pinning.
- A timestamped log file that the share sheet can export. Log every request start, `didWriteData` progress at 10% steps, `didResumeAtOffset`, completion, the HTTP status, the error domain and code, the elapsed time, and each `NWPathMonitor` update with `usesInterfaceType(.cellular)`, `isExpensive`, and `isConstrained`.

`Info.plist` has no `NSAppTransportSecurity` key. It declares `NSLocalNetworkUsageDescription`, as the real app does in `apps/ios/project.yml`, because path A-lan uses a LAN address.

The plans remove `NSLocalNetworkUsageDescription` from the real app on the assumption that the Tailscale interface needs no local network permission. On a fresh install, complete Q1 on N alone, first on Wi-Fi and then on cellular. Record any local network prompt or failed request on each network before contacting the fixture. Then compare A-name and A-ip on Wi-Fi. Try A-lan last.

### The hosts

Path N reaches the owner's real library at `https://music.example.ts.net`. Serve forwards to Caddy inside the sidecar. Caddy passes only `GET` and `HEAD` on `/v4/catalog` and `/v4/tracks/{id}/audio`. Every other method or path gets `404` before it reaches the host.

Select an existing album of 10 to 15 tracks and a file of at least 200 MB on N. If no suitable large file exists, record the affected run as unmeasured. For the comparisons, copy the same album into a disposable Mac fixture running Tailscale. Use the fixture's own identity and token. Run from the repository root:

```sh
cargo build --locked --manifest-path headless/Cargo.toml
mkdir -p tmp/spike
headless/target/debug/syncstr-headless init --identity tmp/spike/identity --host 100.x.y.z
headless/target/debug/syncstr-headless serve --data tmp/spike/data --identity tmp/spike/identity --listen 0.0.0.0:8443
```

Replace `100.x.y.z` with the output of `tailscale ip -4`. In another terminal, upload each file:

```sh
headless/target/debug/syncstr-headless upload --url https://100.x.y.z:8443 \
	--cert tmp/spike/identity/tls.crt --token-file tmp/spike/identity/token \
	--file <copied-file> --title '<title>' --artist '<artist>' --album 'Spike album'
tailscale serve --bg https+insecure://127.0.0.1:8443
```

The `upload` command checks that the certificate names the address in `--url`, so the URL uses the tailnet address. Copy `tls.crt` into the build for the pinned paths.

| Path | Address the phone uses | Certificate | Used by |
| --- | --- | --- | --- |
| N | `https://music.example.ts.net` | Let's Encrypt, through Serve | Q1 to Q3, Q5, Q7 to Q9 |
| A-name | `https://mac.example.ts.net` | Let's Encrypt, through Serve | Q1 range comparison, Q4 and Q5 |
| A-ip | `https://100.x.y.z:8443` | The fixture's own, pinned | Q1 range comparison, Q4 address probe, Q5 and Q6 |
| A-lan | `https://192.0.2.20:8443`, the Mac's LAN address, with Tailscale off on the phone | The fixture's own, pinned | Q1 permission check and Q5 baseline |

If A-lan fails on the certificate name, run `init` again with `--host 192.0.2.20` into a second identity directory. For A-lan, restart `serve` on the same fixture data with the second identity. Set the build to that identity's certificate and token. Before returning to A-name or A-ip, restore the original identity on `serve` and the original certificate and token in the build. Use that original identity for Q6.

Before each session, record the environment below. Read the phone's line in `tailscale status` on the serving peer (the sidecar for N or the Mac for A-name and A-ip). Record `direct` or the DERP region. A-lan bypasses Tailscale.

When the spike ends, on the fixture Mac stop `serve` and delete `tmp/spike`. Turn off each Serve setting that the spike added by running its command again with `off` at the end. `tailscale serve reset` also works, but it removes every Serve setting on the Mac.

## Steps

### Q1. Foreground download and playback over the tailnet name

1. On the Mac, match each album track across the two catalogs by SHA-256 and byte size. Upload gives each fixture track a new ID. Fill in the track table in [Results](#results) in play order. Use the ID for the current host in every request.
2. On a fresh install, connect the phone to Wi-Fi and Tailscale. Run the range check on the first row's track over N. Record the status and `Content-Range`. Download the same track in the foreground, verify its hash, and play it for 10 seconds.
3. Turn Wi-Fi off in **Settings**. Repeat the N range check, download, verification, and playback on cellular. Record any local network prompt and any failure separately for each N run.
4. Return to Wi-Fi. Repeat the range check with the first row's fixture ID over A-name and then A-ip. Pin the fixture certificate only on A-ip. Record each status and `Content-Range`.
5. Turn Tailscale off and make one A-lan request. Record whether the local network prompt appears and accept it if shown. Reconnect Tailscale before Q2.

Expected: status `200`, a matching hash, and playback. The range check returns `206` with `Content-Range`. No error `-1022` (App Transport Security) or `-1202` (untrusted certificate) appears.

- PASS: ADR 0008's premise holds. A device uses `URLSession` with default trust.
- FAIL with `-1022` or `-1202`: the host address design needs an exception that App Review asks about. ADR 0008 and ASO-165 change.
- A range check without `206` over A-name, while the same check over A-ip returns `206`: the fixture Serve path loses `Range`. A failure on N alone does not isolate Serve. ASO-160 must not rely on ranges through Serve. If A-ip fails too, the result says nothing about Serve alone. Record it and check the fixture's range handling first.

### Q2. Background download while suspended and locked

1. Start all album tracks and the large file at once on the background session over N.
2. Within 5 seconds, go to the Home Screen. In the sidecar, read `tailscale status` every 30 seconds and watch the `tx` count on the phone's line. When it stops growing, open the app and export the log.
3. Delete the downloads from the throwaway build. Start again, lock the phone within 5 seconds, and leave it locked for 10 minutes.
4. Unlock, open the app, and export the log.

Expected: bytes keep flowing while the app is suspended. iOS wakes the app when the tasks finish, and every hash matches. Record whether moving a file in `didFinishDownloadingTo` fails while the phone is locked.

- PASS: ASO-166 uses one background session for offline saves and album downloads.
- Transfers stop while suspended, or resume only in the foreground: background downloads do not work over the tunnel. ASO-166 falls back to foreground downloads, and the interface says so.
- Transfers work, but the move fails while locked: ASO-166 sets the file protection of downloaded audio.

### Q3. Network change during a download

1. On Wi-Fi, start the large file on the foreground session over N.
2. At about 30%, turn Wi-Fi off in **Settings**. Record what follows. The bytes continue, the task resumes, or the task fails with an error code.
3. Repeat with the background session. Record whether `didResumeAtOffset` arrives and at which offset.
4. Repeat steps 1 to 3 from cellular to Wi-Fi.

Expected: unknown. A guess is that the connection inside the tunnel survives, because the phone's tailnet address does not change. If it fails, the background session should resume with a range request, because the host sends `ETag` and `Accept-Ranges`.

- Continues: the app needs no handling for a network change.
- Foreground fails with `-1005` (connection lost), and background resumes at its offset: ASO-165 either retries foreground downloads from their offset or sends every download through the background session.
- Background restarts from zero: resumption does not survive the tunnel or Serve. ASO-166 plans for full restarts of large files.

### Q4. When the host cannot be reached

Use A-name for every case except the A-ip probe in step 1. Change policy only for access to the fixture Mac. First, with everything on, run the probe 10 times on Wi-Fi and 10 times on cellular. Record the slowest `401`. That time is the floor for any probe timeout.

For each case below, run the probe and one foreground download. Record the error code or HTTP status, and the time from request to callback.

1. Tailscale off on the phone. Probe by name, and then by `100.x.y.z`.
2. Tailscale on, with Tailscale disconnected on the Mac.
3. Tailscale on, with the fixture `serve` stopped and Serve still on.
4. Tailscale off. Start one task on the background session, wait 2 minutes, and connect Tailscale. Record whether the task starts by itself and how long after.
5. Tailscale off in the middle of a foreground download and of a background download.
6. Everything on, with the tailnet policy changed so that this iPhone cannot reach the Mac. Probe and download from this iPhone, and from a second device that the policy still allows. This is the only remote access control of the first release, so record how the refusal looks and how long it takes. Then restore the policy and check that the probe from this iPhone answers `401` again before the next step.
7. If the phone has another VPN app, connect it during a download. Record what Tailscale and the app do, and whether VPN On Demand comes back after the other VPN disconnects.

Expected: unknown. A guess for step 1 is a fast `-1003` (cannot find host) by name, because the name resolves inside the tunnel, and a timeout by address. Step 3 should return an HTTP error status from Serve.

- A distinct, fast error for "Tailscale off": ASO-167 can name the cause in the unreachable state.
- Only timeouts: the app says "host unreachable" without naming the cause, after a probe timeout set from the slowest `401`. [Host API design](../host-api-design.md) uses 15 seconds until this measurement replaces it.
- A distinct status for step 3: the app can say that the host machine answers but the host does not.
- A background task that waits and then starts by itself: ASO-166 can queue offline saves while the phone is disconnected.

### Q5. Time for one album

1. Delete the album's files from the build between runs.
2. Start the foreground downloads in the play order recorded in Q1. Use the N ID or fixture ID from each row for the current path. Measure the wait for playback until the first row's track is verified. Measure the album time until all rows are verified.
3. Run three times on N over Wi-Fi and three times on N over cellular. On Wi-Fi, repeat the three runs with the fixture copy over each of A-name, A-ip, and A-lan.
4. Run once over N on Wi-Fi with the background session. Record this time separately from the foreground medians.

Record the track count, total bytes, and formats once. Report the median of each path. Compute MB/s from the bytes and the time.

- The first track is verified before the listener would give up: whole-file download stays the playback model of ADR 0008. The owner records the wait that they accept.
- The first track takes longer than that: ADR 0008's statement that whole-file download stays the playback model needs to be reopened, and ASO-165 considers playback that starts before the file completes.
- Tailnet much slower than LAN on a direct path: the cost is in the tunnel or in Serve. A-ip skips Serve, so A-name against A-ip gives Serve's share, and A-ip against A-lan gives the tunnel's share.
- Slow only on DERP paths: the cost is the network path. The [setup guide](../tailscale-setup.md) covers it in troubleshooting.

### Q6. A direct `100.x` address with a pinned certificate

1. Download one track over A-ip with the foreground session, without the trust handler. Expect `-1202`.
2. Turn the trust handler on and repeat.
3. Repeat step 2 on the background session while the app is suspended.

Expected: step 2 works. The background session can wake the app for the trust challenge, because `sessionSendsLaunchEvents` covers tasks that require authentication.

Record success or failure separately for foreground and background. Q6 compares the direct-IP path with Serve. Its result does not add a direct LAN listener to the first release.

### Q7. A container host on the tailnet

The read-only inspection on 2026-11-18 found a userspace Tailscale sidecar with persistent state. Its Serve configuration publishes HTTPS on port 443 and proxies `/` to Caddy at `http://127.0.0.1:8441`. Caddy reaches the legacy host over the LAN at `https://192.0.2.30:8443`. It trusts only the host's read-only `tls.crt`. The image contains both the Serve configuration and the Caddyfile. Its source commit is outside this repository.

A Mac on the same tailnet trusted Serve's Let's Encrypt certificate without an exception. An unauthenticated `GET /v4/catalog` returned `401`. Both `GET /v4/organization` and `GET /` returned `404`. Caddy also returned `404` for `POST /v4/tracks`. These observations cover the Mac path. Q1 checks the physical iPhone.

Every Q7 measurement covers the existing path through Caddy to the legacy host on the LAN. ASO-163 verifies the recommended Compose layout in a disposable environment. There, Serve must reach the new host on its loopback-only listener in their shared network namespace.

1. A NAS restart stops the everyday library. It needs the owner's separate go-ahead. At an approved restart, check that the sidecar rejoins without signing in again. Repeat the unauthenticated probe on N and expect `401`. Until then, record rejoin as unverified.
2. At the next owner-scheduled update of each container, record the time from the start of its update until N answers the probe again. Record separate times for the sidecar and the legacy host. Leave each time unmeasured until that update.

### Q8. Cellular restriction through the tunnel

1. On cellular with Wi-Fi off, download one track over N with `allowsCellularAccess = false`.
2. Repeat with `allowsCellularAccess = true` and `allowsExpensiveNetworkAccess = false`.
3. Start a large download on Wi-Fi with `allowsCellularAccess = false`, then turn Wi-Fi off. Record whether the task pauses or continues over cellular.
4. Record what `NWPathMonitor` reports for the path in each case.

- The task waits or fails: a Wi-Fi-only setting can rely on `URLSession`.
- The task downloads over cellular in step 1 or 2: the tunnel hides the interface. ASO-166 checks the path itself before it starts a download.
- The task in step 3 continues over cellular: a check before the start is not enough. ASO-166 tests a way to stop a running save when the path becomes cellular.

### Q9. VPN On Demand

1. In the Tailscale app, set VPN On Demand to **Always** for Wi-Fi and for cellular.
2. Restart the phone. Without opening the Tailscale app, open the build and run the probe on N.
3. Turn Wi-Fi off and run the probe again.
4. Turn VPN On Demand off and repeat steps 2 and 3.

- The probe reaches the host with On Demand: the setup guide recommends it, and ASO-167 points to it in the unreachable state.
- The probe fails: the app must tell the listener to open Tailscale.

## Outcomes that change the design

| Outcome | What changes | Issue |
| --- | --- | --- |
| Q1 needs an App Transport Security exception | ADR 0008's preference for a public certificate with no app exception | ASO-158, ASO-165 |
| Q2 stops while suspended | Background downloads become foreground downloads | ASO-166 |
| Q3 restarts from zero | Retry and resume design for large files | ASO-165, ASO-166 |
| Q4 gives only timeouts | The unreachable state cannot name its cause | ASO-167 |
| Q5 first track too slow | ADR 0008's whole-file playback model | ASO-158, ASO-165 |
| Q6 pinning works or fails | Record which direct-IP comparison paths worked | ASO-163, ASO-165 |
| Q7 sidecar fails to rejoin | Record the recovery failure for the existing layout. Check rejoin separately in the disposable Compose setup. | ASO-163 |
| Q8 cellular is not blocked | The Wi-Fi-only setting checks the path itself | ASO-166 |
| Q9 On Demand does not reconnect | First-launch and reconnect wording | ASO-167 |

ADR 0008 records the accepted decisions on tailnet-controlled library reads, first-release device capabilities and the cutover order.

## Results

Status: the Mac observations are recorded in Q7. Physical iPhone runs, NAS restart recovery, and update times are pending.

PASS, FAIL, and BLOCKED have the meanings in the [validation README](README.md). Fill in one environment row per session.

| Date | iPhone model | iOS | Tailscale on the phone | Host machine and OS | Tailscale on the host, and variant |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

| ID | Path | Network | Direct or DERP | Observation (status, error code, elapsed time) | Result |
| --- | --- | --- | --- | --- | --- |
| Q1 | N | Wi-Fi | | | |
| Q1 | N | Cellular | | | |
| Q1 | A-name | Wi-Fi | | | |
| Q1 | A-ip | Wi-Fi | | | |
| Q1 | A-lan | Wi-Fi | LAN | | |
| Q2 | N | | | | |
| Q3 | N | | | | |
| Q4 | A-name, A-ip | | | | |
| Q5 | N, A-name, A-ip, A-lan | | | | |
| Q6 | A-ip | | | | |
| Q7 | N | Tailnet (Mac) | | Trusted certificate. Catalog probe `401`. Blocked routes `404`. | NAS rejoin and both update times pending |
| Q8 | N | | | | |
| Q9 | N | | | | |

Use one row per album track for Q1 and Q5. Row 1 is the first track on every path.

| Play order | N track ID | Fixture track ID | SHA-256 | Bytes |
| --- | --- | --- | --- | --- |
| 1 | | | | |

| Path | Network | Direct or DERP | Tracks | Bytes | First track, median (s) | Album, median (s) | MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A-name | Wi-Fi | | | | | | |
| A-ip | Wi-Fi | | | | | | |
| A-lan | Wi-Fi | | | | | | |
| N | Cellular | | | | | | |
| N | Wi-Fi | | | | | | |

Use the foreground runs for the album table.

## Limits

- One iPhone, one tailnet, and one cellular network give one sample of each path.
- Only the Mac fixture provides matched Serve, direct-IP, and LAN comparisons.
- The results hold for the recorded iOS and Tailscale versions.
- The current apps are not measured, because they would write to the everyday app's profile. A-lan measures the same host without the tunnel.
- The fixture is today's `/v4` host behind `https+insecure`. The planned host listens with plain HTTP on loopback ([Host API design](../host-api-design.md)). The phone sees the same Serve certificate in both cases.
- The size of the planned catalog is measured in ASO-160, not here. The `/v4` catalog carries artwork inside each entry ([`model.rs`](../../headless/src/model.rs)), so its size says little about the planned one.

## Sources

Read on 2026-11-17.

- Apple: "Downloading files in the background" (Apple Developer Documentation), and "Build robust and resumable file transfers" (WWDC23).
- Apple: `NSURLSession.h`, `NSURLError.h`, and the Network module interface in the iOS 27.2 SDK of the local Xcode, for default timeouts, background retry and waiting, launch events, and error codes.
- Tailscale: "Tailscale CLI", "tailscale serve command", "Tailscale Serve", and "Using VPN On Demand for iOS and macOS".
- Tailscale: `ExpandProxyTargetValue` in `ipn/serve.go` of `tailscale/tailscale`, for targets other than `127.0.0.1`.
- Repository: [`headless/src/api.rs`](../../headless/src/api.rs) for the `/v4` routes, `ETag`, `Accept-Ranges`, and the `401` answer, and [`headless/README.md`](../../headless/README.md) for `init`, `serve`, and `upload`.

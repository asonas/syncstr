# Tailscale device spike

This is the protocol and the record of the ASO-159 spike. A throwaway iOS build downloads and plays tracks from a host over Tailscale on a physical iPhone. It answers by observation what the documentation behind [ADR 0008](../adr/0008-one-primary-host-over-a-private-network.md) leaves open. The owner runs it and fills in the result tables in this file. The Simulator does not answer these questions.

No production host or library is changed. This protocol authorizes no production operation.

Status: not run. No question has a recorded answer. The fixture serves legacy /v4 with bearer authentication. Its token and 401 probe apply only to this experiment. The first-release read API uses tailnet policy and needs no Syncstr token.

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
| Q7 | Which way to put a container host on the tailnet is better: Tailscale on the NAS, or a Tailscale container next to the host? | Decides the one documented command for a NAS host. | ASO-163 |
| Q8 | Does `allowsCellularAccess = false` stop a download through the tunnel when the phone is on cellular? | Decides how a Wi-Fi-only download setting works. | ASO-166 |
| Q9 | With VPN On Demand set to **Always**, does the tunnel come up without opening the Tailscale app, after a phone restart and after a network change? | Decides what the first launch and the unreachable state tell the listener. | ASO-167 |

## Rules

- Read only. The `/v4` token also authorizes `POST /v4/tracks` and `POST /v4/organization` ([`api.rs`](../../headless/src/api.rs)). Read-only access is therefore a rule that the build keeps. It sends `GET` requests only.
- Use a throwaway build with its own bundle identifier. It never opens the everyday app's container or profile.
- Paste the token into the build at run time. Keep it out of the repository and out of this file.
- Install nothing on the owner's NAS without the owner's go-ahead. Do not change the running host's Compose project.
- Record no addresses, machine names, account names, or device identifiers. Write `mac.example.ts.net`, `100.x`, `192.0.2.20`, and "the owner's NAS".
- Run on a physical iPhone.

## Prepare

### The throwaway build

Create a minimal SwiftUI app outside the product targets, for example under `experiments/tailscale-device-spike/`. It needs these parts:

- Fields for the host address, the token, and a list of track IDs with their SHA-256 values and sizes. Read these on the Mac with the `catalog` command of `syncstr-headless`, which takes the same `--url`, `--cert`, and `--token-file` as `upload` below. The phone then never fetches a whole catalog.
- One foreground session from `URLSessionConfiguration.default`, and one background session from `URLSessionConfiguration.background(withIdentifier:)`. The app recreates the background session at launch and implements `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
- Download tasks for `GET /v4/tracks/{id}/audio`. In `didFinishDownloadingTo`, the app moves the file, computes its SHA-256, and compares it with the catalog value.
- A probe: `GET /v4/catalog` with no token. A `401` answer means that the host is reachable. The probe keeps the default `timeoutIntervalForRequest` of 60 seconds, so that the log shows when each failure arrives on its own.
- A range check: `GET` of one track with `Range: bytes=0-99`. Record the status and the `Content-Range` header.
- Playback of a verified file with `AVPlayer`.
- An optional server trust handler for Q6 and the LAN baseline. It accepts the challenge only when the server's public key equals the public key in the bundled `tls.crt`, and it ignores the name in the certificate. This handler exists only for the comparison paths. The first-release [host API](../host-api-design.md) has no pinning.
- A timestamped log file that the share sheet can export. Log every request start, `didWriteData` progress at 10% steps, `didResumeAtOffset`, completion, the HTTP status, the error domain and code, the elapsed time, and each `NWPathMonitor` update with `usesInterfaceType(.cellular)`, `isExpensive`, and `isConstrained`.

`Info.plist` has no `NSAppTransportSecurity` key. It declares `NSLocalNetworkUsageDescription`, as the real app does in `apps/ios/project.yml`, because path A-lan uses a LAN address.

The plans remove `NSLocalNetworkUsageDescription` from the real app, on the assumption that reaching a host over the Tailscale interface needs no local network permission. Test that assumption first: on a fresh install, run Q1 over A-name on Wi-Fi and then on cellular before the first A-lan request. Record whether iOS shows the local network prompt and whether any request fails. Only then make one A-lan request and accept the prompt for the timed A-lan runs.

### The hosts

Run Q1 to Q6, Q8, and Q9 against a disposable fixture host on a Mac that runs Tailscale. Its library is files that the owner copies in, not the real library. It needs one album of 10 to 15 tracks and one file of at least 200 MB for Q3. Run from the repository root:

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
| A-name | `https://mac.example.ts.net` | Let's Encrypt, through Serve | Q1 to Q5, Q8, and Q9 |
| A-ip | `https://100.x.y.z:8443` | The fixture's own, pinned | Q5 and Q6 |
| A-lan | `https://192.0.2.20:8443`, the Mac's LAN address, with Tailscale off on the phone | The fixture's own, pinned. The name does not match. | Q5 baseline |
| C | `https://spike.example.ts.net`, a disposable host on the NAS | Let's Encrypt, through Serve | Q5 and Q7 |

If A-lan fails on the certificate name, run `init` again with `--host 192.0.2.20` into a second identity directory. Then restart `serve` with that identity for the baseline runs.

No path publishes the owner's real host. Serve would publish the whole `/v4` router, and the `/v4` token also allows uploads and organization changes, so a read-only build does not make such a path read-only. NAS times come from path C.

Before each session, record the environment table below. During each tailnet run, read the phone's line in `tailscale status` on the Mac. It shows `direct` and an address for a direct path. Otherwise it names the Tailscale DERP region that carries the traffic. Record which one the run used. On a NAS with a Tailscale container, run `docker compose exec tailscale tailscale status` instead.

When the spike ends, stop `serve` and delete `tmp/spike`. Turn off each Serve setting that the spike added by running its command again with `off` at the end. `tailscale serve reset` also works, but it removes every Serve setting on the Mac.

## Steps

### Q1. Foreground download and playback over the tailnet name

1. Connect the phone to Wi-Fi and connect Tailscale.
2. Run the range check over A-name.
3. Download one track over A-name with the foreground session. Verify the hash and play the file for 10 seconds.
4. Turn Wi-Fi off in **Settings**, and repeat steps 2 and 3 on cellular.

Expected: status `200`, a matching hash, and playback. The range check returns `206` with `Content-Range`. No error `-1022` (App Transport Security) or `-1202` (untrusted certificate) appears.

- PASS: ADR 0008's premise holds. A device uses `URLSession` with default trust.
- FAIL with `-1022` or `-1202`: the host address design needs an exception that App Review asks about. ADR 0008 and ASO-165 change.
- A range check without `206`: Serve does not pass `Range`. ASO-160 must not rely on ranges through Serve.

### Q2. Background download while suspended and locked

1. Start all album tracks and the large file at once on the background session over A-name.
2. Within 5 seconds, go to the Home Screen. On the Mac, run `tailscale status` every 30 seconds and watch the `tx` count on the phone's line. When it stops growing, open the app and export the log.
3. Delete the files. Start again, lock the phone within 5 seconds, and leave it locked for 10 minutes.
4. Unlock, open the app, and export the log.

Expected: bytes keep flowing while the app is suspended. iOS wakes the app when the tasks finish, and every hash matches. Record whether moving a file in `didFinishDownloadingTo` fails while the phone is locked.

- PASS: ASO-166 uses one background session for offline saves and album downloads.
- Transfers stop while suspended, or resume only in the foreground: background downloads do not work over the tunnel. ASO-166 falls back to foreground downloads, and the interface says so.
- Transfers work, but the move fails while locked: ASO-166 sets the file protection of downloaded audio.

### Q3. Network change during a download

1. On Wi-Fi, start the large file on the foreground session over A-name.
2. At about 30%, turn Wi-Fi off in **Settings**. Record what follows. The bytes continue, the task resumes, or the task fails with an error code.
3. Repeat with the background session. Record whether `didResumeAtOffset` arrives and at which offset.
4. Repeat steps 1 to 3 from cellular to Wi-Fi.

Expected: unknown. A guess is that the connection inside the tunnel survives, because the phone's tailnet address does not change. If it fails, the background session should resume with a range request, because the host sends `ETag` and `Accept-Ranges`.

- Continues: the app needs no handling for a network change.
- Foreground fails with `-1005` (connection lost), and background resumes at its offset: ASO-165 either retries foreground downloads from their offset or sends every download through the background session.
- Background restarts from zero: resumption does not survive the tunnel or Serve. ASO-166 plans for full restarts of large files.

### Q4. When the host cannot be reached

First, with everything on, run the probe 10 times on Wi-Fi and 10 times on cellular. Record the slowest `401`. That time is the floor for any probe timeout.

For each case below, run the probe and one foreground download. Record the error code or HTTP status, and the time from request to callback.

1. Tailscale off on the phone. Probe by name, and then by `100.x.y.z`.
2. Tailscale on, with Tailscale disconnected on the Mac.
3. Tailscale on, with the fixture `serve` stopped and Serve still on.
4. Tailscale off. Start one task on the background session, wait 2 minutes, and connect Tailscale. Record whether the task starts by itself and how long after.
5. Tailscale off in the middle of a foreground download and of a background download.
6. Everything on, with the tailnet policy changed so that this iPhone cannot reach the Mac. Probe and download from this iPhone, and from a second device that the policy still allows. This is the only remote access control of the first release, so record how the refusal looks and how long it takes.
7. If the phone has another VPN app, connect it during a download. Record what Tailscale and the app do, and whether VPN On Demand comes back after the other VPN disconnects.

Expected: unknown. A guess for step 1 is a fast `-1003` (cannot find host) by name, because the name resolves inside the tunnel, and a timeout by address. Step 3 should return an HTTP error status from Serve.

- A distinct, fast error for "Tailscale off": ASO-167 can name the cause in the unreachable state.
- Only timeouts: the app says "host unreachable" without naming the cause, after a probe timeout set from the slowest `401`. [Host API design](../host-api-design.md) uses 15 seconds until this measurement replaces it.
- A distinct status for step 3: the app can say that the host machine answers but the host does not.
- A background task that waits and then starts by itself: ASO-166 can queue offline saves while the phone is disconnected.

### Q5. Time for one album

1. Delete the album's files from the build between runs.
2. Start all of the album's tracks at once on the foreground session. Record the time to the first verified track and to the last verified track.
3. Run three times each over A-name on Wi-Fi, A-ip on Wi-Fi, A-lan on Wi-Fi, and A-name on cellular. Once path C exists for Q7, add three runs over C with the same album copied to it.
4. Run once over A-name on the background session.

Record the track count, total bytes, and formats once. Report the median of each path. Compute MB/s from the bytes and the time.

- The first verified track arrives before the listener would give up: whole-file download stays the playback model of ADR 0008. The owner records the wait that they accept.
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

This question needs the owner's go-ahead, because it installs something on the NAS. Without it, mark Q7 as BLOCKED, and the choice rests on the [setup guide](../tailscale-setup.md).

1. On the NAS, create a second Compose project with an empty data directory and a new identity, not the real library. Create the identity with the `init` step of "Docker on a NAS" in [`headless/README.md`](../../headless/README.md). Add the Tailscale container from the setup guide with `hostname: spike`. Today's container listens with HTTPS on 8443, so the proxy in `serve.json` is `https+insecure://127.0.0.1:8443`, not the planned `http://127.0.0.1:8441`.
2. From the phone, open `https://spike.example.ts.net/v4/catalog` and expect `unauthorized`.
3. Run `docker compose restart`, and then restart the NAS. Repeat step 2 after each.
4. Record the number of steps, the time taken, and what an update of each container takes.
5. If the owner accepts Tailscale on the NAS itself, record the same for it. The fixture container then uses `network_mode: host`, so start it with `--listen 127.0.0.1:<port>` on a port that no NAS service uses, and remove its `ports` entry, so that it does not answer on the NAS's LAN address.
6. Remove the project, its data, and the `spike` machine from the tailnet.

- The container passes steps 2 and 3: ASO-163 ships it as the one documented command.
- The container fails, for example because Serve cannot reach the host in the shared network: the setup guide's recommendation changes to the option that passed.

### Q8. Cellular restriction through the tunnel

1. On cellular with Wi-Fi off, download one track over A-name with `allowsCellularAccess = false`.
2. Repeat with `allowsCellularAccess = true` and `allowsExpensiveNetworkAccess = false`.
3. Record what `NWPathMonitor` reports for the path in each case.

- The task waits or fails: a Wi-Fi-only setting can rely on `URLSession`.
- The task downloads over cellular: the tunnel hides the interface. ASO-166 checks the path itself before it starts a download.

### Q9. VPN On Demand

1. In the Tailscale app, set VPN On Demand to **Always** for Wi-Fi and for cellular.
2. Restart the phone. Without opening the Tailscale app, open the build and run the probe.
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
| Q7 container fails | The NAS recommendation in the setup guide | ASO-163 |
| Q8 cellular is not blocked | The Wi-Fi-only setting checks the path itself | ASO-166 |
| Q9 On Demand does not reconnect | First-launch and reconnect wording | ASO-167 |

ADR 0008 records the accepted decisions on tailnet-controlled library reads, first-release device capabilities and the cutover order.

## Results

Status: not run.

PASS, FAIL, and BLOCKED have the meanings in the [validation README](README.md). Fill in one environment row per session.

| Date | iPhone model | iOS | Tailscale on the phone | Host machine and OS | Tailscale on the host, and variant |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

| ID | Path | Network | Direct or DERP | Observation (status, error code, elapsed time) | Result |
| --- | --- | --- | --- | --- | --- |
| Q1 | | | | | |
| Q2 | | | | | |
| Q3 | | | | | |
| Q4 | | | | | |
| Q5 | | | | | |
| Q6 | | | | | |
| Q7 | | | | | |
| Q8 | | | | | |
| Q9 | | | | | |

| Path | Network | Direct or DERP | Tracks | Bytes | First track, median (s) | Album, median (s) | MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A-name | Wi-Fi | | | | | | |
| A-ip | Wi-Fi | | | | | | |
| A-lan | Wi-Fi | | | | | | |
| A-name | Cellular | | | | | | |
| C | Wi-Fi | | | | | | |

Record C as not measured if the owner does not allow Q7.

## Limits

- One iPhone, one tailnet, and one cellular network give one sample of each path.
- The fixture host runs on a Mac. It is not the NAS container. Q7 covers the container.
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

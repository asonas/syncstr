# TestFlight QA on the owner's iPhone

ASO-159 checks the real Syncstr app against the NAS over Tailscale. A push to Syncstr's `main` starts an Xcode Cloud build for internal TestFlight testing. Install the build that contains the changes listed below. Local Simulator runs cannot answer these device questions.

Use the host's full HTTPS address, such as `https://syncstr.example.ts.net`. The tailnet policy grants access. The numbers follow the earlier device spike. Its Q6, a direct-IP comparison with a pinned certificate, was dropped because the app connects by the Serve name and uses its HTTPS certificate.

## Questions

All phone checks use ASO-165 (catalog and file reads) and ASO-164 (connection by host address). The table lists any further requirement. Start each download with an uncached track or album. Keep existing offline saves.

| Check | Build needed | What the owner does | What to record |
| --- | --- | --- | --- |
| Q1. Foreground playback | ASO-165 and ASO-164 | Before connecting, note whether Syncstr already has local network permission in Settings. Connect by name, open a playlist and play an uncached track with Syncstr open. Repeat on cellular with Wi-Fi off. | The local network permission before the run, whether the catalog, artwork and audio load, whether playback starts, and any certificate error or local network permission prompt. |
| Q2. Suspended and locked | ASO-166 background saves | Run 1: start a long album save and switch to another app without quitting Syncstr. Run 2: start a fresh save and lock the phone. In each run, after ten minutes, turn off Wi-Fi and cellular, then reopen Syncstr and play the saved tracks. Restore connectivity between runs. | For each run separately: tracks or bytes completed before leaving, completed while away (seen with networking off on return), time away, whether the save resumed after connectivity returned, and whether the saved files play. |
| Q3. Network change | ASO-165 for foreground playback, ASO-166 for background saves | Allow cellular. During a large transfer switch from Wi-Fi to cellular, then back. Repeat during a background save. | Progress at each switch, interruption time, whether the file continued, resumed or restarted, and whether it played. Mark the resume offset unknown if it is not visible. |
| Q4. Unreachable host | ASO-167 connection states | Refresh with Tailscale disconnected, then with another VPN active. During an approved outage or policy check, repeat with the host offline, the node stopped, or the phone denied access. Restore access and refresh. | For each cause, seconds from refresh to feedback, the message or error code, whether an existing save plays offline, and time to reconnect. Mark unobserved causes pending. |
| Q5. Time for one album | ASO-165 playback, ASO-166 album saves | On Wi-Fi, start playback and save an uncached album. Repeat on cellular with an uncached copy of comparable size, choosing **今回はモバイル通信で保存** ("Save over cellular this time") when the save waits for Wi-Fi. | Network, track count, total bytes, seconds to first sound and to the last completed file. Note whether the wait was acceptable. |
| Q7. NAS rejoin | ASO-165 and ASO-164 for the phone read | **Restart the NAS only with the owner's explicit go-ahead.** From the phone, refresh until the same host address serves the library again. | Time from restart to Serve responding and to a successful catalog read, any 502s, and whether the sidecar rejoined without a new login. |
| Q8. Cellular restriction | ASO-166 Wi-Fi-only saves | Disable cellular downloads in Syncstr. Run 1: start a save on Wi-Fi, then turn Wi-Fi off with Tailscale connected, wait five minutes and restore Wi-Fi. Run 2: with Wi-Fi off, start another save on cellular, wait five minutes and restore Wi-Fi. Read Syncstr's cellular data use in the iOS Settings app before and after each run. | For each run separately: whether bytes moved on cellular (the change in Syncstr's cellular data use, and whether the save's progress advanced while Wi-Fi was off), the waiting message, and whether both saves continued on Wi-Fi. |
| Q9. VPN On Demand | ASO-164 and ASO-165 for reads, ASO-167 for reconnect messages | Set VPN On Demand to Always on Wi-Fi and cellular. Restart the phone and open Syncstr without opening Tailscale. Repeat after changing networks. | Whether the tunnel connected automatically, time to a catalog read, any manual step and the message shown. |

## Outcomes that change the design

- A certificate error on the full name calls for checking the Serve address and the app's HTTPS handling (ASO-164, ASO-165).
- If a save stops while suspended or locked, ASO-166 must support saving with Syncstr open and resuming on return. If a network switch restarts a file, revisit range-based resume.
- If several unreachable cases give the same timeout, ASO-167 should show only what the app can determine. Use the observed delay to set the probe timeout.
- If the first track takes too long, revisit whole-file playback with the measured file size and network (ASO-165).
- If the NAS needs manual sign-in after reboot, revise the sidecar setup (ASO-163).
- If bytes move on cellular with cellular downloads disabled, revisit how ASO-166 enforces Wi-Fi-only saves. If On Demand needs manual reconnection, update the first-launch and recovery instructions (ASO-167).
- Remove `NSLocalNetworkUsageDescription` only if a Q1 run that started without the permission showed no prompt and still loaded the catalog, artwork and audio by the Serve name and played.

## Results

**Mac over the tailnet, 2026-11-19.** Library information returned 200 with the host address. The catalog returned 200 with several thousand entries and their playlists: about 12.7 MB uncompressed, 4.5 MB with gzip, in about 0.25 seconds. An audio range request returned 206 with the SHA-256 ETag. Artwork returned 200 with `image/jpeg`. A POST returned 405. Through Serve, `/v4/catalog` returned 404. No TCP connection opened to the tailnet name on ports 8441 and 8443, or to the NAS's LAN address on the old Syncstr ports. After deployment, Serve returned 502 for a few tens of seconds while the node opened its store.

**Physical iPhone.** All checks, including NAS reboot recovery, are pending. Append one row per run here. Use the device model, never its personal name. Omit actual host addresses, account details, library metadata and raw logs.

| Date | Device model | iOS version | TestFlight build | Check and network | Observations and measurements | Result |
| --- | --- | --- | --- | --- | --- | --- |

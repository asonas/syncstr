# Playback diagnostics validation

## Delivery scope

The macOS source implements local playback-attempt recording and JSONL copying beside playback errors and in Settings > Playback Diagnostics. Both Debug and TestFlight use the same source; recording has no Debug-only compilation gate. This does not establish TestFlight distribution or reproduction of the reported tracks.

The recorder persists beneath the local music store in `PlaybackDiagnostics/attempts.json`. It retains up to 20 attempts and 5 MB, with a 200 KB per-attempt event budget to bound a noisy attempt. Truncation retains outcome, last stage, omitted count and omitted counts by stage. Serial background persistence coalesces updates; failed persistence leaves bounded in-memory evidence and appears in Settings and exports. Copies include retained retry ancestors and explicitly identify missing ancestors.

## Automated evidence

- The macOS regression suite passed: 94 XCTest cases, six skipped, no failures; 16 Swift Testing cases passed at that checkpoint.
- Eight focused diagnostic tests passed, including the subsequently added cyclic-underlying-error check. They cover candidate failures across retry exports, active snapshots, restart interruption, retention pressure, missing ancestors, unsafe error data, persistence failure, real Library manual retries, and cache verification versus save failures.
- The final player-observation changes passed all eight focused diagnostics and eight existing player-interaction tests.
- The existing TLS loopback transfer test also checks recorded acquisition mode, hash verification and save completion.
- iOS Simulator compilation passed. iOS does not start diagnostic attempts or expose this initial diagnostic UI.
- Native UI interaction and clipboard verification remain pending. The running application was not replaced during validation.

No headless interoperability binary was available for this checkout, so the gated cluster interoperability cases were skipped. Passing recorder tests establishes preservation of separately recorded candidate failures, not a live multi-host failover run.

## Observation limits

- Current Mac audio acquisition uses cluster or an existing legacy channel. It has no HTTPS audio-download branch. No unrelated HTTP request is added to a playback trace.
- Cluster membership exposes host identities but not host display names; unavailable names are labeled `not_observable`.
- Local synchronized-catalog resolution is labeled separately from the remote audio response. Peer-internal object lookup/read failures cannot be inferred from the current response protocol.
- A pre-existing legacy channel is labeled reused, with TLS-PSK versus Iroh channel mode. Its prior authentication is not replayed; its physical path is unknown. Cluster sessions report the selected direct/relay path when observable.
- Byte counters describe bytes delivered by successful reads to the application. Bytes buffered inside an SDK read that subsequently fails are not observable.
- Known application errors retain their fixed description and category. Untrusted free-form descriptions and domains are omitted with a reason. Selected native domain/code and bounded underlying errors remain; raw `userInfo`, full URLs, local paths, credentials, payloads and raw player logs are never copied.

## Remaining device checks

With the target build identified, reproduce a failed playback and copy its JSONL beside the error. Retry and verify the prior attempt is included. In Settings, select an older attempt and verify that changing the current track does not alter the selected copy. Inspect empty, failed, active, truncated and persistence-failure states, including a narrow window and long track names. Confirm clipboard success feedback and valid JSONL.

On actual devices, exercise cluster acquisition, multiple failing hosts, a failed host followed by a successful host, local playback, a later player error, pause/resume and app relaunch. Check that diagnostics identify the actual path and do not change the audible playback/retry behavior. Repeat the reported tracks in a distributed TestFlight build; attaching the resulting trace is separate from successful compilation or unit tests.

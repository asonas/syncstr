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

The connection-context follow-up allows the explicitly requested application/configuration paths in `environment/runtime`. Other paths remain excluded. Tests cover trace-array archive migration, bounded persistent connection history, copying original observation times into a retry, missing restored peers at reload, and absent versus unreadable registration. Live TestFlight reconnect and target-track playback require a run of the instrumented build; inspecting a manual-build database does not establish the contents or Keychain access of a sandboxed distribution build.

Follow-up verification passed 13 diagnostic tests (including two registration-state parameter cases), eight player-interaction tests and the real TLS pairing/transfer/retry test, which now checks that connection success appears in the subsequent playback trace. The broader legacy-transfer test group also passed before the final observation-only classification adjustments. Final iOS Simulator compilation passed.

Database contention diagnostics retain the fixed `Syncstr.CatalogDatabase` domain, numeric SQLite code, and an allowlisted operation verb. Busy and locked errors have distinct categories; raw SQL, bound values, paths, and free-form SQLite descriptions remain excluded. A real competing SQLite writer exercises the initialization timeout and exported diagnostics. This identifies the blocked operation, not the connection holding the lock; a busy error alone does not establish the holder or justify changing retry behavior.

The current source has three relevant policy boundaries:

- Startup restores the peer identity before loading cluster registration and saved P2P credentials. A failure at the identity step prevents both later reads; a nil in-memory registration alone does not prove an absent database registration.
- Startup requests connection only for a registered cluster. Library reload requests a legacy reconnect only when a peer name has been restored, except when rescanning a selected local folder.
- Before the playback-recovery fix, legacy playback required an existing channel. Live distribution-app observations reproduced a cancelled acquisition followed by zero candidates; reconnecting and selecting the same track once completed its transfer, hash verification and playback.

The playback-recovery fix keeps an in-flight acquisition when album Play selects the same track, while updating the queue. A subsequent unsaved request can reconnect to the restored P2P endpoint or the previously paired in-session TLS device. Reconnection checks the catalog identity, and cancellation only tears down its own connection generation. The error and copy controls follow the queue so their disappearance does not move track rows. Focused player, diagnostic, and real TLS recovery tests passed; shared iOS compilation also passed. This does not establish a fix for the separately observed SQLite lock timeout.

Computer-use validation of the signed debug build confirmed same-track acquisition reuse after selecting an album track and pressing album Play. The source transfer completed with matching size and hash and playback advanced. Switching from an in-progress uncached track to the next uncached track cancelled the original transfer, reconnected to the same host, and played the replacement. The observed reconnect took approximately 47 seconds including catalog exchange; recovery latency remains. The app was left paused. Distribution-build verification requires shipping this patch; the existing distribution build still contains the original behavior.

## Remaining device checks

With the target build identified, reproduce a failed playback and copy its JSONL beside the error. Retry and verify the prior attempt is included. In Settings, select an older attempt and verify that changing the current track does not alter the selected copy. Inspect empty, failed, active, truncated and persistence-failure states, including a narrow window and long track names. Confirm clipboard success feedback and valid JSONL.

On actual devices, exercise cluster acquisition, multiple failing hosts, a failed host followed by a successful host, local playback, a later player error, pause/resume and app relaunch. Check that diagnostics identify the actual path and do not change the audible playback/retry behavior. Repeat the reported tracks in a distributed TestFlight build; attaching the resulting trace is separate from successful compilation or unit tests.

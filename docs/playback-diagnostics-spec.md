# Playback attempt diagnostics

Status: Q1–Q8 and shared understanding confirmed. Implemented; automated validation passed. Native UI and device validation remain pending; see [validation](validation/playback-diagnostics.md).

## Purpose and scope

Make one playback attempt explain which audio object the Mac needed, which source devices it considered, which sources it tried, and the stage and original error of every failure. A successful request from another machine does not establish that the Mac used the same route or successfully acquired the same object.

The initial delivery targets macOS TestFlight and local Debug builds, with the same diagnostic fields and copy capability. Diagnostics are always collected locally and survive app relaunch. Retain at most 20 attempts and 5 MB. There is no automatic upload.

Preserve playback, synchronization, source ordering, retries, timeouts, cancellation, cache retention, and user-facing playback errors. Do not introduce a new acquisition route or extra network probes to improve diagnostics. Shared Apple sources must continue compiling for iOS; iPhone diagnostic UI is outside the initial scope.

## Confirmed decisions

| Decision | Agreement |
| --- | --- |
| Q1: platforms | macOS TestFlight and local Debug builds initially |
| Q2: recording | Always record; retain the latest 20 attempts subject to a 5 MB local limit; persist across relaunch |
| Q3: identity | New attempt for a new playback request or manual retry; manual retry includes the previous attempt ID; internal candidate changes and automatic retries retain the attempt ID |
| Q4: access and export | Copy JSONL beside the playback error and from a recent-attempt list in Settings. No dedicated file-export UI initially. |
| Q5: player observation | Continue after first playback advancement; pause/resume retains the attempt. Failure, explicit stop, or track replacement ends the attempt. |
| Q6: retention pressure | Evict oldest attempts as units; prioritize recent evidence. Bound oversized attempts, disclose missing records, and never block playback to preserve a log. |
| Q7: retry-chain copying | Include the selected attempt and its retained retry ancestors. Identify missing ancestors explicitly. |
| Q8: privacy | Retain requested music/device identifiers and names; omit absolute paths, raw IP addresses, and full URLs. Normalize descriptions before persistence; omit unsafe descriptions with a reason. |

The diagnostic attempt ID is independent of the cancellation-generation UUID. Never change the meaning of the existing cancellation UUID to obtain diagnostic correlation.

## Attempt lifecycle and copy behavior

A new track's playback request starts an attempt, including automatic track advancement and repeat after completion. A manual retry after failure creates a new attempt linked by `retry_of`; restarting a failed player's item is not an unlinked continuation. A normal pause/resume continues the attempt. Internal cancellation during pause or acquisition replacement is recorded as an operation outcome and must not be confused with an explicit user stop or final attempt failure.

First position advancement is a milestone, not a terminal success. Continue observing player failures until normal track completion, explicit stop, track replacement, or final failure. A successful candidate does not erase earlier candidate failures. An existing paused player restored after app relaunch starts a new diagnostic attempt when playback is requested; it cannot continue the interrupted process's monotonic clock.

The playback-error copy action snapshots that error's attempt ID, not a mutable pointer to whatever track is current at copy time. Settings lists recent attempts with time, track, outcome, last observed stage, and completeness; selecting an attempt provides the same copy action. Use the concise Japanese action label “診断ログをコピー”. Expose copy completion or clipboard failure without modifying playback state.

Copy the selected attempt and all still-retained ancestors reachable through `retry_of`, oldest first and ordered within each attempt. Do not include unrelated tracks or later retry descendants. Include missing-ancestor IDs, export time, schema version, and completeness metadata. Copying an active attempt produces an explicitly in-progress snapshot, without stopping playback or waiting for it to finish.

## Current code and evidence gaps

Baseline: `e6b8240`.

| Boundary | Current behavior and lost evidence |
| --- | --- |
| [Library](../apps/macos/Library.swift) `play`, `select`, `resumePlayback` | Reuses an existing player, otherwise checks local files and the playback cache before requesting audio. A `try?` suppresses cache lookup errors. The visible retry uses `resumePlayback` too. |
| [Library](../apps/macos/Library.swift) `playbackRequest`, `pause`, `stop` | The UUID invalidates stale asynchronous work. It changes on pause/stop, but is not necessarily renewed on acquisition retry. It is not a playback attempt ID. |
| [LocalTransfer](../apps/macos/LocalTransfer.swift) `playbackFile` | Resolves the local catalog entry, rechecks cache, makes cache room, then selects cluster acquisition when registered or the existing legacy channel otherwise. No HTTPS audio-download branch exists here. |
| [ClusterTransport](../apps/macos/ClusterTransport.swift) `addresses` | Filters membership host grants, excludes this device and invalid grants, then discovers direct addresses. Relay configuration changes which eligible hosts become candidates. Empty eligible-host and discovery-failure outcomes currently collapse into a general error. |
| [ClusterTransport](../apps/macos/ClusterTransport.swift) `download(object:)` | For each candidate: connect, authenticate, reconcile, resolve from synchronized catalog, request audio, receive and save. Candidate errors overwrite `failure`; Iroh errors become `clusterUnavailable`. Record before both transformations. |
| [ClusterTransport](../apps/macos/ClusterTransport.swift) `ClusterSession` | Selected transport path is observable after connection, but current `lastPath` is assigned only after success. Configured direct/relay addresses do not establish the actual selected path. |
| [CatalogDatabase](../apps/macos/CatalogDatabase.swift) `clusterDownloadEntry` | Resolves the audio object and source authorization from local synchronized state. This does not prove that the peer has or opened its physical audio file. |
| [ClusterTransport](../apps/macos/ClusterTransport.swift) `download(_:)` | Receives remote status and entry, validates SHA/size, writes received bytes, imports the file, and syncs the directory. Several distinct failures become `invalidData` or `disconnected`. |
| [LocalCatalog](../apps/macos/LocalCatalog.swift), [PlaybackCache](../apps/macos/PlaybackCache.swift) | Presence/size checks can suppress attribute errors; a cache hash mismatch removes that cache file and becomes a miss. Record the existing result and reason without adding another full-file hash pass. |
| [Library](../apps/macos/Library.swift) `preparePlayer` | Player/item observers update UI state; item failure loses the native error. The periodic time observer can identify first position advancement. Stale callbacks are intentionally ignored for playback. |
| [PeerTransfer](../apps/macos/PeerTransfer.swift) `resolved` | HTTPS is used for signed endpoint discovery in the legacy P2P connection setup. It is not an HTTPS audio download. If an existing attempt actually triggers this setup, distinguish discovery HTTP from audio acquisition. |

The current visible failure is a symptom, not a confirmed cause. Do not infer server absence, authorization failure, transport failure, or decode failure from the general UI message alone.

## Diagnostic envelope

Use structured, versioned JSONL. Every event includes a timezone-qualified timestamp, monotonic elapsed milliseconds from attempt start, attempt ID, event sequence, stage, event name, and outcome. Include app version/build and macOS version in the copied attempt's metadata; the export must be self-contained.

The requested track ID, audio SHA-256, library ID, and track title belong to attempt metadata. If a value is unavailable at the request boundary, record that explicitly and enrich it when catalog resolution succeeds. A manual retry carries `retry_of`. Each source attempt has a separate candidate-operation ID and ordinal under the same playback attempt.

Do not confuse a source device identity, an endpoint address, a logical protocol, and a selected physical transport path. Record separate fields for acquisition mode (`local`, `cluster`, or the observed legacy mode), connection reuse, and selected path (`direct`, `relay`, or `unknown`). Include an observation reason for `unknown`.

An event sequence expresses observation order within a trace. Do not imply an exact cross-task causal order solely from wall-clock timestamps. Existing asynchronous tasks and player callbacks carry their attempt context explicitly; late completions must not be reassigned to the current track's attempt.

## Required observations

| Stage | Required evidence |
| --- | --- |
| Playback request | Request origin, title, track ID, expected SHA-256, library ID, retry parent, app/OS metadata; distinguish rejected/no-op requests from dispatched acquisition. |
| Local source and cache | Original-folder, saved-copy, and cache roles; lookup outcome; exists/size/readability when observable; expected size and existing validation outcome; selected local source or reason acquisition is required. Preserve attribute/hash/lookup errors before a miss or general error replaces them. |
| Source selection | Eligible devices, discovered candidates and count, selection order, chosen device identity/name when available, per-device exclusion reason, and an explicit no-candidate result. Distinguish no authorized hosts, no discovered direct endpoint, and discovery failure. |
| Connection | Candidate-specific start/success/failure, established versus reused connection, expected versus observed peer identity, selected direct/relay path when known, and elapsed time. Failed connection before path selection remains `unknown`, not an inferred direct or relay failure. |
| Authentication | Verification attempted/succeeded/failed and reason category. Do not export credentials, grants, proofs, handshakes, or authentication payloads. |
| Synchronization | Playback-triggered synchronization start/result and stage-specific failure under the candidate operation. Unrelated background sync is not copied into the attempt. A reused pre-existing session is labeled as reused rather than given fabricated connect/auth events. |
| Object resolution | Requested track ID/SHA, local synchronized-catalog resolution result, source authorization result, actual requested wire object, remote response status, and matching/mismatching response SHA and expected size. Keep local resolution distinct from remote acknowledgment. |
| Transfer | Start, expected size, throttled progress, received bytes, elapsed time, end/EOF outcome, expected/actual length, and the result of the existing hash verification. Capture the byte count and phase even when transfer fails. An actual HTTP operation records its status and purpose; cluster protocol status is never labeled as HTTP status. |
| Save | Temporary-file creation, writing, verification, import/move, and final durable-save outcomes as observable in the existing path. Record save failures separately from network failures. No absolute paths or file contents. |
| Player | File exists/size at the player handoff, item creation/current-item presence, `AVPlayerItem.status`, `timeControlStatus`, `reasonForWaitingToPlay`, and first actual position advancement. Existing seek/resume position must not be mistaken for playback advancement. |
| Error and termination | Failed stage, source operation, original error type, selected NSError domain/code, safe normalized description, and bounded underlying-error chain, captured before UI conversion. Distinguish normal completion, cancellation, replacement, and failure; preserve prior candidate failures even if a later candidate succeeds. |

## Observation limits and error safety

An audio response acknowledges only what the protocol actually reports. A local synchronized catalog selection does not prove remote object resolution. A remote negative response can be recorded as a reported status, but peer-internal read errors or reasons cannot be reconstructed by the Mac when the protocol does not expose them. Emit `unknown` or `not_observable` with a reason rather than claiming that an object is missing.

Do not add protocol fields, server deployments, SDK forks, authentication calls, or transport probes in this delivery. Report any requested evidence unavailable through the pinned SDK or current protocol as a limitation.

Use an allowlist for exported fields. Never serialize raw `userInfo`, generic error dumps, AVPlayer access/error logs, request/response objects, certificates, invitations, authentication headers, tokens, private keys, audio, or artwork. Never export an audio payload or handshake, including as a debugging convenience.

Track title and track/library/object/device identifiers are necessary diagnostic metadata. Omit absolute local paths, raw network addresses, full URLs, URL credentials/query/fragment, and user account/home-directory names. Export file role and measurements instead. Normalize error descriptions before persistence and clipboard use; keep native type/domain/code and bounded underlying errors. If a free-form description cannot be normalized safely, omit it and mark that omission rather than exporting an unchecked string. Underlying-error traversal must detect cycles and impose a depth limit.

### Connection-context follow-up

The listener explicitly requested runtime paths to distinguish TestFlight and manual-build configuration stores. The `environment/runtime` event therefore includes the application bundle path, bundle identifier, local store root and catalog database path. This exception does not include audio paths, credential contents or network addresses. Keychain service names identify the credential store; key material and saved endpoint JSON remain excluded.

Preserve bounded pre-playback connection observations across restarts. Each observation retains its original timestamp and connection operation ID when copied into an attempt, under `connection_history`; the copy timestamp is not the time of the original connection. Capture new connection observations again at acquisition selection, without duplicating previously copied event IDs. Keep up to 128 observations with a maximum 128 KB event budget inside the existing overall retention limit, plus the last observed success, failure and disconnection. Disclose history eviction separately from attempt-event truncation. An unobserved historical connection time stays `not_observed`.

Record calls and skips at startup restore, library reload, explicit legacy reconnect and playback selection. Distinguish in-memory cluster-registration presence from the last read result (`not_read`, `absent`, `present`, `failed`). Preserve restoration failures before the first registration read, Keychain OSStatus values, saved-peer presence, and address availability without endpoint contents. A saved peer ID identifies a peer, not necessarily a catalog: only a successfully received remote catalog establishes the library association. Keep unknown associations explicit and report the last successful peer/catalog pair separately from current configuration.

This follow-up observes the existing policy: startup automatically connects a registered cluster, reload can reconnect a restored legacy peer, and legacy playback requires an existing channel. It does not introduce automatic legacy reconnect or clear settings/cache. The diagnostic archive reads the earlier trace-array format without discarding those traces; schema version 2 exports add connection context.

## Non-interference and durability

Recording must not perform synchronous disk I/O on the playback actor or wait for diagnostic persistence before connection, transfer, or playback. Avoid unbounded buffering, per-audio-chunk disk writes, extra reads/hashes, new sleeps, retry changes, or connection reuse changes. Capture existing progress counters and state transitions; throttle progress records.

Logging failure must not become playback failure, swallow an original playback error, or replace its error identity. Surface diagnostic persistence failure and incomplete evidence in the diagnostic view/export, with a bounded best-effort in-memory fallback. The outcome of a playback attempt must not claim success merely because the log was written.

Retain at most 20 attempts and 5 MB of diagnostic data. Evict the oldest inactive attempt as a unit before newer or active evidence. Rate-limit progress events and reserve space for outcome/completeness metadata. If one active attempt exceeds its remaining budget, bound its records, report omitted-record counts/categories and the last observed stage, and mark the evidence as incomplete. Capacity pressure must never introduce another acquisition, retry, wait, or playback error. Any inability to retain all candidate failures is explicitly disclosed, never silently presented as a complete history.

A copied trace carries retention/truncation markers and explains missing retry ancestors. A process interrupted before terminal recording is reported as interrupted/incomplete on relaunch, not retroactively as a transport error. The 5 MB limit covers stored diagnostic records and metadata, rather than audio/cache storage. Export snapshots are bounded by retained data.

## Acceptance criteria

1. A single failed playback can be copied from a TestFlight or local Debug build without Console, Xcode, SSH, or a debugger.
2. The exported JSONL identifies the requested audio and actual Mac acquisition mode, eligible/candidate counts, source attempts, and the last observed stage.
3. Two failing candidates produce two distinct failure records under the same playback attempt. A final general UI error does not erase either error. A failed candidate followed by a successful candidate remains visible.
4. No eligible host, discovery failure, connection failure, authentication failure, synchronization failure, local resolution failure, remote negative response, transfer failure, verification failure, save failure, and player failure are distinguishable when those boundaries expose evidence. Unsupported remote details are explicitly unknown.
5. Local playback and cache hits are recorded without implying a network request. Existing cache-miss reasons and errors are visible. Logging introduces no extra acquisition or duplicate full-file hash validation.
6. First advancement is observed from actual playback, not an initial seek. Native item failure is captured before the UI message replaces it. Earlier attempt callbacks never become later attempt events.
7. Manual retry and internal source retry follow Q3. Pause/resume and post-start player failure follow Q5. Copy includes retained ancestors and explicitly identifies missing ones; a later current track cannot replace the failed attempt selected for export.
8. Logging survives restart subject to the agreed bounds, marks interrupted/truncated traces, and handles logger write failure without changing playback behavior.
9. Secret-bearing error/URL fixtures produce no exported token, key, header, credential, raw payload, or absolute path. Validate safe field extraction, nested errors, cyclic underlying errors, and unsafe-description omission.
10. Validate the existing playback, cancellation, source failover, synchronization, and retry contracts. Distinguish automated tests, real UI copying, TestFlight verification, and actual reproduction of the reported tracks; none implies the others.

## Completion gate

All interview decisions Q1–Q8 are agreed. Shared understanding was explicitly confirmed before application implementation. Documentation changes do not establish that the logging feature exists, that TestFlight contains it, or that the reported tracks have been reproduced or diagnosed.

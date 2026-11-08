# Shared verified audio and offline saves

The shared Rust client now owns verified playback acquisition, durable save jobs
and the lifetime of managed audio. It extends the
[catalog client](shared-rust-catalog.md), using the existing authenticated v5 audio
request without adding a wire protocol or changing native applications.

## Playback and file lifetime

`prepare_playback(track_id, optional_hash, hosts, optional_secret, operation)`
returns `VerifiedAudio`. An explicit hash selects that exact historical pin;
otherwise the current preferred pin is used. Logical aliases resolve before
acquisition. Verified local bytes can be used offline without credentials.

Keep the asset, or a clone of it, until the native player closes the file. Its
`path()` is protected by the handle: cache eviction and save removal cannot remove
active bytes. The final handle release reclaims an explicitly removed copy, or
trims evictable playback cache. A dropped client cannot release the profile lock
while a player or transfer still retains it.

Network acquisition considers only authorized hosts. A v5 catalog exchange checks
membership, protocol and baseline before requesting the exact ID/hash pair.
Transport failures can try another authorized source; identity, membership and
integrity failures are not retried as ordinary connectivity failures. The existing
download implementation verifies the announced size against the catalog, complete
received length and SHA-256, then flushes the staged file. Only verified bytes are
atomically published under `catalog-audio/<hash>.audio`. Windows closes temporary
file handles before replacement and uses write-through publication.

`Policy` is a cloneable handle for network/execution changes during acquisition.
Explicit playback permits necessary cellular acquisition. Offline saves require
Wi-Fi unless `allow_cellular_saves` is enabled. New clients start offline; the
native owner supplies current connectivity and execution permission. Transfer
policy changes and explicit `Operation::cancel()` stop acquisition, drain I/O and
reject late completion. Whole-file playback is used; progressive playback is not
implemented.

The playback cache defaults to 10 GiB. `cache_limit_bytes` and `trim_cache()` apply
to evictable bytes, excluding explicit saves. Active audio is never evicted, even
when one track exceeds the budget. Last-used order is retained across restart;
release retries trimming. Opening a profile cleans interrupted staging and
deferred removals without applying a cache budget before native settings arrive.
Only the dedicated managed audio directory is reclaimed. Existing objects,
external originals and host files remain outside this eviction path.

## Durable saves

`save_tracks` and `save_album` persist an immutable job snapshot before returning
its ID. Album snapshots cover the current tracks, not later additions. Already
verified cached audio receives logical-track/hash save receipts in the same
transaction as job acceptance. Merely preparing playback creates no save receipt.

The retained application worker calls `run_save` for accepted job IDs. Each
verified success checkpoints its receipt and item result atomically. A failed
item leaves earlier successes protected. Running a partial job verifies and
reuses local successes and downloads only missing audio. Results are available
through `save_jobs()` and `saved_tracks()`; no UI callback runs under a store lock.

Operation cancellation interrupts execution while preserving accepted intent.
`cancel_save` explicitly persists cancellation without undoing completed saves;
`retry_save` makes the job eligible again. Dropping a view or observer must not
drop the service-owned client/worker. If a Rust calling future is abandoned, the
client still tracks its transfer, and accepted intent remains resumable.

`remove_save` removes the selected logical-track/hash receipt, including that
pin's ownership in job snapshots. Another logical track sharing the hash still
protects the file. Removing the last receipt marks the managed copy for deletion;
active player handles defer physical removal. The marker survives restart. It
does not turn the removed save into permanently retained playback cache.

## Shutdown and recovery

Callers must now `await client.shutdown()` and handle its result. Shutdown is
idempotent: reject new calls, cancel tracked transfers, wait for their I/O and
active player handles, checkpoint/close the serialized SQLite writer off the
calling executor, then release the profile lock. Stop native playback and release
its handles before waiting for shutdown. Use the application's retained Tokio
runtime and worker rather than creating a runtime per command.
Run core file operations and final asset release on that worker; this Rust API
does not dispatch native UI calls or binding disposal onto a worker automatically.

After process interruption, running jobs restore as waiting with the same request
ID, snapshot and completed receipts. Unverified staging is discarded. A verified
hash-named file published before its database checkpoint can be recovered as
cache; recovery does not invent a save receipt. Production migration is not
performed, and the enrolled identity is reused without persisting a new key.

## Windows verification

Started from main `b594863` with Rust/Cargo 1.99.1. Reproduce the focused checks:

```powershell
cargo test --manifest-path headless/Cargo.toml --features p2p -j 1 --test catalog_audio --test catalog_client --test cluster_client --test playlists
cargo clippy --manifest-path headless/Cargo.toml --features p2p --lib --test catalog_audio --test catalog_client --example shared_audio_fixture -- -D warnings
```

| Check | Result |
| --- | --- |
| Shared acquisition/save/lifecycle scenarios | 6 passed |
| Shared catalog regression | 4 passed |
| Existing playback client and playlists | 6 passed |
| Broader shared-audio regression | 35 passed; 1 existing Windows failure below |
| Clippy, changed-file rustfmt and whitespace checks | Passed |
| Existing fixture command-line generation | Passed |

The broader suite was first run in full. Its known failing test was then excluded
only from the remaining local rerun after an independent main comparison; the
failure is not counted as a pass. A transient Windows PDB linker error during a
parallel build did not recur with `-j 1`.

The existing disposable v5 generator is shared between its unchanged command-line
entry point and the audio tests. The real server verifies two distinct logical
tracks sharing bytes, independent receipt removal during playback, and offline
reopen. An authenticated scripted host exercises partial retry, fixed album
snapshots, unauthorized-source filtering, bad bytes/size, cancellation and policy
changes. Additional lifecycle cases terminate an actual worker process and drain
a transfer after its calling future is dropped. The ignored worker entry point is
explicitly invoked by the crash-recovery test, not a skipped product scenario.

The broader Windows `shared_audio` suite has a pre-existing failure in
`quic_audio_additions_share_bytes_and_reject_invalid_uploads` (`deadline has
elapsed`). The same isolated test fails on unmodified main `b594863` in a separate
worktree. This result is recorded separately from the new catalog/audio tests;
the CI configuration does not skip it.

Native Apple/Android builds and binding execution, native audio output, OS
background behavior and real-profile migration remain unverified here. ASO-10/11
own native integration and ASO-12 owns cross-platform acceptance.

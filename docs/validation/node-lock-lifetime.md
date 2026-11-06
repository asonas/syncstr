# Node lock lifetime

ASO-49 fixes ownership of `node.lock` in both the legacy and v5 headless stores.
Ownership ends when the final Store clone is dropped, even if a child process
temporarily retains an inherited file descriptor. The wire protocol, signed
records, baseline, database schema, and stored payloads are unchanged.

## Cause and evidence

The stores previously relied on closing a `File` to release its exclusive
`flock`. Inherited descriptors reference the same lock; closing only the
parent's descriptor does not release it while the child retains its reference.
See Apple's [flock manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html).

The migration integration test starts `shared-audio-inspect` as a subprocess.
Rust 1.99.1 selects `posix_spawnp` for that ordinary `Command` on macOS. Another
test can finish inspection, close its lock, and attempt activation while that
spawn is still carrying its descriptor into the child.

Before the fix, the default parallel suite failed in two of five baseline runs.
An external-command-free observer recorded this sequence for one inode:

| Time relative to spawn entry | Event |
| --- | --- |
| 0 us | Another thread enters `posix_spawnp` for the inspector |
| 408 us | Parent finishes closing its last lock descriptor |
| 546 us | Reacquiring that lock fails with EWOULDBLOCK |
| 1,310 us | Spawn returns its child PID |

A separate diagnostic sampled reacquisition after failure. In one case the
lock remained unavailable 344 us after parent close and became available by
578 us after close, during the same spawn. That diagnostic still returned the
original failure; it was removed and is not the fix. Child-PID enumeration could
not see the child during this short spawn interval, so it did not yield a live
child-FD snapshot. The returned spawn PID identifies the pending child operation.
Excluding only the subprocess-launching migration case made the remaining ten
parallel cases pass in ten diagnostic runs; the case remains enabled in CI.

The regression tests make the inheritance deterministic: a child reports its
PID and waits on a socket before exec while the parent drops its Store. Both
legacy and v5 stores failed to reopen before the fix, with a known child holding
the descriptor throughout the measured 253 us and 210 us intervals respectively.
The tests release and join the child before asserting, including on failure.

## Fix and production impact

The internal `NodeLock` guard explicitly unlocks on the acquiring process's
final owner drop, rather than waiting for every inherited descriptor to close.
Store clones continue sharing their existing Arc; dropping one clone does not
release the lock. A process-ID check prevents a forked child from unlocking its
parent's still-live Store when it drops an inherited guard. Both stores retain
the same lock file and nonblocking acquisition behavior. This adds no retry,
wait, or serialization of tests.

This is a production lifetime bug, not only fixture interference. A Unix host
that launches a child while holding a store lock can close its final Store and
then fail to reopen it, or cause another opener to fail, until the inherited
reference is gone. The observed trigger uses macOS `posix_spawnp`; the controlled
fork/exec regression covers the underlying Unix inheritance behavior. Fresh
Linux and Windows executions were not performed for this patch. Windows has no
Unix fork path; the guard continues using fs2's native lock/unlock operations.

## Verification

On macOS with Rust 1.99.1:

- The final default-parallel `shared_audio` suite passed 20 consecutive runs:
  13 passed, zero failed, zero ignored in every run (260 test executions).
- The same suite passed serially: 13 passed, zero failed, zero ignored.
- The inherited-guard unit test and CI's other selected integration suites
  passed: 34 tests, zero failures. They cover live owner exclusion, child guard
  disposal, CLI processes, node restart, native field contracts, cluster changes,
  playback clients, replication, private relay access, and playlists.
- CI's production-library Clippy command passed with `-D warnings`.
- The workflow remains unchanged and uses its default parallel mode.

The parallel suite includes the two new inheritance regressions, not just the
original eleven tests. To reproduce its required repeated verification:

```sh
(
  for aso49_run in {1..20}; do
    cargo +1.99.1 test --manifest-path headless/Cargo.toml --locked \
      --features p2p --test shared_audio || exit 1
  done
)
cargo +1.99.1 test --manifest-path headless/Cargo.toml --locked \
  --features p2p --test shared_audio -- --test-threads=1
```

Temporary syscall observation and release probes are excluded from the patch.
The separate `device.lock` paths in `peer.rs` still return raw files; extending
their lifetime handling was outside ASO-49 and was not changed or verified here.

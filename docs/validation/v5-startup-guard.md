# v5 startup guard

ASO-146 raises the schema generation of the host database from 5 to 6 when its
activation control storage is initialized. This record shows that host builds
from before the guard refuse such a store by their own check. The rules are in
the [control protocol design](../v5-activation-control-protocol.md#part-4-startup-guard).

No production host or library was used. The store is the disposable fixture of
the [v5 handoff](../shared-audio-v5-handoff.md#disposable-native-client-fixture).

## What every earlier build checks

The first build with a shared store is `c0b352e`. The last build before the
guard is `8173cab`. For each of the 67 first-parent revisions from one to the
other, the lines of `headless/src` that open `node.sqlite` or compare its
`PRAGMA user_version` were listed with `git grep`. They form seven distinct
sets, and all seven hold the same three rules:

| Code path | Accepted generation | Opens the database for writing |
| --- | --- | --- |
| `shared_audio::Store::open` | exactly 5 | yes |
| `shared_audio::Store::activate` | 4 or 5 | yes |
| `store::Store::open` (legacy) | 0 to 4 | yes |

`shared_audio::Store::inspect`, the inventory and the catalog client open the
database without this check. They only read it.

Revisions outside the first-parent history of `main` were not listed.

## Observed refusals

Two earlier builds and the build of this change were started on one fixture
store. Each `shared-audio-serve` ran for at most five seconds.

Environment: macOS on Apple silicon, Rust 1.99.1, `--features p2p`, debug builds.

| Build | Generation 5, no control storage | Generation 6, after `init` by the new build |
| --- | --- | --- |
| `c0b352e` (first v5 build) | serves | exit 1, `shared audio is not activated` |
| `8173cab` (last build before the guard) | serves | exit 1, `shared audio is not activated` |
| this change | serves | serves |

On the store at generation 6, `8173cab` also refused these commands:

| Command | Result |
| --- | --- |
| `shared-audio-control status` | exit 1, `shared audio is not activated` |
| `shared-audio-activate` | exit 1, `unsupported migration source` |
| `serve` (legacy store) | exit 1, `unsupported catalog schema 6` |

## Reproduce

Export and build an earlier revision outside the working tree, then use the
binaries on a new fixture directory:

```sh
mkdir -p tmp/old
git archive 8173cab headless | tar -x -C tmp/old
(cd tmp/old/headless && cargo +1.99.1 build --locked --features p2p --target-dir ../target)
cargo +1.99.1 run --manifest-path headless/Cargo.toml --locked --features p2p \
  --example shared_audio_fixture -- tmp/guard-fixture
headless/target/debug/syncstr-headless shared-audio-control --data tmp/guard-fixture/host-data init
sqlite3 tmp/guard-fixture/host-data/node.sqlite "PRAGMA user_version"
tmp/old/target/debug/syncstr-headless shared-audio-serve --data tmp/guard-fixture/host-data \
  --identity tmp/guard-fixture/host-tls --peer-state tmp/guard-fixture/host
```

The last command exits with `shared audio is not activated`.

## Limits

- Only two of the 67 revisions were built and run. The others rest on the listing of their source.
- Only macOS builds were run. The check is the same Rust code on every platform, and no Linux or Windows build was started.
- A build that someone changes to ignore the generation is not stopped. Operators verify installed builds separately.
- A data directory restored from before `init` is at generation 5 again. Such a restore is a downgrade under D6 of the [activation design](../v5-activation-and-recovery.md).

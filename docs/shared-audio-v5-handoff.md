# ASO-8: v5 protocol and Apple handoff

This contract is the server prerequisite for ASO-9 (Apple), ASO-10 (Android) and
ASO-11 (Windows). ASO-12 tracks cross-platform acceptance. It does not authorize
production activation. Use the exact published revision recorded on ASO-8.

## Wire contract

The cluster protocol ALPN is `syncstr/cluster/5`. It uses the existing enrolled
Iroh endpoint identity and signed enrollment proof. Every JSON message is UTF-8,
preceded by a four-byte unsigned big-endian byte length. The maximum frame is
64 MiB; the handshake maximum is 4 MiB. Frames are not newline-delimited.

The first bidirectional stream carries a client frame
`{"version":5,"proof":<enrollment-proof>}`. The client finishes its send side.
The server authenticates the QUIC remote ID against the merged proof and replies
with the same JSON shape containing its current proof, then finishes. Clients
must keep their known revocations when merging the response, validate root and
cluster equality, and require a live host grant for the actual remote ID.
They must also verify their own live membership. A successful QUIC transport
handshake alone is not application authorization.

Every subsequent bidirectional stream contains one request frame; the requester
finishes its send side. The server sends the indicated response and finishes.
Errors reset/close the stream or connection; there is no success-shaped error
envelope. Do not replace retained state on an incomplete or failed response.

| Request JSON | Response JSON, followed by optional bytes |
| --- | --- |
| `{"operation":"catalog"}` | `Snapshot { catalog, playlists, playlist_history }` |
| `{"operation":"records","after":0}` | Array of `[cursor, Signed]`, at most 64 |
| `{"operation":"playlist-records","after":0}` | Array of `[cursor, PlaylistSigned]`, at most four |
| `{"operation":"receive","records":[...]}` | `true`; only an authorized host may submit signed decisions |
| `{"operation":"audio","track":"T-A","hash":"<sha256>"}` | A JSON integer byte length, then exactly that many raw audio bytes until EOF |

`Snapshot.catalog` is the same typed catalog as HTTPS `GET /v5/catalog`;
`version: 1` denotes its first schema, not the transport version. The exact types
are `Catalog`, `Track`, `Object`, `Source`, `Evidence`, `Edit`, `Body`, `Signed`
and `Request` in the shared-audio module. Rust structs use snake_case unless
their serde attributes say otherwise. Signed decision payloads retain the exact
`syncstr-shared-audio-v1\n` prefix and JSON text; hash and verify the original
payload bytes, never a decoded/re-encoded dictionary.

The snapshot includes all logical tracks, including unavailable, retired or
conflicted tracks. There is deliberately no conversion into a one-row-per-hash
legacy catalog. `tracks` is keyed by logical ID; `addresses` retains frozen
legacy aliases. `audio` and `preferred` are current bindings; `pins` includes
historical bindings. `objects` describes content independently. Physical
`locators` are server-local relative names, not download URLs or device paths.
Unknown byte lengths and missing replicas remain unavailable.

Track metadata retains supplied values. Migrated metadata has `organization`
and `legacyEntry` provenance; subsequent explicit metadata keys belong to the
logical track. Apply ADR 0004 precedence without inventing absent values. Never
infer a track alias from equal hashes. Conflicts/incomplete history must remain
visible as unresolved state and must not be selected by timestamp or iteration
order. A correspondence pointing to a retired track is not reusable for import.

`playlists` contains projected documents and revision/conflict state.
`playlist_history` contains the original signed envelopes, including baseline
v1/v2 history, so clients can verify and retain exact payloads. The snapshot is
read under one store lock. The incremental playlist endpoint returns new v5-era
records; initialize historical state from the snapshot first. Preserve
occurrence IDs, order, repeats and source fields. Download the occurrence's exact
`(track_id, sha256)` pair rather than a track's latest preferred encoding.

For audio, enforce the advertised size and 20 GiB maximum, stream to a temporary
file, check SHA-256 and install atomically. A missing binding never falls back to
another track with matching metadata. Store local save intentions by logical ID
and pinned hash; coalesce physical bytes by hash. Keep active queue pins stable.

## Membership, writers and synchronization

The dedicated service checks membership for every request and during audio
streaming. A revoked peer cannot start another operation on an existing session.
Signed revocations merge monotonically; replaying an older proof cannot restore
membership. New records from revoked authors are rejected; already accepted
signed history remains readable. Histories first received after their author was
revoked require explicit review rather than automatic acceptance.

HTTPS bearer tokens are administrative host credentials, not playback-member
tokens. Do not install them in ordinary native playback clients. Host approval
and explicit playlist revisions use the documented authenticated HTTPS endpoints.
The member QUIC service offers read/replication operations, not unsigned client
metadata writes. New invitation issuance/redemption remains pre-activation;
v5 recognizes existing grants and accepts additional valid signed membership
proofs. Do not reset existing device identities to connect.

The v5 server advertises the existing cluster discovery service when bound to a
non-loopback IPv4 address. Discovered authorized hosts are retried every three
seconds. Each pass is bounded to 120 seconds, validates cluster/baseline equality,
pulls decision and playlist pages with atomic cursors, then retrieves missing
pinned objects. A newly installed object serves every logical binding sharing
its hash. Discovery is an address hint; membership and endpoint identity are the
authority. Each host pulls, so no automatic writer is inferred from discovery.
There is no new remote relay configuration in this slice.

Old cluster ALPNs and old HTTP mutations are rejected by the dedicated v5
service. Once a client retains a v5 baseline, it must not fall back to legacy
logical merging on a failed refresh. Independently populated hosts with different
baselines fail closed; this release does not reconcile divergent migrations.

## Disposable native-client fixture

From the repository root, generate a new output directory:

```text
mise exec -- cargo +1.99.1 run --manifest-path headless/Cargo.toml --locked --features p2p --example shared_audio_fixture -- tmp/v5-fixture
mise exec -- cargo +1.99.1 build --manifest-path headless/Cargo.toml --locked --features p2p
```

The generator refuses an existing directory. It creates one second of quiet
440 Hz PCM WAV audio, one legacy track/alias and signed playlist with repeated
occurrences, and two independent registrations sharing that object. It creates
two schema-5 fixture databases with the same activation baseline, generated test
host/reader identities, TLS credentials, `snapshot.json`, `records.json`,
`expected.json` and `reader-enrollment.json`. The replica initially has no audio
or new logical decisions, making catch-up observable.

For automated Apple tests, import the fixture reader identity from
`reader/device.key` and its corresponding `grant`/`proof` into an isolated test
credential store. Never import these into an everyday app profile. Generated
keys, bearer tokens, databases and outputs stay local and out of Git/Linear.
Tests can verify the exported signed history independently using the proof.

Start the host using the built binary (append `.exe` on Windows):

```text
headless/target/debug/syncstr-headless shared-audio-serve --data tmp/v5-fixture/host-data --identity tmp/v5-fixture/host-tls --peer-state tmp/v5-fixture/host --listen 127.0.0.1:8443 --peer-listen 127.0.0.1:8444 --peer-address-out tmp/v5-fixture/host-address.json
```

The default QUIC bind is loopback. For a separate Mac/device on a trusted test LAN,
replace `--peer-listen` with the fixture machine's LAN address and chosen UDP port;
keep HTTPS loopback. Use the exported endpoint address and proof, or LAN discovery.
Start the replica with `replica-data`, `replica-tls`, `replica` and different ports
on the same LAN to observe automatic convergence. A loopback-only setup uses
explicit addresses in the Rust tests because mDNS does not advertise loopback.

Run the contract tests:

```text
mise exec -- cargo +1.99.1 test --manifest-path headless/Cargo.toml --locked --features p2p --test shared_audio
```

They exercise real loopback QUIC, feed discovery events at the external address
boundary, test automatic scheduling/catch-up after restart, and verify legacy
pins, membership and protocol rejection. They do not establish multicast
reachability on the Mac's LAN, Apple UI behavior or physical audible output.

ASO-9 should report its tested server commit, app builds, focused tests,
Simulator/macOS interaction results and any device gaps. Keep ASO-12 open until
the cross-platform acceptance matrix is complete. No fixture result authorizes
production migration, broad source approval, deployment or object deletion.

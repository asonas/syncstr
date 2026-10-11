# Compilation and artwork in the shared cluster

Status: stage C implemented locally. This record covers development verification,
not TestFlight delivery or physical-device screen checks.

## Contract

Import context, former album references, acquired image candidates, and listener
choices travel in the cluster's existing host-signed object changes. No second
replication protocol or permanent importing-device authority is introduced.
Complete-file hashes identify replicas; neither a storage path nor a matching
album title recreates missing import context.

Playback clients request missing tag evidence from reachable hosts without
downloading audio. A host verifies the complete file before and after reading
tags with [Lofty](https://docs.rs/lofty/0.25.4/lofty/), preserves the raw assertions,
and publishes an ordinary signed metadata edit. Unknown values remain unknown;
deleted or conflicted objects are unavailable for recovery. Original import
context and listener choices survive extraction from a managed replica path.
The reader tolerates ordinary empty legacy fields, including an ID3v1 year,
instead of discarding readable ID3v2 evidence. Native saved replicas can also
recover tags and normalized embedded images after complete-hash verification.

Headless projection retains catalog metadata and image content before audio is
downloaded. Only verified audio storage creates an audio receipt. Hosts retain
validated images in their durable signed history and projected organization;
playback devices retain catalog images independently of downloaded audio.

Concurrent changes with identical entry and import evidence can combine their
causal organization histories in a host-signed edit referencing all competing
heads. Both manual cover choices remain available for listener resolution.
Different entry metadata, import evidence, deletion, restoration, and explicit
object resolution remain object conflicts. No device clock chooses a winner.

Explicit tombstones remove a deleted object's tracks, candidates, and unreferenced
cover choices from active projection. Signed history and source bytes remain
retained. Missing files, hosts, or Music access are not tombstones. Restoration
requires the existing explicit cluster restoration path.

The cluster ALPN is `syncstr/cluster/3`; older cluster writers must upgrade.
Signed change preimages are bounded to 16 MiB and encoded frames to 64 MiB,
including the signature preimage carried beside a change. Each verified JPEG
remains at most 400 pixels per dimension and 512 KiB. Enrollment and legacy music
protocols retain their own version domains and existing bounds.

## Verification

- Rust real-host exchange transfers a five-image causal history exceeding the
  former 1 MiB change and 4 MiB page limits. Duplicate reconciliation and reopening
  after the source host stops preserve the exact image assets without an audio
  receipt.
- Twenty differently credited tracks retain one portable source context and
  positive compilation evidence. A second host receives their signed metadata,
  repairs one album after the first host stops, and repeats projection without
  changing the result. No original absolute source path is available or needed.
  Per-object transfer of the already consolidated catalog retains former album
  records and can recompute automatic aliases on another replica.
- Parallel cover choices converge to one object history while preserving both
  images and choice heads. A later choice references both alternatives.
- Headless catalog projection works without audio, rejects an ordinary import
  over a deletion, and supports explicit restoration. Native persistence excludes
  deleted image evidence while retaining an offline cover before deletion.
- A reachable host recovers raw tags from verified bytes without sending audio.
  Unrecognized compilation assertions survive extraction; same-length corruption,
  deletion, and unresolved object conflicts cannot supply recovery evidence.
  Native saved-replica recovery retains import context and choices, groups two
  compilation tracks, rejects altered bytes, and remains idempotent.
- A real Swift client and two headless processes acquire a Music-origin image
  before downloading audio. Image selection and clearing propagate without
  changing downloaded audio bytes, modification time, or transfer-job count.
  The surviving host supplies the retained cover and verified audio after the
  original host stops. A higher-priority shared embedded candidate replaces the
  automatic Music cover. After the original host stops, the native client also
  recovers two undownloaded tracks' tags from the surviving host, groups them in
  one album, and retains its Music-origin image.

Rust's full p2p suite passed 55 tests; the five cluster-artwork tests were repeated
after review and parser fixes. The ordinary Rust build passed 25 tests. Clippy
passed with warnings denied for both feature configurations. The final iOS
simulator suite passed 48 tests. The final macOS suite passed 66 tests with two
explicit external-environment tests skipped and no failures. Cluster and local
headless process interoperability tests ran. Existing stage B image-conflict and
reordered-delivery tests remain part of that suite.

The development-signed LibraryCheck passed all ten AVPlayer checks, including
catalog restoration, offline playback, image save/clear, and automatic membership
repair without replacing the active player or queue. Its Keychain stores are
isolated from ordinary peer identity and pairing records. Specification and
standards reviews have no unresolved findings.

Native process tests accept `SYNCSTR_HEADLESS_TEST_BINARY` to select the verified
host executable outside disposable build caches. A test run whose executable
disappeared during cache collection was rejected and repeated with a fixed copy;
missing binaries and skipped process tests are not interoperability proof.

Physical iPhone interaction, screen screenshots, TestFlight delivery, and M3's
remaining manual acceptance checks are unverified and remain separate from these
automated integration gates.

# Moving the library and the code to one primary host

Status: proposed on 2026-11-17 with [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md), which the owner accepted on 2026-11-18. Nothing in this plan is implemented, and it authorizes no production operation. Every step that touches the owner's NAS waits for the owner's explicit go-ahead, as listed in [Steps that need the owner's go-ahead](#steps-that-need-the-owners-go-ahead).

Devices connect to the new host by its Tailscale HTTPS address, and the tailnet policy decides which of them can read. The new host keeps no device records and no tokens. The old `serve` keeps its own `/v4` token until it is retired.

This plan takes the repository and the owner's library from main at `d0b4db5` to the design in [Syncstr on a private network](private-network-architecture.md), which links to the other parts. It answers ASO-161 (the store and the migration), ASO-165 (the order of the Apple transport change), ASO-168 (what a device may change), ASO-169 (removal of the old stacks), ASO-170 (the Windows, Android and gpui apps) and ASO-171 (existing issues).

The owner accepts the recommendations below by merging this document, except the removal of the Windows, Android and gpui apps. That removal is a recommendation that needs the owner's separate decision in ASO-170, and merging this document does not decide it.

## Where things stand at d0b4db5

### The owner's host

The owner's NAS runs the headless host in a container as the legacy `serve`. That process serves the `/v4` HTTPS API (`headless/src/api.rs`), the legacy peer transfer over iroh on a fixed UDP port (`headless/src/peer.rs`), and announcements to the rendezvous directory (`headless/src/rendezvous.rs`). The store is at schema generation 4, with several thousand tracks, tens of gigabytes of audio, artwork assets, and a `node.sqlite` of a few gigabytes. Devices are paired with it, and Tailscale is not installed. A test deployment of the cluster host and a relay has run on the same NAS since October. These facts come from a read-only inspection on 2026-11-17. Its exact figures stay out of this repository, in Linear issue ASO-161, and the migration compares against them.

Schema generation 4 describes the catalog tables, not every table in the file. `Store::open` creates the cluster tables on every open, because `headless/src/cluster.rs` is not behind the `p2p` feature, and a `p2p` build adds the enrollment, change, replica and playlist tables (`headless/src/store.rs`, lines 104 to 112). The owner's library was filled through `tools/music-migration/nas_import.py`, which runs `headless/examples/migration_batch.rs`. That example imports each file with `import_cluster_file`, which creates a cluster identity and signs changes.

A second read-only inspection on 2026-11-17 counted what the owner's database holds besides the four catalog tables:

| Content | What the migration does with it |
| --- | --- |
| Cluster identity and enrollment grant | Not carried |
| Signed cluster changes, about two per track | Not carried |
| Cluster object and peer rows | Not carried |
| Playlist records with their history | The single head of each playlist becomes a plain row. A playlist with more than one head stops the migration. |

The signed cluster changes take about three quarters of the database, and the `tracks` table most of the rest. The volume that holds the library has room for a full copy of the audio many times over. Its filesystem supports hard links within one dataset. Whether the original and the new data directory would be in one dataset is not known.

### The apps

The macOS app and the iPhone app share 30 Swift files from `apps/macos`, listed in `apps/ios/project.yml`. `Library` gets every remote file through `LocalTransfer.playbackFile` in `apps/macos/LocalTransfer.swift`, which returns a whole local file whose hash it has checked. A device with a cluster registration downloads through `ClusterNetwork`. Every other device uses the legacy connection to a Mac over Bonjour or to a host over iroh (lines 1638 to 1645).

Devices also change the library over the legacy connection. `headless/src/peer.rs` accepts `put`, which adds a file with its album organization, and `organize`, which merges album organization changes such as a hidden album (lines 329 to 424). `headless/src/playlist_sync.rs` accepts playlist import and reconcile from Music XML. Track metadata edits exist only on the cluster path, which the owner's library never used.

The transport code in the Apple apps is 5,366 lines. Twelve files (`Cluster*.swift`, `Peer*.swift`, `SharedAudio.swift`, `SharedTrackResolution.swift` and `LocalSetup.swift`) hold 3,499 lines, and `LocalTransfer.swift` holds 1,867. The apps bundle IrohLib and two copies of its licence text, 61,668 lines each.

### The repository

| Part | Files | Lines |
| --- | --- | --- |
| `headless/src`, all of it | 48 | 24,057 |
| Activation journal and inventory, `headless/src/activation_*` | 14 | 8,660 |
| v5 store, API and host-to-host network, `headless/src/shared_audio*` | 3 | 4,499 |
| v5 app core, `headless/src/catalog_client*` | 5 | 2,125 |
| Cluster, enrollment, peer, playlist sync, relay and rendezvous code in `headless/src` | 13 | 4,667 |
| Windows, Android and gpui apps, the bindings experiment and the IME probe | 98 | 21,771 |
| Connectivity probe, `headless/connectivity-probe` | 23 | 2,007 |
| Rendezvous Worker, `rendezvous` | 8 | 261 |

Line counts exclude lockfiles, images and the IrohLib licence texts. [Regenerate the counts](#regenerate-the-counts) gives the commands.

In CI, `verification.yml` tests the headless crate only with `--features p2p`, and its macOS job builds the v5 fixture examples. `desktop.yml` builds the gpui app on a macOS runner and a Windows runner for every change under `headless/`. `lan-verification.yml` runs the mDNS tests by hand, and `weekly-simulator.yml` also builds the v5 fixture tools. The repository has 8 ignored Rust tests. Five are in the connectivity probe, two in `headless/tests/lan_process.rs`, and one is a subprocess entry point in `headless/tests/catalog_audio.rs`.

## Keep the schema-4 catalog and remove its conflict with ADR 0006

### Two candidates

The first candidate keeps the schema-4 catalog of `headless/src/store.rs`. The second keeps the v5 logical-track model of `headless/src/shared_audio.rs` without signatures, cursors and membership. Without signing, that model is a `Track` with a list of audio hashes, a map from old track addresses to tracks, and pins for playlist references. `legacy()` (lines 409 to 562) already projects a generation-4 store into it. Most of the rest of the file's 2,846 lines is the signed record log, its projection and the write gates, so keeping the model means rebuilding its shape as plain tables.

The schema-4 catalog breaks ADR 0006 on the write path in three places:

- The `tracks` table has `UNIQUE(sha256, suffix)` (`store.rs`, line 40), so two tracks cannot name one file.
- `commit_organized` gives a new import the ID of a stored track with the same bytes and records a track alias (`store.rs`, lines 237 to 260).
- `Organization::merge` adds a track alias when a new track's hash matches one existing track (`headless/src/organization.rs`, lines 434 to 451).

The schema never let two track rows share a file, so the owner's store has no split to undo. Registrations that the old write path merged by bytes survive as entries in `trackAliases`, and ADR 0007 keeps those aliases as they are. So ADR 0006 constrains the write path, not the migration. The source inventory behind the [shared-audio server design](shared-audio-server-design.md) found a few registrations that suggest shared destinations, and none is approved.

| | Schema-4 catalog, amended | v5 model without signing |
| --- | --- | --- |
| What the migration does to the owner's data | Copies tracks, album organization and artwork byte for byte, and converts playlists | Projects every track into new tables, as `legacy()` does |
| ADR 0006 and ADR 0007 | Kept by the write-path changes below | Kept by design, including several audio files per track |
| Catalog shape a device reads | The `Entry` and `Organization` JSON that the Apple apps already decode, fixed by `headless/tests/contracts.rs` and the shared fixtures | A new shape. Its Apple decoder, `SharedAudio.swift`, requires a cluster registration |
| Code to write, estimated | Under 1,000 lines with tests, mostly the migration command | 2,000 lines or more on the host, plus a new decoder in the apps |
| How the migration is checked | Byte equality of copied rows | Equality of two projections, which needs its own reference |

Both candidates delete all of `shared_audio*`.

### Recommendation

This plan recommends the schema-4 catalog with these changes:

1. Drop the uniqueness constraint. Two tracks may name the same audio file, and the file is stored once.
2. Give each import a new track ID unless the request names an existing track. An import never takes an ID or adds a track alias because bytes match. This changes `commit_organized` and `Organization::merge`.
3. Keep one audio file per track, named by the `sha256` and `suffix` that each track row already has. That is the explicit binding between a track and its audio that ADR 0007 asks for.
4. Store playlists as plain rows instead of signed records.
5. Add the `revision` of the [host API](host-api-design.md) to the library row. It rises by one in the same transaction as every change, and it is the last part of the change marker.
6. Remove the cluster tables and the `migrate` calls that create them.
7. Call the result schema generation 7 and keep it as `node.sqlite` in a new data directory. Generations 5 and 6 already mean v5 (`ACTIVATED` and `GUARDED`, `shared_audio.rs` lines 571 to 577). The old `serve` refuses any generation above 4 (`store.rs`, lines 34 to 37), and v5 builds refuse any generation above 6 (`shared_audio.rs`, lines 653 to 656). No old binary can open the new store by mistake.

The owner's data and the devices decide it. The owner's library never held v5 data, so the v5 shape would be a projection built for this migration alone. The schema-4 rows are what the devices already decode, so the first release changes the transport and not the catalog format. A byte copy is also the easiest migration to check.

The cost is a real migration of the owner's library into a new directory, where leaving the store alone would cost nothing, plus the two write-path changes. A track also cannot yet have a second encoding, such as a smaller copy for the phone.

Three things would change this recommendation:

- If the owner wants several encodings per track, add a table that binds a track to several audio files. That extends this store and does not need the v5 model.
- If a re-import from Music must recognize a track imported before, add the source correspondence of ADR 0006 to the import (ASO-41, rewritten).
- If both arrive and devices must show encodings per track, the v5 shape becomes the better fit.

### How playlists and album organization are stored

A playlist is one row that holds the `Document` JSON of `headless/src/playlists.rs` unchanged. The document keeps its ID, folder parent, kind, smart-playlist definition, source fields, and every item with its occurrence ID and its pair of track ID and audio hash. That pair stays pinned, as ADR 0007 requires. If the pinned track or audio is missing, the item is unavailable and is never pointed at another track. A later edit from a device sends the change marker it saw, and the primary refuses a stale one.

Album organization stays as it is today. One `Organization` document in the `organization` table holds albums, track aliases, and the membership, classification, artwork and visibility choices. Artwork bytes stay in `artwork_assets`. The primary changes the document in one transaction, as `merge_organization` does today. Each choice keeps its `parents`, and with one writer each subject has one current choice.

### What the store keeps besides the library

The same `node.sqlite` keeps the host state that [mirrors and the primary switch](mirrors-and-primary-switch.md) lists: the host ID, the switch record, the role, the known hosts and any held copies. One database means that a change and the switch record it depends on commit together. How a host proves itself to another host is not decided, and ASO-172 adds what the store needs for it.

The owner's store keeps its library ID and starts at switch number 1 with itself as the primary. The migration creates no host ID, because it is random and the migration stays repeatable. The new host creates it on its first start. Connections to the old `serve`, which are its iroh peer list and its single `/v4` token, are not carried. The owner's devices connect to the trial host by its host address.

## Migrate the owner's library into a new directory

### Rules the migration follows

- The migration reads the source through a read-only SQLite connection. It never calls `Store::open`, because that call writes. It creates tables, repairs membership, rewrites the organization, assigns random IDs to legacy artwork, and deletes files in `staging/`.
- It writes only into a new data directory and never writes the original. The new host needs its own directory anyway, because `node.lock` admits one process.
- It assigns no random IDs. Two runs on the same snapshot produce the same content, so a rerun is safe and the rehearsal can be compared with the real run.
- It supports a library at schema generation 4 only, and refuses 5 and 6 with a message that names the generation, because the owner's library is at 4 and no real library reached 5 or 6.
- Audio files in the new directory are hard links to the originals, so they take no extra space. A hard link needs both directories in one dataset and inside one mount, so the migration runs on the NAS outside the container, or in a container that mounts the common parent of both directories. Neither host writes an object file in place. `platform_fs::persist_replace` writes a temporary file and renames it over the destination, so a link in the other directory keeps the old bytes. Without hard links, the migration copies the audio in full, which the free space allows.

### Steps and their checks

1. **Snapshot.** The migration copies `node.sqlite` with SQLite's online backup while no import or upload runs, or while the old `serve` is stopped. The check is that `PRAGMA integrity_check` returns `ok`, `user_version` returns 4, and every table has the same row count in the copy and the original.
2. **Inventory.** On the snapshot, the migration reports the row count and size of every table, cluster tables included. It also reports the distinct audio hashes, the tracks added per month by `addedAt`, the albums, choices and track aliases, the artwork assets, and the playlist records and their heads. The first inventory is checked against the inspection figures recorded in ASO-161. Each later inventory is checked against the previous one, and every difference must be explained by changes on the old path in between. A surprise stops the plan for review.
3. **Audio.** For every track row, the file `objects/<sha256>.<suffix>` must exist with the recorded size. Then every file is hashed once and the time is recorded. The report lists missing files, wrong sizes, wrong hashes, and files that no track names. Unnamed files stay in place.
4. **Transform.** The migration writes the new store into a new directory on the same volume:
	- It copies the library ID, every track row, the organization row and every artwork asset byte for byte.
	- It checks that each playlist record's ID is the SHA-256 of its payload and that its document passes `Document::validate`. A record is a head when no other record names it as a parent. Each head becomes a plain row. Signatures are not verified, because they proved authorship between hosts and this file is the owner's own. If a playlist has more than one head, the migration stops and names it.
	- Each playlist item keeps its track ID and hash. If the ID does not resolve through the track aliases to a track with that hash, the report lists the item as unavailable and the item stays unchanged.
	- The switch number is 1. The revision is 1 in a rehearsal. When the run replaces a store that devices have read, as a rebuild of the trial host or the real run does, the revision is one more than that store's, so a device never sees two catalogs under one change marker.
	- Cluster tables, signed history, grants, cursors and the `peer` identity directory are not carried, and the report counts them.

	The checks are a hash per copied table that matches the source, every track ID and alias resolving to one track, and every track's audio file present.
5. **Repeat.** The migration runs steps 1 to 4 again on a fresh snapshot, after the first snapshot is deleted. Both runs are rehearsals at revision 1, so the two outputs match, or the report explains every difference by a change made on the old path between the snapshots, such as an added track or an edited playlist. Two runs on the same snapshot must match exactly.
6. **Report.** The migration writes a JSON file for tools and a one-page summary for the owner. The summary gives counts in and out, everything not carried and why, the time of each step, and the free disk space before and after. The report stays out of the repository, because it holds the owner's library metadata.

Steps 1 to 6 are the rehearsal. They run on a snapshot in a disposable directory and repeat until two runs agree, or differ only by changes on the old path that the report explains. The real run at the cutover is the same command on a final snapshot. It hashes only the files that the rehearsal did not verify and checks the size of all of them. A rebuild of the trial host and the real run also copy the host ID from the trial host's directory, so the host's identity survives. Devices keep working because the host address does not change.

### How to go back

The original directory is never written. Going back means stopping the new host and starting the old `serve` on the original directory. The devices still speak the legacy connection until removal step 4 ships. A change made on the new path after the cutover is not in the old store. Going back loses every such change: imports, and edits of metadata and playlists on the primary. `addedAt` lists the tracks imported after the cutover, so the owner can import them again on the old path, but they get new track IDs, and playlists that referred to them do not follow. Until ASO-161 defines how these changes are kept, going back is not lossless.

Every device can go back until the first device gets removal step 4. While that step rolls out, only devices that do not have it yet can go back, because the others no longer speak the legacy connection. Until removal step 5, the old `serve` keeps running the image it runs today. Nothing built from main is deployed to it, because main loses v5 in removal step 3 and gains the new store. That image and the original directory are kept until removal step 5.

### Steps that need the owner's go-ahead

1. Take a snapshot of the live database and run the rehearsal on the NAS. This reads the live directory and writes only a new one. A short stop of the old `serve` for the snapshot is part of this go-ahead.
2. Install Tailscale on the NAS and publish the trial host, the new host serving a rehearsal directory, with `tailscale serve`. The machine name then appears in public certificate transparency logs, as [Tailscale setup](tailscale-setup.md) explains.
3. The cutover. Stop the old `serve`, run the final migration, and start the new host as the primary.
4. Retire the cluster test deployment and the relay on the NAS.
5. After the soak, retire the old `serve` container, shut down the rendezvous Worker, and later delete the original data directory.

## Cut over the host first, then the Mac, then the iPhone

### The Apple apps change behind one seam

ASO-165 replaces the transport in four pull requests:

1. Split the seam. `Library` reaches the catalog, audio and artwork through one protocol, and `LocalTransfer` implements it. Behavior does not change, and the macOS tests pass unchanged.
2. Add a host transport behind the seam, with its own tables in the device database, apart from the cluster tables. A device connected to a host by its address uses it, and any other device keeps the legacy connection. Its tests run against a host process on loopback and need neither mDNS nor a relay.
3. Let offline saves and the playback cache find files by track ID and hash on both transports. A save made on the old path then plays on the new path without a new download, which keeps the promise of [ADR 0005](adr/0005-distinguish-playback-cache-from-offline-saves.md).
4. Remove the legacy implementations, as removal step 4 below. Two transports exist side by side only while the new path is tried.

### The order

1. **Trial host.** After the first two go-aheads, the trial host runs on the NAS. It accepts no change except the one test import of the cutover test, and it is rebuilt from a fresh snapshot, not updated. The old `serve` keeps running as the primary, and the devices paired with it keep using it. ASO-162 (a host in the macOS app) is not on this path, because the owner's primary is the NAS.
2. **Mac.** The macOS app connects to the trial host by its host address, browses, downloads and plays. The Mac comes first because it needs no TestFlight and compiles the same `Library` code as the iPhone.
3. **iPhone.** The iPhone app, installed through TestFlight, connects to the trial host over Tailscale. It saves albums (ASO-166), in the background or with Syncstr open as Q2 of the device spike decides, and plays offline saves made on the old path.
4. **Cutover.** After the third go-ahead, the owner stops changing the library on the old path. The old `serve` stops, the final migration runs, and the new host starts as the primary at the trial host's host address. Devices connected to the trial host keep working, because the address stays.
5. **Soak.** The owner uses only the new path for 14 days.

### The test that says the library runs on the new path

The owner's library runs on the new path when all of these hold:

1. The old `serve` is stopped, and the NAS runs only the new host.
2. The iPhone, with Wi-Fi off and Tailscale on, shows the track, album and playlist counts of the final migration report.
3. The iPhone downloads an album it never had as an offline save, then plays it with networking off. If Q2 of the device spike showed that background downloads work over the tunnel, the save runs while the screen is locked. Otherwise it runs with Syncstr open and resumes after the listener returns, as [the fallback](onboarding-and-connection-states.md#continue-in-the-background) describes.
4. An offline save made on the old path before the cutover plays with networking off, and the host log shows no download of its hash.
5. The macOS app, as a device, plays a track that it had not downloaded.
6. Before the cutover, one track imported on the trial host appears on the connected devices after a refresh and plays, because an import on the primary is the only way to add music. This is the one change the trial host accepts. The next rebuild or the final migration drops it, because both start from a snapshot of the old store.
7. A tailnet device that the policy does not allow, such as a work computer, cannot connect to the host address, and the host's loopback listener does not answer on the NAS's LAN address.
8. For 14 days the owner does not go back and sees no playback failure that the old path did not have. The playback diagnostics and the host log are the evidence.

Removal on the owner's daily path starts only after this test passes.

## Remove what the owner never ran first, and the daily path last

ADR 0008 keeps the daily path until the owner's library runs on its replacement. Earlier removal requires both an unused path in that library and no dependency from an active client. This plan applies the decision in three parts:

- The v5 host-to-host code, activation journal and connectivity probe are candidates for early removal. Each can go once confirmed unused by both the owner's library and all active clients.
- Everything the owner uses daily is removed only after the owner's library runs on the new path.
- Removing the Windows, Android and gpui apps is a recommendation that needs the owner's separate decision in ASO-170. Merging this plan does not decide it.

The Apple apps reach v5 only through `ClusterSession.connect` in `apps/macos/ClusterTransport.swift`, and only on a device with a cluster registration. It opens `syncstr/cluster/5` first and falls back to `syncstr/cluster/3` when the device holds no v5 snapshot. A device without a cluster registration uses the legacy connection (`legacyPlaybackFile` in `apps/macos/LocalTransfer.swift`). No real library reached v5, and nothing built from main is deployed to the owner's NAS before the cutover. Removing the v5 host code first therefore breaks no shipped flow.

Removing the early code shrinks what the store and API work must read, build and test. Each step is one pull request that leaves the build and the tests green. It deletes the documents that describe only the code it removes, and fixes the links to them.

### Steps 1 to 3 may come before the cutover

Step 2 needs nothing first. Step 1 waits for the owner's decision in ASO-170. Step 3 needs step 1, because the gpui app calls `catalog_client`, so it also waits for that decision. If ASO-170 keeps the gpui app, the v5 code stays until that app no longer calls `catalog_client`.

1. **The Windows, Android and gpui apps, if ASO-170 removes them.** This step removes `apps/windows`, `apps/android`, `apps/desktop`, `experiments/client-bindings`, `tools/windows-ime-probe`, `.github/workflows/desktop.yml` and `.agents/skills/syncstr-android-dev`. That is 98 files and 21,771 lines, of which 15,185 are the vendored `gpui_windows`. The 31 screenshots in `docs/validation/evidence/windows-gpui` go, and so do eleven documents: `android-remote-development-plan.md`, `android-ui-development-handoff.md`, `cluster-android-m5.md`, `cluster-windows-m5.md`, `windows-android-playback-support.md`, `windows-android-review-repair-plan.md`, `shared-rust-client-design.md`, `native-client-merge-decisions.md`, and the validation records `windows-gpui.md`, `windows-shared-client.md` and `windows-android-review-repairs.md`. This step needs the owner's decision in ASO-170. The check is a green `verification.yml` and a README map that no longer names the removed paths.
2. **The connectivity probe.** This step removes `headless/connectivity-probe` (23 files, 2,007 lines, five ignored tests) and `docs/cluster-connectivity-m0.md`. It needs nothing first. The probe is its own crate with no CI job, so the check is an empty `git grep connectivity-probe` and a green `verification.yml`.
3. **v5 and the activation journal, in one pull request.** `shared_audio.rs` calls `activation_control::ensure_writable`, and the activation code uses `shared_audio::GUARDED`. Removing either alone would mean editing code that the next pull request deletes. This step removes 22 source files with 15,284 lines (`headless/src/activation_*`, `shared_audio*` and `catalog_client*`). It also removes 11 files with 9,425 lines of tests, examples, fixtures and notes:
	- `headless/tests/shared_audio.rs` and `headless/tests/catalog_*`, which hold the ignored subprocess test.
	- `headless/examples/shared_audio_*`, `headless/fixtures/create_shared_audio.rs` and `headless/fixtures/activation-control`.
	- `headless/activation-inventory.md` and `headless/backup-manifest.md`.
	- `apps/ios/UITests/SharedAudioFlowTests.swift`.

	In `apps/macos/Tests/SharedAudioTests.swift` it removes only the tests that start a v5 host with `shared_audio_fixture`. The rest of that file stays until step 4, because `ClusterMetadataTests.swift` and `OfflineSaveTests.swift` use its `Fixture`.

	Four files that stay need edits. The v5 subcommands leave `headless/src/main.rs`, and the v5 calls leave `headless/src/client.rs`. The v5 and activation protocols leave the iroh endpoint in `headless/src/peer.rs`. The `Origin` type moves from `shared_audio.rs` into `headless/src/playlists.rs`, because the signed playlist body that the old `serve` and the migration decode still names it. It removes the v5 fixture setup from `apps/ios/scripts/verify_simulator.py` and its test, and the `shared_audio_fixture` examples from `verification.yml` and `weekly-simulator.yml`. Eleven documents go: the five `v5-*.md`, `shared-audio-v5-handoff.md`, `shared-audio-server-implementation.md`, `shared-rust-catalog.md`, `shared-rust-audio.md`, `validation/v5-startup-guard.md` and `validation/shared-audio-apple.md`. This step needs step 1, as stated above. It also needs the activation issues cancelled under ASO-171. The check is a green `verification.yml` and a green manual run of `weekly-simulator.yml`. `PeerTransferTests` must still pass, because they run the legacy protocol against the `syncstr-headless` binary. The Swift code that receives v5 catalogs stays until step 4, with no host left to serve it except the test deployment.

The pull request for step 3 also adds a CI job that runs `cargo test --locked --tests` without features. The new host builds without `p2p`, and CI never builds that configuration today. After step 3 merges, the duration of each `verification.yml` job on main is recorded against the five-minute budget.

### Steps 4 to 7 come after the soak

4. **The old Apple transports and IrohLib.** This step removes the twelve transport files (3,499 lines). It also removes the legacy and cluster parts of `LocalTransfer.swift`, the cluster tables in `CatalogDatabase.swift`, and the cluster and legacy screens in `SettingsView.swift` and `apps/ios/Sources/PhoneRoot.swift`. Nine test files with 3,454 lines go: the `Cluster*Tests.swift` files, `PeerTransferTests.swift`, `SharedTrackResolutionTests.swift` and the rest of `SharedAudioTests.swift`. The v5 test in `OfflineSaveTests.swift` goes with them. IrohLib leaves the three targets in `apps/ios/project.yml` and `Package.resolved`, with both licence copies, `apps/macos/scripts/collect_iroh_notices.py`, and the IrohLib cache step in `verification.yml`. `NSBonjourServices` goes from both apps. `NSLocalNetworkUsageDescription` goes from the iOS app if the [device spike](validation/tailscale-device-spike.md) shows that a host reached over Tailscale needs no local network permission. The macOS app keeps it until the same check passes on a Mac. `cluster-signed.json` and `cluster-state.json` leave the Apple test resources, and `local-music-transfer.md` and `cluster-apple-m3.md` go. This step is the fourth pull request of ASO-165, and it needs the soak passed and the first three merged. The check is a green macOS job and weekly Simulator run, a launch with `sh apps/macos/run.sh` that plays from the host, a TestFlight build that plays an offline save in airplane mode, and an empty `git grep IrohLib apps`.
5. **The legacy host, the cluster code and the `p2p` feature.** This step removes 13 source files with 4,667 lines: `headless/src/cluster*.rs`, `peer.rs`, `playlist_sync.rs`, `rendezvous.rs`, `relay.rs` and `enrollment.rs`. It removes 10 test files with 2,711 lines, including the two ignored `lan_process` tests. It removes 11 other files with 535 lines: the `migration_batch` example, `headless/Dockerfile.migration-batch`, `headless/Dockerfile.catalog-fix`, `headless/remote-access`, `.github/workflows/lan-verification.yml` and the two cluster fixtures. It also removes the schema-4 open path of `store.rs`, the signed parts of `playlists.rs`, and the matching subcommands of `main.rs`. The `p2p` feature leaves `headless/Cargo.toml` with `iroh`, `iroh-relay`, `qrcode`, `mdns-sd` and `if-addrs`. `lofty` becomes an ordinary dependency if the import on the primary reads tags, and goes otherwise. `--features p2p` leaves both workflows and `headless/scripts/collect_licenses.py`. The documents `p2p-music-transfer.md`, `cluster-lan-sync-m2.md`, `cluster-persistence-m1.md`, `cluster-remote-m4.md`, `validation/lan-discovery.md` and `validation/signed-addition-time.md` go.

	`headless/src/membership.rs` stays. It holds album membership evidence (`ImportContext`) for the organization, not cluster membership.

	This step needs step 4 on every device the owner uses, the old `serve` container retired with the owner's go-ahead, and the real migration done. It also needs an import on the primary that replaces the `migration_batch` path of `nas_import.py`, so that the owner can still add music. The check is a green `cargo test --locked --tests` and clippy without features, a Docker image that builds, and `cargo tree -i iroh` failing because no package depends on it.
6. **The rendezvous Worker.** This step removes `rendezvous` (8 files, 261 lines) and `docs/peer-rendezvous.md`, and the owner shuts the Worker down. It needs step 5 deployed and 7 days with no announcement reaching the Worker. The check is that no code, workflow or README entry names `rendezvous`.
7. **The map and the CI budget.** This step rewrites the code and documentation map in `README.md` to list only what exists, and records each workflow's duration against the five-minute budget in the pull request. It needs steps 1 to 6. The check is that every relative link in `README.md` and `docs/` resolves.

### Documents that stay

A document that an ADR links to stays, marked as superseded. These are `cluster-model-design.md`, `cluster-implementation-plan.md`, `cluster-ui-review.md`, `shared-audio-server-design.md`, `source-track-identity-windows-handoff.md` and the compilation documents. ADR 0002 stays with the note that ADR 0008 adds. Validation records already labelled historical, such as `validation/sync-core-report.md`, stay. Every other document that describes only removed code goes in the step that removes that code. The replacement table of ADR 0008 is an exception to the first rule: it links to replaced documents only to name them, and the step that removes one of them changes its link in ADR 0008 to the file at `d0b4db5`.

## Devices read and download in the first release

This plan recommends the proposal in ADR 0008. In the first release a device reads and downloads, and the library changes only on the primary. Music still enters the library through an import on the primary, ported from `tools/music-migration/nas_import.py`.

The cutover takes away three edits that the owner's devices have today on the legacy connection. They return in this order:

1. **Album organization, including hiding albums (`organize`).** The organization document and its validation exist on both sides, in `organization.rs` and `apps/macos/AlbumOrganization.swift`. With one primary, a request carries the change marker the device saw, and the primary refuses a stale one. The README describes hidden albums for every app, so their loss is the most visible.
2. **Adding music from the macOS app (`put`).** The owner's primary is a NAS without a screen, and the import on it needs a terminal. The upload calls the same import code as the primary.
3. **Playlists.** Import from Music XML comes first, then ordinary editing. ASO-5, ASO-6 and ASO-7 measure and improve the XML import, so they wait for this edit.
4. **Track metadata.** The owner never had it on the legacy connection, so its absence takes nothing away.

Adding music from the iPhone comes after these, and only if the owner asks for it.

The host cannot tell devices apart, so a write route would let every device that the tailnet policy allows change the library. Before the first edit returns, ASO-168 decides whether that is acceptable or whether writes need a check of their own.

When the primary cannot be reached, a device refuses the edit and says why. It queues nothing. A queue needs a rule for an edit whose base changed on the primary in the meantime, and a screen for that case, which is a small copy of the machinery that ADR 0008 removes. A queue can return for playlists alone, under a rewritten ASO-42, if refusal proves to be a real problem.

This replaces ASO-98, ASO-103 and ASO-105, which retry an edit at another host, and they are cancelled. ASO-42 is rewritten for one primary and carried into the playlist issue. ASO-168 creates one issue per edit above.

## Pause the Windows, Android and gpui apps

This plan recommends pausing all three until the Mac and iPhone path passes the cutover test, and removing them from main in removal step 1. The owner decides this in ASO-170, apart from merging this plan.

- **Win32 (`apps/windows`).** It speaks cluster v3 and finds hosts by LAN discovery. It cannot reach the owner's library today, because the owner's NAS runs the legacy `serve`, not the cluster host. An app of the host API shares little with it. It returns as a new app of the host API if the owner wants to listen on Windows.
- **Android (`apps/android`).** The same reasons apply. It returns as a new app of the host API, on Android's own HTTP and media stack, if the owner asks for it.
- **gpui (`apps/desktop`).** Its backend speaks v5 through `catalog_client`, which removal step 3 deletes. This plan does not reverse the choice of gpui for a Windows app. It pauses the app. When Windows playback is wanted, `ui.rs`, `text_input.rs`, `windows_player.rs` and the vendored `gpui_windows` come back from the history at `d0b4db5` with a new backend that calls the host API. If the owner wants Windows before Android, this app returns first.
- **The shared Rust core (ASO-48, ASO-68).** It is no longer wanted. An app of the host API sends HTTPS requests, decodes JSON, downloads files and checks SHA-256 hashes, which every platform does natively, while a shared core adds an FFI binding and a native build per platform. The apps share the API contract instead, which ASO-86, ASO-87 and ASO-89 check in CI. A shared core returns only if two or more apps outside Apple duplicate hard offline logic, such as save accounting, and then only for that logic.

## Handle the existing issues in four batches

ASO-171 lists the issues. They are handled in batches, when each decision is made:

1. **When ADR 0008 merges.** The issues for activation and recovery, retries across hosts, enrollment and host roles, remote access and identity across hosts, and the contracts of the old protocols are cancelled with a link to ASO-157. Open questions that still matter move to their new owners. Host roles move to ASO-172 and ASO-173, and offline playlist editing moves to the playlist issue of ASO-168. ASO-86, ASO-87 and ASO-89 are rewritten for the contract of the host API (ASO-160).
2. **Also when ADR 0008 merges, the v5 app designs.** ASO-46 is cancelled, because one writer leaves no partial history to show. ASO-47 is rewritten as artwork in the host API. ASO-41 is rewritten as source correspondence on import and deferred, as the store recommendation describes.
3. **When ASO-170 is decided.** ASO-10, ASO-11, ASO-48 and ASO-68 are cancelled. ASO-45, ASO-51, ASO-56, ASO-58 and ASO-72 to ASO-79 stay in the backlog with a comment that ASO-170 paused them.
4. **When ASO-168 creates the playlist issue.** ASO-5, ASO-6 and ASO-7 stay valid and are marked as blocked by it. ASO-99 is not affected.

## Risks and how each is checked

- **Disk space.** A rehearsal needs the size of the database for the snapshot and at most that again for the new database, which holds a subset of the old rows. Two rehearsals hold two outputs and, if the first snapshot is kept, two snapshots, which is up to four times the database. Hard-linked audio adds nothing. Without hard links, each directory adds the size of the audio. The volume has several terabytes free, so either fits. The report records the free space before and after.
- **The size of the database.** The signed cluster changes take about three quarters of it. The migration does not carry them, so the new database is estimated at about a quarter of the old one. Inventory step 2 measures every table again on the snapshot. The catalog of the [host API](host-api-design.md) leaves artwork out, so the size matters for the copies on disk and for the time of a snapshot, not for devices.
- **Time of a full verification.** Hashing at 30 to 100 MB/s takes roughly 10 to 35 seconds per gigabyte of audio. This is an estimate. Rehearsal step 3 measures it, and the cutover hashes only the files added since the rehearsal.
- **A torn snapshot.** A plain file copy of a database in use can be inconsistent. The online backup and `PRAGMA integrity_check` catch that, and a short stop of the old `serve` avoids it.
- **A device enrolled in the cluster test deployment.** `LocalTransfer.playbackFile` prefers a cluster registration over the legacy connection, so such a device plays from the test deployment. The owner checks each device's settings for a cluster registration before the fourth go-ahead.
- **Playlist records with more than one head.** The migration stops and names them, and the owner resolves them on the old path before the cutover.
- **The owner cannot add music.** Removal step 5 deletes `cluster_replica.rs`, which `nas_import.py` uses through `migration_batch`. Step 5 therefore requires a working import on the primary.

## Phases

| Phase | Issues | Done when |
| --- | --- | --- |
| Decide and measure | ASO-158, ASO-159 | ADR 0008 is merged, and the device spike has recorded its results |
| Remove what the owner never ran | ASO-169 step 2, then steps 1 and 3 after the owner decides ASO-170, and ASO-171 batches 1 to 3 | The steps that may go are merged, CI is green, and the job durations are recorded |
| Store and migration | ASO-161 | The store and the migration command are merged with tests on fixtures, and two rehearsals on a snapshot of the owner's library agree |
| Host API, connecting by address and Tailscale | ASO-160, ASO-164, ASO-163 | The trial host serves the rehearsal directory at a host address |
| Apple apps | ASO-165, ASO-166, ASO-167 | The Mac and then the iPhone play from the trial host, and an old offline save plays without a download |
| A Mac as the host | ASO-162, ASO-163 | Apart from the owner's NAS, a Mac with a folder library serves it over Tailscale, and an iPhone allowed by the tailnet policy connects, saves an album and plays it with networking off |
| Cutover and soak | ASO-161, ASO-169 | Every point of the cutover test holds |
| Remove the daily path | ASO-169 steps 4 to 7 | Step 7's link check passes and the CI durations are recorded |
| Mirrors and the primary switch | ASO-172, ASO-173 | As [mirrors and the primary switch](mirrors-and-primary-switch.md) defines |
| Edits from devices | ASO-168 and one issue per edit | Each edit's issue is done, in the order above |
| The Windows, Android and gpui apps | ASO-170 | The owner asks for one, and it plays from the host |

## Open questions

- Which of the three lost edits the owner uses every week, and whether the cutover waits for them. Inventory step 2 shows how often music arrived. Owned by ASO-168.
- Whether the original and the new data directory are in one dataset, so that hard links work. If they are not, the migration copies the audio in full. Owned by ASO-161.
- Whether any of the owner's devices is enrolled in the cluster test deployment. Owned by ASO-169.
- How long the soak lasts. This plan proposes 14 days. Owned by ASO-169.
- Whether the Windows, Android and gpui apps are removed, which also decides when removal step 3 can run. Owned by ASO-170.
- Whether the import on the primary keeps the Windows-to-NAS flow of `tools/music-migration`, and whether it reads tags itself. Owned by ASO-161.

## Regenerate the counts

The counts above are true at `d0b4db5`, and `git diff --stat d0b4db5 -- headless apps rendezvous tools experiments .github` is empty while they hold. Run these lines from the repository root in zsh or bash:

```sh
x=(':(exclude)*.lock' ':(exclude)*package-lock.json' ':(exclude)*Package.resolved' ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jar' ':(exclude)*IrohLib.txt')
count() { echo "$(git ls-files -- "$@" "${x[@]}" | wc -l) files, $(git ls-files -z -- "$@" "${x[@]}" | xargs -0 cat | wc -l) lines"; }
count headless/src
count 'headless/src/activation_*'
count 'headless/src/shared_audio*'
count 'headless/src/catalog_client*'
count 'headless/src/activation_*' 'headless/src/shared_audio*' 'headless/src/catalog_client*'
count headless/tests/shared_audio.rs 'headless/tests/catalog_*' 'headless/examples/shared_audio_*' headless/fixtures/create_shared_audio.rs headless/fixtures/activation-control headless/activation-inventory.md headless/backup-manifest.md apps/ios/UITests/SharedAudioFlowTests.swift
count apps/windows apps/android apps/desktop experiments/client-bindings tools/windows-ime-probe .github/workflows/desktop.yml .agents/skills/syncstr-android-dev
count apps/desktop/vendor
count headless/connectivity-probe
count 'apps/macos/Cluster*.swift' apps/macos/SharedAudio.swift apps/macos/SharedTrackResolution.swift 'apps/macos/Peer*.swift' apps/macos/LocalSetup.swift
count apps/macos/LocalTransfer.swift
count 'apps/macos/Tests/Cluster*Tests.swift' apps/macos/Tests/PeerTransferTests.swift apps/macos/Tests/SharedTrackResolutionTests.swift apps/macos/Tests/SharedAudioTests.swift
count 'headless/src/cluster*.rs' headless/src/peer.rs headless/src/playlist_sync.rs headless/src/rendezvous.rs headless/src/relay.rs headless/src/enrollment.rs
count 'headless/tests/cluster*.rs' headless/tests/enrollment.rs headless/tests/lan_process.rs 'headless/tests/peer*.rs'
count headless/examples/migration_batch.rs 'headless/Dockerfile.*' headless/remote-access .github/workflows/lan-verification.yml 'headless/fixtures/cluster-*.json'
count rendezvous
git ls-files -z '*IrohLib.txt' | xargs -0 wc -l
git ls-files docs/validation/evidence/windows-gpui | wc -l
awk '/^  Syncstr:/{t=1} /^  SyncstrUITests:/{t=0} t && /path: \.\.\/macos\/.*\.swift/' apps/ios/project.yml | wc -l
git grep -c '#\[ignore' -- '*.rs'
```

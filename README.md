# syncstr

A native macOS and iPhone player for a music library you manage yourself.

## Current implementation

Both Apple apps can join an existing cluster library using an invitation, or import music for local playback without enrollment. macOS also supports a selected music folder. The retained catalog stays visible offline, and playback and explicit offline saves automatically select an authorized source. Track and album saves retain pending requests across restarts, report partial results, and resume under the communication policy while the app is active.

Settings contains enrollment, hosts, connection diagnostics, conflicts, communication policy, storage limits, and legacy connections. The older Mac-to-iPhone pairing flow remains available under **Legacy device transfer** in Settings; see [the legacy transfer guide](docs/local-music-transfer.md) for its protocol and verification limits.

An opt-in headless P2P node also supports catalog browsing, original-file uploads, and verified downloads from both native apps. See [P2P setup](docs/p2p-music-transfer.md); existing deployments must explicitly enable this transport.

- **macOS:** album, artist, and track browsing; search; continuous playback; seeking; and folder selection.
- **iPhone:** library browsing, search, local import, playback, track/album offline saves, background audio, and lock-screen controls. The saved library opens without a connection.

Start with the [macOS guide](apps/macos/README.md) or [iPhone guide](apps/ios/README.md) for build and verification steps. [Issue #11](https://github.com/asonas/syncstr/issues/11) records implementation milestones; the [Syncstr project in Linear](docs/agents/issue-tracker.md) tracks follow-up work. Record local builds, distribution, and device verification separately.

## Hidden albums

Hide an album from its menu or detail page on macOS and iPhone, from its album
group on Android, or with **Hide / Unhide album** after selecting a track on
Windows. **Hidden albums** lists these albums and lets you restore them. Hidden
albums are excluded from normal album, artist, and track browsing and search;
original audio and the current playback queue are retained.

Visibility is shared by members of the same cluster. Local changes survive
restarts while awaiting synchronization. Apple apps retry while active; Android
tries immediately, and **Refresh library** retries pending changes on Android
and Windows. Update the headless hosts and all clients before using this feature:
older versions do not recognize the new visibility records. Object conflicts
continue to use the existing conflict-resolution flow.

## Code and documentation map

| Task | Start here |
|---|---|
| macOS UI and launch | [Syncstr.swift](apps/macos/Syncstr.swift), [macOS guide](apps/macos/README.md) |
| Local catalog, pairing, and transfer | [LocalCatalog.swift](apps/macos/LocalCatalog.swift), [CatalogDatabase.swift](apps/macos/CatalogDatabase.swift), [LocalTransfer.swift](apps/macos/LocalTransfer.swift), [LocalSetup.swift](apps/macos/LocalSetup.swift), [protocol and setup](docs/local-music-transfer.md) |
| Compilation album organization | [Retention policy](docs/compilation-data-design.md), [revised membership and artwork policy](docs/compilation-policy-review.md), [revision implementation plan](docs/compilation-revision-implementation-plan.md), [earlier implementation](docs/compilation-implementation-spec.md), [verification](docs/validation/compilation-albums.md), [glossary](GLOSSARY.md), [metadata preservation decision](docs/adr/0001-preserve-imported-metadata-and-user-choices.md) |
| Shared playback and pairing credentials | [Library.swift](apps/macos/Library.swift), [Track.swift](apps/macos/Track.swift), [CredentialStore.swift](apps/macos/CredentialStore.swift). The iOS target compiles these same files |
| Player behavior and retention | [Player specification](docs/player-interaction-spec.md), [cluster interaction specification](docs/cluster-ui-review.md), [verification](docs/validation/player-interactions.md), [playback cache](apps/macos/PlaybackCache.swift) |
| Playback failure diagnostics | [Specification](docs/playback-diagnostics-spec.md), [recorder and copy UI](apps/macos/PlaybackDiagnostics.swift), [validation and observation limits](docs/validation/playback-diagnostics.md) |
| Connection and playback responsiveness | [Execution and cancellation design](docs/playback-responsiveness.md), [regression and app verification](docs/validation/playback-responsiveness.md) |
| Offline-save lifecycle and Apple library entry | [Shared save queue and controls](apps/macos/OfflineSaves.swift), [cluster interaction validation](docs/validation/cluster-library-ui.md) |
| iPhone UI and device features | [Sources](apps/ios/Sources/), [iPhone guide](apps/ios/README.md) |
| Folder settings | [SettingsView.swift](apps/macos/SettingsView.swift) |
| Headless NAS node and CLI | [Headless guide](headless/README.md), [HTTPS API](headless/src/api.rs), [node catalog](headless/src/store.rs) |
| Music/iTunes owned-library migration | [Windows handoff](docs/music-library-migration-windows-handoff.md), [Windows-to-NAS MVP plan](docs/music-library-migration-plan.md), [source metadata precedence](docs/adr/0004-preserve-source-library-metadata-during-migration.md); implementation pending |
| Shared playlists and playlist XML migration | [Implementation plan](docs/playlist-implementation-plan.md), [updating imported playlists and verification](docs/playlist-reconciliation.md); full editing and smart-rule evaluation remain planned |
| Source track identity and Windows evidence collection | [Shared-audio server design](docs/shared-audio-server-design.md), [implementation and verification](docs/shared-audio-server-implementation.md), [Inventory and correspondence commands](tools/playlist-audit/README.md#source-registration-inventory), [report format](tools/playlist-audit/inventory-format.md), [Windows validation](docs/validation/source-track-identity-windows.md), [Windows implementation handoff](docs/source-track-identity-windows-handoff.md), [identity boundary](docs/adr/0006-preserve-source-track-identity-independently-of-audio.md) |
| Cluster enrollment and LAN replication | [Implementation plan](docs/cluster-implementation-plan.md), [M2 protocol and CLI](docs/cluster-lan-sync-m2.md), [membership](headless/src/enrollment.rs), [reconciliation](headless/src/cluster_sync.rs) |
| Signed cluster-record compatibility | [Addition-time contract](docs/validation/signed-addition-time.md), [shared signed fixture](headless/fixtures/cluster-signed.json) |
| Optional user-operated remote access | [M4 implementation and limits](docs/cluster-remote-m4.md), [relay deployment package](headless/remote-access/README.md), [relay admission and health](headless/src/relay.rs) |
| Android LAN playback client | [Android build and setup](apps/android/README.md), [M5 verification](docs/cluster-android-m5.md), [UI-development handoff](docs/android-ui-development-handoff.md), [Rust playback boundary](headless/src/cluster_client.rs) |
| Remote Android development | [Agreed setup plan and acceptance checklist](docs/android-remote-development-plan.md), [syncstr-android-dev skill](.agents/skills/syncstr-android-dev/SKILL.md); Linux build, local device loop and remote skill discovery verified |
| Windows implementation preparation | [M5 native development handoff](docs/cluster-windows-m5.md); native Windows acceptance is pending |
| Windows playback client | [Windows build and operation guide](apps/windows/README.md) |
| App-to-node P2P transfer | [P2P setup and protocol](docs/p2p-music-transfer.md), [Rust transport](headless/src/peer.rs), [native transport](apps/macos/PeerTransfer.swift), [setup controls](apps/macos/PeerSetup.swift) |
| Signed endpoint discovery | [Rendezvous setup and protocol](docs/peer-rendezvous.md), [Cloudflare directory](rendezvous/src/index.ts), [headless publisher](headless/src/rendezvous.rs) |
| Device identity and direct/relay connectivity experiment | [Connectivity probe](headless/connectivity-probe/README.md). Isolated from deployed services; independent-network verification is pending |
| Xcode Cloud and distribution for both platforms | [project.yml](apps/ios/project.yml), [ci_post_clone.sh](apps/ios/ci_scripts/ci_post_clone.sh). Generate the Xcode project from YAML |
| Automated regression checks and reproducible Simulators | [Verification workflow](.github/workflows/verification.yml), [Simulator runner and results](apps/ios/README.md#verification), [headless verification](headless/README.md#verification) |
| UI and icon design | [DESIGN.md](DESIGN.md), which distinguishes UI colors from icon colors; [current, prototype, reference, and archive index](docs/design-status.md) |
| Earlier UI prototype | [Apple MVP operation model](https://github.com/asonas/syncstr/tree/be9fd4d9f06fca3676ec0426dbfe4b6606aae0ea/prototypes/apple-mvp-operation-model), [decision #5](https://github.com/asonas/syncstr/issues/5). The prototype is preserved on a separate branch, outside main |
| Interpreting design decisions | [Domain docs](docs/agents/domain.md) |

### Changes to app interactions

Before changing an app interaction, inspect its macOS and iOS entry points and any shared implementation using the map above. When the request does not specify a platform, fix the same defect on both platforms where that interaction is supported. For a platform-specific request, check the other platform for effects of changes to shared code and keep edits within the requested scope.

Record the expected behavior before, during, and after the interaction, including its return action where applicable, such as playback, pause, and resume. Validate the affected behavior on each platform. Report each platform as changed, unchanged with a reason, or unverified, and distinguish builds and automated tests from screen interaction and physical-device checks.

## Long-term design and deferred work

Playback-state synchronization, passkey authentication, Music XML migration, and the Windows client belong to the long-term design. Android has an initial LAN playback implementation; remote access and distribution remain pending. These are not prerequisites for running or changing the local music player.

The service specification describes the current local music product. The plans and technical investigations preserve earlier work; their server requirements are superseded by the local transfer design. Use the app guides and source code for implemented behavior, and issues for work status.

- [Service specification](docs/design-spec.md), [service overview](docs/service-overview.md), [design decisions](docs/decisions.md)
- [Design interview](docs/grill-me.md), [long-term plans](docs/plans/README.md), [initial roadmap](docs/plans/2026-08-15-syncstr-implementation-plan.md)
- [Technical validation records](docs/validation/README.md)

## License

The license for the planned open-source release has not been selected. See each app's `Licenses/` directory for bundled third-party notices.

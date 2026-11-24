# syncstr

A native macOS and iPhone player for a music library you manage yourself.

## Current implementation

The macOS and iPhone apps read a host's `/api/v1` over HTTPS. Enter the host address on each device and confirm the library. The tailnet policy controls access. See [ADR 0008](docs/adr/0008-one-primary-host-over-a-private-network.md) for the decision and the [private network design](docs/private-network-architecture.md) for planned mirror support.

- **macOS:** Browse albums, artists, tracks, and host playlists. Search, play, seek, or save music for offline listening.
- **iPhone and iPad:** Browse and play the host library. Playback supports background audio and lock-screen controls.
- **Offline listening:** The last host catalog and saved audio remain available after disconnect. Pending saves survive restarts. Settings groups the library connection, saved music, and the playback cache; see [Settings](DESIGN.md#settings).
- **Earlier local libraries:** The apps no longer play a local folder or imported files. On the first launch after updating, they remove that catalog and any imported audio that no host entry or saved track shares. Installs that still kept only the older `catalog.json` keep their imported audio files.

Start with the [macOS guide](apps/macos/README.md) or [iPhone guide](apps/ios/README.md) for build and verification steps. [Issue #11](https://github.com/asonas/syncstr/issues/11) records implementation milestones; the [Syncstr project in Linear](docs/agents/issue-tracker.md) tracks follow-up work. Record local builds, distribution, and device verification separately.

## Hidden albums

Hide an album from its album group on Android, or with **Hide / Unhide album**
after selecting a track on Windows. **Hidden albums** lists these albums and lets
you restore them. Hidden albums are excluded from normal album, artist, and track
browsing and search; original audio and the current playback queue are retained.

Apple apps list the host's hidden albums read-only and cannot hide or restore them. On Android and Windows,
visibility is shared by members of the same cluster. Android
tries immediately, and **Refresh library** retries pending changes on Android
and Windows. Update the headless hosts and all clients before using this feature:
older versions do not recognize the new visibility records. Object conflicts
continue to use the existing conflict-resolution flow.

## Code and documentation map

| Task | Start here |
|---|---|
| One primary host over a private network | [Overview](docs/private-network-architecture.md), [ADR 0008](docs/adr/0008-one-primary-host-over-a-private-network.md), [host read API](docs/host-api-design.md), [mirrors and the primary switch](docs/mirrors-and-primary-switch.md), [onboarding and connection states](docs/onboarding-and-connection-states.md), [migration plan](docs/private-network-migration-plan.md), [Tailscale setup](docs/tailscale-setup.md), [TestFlight QA](docs/validation/tailscale-testflight-qa.md). The NAS serves the read API. Both Apple apps read it. |
| macOS UI and launch | [Syncstr.swift](apps/macos/Syncstr.swift), [macOS guide](apps/macos/README.md) |
| Local catalog and host connections | [LocalCatalog.swift](apps/macos/LocalCatalog.swift), [CatalogDatabase.swift](apps/macos/CatalogDatabase.swift), [HostAPIClient.swift](apps/macos/HostAPIClient.swift), [connection controls](apps/macos/HostConnectionView.swift) |
| Compilation album organization | [Retention policy](docs/compilation-data-design.md), [revised membership and artwork policy](docs/compilation-policy-review.md), [revision implementation plan](docs/compilation-revision-implementation-plan.md), [earlier implementation](docs/compilation-implementation-spec.md), [verification](docs/validation/compilation-albums.md), [glossary](GLOSSARY.md), [metadata preservation decision](docs/adr/0001-preserve-imported-metadata-and-user-choices.md) |
| Shared Apple playback | [Library.swift](apps/macos/Library.swift), [Track.swift](apps/macos/Track.swift), [host audio source](apps/macos/HostLibrarySource.swift) |
| Player behavior and retention | [Player specification](docs/player-interaction-spec.md), [verification](docs/validation/player-interactions.md), [playback cache](apps/macos/PlaybackCache.swift) |
| Playback failure diagnostics | [Specification](docs/playback-diagnostics-spec.md), [recorder and copy UI](apps/macos/PlaybackDiagnostics.swift), [validation and observation limits](docs/validation/playback-diagnostics.md) |
| Connection and playback responsiveness | [Execution and cancellation design](docs/playback-responsiveness.md), [regression and app verification](docs/validation/playback-responsiveness.md) |
| Offline-save lifecycle and Apple library entry | [Shared save queue and controls](apps/macos/OfflineSaves.swift), [host API tests](apps/macos/Tests/HostAPITests.swift) |
| iPhone UI and device features | [Sources](apps/ios/Sources/), [iPhone guide](apps/ios/README.md) |
| Settings | [Mac window](apps/macos/SettingsView.swift), [shared sections](apps/macos/SettingsSections.swift), [design](DESIGN.md#settings) |
| Headless NAS node and CLI | [Headless guide](headless/README.md), [HTTPS API](headless/src/api.rs), [node catalog](headless/src/store.rs) |
| Music/iTunes owned-library migration | [Existing inventory/prepare/import/resume CLI](tools/music-migration/README.md), [Windows-to-NAS plan](docs/music-library-migration-plan.md), [source metadata precedence](docs/adr/0004-preserve-source-library-metadata-during-migration.md); v5 correspondence integration is replaced by ADR 0008, and ASO-41 rewrites it for the new store |
| Read-only Windows playlist inspection | [Audit tool](tools/playlist-audit/README.md), [observations and verification gaps](docs/validation/windows-playlist-audit.md) |
| Apple host playlists | [Read-only playlist browser and save controls](apps/macos/PlaylistViews.swift) |
| Source track identity and Windows evidence collection | [Shared-audio server design](docs/shared-audio-server-design.md), [implementation and verification](docs/shared-audio-server-implementation.md), [Inventory and correspondence commands](tools/playlist-audit/README.md#source-registration-inventory), [report format](tools/playlist-audit/inventory-format.md), [Windows validation](docs/validation/source-track-identity-windows.md), [Windows implementation handoff](docs/source-track-identity-windows-handoff.md), [identity boundary](docs/adr/0006-preserve-source-track-identity-independently-of-audio.md) |
| Cluster enrollment and LAN replication | [Implementation plan](docs/cluster-implementation-plan.md), [M2 protocol and CLI](docs/cluster-lan-sync-m2.md), [membership](headless/src/enrollment.rs), [reconciliation](headless/src/cluster_sync.rs) |
| Signed cluster-record compatibility | [Addition-time contract](docs/validation/signed-addition-time.md), [shared signed fixture](headless/fixtures/cluster-signed.json) |
| Optional user-operated remote access | [M4 implementation and limits](docs/cluster-remote-m4.md), [relay deployment package](headless/remote-access/README.md), [relay admission and health](headless/src/relay.rs) |
| Android LAN playback client | [Android build and setup](apps/android/README.md), [M5 verification](docs/cluster-android-m5.md), [UI-development handoff](docs/android-ui-development-handoff.md), [Rust playback boundary](headless/src/cluster_client.rs) |
| Remote Android development | [Agreed setup plan and acceptance checklist](docs/android-remote-development-plan.md), [syncstr-android-dev skill](.agents/skills/syncstr-android-dev/SKILL.md); Linux build, local device loop and remote skill discovery verified |
| Windows implementation preparation | [M5 native development handoff](docs/cluster-windows-m5.md); native Windows acceptance is pending |
| Windows playback client | [Windows build and operation guide](apps/windows/README.md) |
| Shared client binding experiment | [Windows Rust, Swift and Kotlin execution probe](experiments/client-bindings/README.md); isolated ASO-68 results and remaining native-target checks |
| Windows and Android playback scope | [macOS reference inventory and accepted support contract](docs/windows-android-playback-support.md); full-parity follow-up scope remains in ASO-45 |
| Shared Rust client design | [Module ownership and migration design](docs/shared-rust-client-design.md), [accepted staged decisions](docs/native-client-merge-decisions.md); Apple adoption/measurements remain gated |
| Shared Rust catalog | [Read-only v5 client API and verification](docs/shared-rust-catalog.md), [implementation](headless/src/catalog_client.rs); native app integration follows separately |
| Shared Rust audio and offline saves | [Protected assets, durable jobs and Windows verification](docs/shared-rust-audio.md); native player/binding integration follows separately |
| Optional headless P2P transport | [P2P setup and protocol](docs/p2p-music-transfer.md), [Rust transport](headless/src/peer.rs) |
| Signed endpoint discovery | [Rendezvous setup and protocol](docs/peer-rendezvous.md), [Cloudflare directory](rendezvous/src/index.ts), [headless publisher](headless/src/rendezvous.rs) |
| Device identity and direct/relay connectivity experiment | [Connectivity probe](headless/connectivity-probe/README.md). Isolated from deployed services; independent-network verification is pending |
| Xcode Cloud and distribution for both platforms | [project.yml](apps/ios/project.yml), [ci_post_clone.sh](apps/ios/ci_scripts/ci_post_clone.sh). Generate the Xcode project from YAML |
| Automated regression checks and reproducible Simulators | [PR/push verification](.github/workflows/verification.yml), [weekly and manual Simulator workflow](.github/workflows/weekly-simulator.yml), [Simulator schedule, manual runs, and results](apps/ios/README.md#verification), [headless verification](headless/README.md#verification) |
| Advisory PR quality and intent review | [Jevlint setup, API key, and review limitations](docs/agents/jevlint.md) |
| API contract gate design | [OpenAPI contracts, breaking-change rules, and Jev decision rule](docs/api-contract-gate-design.md) |
| UI and icon design | [DESIGN.md](DESIGN.md), which distinguishes UI colors from icon colors; [current, prototype, reference, and archive index](docs/design-status.md) |
| Earlier UI prototype | [Apple MVP operation model](https://github.com/asonas/syncstr/tree/be9fd4d9f06fca3676ec0426dbfe4b6606aae0ea/prototypes/apple-mvp-operation-model), [decision #5](https://github.com/asonas/syncstr/issues/5). The prototype is preserved on a separate branch, outside main |
| Interpreting design decisions | [Domain docs](docs/agents/domain.md) |

### Changes to app interactions

Before changing an app interaction, inspect its macOS and iOS entry points and any shared implementation using the map above. When the request does not specify a platform, fix the same defect on both platforms where that interaction is supported. For a platform-specific request, check the other platform for effects of changes to shared code and keep edits within the requested scope.

Record the expected behavior before, during, and after the interaction, including its return action where applicable, such as playback, pause, and resume. Validate the affected behavior on each platform. Report each platform as changed, unchanged with a reason, or unverified, and distinguish builds and automated tests from screen interaction and physical-device checks.

## Long-term design and deferred work

Cross-device playback-state synchronization remains deferred. Music XML migration and Windows/Android clients have partial implementations; see their guides for supported behavior and outstanding acceptance. Passkey authentication belongs to the superseded account-based design and is not a requirement for opening a host library.

The service specification preserves the local-transfer milestone. [ADR 0008](docs/adr/0008-one-primary-host-over-a-private-network.md), the identity ADRs and specific player/save/playlist contracts define subsequent direction. The [cluster model](docs/cluster-model-design.md) describes the design that ADR 0008 replaces. Historical plans do not reinstate NAS authority or account requirements. Use the app guides and source code for implemented behavior, and Linear issues for work status.

- [Service specification](docs/design-spec.md), [service overview](docs/service-overview.md), [design decisions](docs/decisions.md)
- [Design interview](docs/grill-me.md), [long-term plans](docs/plans/README.md), [initial roadmap](docs/plans/2026-08-15-syncstr-implementation-plan.md)
- [Technical validation records](docs/validation/README.md)

## License

The license for the planned open-source release has not been selected. See each app's `Licenses/` directory for bundled third-party notices.

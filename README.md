# syncstr

A native macOS and iPhone player for a music library you manage yourself.

## Current implementation

The apps support a local music folder on macOS and direct album copies to a paired iPhone on the same LAN. Received music and its catalog can be opened without a network connection. See [local music onboarding](docs/local-music-transfer.md) for setup, the transfer contract, and verification limits.

- **macOS:** album, artist, and track browsing; search; continuous playback; seeking; and folder selection.
- **iPhone:** library browsing, search, playback, album transfers, background audio, and lock-screen controls. The saved library opens without a connection.

Start with the [macOS guide](apps/macos/README.md) or [iPhone guide](apps/ios/README.md) for build and verification steps. [Issue #11](https://github.com/asonas/syncstr/issues/11) records implementation milestones; [open issues](https://github.com/asonas/syncstr/issues) track follow-up work. Record local builds, distribution, and device verification separately.

## Code and documentation map

| Task | Start here |
|---|---|
| macOS UI and launch | [Syncstr.swift](apps/macos/Syncstr.swift), [macOS guide](apps/macos/README.md) |
| Local catalog, pairing, and transfer | [LocalCatalog.swift](apps/macos/LocalCatalog.swift), [LocalTransfer.swift](apps/macos/LocalTransfer.swift), [LocalSetup.swift](apps/macos/LocalSetup.swift), [protocol and setup](docs/local-music-transfer.md) |
| Shared playback and pairing credentials | [Library.swift](apps/macos/Library.swift), [Track.swift](apps/macos/Track.swift), [CredentialStore.swift](apps/macos/CredentialStore.swift). The iOS target compiles these same files |
| iPhone UI and device features | [Sources](apps/ios/Sources/), [iPhone guide](apps/ios/README.md) |
| Folder settings | [SettingsView.swift](apps/macos/SettingsView.swift) |
| Xcode Cloud and distribution for both platforms | [project.yml](apps/ios/project.yml), [ci_post_clone.sh](apps/ios/ci_scripts/ci_post_clone.sh). Generate the Xcode project from YAML |
| UI and icon design | [DESIGN.md](DESIGN.md), which distinguishes UI colors from icon colors |
| Earlier UI prototype | [Apple MVP operation model](https://github.com/asonas/syncstr/tree/be9fd4d9f06fca3676ec0426dbfe4b6606aae0ea/prototypes/apple-mvp-operation-model), [decision #5](https://github.com/asonas/syncstr/issues/5). The prototype is preserved on a separate branch, outside main |
| Interpreting design decisions | [Domain docs](docs/agents/domain.md) |

### Changes to app interactions

Before changing an app interaction, inspect its macOS and iOS entry points and any shared implementation using the map above. When the request does not specify a platform, fix the same defect on both platforms where that interaction is supported. For a platform-specific request, check the other platform for effects of changes to shared code and keep edits within the requested scope.

Record the expected behavior before, during, and after the interaction, including its return action where applicable, such as playback, pause, and resume. Validate the affected behavior on each platform. Report each platform as changed, unchanged with a reason, or unverified, and distinguish builds and automated tests from screen interaction and physical-device checks.

## Long-term design and deferred work

Playback-state synchronization, passkey authentication, Music XML migration, and Windows/Android clients belong to the long-term design. They are not prerequisites for running or changing the local music player.

The service specification describes the current local music product. The plans and technical investigations preserve earlier work; their server requirements are superseded by the local transfer design. Use the app guides and source code for implemented behavior, and issues for work status.

- [Service specification](docs/design-spec.md), [service overview](docs/service-overview.md), [design decisions](docs/decisions.md)
- [Design interview](docs/grill-me.md), [long-term plans](docs/plans/README.md), [initial roadmap](docs/plans/2026-08-15-syncstr-implementation-plan.md)
- [Technical validation records](docs/validation/README.md)

## License

The license for the planned open-source release has not been selected. See each app's `Licenses/` directory for bundled third-party notices.

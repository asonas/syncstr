# syncstr for iPhone

A SwiftUI player for a cluster library or locally imported music, targeting iOS 27 or later. The target compiles the shared library, local catalog, save queue, transfer, track, and credential components from `apps/macos/`.

## Library entry and offline saves

The library screen offers **Join an existing library** and **Add music files**. An invitation registers the existing library; local file import needs no enrollment and does not assign the library-host role. Previously received catalogs stay visible without a connection.

Save tracks or albums near playback controls. Requests and completed results survive restart. The app shows connection waiting, Wi-Fi waiting, progress, partial results, retry, and cancellation. Automatic resumption runs while the app is active and follows the cellular policy. Cancellation keeps successful tracks; album additions require another explicit Save. Save removal frees managed audio and its cache copy, preserves originals and shared items, and confirms playback interruption. Host copies are excluded.

Settings groups enrollment, hosts, diagnostics, conflicts, cellular policy, and storage. Existing paired users can open **Legacy device transfer** there. On the Mac, select a folder and open the same Settings entry, then scan its QR code or enter its pairing code and approve the phone. Keep both apps open during transfer. Removing pairing retains received files. See [the legacy transfer guide](../../docs/local-music-transfer.md).

## Player behavior

Tap a track to start a queue from its displayed list, or Album Play to start that album from the beginning. Browsing and search do not change the active queue. The mini-player appears after a track is selected; tap its metadata to open the full-player sheet and inspect or select from the queue. Playback controls are independent of that navigation.

Previous restarts the track at three seconds or later, otherwise moves back. Paused navigation stays paused and does not acquire audio until Play. Queue completion retains the last track. Track, position, queue order, shuffle, and repeat restore paused after relaunch. Interruptions and unexpected output disconnections pause without automatic resumption.

Unsaved audio is acquired and verified before playback. Preparation has a cancellation action; failures require manual retry. The playback cache is separate from explicit offline saves, has a configurable 10 GB default limit, and never evicts original or explicitly saved audio. Background playback and remote controls follow the same transport rules; physical interruption, output-route, and cellular behavior require device verification.

## P2P node connection

Settings also provides explicit headless P2P registration, catalog access, audio uploads, and downloads. See [P2P music transfer](../../docs/p2p-music-transfer.md). The app bundles the pinned official IrohLib package and its dependency notices; existing Bonjour pairing is retained.

## Build and run

Use Xcode and an iOS Simulator. [project.yml](project.yml) is the XcodeGen source of truth.

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
open apps/ios/Syncstr.xcodeproj
```

Choose the `Syncstr` scheme and an iPhone Simulator, then run. Connect to a Mac on the same local network using the pairing screen. Approved pairing keys are stored in the device or simulator Keychain.

For a physical device, set the signing team and bundle ID in `project.yml` to match your Apple Developer registration, regenerate the project, and select the connected iPhone. Keep credentials and signing private keys outside the repository.

## TestFlight and Xcode Cloud

Keep `project.yml` and `Syncstr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` under version control. Other generated project files, workspace files, and shared schemes are excluded. [ci_post_clone.sh](ci_scripts/ci_post_clone.sh), next to the generated project, installs XcodeGen if needed and generates the project after cloning. The Xcode Cloud connection manifest remains tracked.

Xcode Cloud disables automatic package resolution. After changing package dependencies, resolve them locally and commit the updated `Package.resolved`. Before pushing, regenerate the project and verify resolution with an empty package checkout directory:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
package_checkouts=$(mktemp -d)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -resolvePackageDependencies -project apps/ios/Syncstr.xcodeproj \
  -scheme SyncstrMac -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -clonedSourcePackagesDirPath "$package_checkouts"
```

Connect the repository through Xcode's Integrate → Create Workflow. Configure:

- Source: this repository's `main` branch
- Project: `apps/ios/Syncstr.xcodeproj`
- Scheme: `Syncstr`
- Start condition: changes to `main`
- Action: iOS Archive for internal TestFlight testing
- Post-action: distribute to your internal test group

The workflow's project path remains `apps/ios/Syncstr.xcodeproj`, even though it is generated after cloning. Do not use the directory or `project.yml` as that setting.

The same YAML defines the `SyncstrMac` scheme. See the [macOS distribution guide](../macos/README.md#testflight-and-xcode-cloud). Check Cloud build completion and TestFlight delivery in App Store Connect separately from local build success.

## Implemented behavior

- The library combines artist, album, and track navigation with a two-column album grid. Album details place artwork and metadata above Play and the ordered track list. Accessibility text sizes use a single album column.
- Search covers tracks, albums, and artists.
- Selecting a track plays the originating list in order. The native glass mini-player opens Now Playing as a sheet, with pause/resume, previous/next, seeking, and a track save menu. The Now Playing tab provides the same controls.
- A cloud/download icon marks an unsaved track, a spinner marks downloading, and a check marks a saved track. Tap the cloud to download; tap the title to play. A spinner next to the title indicates playback preparation.
- Playback uses verified received files. The catalog and audio survive restarts without a network. Choosing another Mac or removing a pairing retains audio files.
- Lock-screen and Control Center integration expose track information, playback position, pause/resume, previous/next, and seeking.
- Settings provide pairing controls and Mac selection. Received audio remains on the phone when changing connections.
- Playback activates the audio session's playback category. Background audio is declared; screen locking, audio-route changes, and interruptions require physical-device verification.

Queue editing, playlists, and favorites are outside the current scope.

## Assets

The app icon is exported from the [selected design](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=12-2). The [1024px iOS frame](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=15-2) extends its background to the edges; the OS applies rounded corners.

App-owned navigation and playback icons use original SVGs from [Regen Icons](https://github.com/kazdenc/regen-icons), pinned to revision `64c0e165c3ce6d5c9d7329acf5762306f86d6b1d`. Download-state icons use its `cloud-download` and `circle-check`. Its MIT license is preserved in [Licenses/RegenIcons.txt](Licenses/RegenIcons.txt) and bundled with the app. System navigation chrome remains native. See [DESIGN.md](../../DESIGN.md) for layout and typography rules.

## Verification

After generating the project, select an available iPhone Simulator destination:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/ios/Syncstr.xcodeproj -scheme Syncstr \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath apps/ios/.build/DerivedData CODE_SIGN_IDENTITY=- test
```

Audio fixtures cover offline catalog restoration, received-file availability, AVPlayer local playback, and Now Playing updates. Tests use temporary storage and do not use production credentials.

Manually verify pairing, album browsing, your own sample tracks, audible playback, seeking, and offline startup after restart. Record Simulator results separately from physical-device playback.

Through TestFlight, verify album transfers, saved-state indicators, playback after locking the screen, and lock-screen controls. After loading the library, disconnect the network and verify playback of saved tracks.

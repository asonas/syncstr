# syncstr for iPhone

A SwiftUI player for music copied from a paired Mac, targeting iOS 27 or later. The target compiles the shared library, local catalog, transfer, track, and pairing credential components from `apps/macos/`.

## Local music onboarding

On the Mac, choose a music folder and open **Transfer to iPhone**. On the phone, allow local-network access, choose the Mac, scan its QR code or enter its pairing code, and connect. Approve the phone on the Mac. Open an album and save it; completed tracks receive a saved indicator. Keep both apps open during copying. After interruption, reconnect and retry; completed tracks are verified and skipped.

The catalog, artwork, and completed audio remain on the phone after restarting without networking. Unsaved tracks remain distinguishable from saved tracks. Pairing controls are in Settings; removing a pairing retains received files. See [the local-transfer guide](../../docs/local-music-transfer.md).

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

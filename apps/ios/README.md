# syncstr for iPhone

A SwiftUI player for music served by Navidrome, targeting iOS 26 or later. The target compiles the shared `Library.swift`, `Navidrome.swift`, and `CredentialStore.swift` files from `apps/macos/`.

## Build and run

Use Xcode and an iOS Simulator. [project.yml](project.yml) is the XcodeGen source of truth.

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
open apps/ios/Syncstr.xcodeproj
```

Choose the `Syncstr` scheme and an iPhone Simulator, then run. Enter the credentials for your Navidrome server in the app. They are stored in the device or simulator's Keychain and restored on subsequent launches. Credentials from the Mac's Keychain are not copied to the device.

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

- The library starts on albums, with album tracks, all tracks, and artists available for browsing.
- Search covers tracks, albums, and artists.
- Selecting a track plays the originating list in order. The mini-player opens Now Playing, which provides pause/resume, previous/next, and seeking.
- A cloud/download icon marks an unsaved track, a spinner marks downloading, and a check marks a saved track. Tap the cloud to download; tap the title to play. A spinner next to the title indicates playback preparation.
- Playback prefers a saved local file. Download state survives restarts and is isolated by server and account. Logout retains audio files. Fetching the library at startup still requires a server connection.
- Lock-screen and Control Center integration expose track information, playback position, pause/resume, previous/next, and seeking.
- Settings provide library refresh and logout. Logout removes saved connection credentials for the device.
- Playback activates the audio session's playback category. Background audio is declared; screen locking, audio-route changes, and interruptions require physical-device verification.

Queue editing, offline library browsing at startup, playlists, and favorites are outside the current scope.

## Assets

The app icon is exported from the [selected design](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=12-2). The [1024px iOS frame](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=15-2) extends its background to the edges; the OS applies rounded corners.

Download-state icons use `cloud-download` and `circle-check` from [Regen Icons](https://github.com/kazdenc/regen-icons). Its MIT license is preserved in [Licenses/RegenIcons.txt](Licenses/RegenIcons.txt) and bundled with the app.

## Verification

After generating the project, select an available iPhone Simulator destination:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/ios/Syncstr.xcodeproj -scheme Syncstr \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath apps/ios/.build/DerivedData CODE_SIGN_IDENTITY=- test
```

Tests use fixed API responses and a test-only Keychain service for automatic login, library loading, and logout. Audio fixtures cover download-state restoration, account isolation, AVPlayer local playback, and Now Playing updates. Production credentials are not used.

Manually verify login, album browsing, your own sample tracks, audible playback, seeking, and automatic login after restart. Record Simulator results separately from physical-device playback.

Through TestFlight, verify streaming of unsaved tracks, downloads, saved-state indicators, playback after locking the screen, and lock-screen controls. After loading the library, disconnect the network and verify playback of saved tracks.

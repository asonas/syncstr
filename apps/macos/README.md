# syncstr for macOS

A native player for music in a folder you select. Browse albums, artists, and tracks; play original files; and copy albums directly to a paired iPhone on the same local network.

## Local music and iPhone pairing

Choose **Select Music Folder** on first launch. Syncstr reads supported audio and tags without editing your files, and remembers folder access through a security-scoped bookmark. Open **Transfer to iPhone** in the sidebar, select the Mac from Syncstr on the phone, scan its QR code or enter its code, then approve the phone on the Mac. Keep both apps open during transfer.

The phone can save albums and listen after the Mac is closed. Use Settings to change folders. See [the local-transfer guide](../../docs/local-music-transfer.md) for trust, retry behavior, and limits.

## Build and run

Use Xcode's Swift compiler, macOS SDK, and XcodeGen. The build fetches TagLib 2.3.0 through Swift Package Manager. Find your development signing identity with `security find-identity -v -p codesigning` and supply it through `CODE_SIGN_IDENTITY`. Keep the same certificate and bundle ID across rebuilds to preserve Keychain access permissions. Switching from an ad-hoc build may require approving Keychain access once.

Local macOS builds use `as.ason.syncstr.macos` across worktrees. TestFlight and App Store builds use `as.ason.syncstr.ios`. The Keychain service names stay the same; switching from the former local bundle ID may require approving access again on the first launch.

Run from the repository root:

```sh
# Replace this example with your own signing identity.
export CODE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh apps/macos/build.sh
sh apps/macos/run.sh
```

`run.sh` lists this user's running Syncstr executables, sends TERM to old builds, and waits for them to exit. It then opens the target by absolute path and verifies that exactly one Syncstr process is running from that path. Finish transfers before restarting. Building and launching are separate operations.

To launch another build, pass its bundle path: `sh apps/macos/run.sh /path/to/Syncstr.app`. Shutdown and startup verification each wait at most 10 seconds. A shutdown timeout reports the remaining PIDs and paths without launching another instance. The script never escalates to a forced kill.

A per-user lock prevents concurrent launches through the script. If an abnormal interruption leaves a lock behind, first confirm that no launch is in progress, then remove the empty lock directory reported by the error with `rmdir`.

## Playback

The library opens on albums. Use the sidebar to switch between albums, artists, and tracks, or to refresh the library. The title-bar search filters the current section. Open an album and select a track to play it; the mini-player opens the Now Playing view in the same window.

Previous/next, pause/resume, and seeking operate on the list from which playback started. Albums are ordered by disc and track number. Navigation and search do not change the active queue. Tracks advance automatically; playback stops after the last track. Pressing play after the final track ends restarts that track.

Select a track again after a playback failure and check folder access. Playlist editing, playback history synchronization, and editing source files' metadata are not implemented. Local-folder audio plays directly from the selected folder.

The screen structure follows the [Apple MVP operation model decision](https://github.com/asonas/syncstr/issues/5#issuecomment-5472974010).

## TestFlight and Xcode Cloud

Both platform targets are generated from [apps/ios/project.yml](../ios/project.yml). Set its signing team and bundle identifiers to match your Apple Developer registration. Add the macOS platform to your App Store Connect app and keep the platform settings consistent.

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
open apps/ios/Syncstr.xcodeproj
```

Configure Xcode Cloud with:

- Project: `apps/ios/Syncstr.xcodeproj`
- Scheme: `SyncstrMac`
- Start condition: changes to `main`
- Action: macOS Archive for internal TestFlight testing
- Post-action: distribute to your internal test group

[ci_post_clone.sh](../ios/ci_scripts/ci_post_clone.sh) generates both platforms' projects and schemes after cloning. The workflow project path is the generated `.xcodeproj`, not `apps/macos` or `project.yml`.

Distribution builds enable App Sandbox, outgoing network access, and read access to user-selected files. Their bundle ID and container differ from the manual `build.sh` build, so select the music folder and pair your phone in that distribution variant. Check Archive success and TestFlight delivery separately in App Store Connect.

## Verification

Run the launcher fixtures with `mise exec -- python3 apps/macos/Tests/test_run.py`. They replace process-listing, termination, and launch commands in a temporary environment; they do not operate on running apps.

Verify source indexing, Japanese tags, artwork, and preservation of original files and audio:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme SyncstrMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The macOS test suite above also checks local transfer over a real TLS loopback connection, pairing rejection, interruption/retry, and file integrity.

Verify continuous playback, end-of-queue behavior, seeking, and folder restoration with the real AVPlayer and a short silent audio fixture. Run this as a standalone executable with access to macOS audio services and Keychain. It uses temporary storage and a unique test-only Keychain service and does not access normal pairing credentials:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme LibraryCheck -destination 'platform=macOS' -derivedDataPath apps/macos/.build/Checks CODE_SIGNING_ALLOWED=NO build
apps/macos/.build/Checks/Build/Products/Debug/LibraryCheck
```

Manually verify folder selection, your own sample tracks, audible playback, pause/resume, track changes, seeking, folder restoration after restart, and iPhone pairing. A passing build does not establish audible playback.

# syncstr for macOS

The Mac app reads a host library over HTTPS.

## Library entry and offline saves

On first launch, choose **Connect to host**, enter the host address, and confirm the library. The Mac reads the catalog, playlists, artwork, and audio from the host's `/api/v1`. Earlier versions could also play a local Music folder or imported files. The first launch after updating removes that catalog and any imported audio that no host entry or saved track shares. Installs that still kept only the older `catalog.json` keep their imported audio files. **Delete all saved music** in Settings removes them along with saved music; it is available once at least one track is saved.

Track and album actions save audio on this device without host selection. Pending requests and successful tracks survive restart. Unreachable sources show connection waiting; automatic resumption obeys the cellular setting. Retry fetches unfinished items, and cancellation keeps successful saves. Album requests snapshot their tracks; later additions need another Save. Removing a save deletes its managed audio and cache copy, keeps the host library entry, and confirms interruption of an affected player.

The Settings window has General, Library, Storage, and Advanced tabs. Storage shows saved music and the playback cache, with actions to delete all saved music and clear the cache. Advanced lists recent playback attempts with a copy action for each. See [Settings](../../DESIGN.md#settings).

## Build and run

Use Xcode's Swift compiler, macOS SDK, and XcodeGen. The project has no Swift package dependencies. Find your development signing identity with `security find-identity -v -p codesigning` and supply it through `CODE_SIGN_IDENTITY`. Keep the same certificate and bundle ID across rebuilds to preserve Keychain access permissions. Switching from an ad-hoc build may require approving Keychain access once.

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

The library opens on albums. Use the sidebar to switch between Recently Added,
albums, artists, tracks, and hidden albums, or to refresh the library. The
sidebar also lists the host's playlists in their folders; click a folder to
expand it and a playlist to open it. Recently Added displays
visible albums by their newest member track's shared addition time, newest first.
Albums are grouped by calendar month. Undated legacy albums appear in an unknown-
date section after dated additions, in stable album-ID order. Missing album
names use the track title for display without changing source metadata. Search
preserves this order; the ordinary Albums sort settings are independent. Opening
an album and returning centers it in the list. The title-bar search filters the
current section. Open an album and select a track to play it; the mini-player
opens the Now Playing view in the same window.

Click an album to open it. **Hidden Albums** lists the albums the host hides. Host catalogs are read-only, so the app cannot hide or restore albums.

The three-line menu beside search sorts albums by title or artist in ascending or descending natural order. The other field breaks ties. Sorting also applies to search results and hidden albums and does not change the playback queue.

Previous/next, pause/resume, and seeking operate on the list from which playback started. Albums are ordered by disc and track number. Navigation and search do not change the active queue. Tracks advance automatically; playback stops after the last track. Pressing play after the final track ends restarts that track.

Album Play always starts a new album queue from its first track. Player controls pause/resume at the current position. Previous restarts the current track after three seconds; before that it moves back. Previous/next while paused select a track without starting audio or acquiring an unsaved file.

The current track, position, decided queue order, shuffle, and repeat restore paused after relaunch. Opening Now Playing preserves the library search and scroll position. The mini-player appears only after selecting a track, and the queue can be inspected in Now Playing.

Playing an unsaved host track downloads and verifies its audio before playback. You can cancel preparation or retry a failed download. The playback cache defaults to 10 GB. Change its limit or clear it in Settings. Eviction and clearing preserve explicit saves and the playing file.

Select a track again after a playback failure and check the host connection. Playlist editing, playback history synchronization, and editing source files' metadata are not implemented.

The screen structure follows the [Apple MVP operation model decision](https://github.com/asonas/syncstr/issues/5#issuecomment-5472974010).

### Keyboard controls

The Controls menu provides playback commands while the library window is active. Space toggles play/pause for the selected track. Command-Right/Left skips to the next/previous track; Command-L opens Now Playing, and Command-[ returns from Now Playing to the library.

Option-Space toggles ordinary shuffle. Repeat supports Off, All, and One through the menu and Now Playing controls. Shuffle retains the current track and restores the original queue order when turned off. Repeat All wraps the queue; Repeat One restarts the current track when it ends, while manual next/previous still change tracks.

Command-Up/Down adjusts app playback volume in 10% steps. Command-Shift-Up/Down sets it to maximum/minimum. These controls affect Syncstr audio, not the system output volume. The same commands are available on iOS with a hardware keyboard; its Now Playing screen also exposes shuffle, repeat, and volume without a keyboard. Volume applies to the current app session; queue, position, shuffle, and repeat persist.

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

Distribution builds enable App Sandbox and outgoing network access. Their bundle ID and container differ from the manual `build.sh` build, so configure the host address in that distribution variant. Check Archive success and TestFlight delivery separately in App Store Connect.

## Verification

Run the launcher fixtures with `mise exec -- python3 apps/macos/Tests/test_run.py`. They replace process-listing, termination, and launch commands in a temporary environment; they do not operate on running apps.

Run the unit tests:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme SyncstrMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The [host API tests](Tests/HostAPITests.swift) cover catalog reads, interrupted downloads, and rejection of corrupt audio and artwork. The [catalog migration tests](Tests/CatalogMigrationTests.swift) cover removal of the earlier local library.

Verify offline restoration of a saved host catalog, continuous playback, end-of-queue behavior, and seeking with the real AVPlayer and a short silent audio fixture. Run this as a standalone executable with access to macOS audio services. It uses temporary files:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme LibraryCheck -destination 'platform=macOS' -derivedDataPath apps/macos/.build/Checks CODE_SIGNING_ALLOWED=NO build
apps/macos/.build/Checks/Build/Products/Debug/LibraryCheck
```

Manually verify playback from the configured host, audible playback, pause/resume, track changes, seeking, and offline playback of saved music after restart. A passing build does not establish audible playback.

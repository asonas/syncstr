# syncstr for macOS

A native player that browses albums, artists, and tracks from a local music folder or Navidrome. Choose a folder to listen locally and copy albums to an iPhone. Alternatively, enter the HTTPS URL and account credentials for a server you manage; that path uses OpenSubsonic for listing and streaming music.

After a successful login, the app saves connection credentials in this Mac's Keychain and reconnects on launch. Failed reconnects return to the login screen. Log out from Settings (Command+,); confirmation stops playback and removes the saved Navidrome credentials.

## Local music and iPhone pairing

Choose **Select Music Folder** on first launch. Syncstr reads supported audio and tags without editing your files, and remembers folder access through a security-scoped bookmark. Open **Transfer to iPhone** in the sidebar, select the Mac from Syncstr on the phone, scan its QR code or enter its code, then approve the phone on the Mac. Keep both apps open during transfer.

The phone can save albums and listen after the Mac is closed. Use Settings to change folders or choose another connection method. Navidrome login remains available from onboarding. See [the local-transfer guide](../../docs/local-music-transfer.md) for trust, retry behavior, limits, and physical-device acceptance checks.

## Uploads

Open the upload screen from the sidebar. Drag audio files onto it or use the file picker, then start uploading. Files are sent one at a time. The list shows file size and pending, sending, completed, or failed status. Duplicate selections are excluded, pending items can be removed, and retries skip completed files.

Use each file's track-information action to edit its title, artist, album, track number, and artwork. Existing metadata is loaded first; only changed fields are written to the temporary upload copy. The original file remains unchanged. Choose JPEG or PNG artwork no larger than 10 MB. If metadata cannot be read for a format, editing is disabled and the file uploads unchanged.

Deploy the Rust upload service described below behind HTTPS. Enter its URL and a dedicated token in the upload settings tab and confirm with OK. These credentials use a separate Keychain service from Navidrome. Logging out of Navidrome does not remove the upload credentials; use their deletion control in settings.

Uploads use a temporary copy so the transmitted content matches its checksum. Allow enough free space for that copy. The server validates file formats and rejects overwrites. The app polls until all uploaded tracks appear in Navidrome and refreshes the library. If scanning has not completed, refresh the library after it finishes. Background transfer, resuming interrupted uploads, and folder selection are not supported.

### Server and deployment sources

| Component | Source |
|---|---|
| Client | [Upload.swift](Upload.swift), [UploadCheck.swift](UploadCheck.swift) |
| Rust server | [server/](../../server/README.md), integrated into main |
| Deployment | [syncstr-uploader-deployment](https://github.com/asonas/syncstr-uploader-deployment); its Compose configuration selects the build source with `SYNCSTR_SOURCE_REF` |

For server API work, read `server/README.md` and `server/src/lib.rs` at the ref selected by the deployment. The source on main may differ from a running deployment's version. Check Compose, environment overrides, and deployment history to establish that version. Do not infer it from a worktree's location or name.

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

Retry a failed connection after checking the server and network. Select a track again after a playback failure. Playlist editing, offline caching of Navidrome streams, playback history submission, and editing existing files' metadata are not implemented in this macOS client. Local-folder audio plays directly from the selected folder.

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

Distribution builds enable App Sandbox, outgoing network access, and read access to user-selected files. Their bundle ID and container differ from the manual `build.sh` build, so enter connection credentials on first launch. Check Archive success and TestFlight delivery separately in App Store Connect.

## Verification

Run the launcher fixtures with `mise exec -- python3 apps/macos/Tests/test_run.py`. They replace process-listing, termination, and launch commands in a temporary environment; they do not operate on running apps.

Verify metadata editing, Japanese tags, artwork addition and removal, preservation of original files and audio, and uploads of edited copies:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme SyncstrMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Verify upload headers, SHA-256, filename encoding, response receipts, conflict handling, and HTTPS restrictions at the HTTP boundary:

```sh
mkdir -p apps/macos/.build/module-cache
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/upload-check apps/macos/Upload.swift apps/macos/UploadCheck.swift
apps/macos/.build/upload-check
```

Verify rejected login, paginated track lists, and streaming URLs with fixed URLSession responses:

```sh
mkdir -p apps/macos/.build/module-cache
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/navidrome-check apps/macos/Navidrome.swift apps/macos/NavidromeCheck.swift
apps/macos/.build/navidrome-check
```

The macOS test suite above also checks local transfer over a real TLS loopback connection, pairing rejection, interruption/retry, and file integrity.

Verify continuous playback, end-of-queue behavior, seeking, and credential restoration with the real AVPlayer and a short silent audio fixture. Run this as a standalone executable with access to macOS audio services and Keychain. It uses a unique test-only Keychain service and fictional credentials, removes its entries afterward, and does not access normal saved credentials:

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/ios/Syncstr.xcodeproj -scheme LibraryCheck -destination 'platform=macOS' -derivedDataPath apps/macos/.build/Checks CODE_SIGNING_ALLOWED=NO build
apps/macos/.build/Checks/Build/Products/Debug/LibraryCheck
```

Manually verify login, your own sample tracks, audible playback, pause/resume, track changes, seeking, credential restoration after restart, and credential removal on logout. A passing build does not establish audible playback.

## References

- [Navidrome Subsonic API support](https://www.navidrome.org/docs/developers/subsonic-api/)
- [OpenSubsonic API](https://opensubsonic.netlify.app/docs/api-reference/)
- [Track search](https://opensubsonic.netlify.app/docs/endpoints/search3/)

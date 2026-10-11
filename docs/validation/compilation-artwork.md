# Album artwork

Stage B of the [revision plan](../compilation-revision-implementation-plan.md) implements local acquisition, independent image storage, manual selection and existing-peer transfer. Cluster replication remains stage C.

## Sources and retained choices

Native imports prefer embedded images, then recognized album-directory files, then an exact Music-library file-location match on macOS. Manual selection takes precedence. Directory filenames are checked case-insensitively in this order: `cover.jpg`, `cover.jpeg`, `cover.png`, `folder.jpg`, `folder.jpeg`, `folder.png`. Shared-parent images require accepted sibling-disc membership and consistent, distinct positive disc numbers. An arbitrary ancestor is never searched.

The macOS reader lazily enumerates one public iTunesLibrary snapshot per operation. It reads the matched media item's `artwork.imageData`; duplicate locations and missing access yield no candidate. It uses the original file location before upload staging, with no title lookup or Apple Events. The macOS target includes `NSAppleMusicUsageDescription` and the read-only Music entitlement. iOS does not link iTunesLibrary.

Image input is limited to 10 MiB, 16,000 pixels per axis and 40 million pixels before thumbnail decoding. Images are normalized to JPEG, at most 400 pixels per axis without upscaling and at most 512 KiB. Previously normalized valid images retain their bytes. Swift and Rust verify SHA-256, dimensions, and JPEG decoding before accepting an asset. Rust uses a bounded decoding buffer with [jpeg-decoder](https://docs.rs/jpeg-decoder/0.3.2/jpeg_decoder/struct.Decoder.html).

Acquisition revisions retain track, source type, opaque source context, asset identity, and causal parents. Track candidates use source priority, disc/track order and stable track identity. Conflicting independent acquisitions retain the local usable cover and remain reviewable; a scan does not silently resolve a conflict. Failed acquisition retains previous bytes. Legacy bytes remain in their original entries; normalizable native images and valid normalized headless JPEGs gain `legacy` provenance rather than being claimed as embedded.

Manual selection and clearing use album-scoped causal choices. Clearing restores automatic selection. Choice history and image bytes remain available after restart and reordered delivery. The native organization sheet keeps selection in a draft until Save, previews the cover and conflict candidates, and offers file selection on both platforms plus Photos selection on iOS.

## Persistence and transfer

Schema 4 stores image payloads in a separate SQLite table. Organization metadata retains an explicit asset manifest, so a new catalog cannot inherit every image left by a previous catalog. Image rows and organization references commit in one transaction. Cached presentation files can be regenerated from the database; missing audio does not remove an image.

Native message version 4 sends organization metadata in bounded chunks and image payloads in separate `artwork` frames, each at most 512 KiB. The 64 MiB metadata limit excludes image bytes. The receiver requires every declared image, rejects duplicate/unexpected assets, validates bytes, and only then returns an organization for persistence. The model bounds album/track/assets to 100,000 records and revisions to 200,000. Existing assets are currently sent again during metadata exchange; this is not an incremental cluster asset protocol.

An `organize` request exchanges image and choice updates independently of audio. Native Save sends when connected and idle, defers behind an active operation, or retains the change for reconnect. Hosts expose their latest organization on reconnect. No audio receipt is inferred from image receipt. Headless HTTP uses `/v4`; older API versions return HTTP 426. Its JSON organization endpoint remains bounded to 64 MiB; large native image libraries use the separate-image peer transport. Both peers must be updated. No node deployment or production catalog is changed by this implementation.

## Verification

Checks use fictional image/audio fixtures and isolated temporary catalogs. The JPEG fixtures are generated solid colors, and the common `headless/fixtures/album-artwork.json` records independent expected identities for both languages.

- Native acquisition tests exercise real MP3, M4A and FLAC files, embedded/folder/Music priority, corrupt folder fallback, exact and ambiguous Music locations, one lazy snapshot, and unavailable access retaining the prior image.
- Model/storage checks exercise manual selection, clear, concurrent acquisition, reordered delivery, restart without audio, invalid-asset rejection and catalog switching without unrelated images.
- Transfer checks cover separate image frames, incomplete/duplicated/reordered chunks, missing assets, and a real Swift client talking to the Rust host. Image selection and clear round-trip while the downloaded audio's bytes and modification time remain unchanged.
- A signed, sandboxed macOS probe with the production Music entitlement matched the user-selected file exactly once and read a 125,721-byte, 400-by-400 JPEG. The source file and Music library were read-only and are not included in fixtures. Denied/unavailable acquisition is exercised at the snapshot boundary; OS privacy settings were not reset.
- `LibraryCheck` uses a real muted AVPlayer. Drafting, saving and clearing the image preserve the current player, current track and queue. Existing playback checks also pass.

The full Rust suite and Clippy passed before review. After tightening image decoding and separating image transfer, 20 focused Rust tests and Clippy passed. The full macOS suite ran 47 tests with the two existing optional external-service/upload cases skipped; real native-to-Rust normal and idle-reconnection cases ran. After review, 17 focused macOS model, migration, LAN and native-to-Rust tests passed. The iOS production-target simulator suite passed 32 tests; 14 focused artwork/migration tests passed after review changes.

The final production macOS Release target built successfully. Its code signature verified, and the built app contains the sandbox Music read-only entitlement and usage description. This is local development signing, not App Store export or delivery.

An isolated iOS 27 simulator app rendered the production `OrganizationView` against a fictional catalog without audio. UI automation verified image preview, cancel retaining the saved manual choice, save clearing to automatic, and image presentation after process restart. The screenshot was inspected in the default light appearance. This exercise caught and fixed simultaneous activation of buttons grouped in a List row. File-provider/photo-library selection, all appearance and accessibility variants, and physical-device interactions were not exercised.

Review found and resolved three specification issues: aggregate image bytes sharing the metadata bound, incomplete Rust image decoding, and restoring unrelated cached assets into a different catalog. A standards review also identified silent file-picker failures; non-cancellation failures are now displayed. Both reviewers confirmed these findings resolved.

macOS visual inspection and clicking the picker could not be verified because the UI automation service failed and OS accessibility/screen capture was unavailable. Successful builds and component tests do not establish visual correctness. TestFlight, App Store distribution, physical-device playback and cluster behavior remain unverified.

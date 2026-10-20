# iPhone library experience

Status: integrated into main in `927aef7`; verification results are recorded
below. Implementation baseline: `81f0dd1`, including adaptive appearances.
The main journeys concern iPhone. The reviewed album action layout also applies
to iPad and macOS. Shared playback, catalog, and save changes require cross-platform
regression checks.

## Review artifacts

Use the [design-status index](design-status.md) to distinguish the current review
from prototypes, earlier references, and archived layouts.

- [Five editable screens](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=147-471): before saving, saving, recently added, compact player, and artist detail.
- [Motion exploration](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=147-2841): expanded player moves into the bottom row while narrowing.
- [Artist navigation prototype](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=147-2978): tap the artist name to reach the origin album centered in artist details.

The proposal reuses existing Syncstr palette variables, Regen icons, components,
and fictional vector artwork. Noto Sans JP is the existing approved Figma font
substitute; the application continues to use system typography. Flat control
fills illustrate geometry only, not production Liquid Glass rendering.

## 1. Lock-screen artwork

Confirmed in `apps/ios/Sources/PhonePlayback.swift`: `update()` replaces
`nowPlayingInfo` with title, artist, album, duration, elapsed time, and rate,
but never supplies `MPMediaItemPropertyArtwork`. The app artwork path separately
uses `library.artworkURLs` through `MusicImage`.

Implementation: load the current artwork asynchronously through the existing
image-loading boundary, cache the decoded image, and publish `MPMediaItemArtwork`.
Avoid loading on every playback-position update. Associate each result with
the selected track/artwork identity; discard stale results after a track switch.
Clear old artwork immediately when the next track has no image. Handle local
files, delayed URL availability, errors, and offline use without blocking playback.

Verification: delayed image completion after a rapid track switch, missing image,
offline cached image, and pause/resume metadata preservation. Verify the actual
iPhone lock screen and background track transitions separately from build checks.
The shared macOS use of `PhonePlayback` must still compile and publish metadata.

## 2. Album details and save states

Confirmed in `apps/macos/OfflineSaves.swift`: `iconOnly` affects only the save
button in the idle/failed branch. Pending and saved branches still render text.
`PhoneRoot.trackRow` uses `compact: true`, including an album-wide cancel label
for a track belonging to an album request. This explains the repeated labels
and changing control width in the supplied screenshots.

Confirmed layout: center Play on the screen, with a shuffle-play button on its
left and save/progress on its right. Both side targets are 44 points wide, with
equal 20-point gaps around the 176-point Play button. Preserve this alignment
before and during saving. Shuffle starts shuffled album playback rather than
merely toggling an unrelated queue setting. The Figma proposal uses the standard
Lucide shuffle SVG as a design preview because the pinned Regen set has no shuffle icon;
resolve this icon exception when implementing the control.

For side-by-side iPad and macOS headers, align the action group's bottom edge
with the artwork bottom and its leading edge with the album title. Keep the
shuffle/play/download order; center Play within the group rather than across
the whole metadata column. Use flexible space between metadata and actions.
In expanded iPhone tab bars, vertically center each icon/label group, with equal
top and bottom clearance. Apply this to the review screens and their prototypes.

Proposal: keep a fixed 44-point action target in each track row.
Show the album's completed-track count once, below its controls. Preserve the
same geometry before and during saving. Track titles retain available width.

| State | Track presentation | Operation |
| --- | --- | --- |
| Not saved | More menu | Save this track |
| Waiting / Wi-Fi wait | Waiting indicator | Open reason and available actions |
| Saving | Progress ring | Open scoped actions |
| Saved | Check icon | Open actions, including removal |
| Failed | Alert icon | Open error and retry |

Album progress exposes album cancellation; a track in that request must not
silently cancel the entire album. Retain retry, partial completion, removal
confirmation, and VoiceOver state/reason labels. The two Figma screens illustrate
idle and mixed completed/saving states; waiting and error variants remain an
implementation acceptance requirement, not a claim of completed visual review.
Do not imply byte-level progress if the transfer boundary only reports completed
tracks. Apply the reviewed macOS album-header layout; keep unrelated macOS
save surfaces unchanged unless shared behavior requires a corresponding change.

## 3. Recently added

Confirmed: `PhoneRoot.catalog` renders an Albums heading and `albumGrid`, which
applies the same `library.sortedAlbums` ordering as normal album browsing.
`Track` has no addition timestamp. The inspected `ClusterChange` signed payload
also has no addition timestamp; local database row order is not a shared date.

Confirmed requirement: order by addition to the shared library, consistently
across devices, not by the time an individual device discovers or downloads it.

Add a Recently Added menu destination and use its album order in the library
landing page. Preserve the existing Albums destination and its title/artist sort.
Reuse the album grid without reapplying the ordinary alphabetical sort.

Before implementation, define and persist shared addition metadata at the import
boundary, and propagate it through host, sync, and client catalog representations.
Use an additive, backward-compatible representation; do not rewrite previously
signed payloads. Audit all readers/writers before selecting the schema. Mac,
headless, Android, and Windows compatibility belongs to this change even though
the requested screen is on iPhone.

Ordering: latest first, stable album identity as the final tie-breaker. The
implementation uses the latest addition of a member track as the album date.
Refreshes, retries, edits, local saves, and restoring an existing object retain
its original date. The host assigns new shared dates, ignoring uploader dates.

Legacy signed import records have no historical date. Existing undated tracks
remain undated and sort behind dated additions using stable album IDs. No old
signed payload is rewritten and no receiving device stamps a local receipt date.
The optional `Track.addedAt` JSON field stores Unix milliseconds and is omitted
when absent, preserving verification of historical signed payloads. Swift and
the shared Rust model used by headless, Android native, and Windows retain it.
Older Rust binaries cannot verify new signed records containing that field;
update participating Rust hosts/clients before importing with this version.

Verify equal order on two devices, delayed synchronization, restart, re-download,
metadata edits, hidden albums, same-time imports, and the chosen legacy migration.

## 4. Scroll-responsive mini-player

Confirmed: iPhone already uses `tabViewBottomAccessory`, but no explicit
`tabBarMinimizeBehavior` or placement-aware accessory layout is present.

Prefer [Apple's native tab minimization](https://developer.apple.com/documentation/swiftui/tabbarminimizebehavior)
with `onScrollDown` and adapt the accessory to
[`tabViewBottomAccessoryPlacement`](https://developer.apple.com/documentation/swiftui/tabviewbottomaccessoryplacement).
Keep library, search, and settings reachable. The compact library control's
navigation expansion must be checked against actual native behavior; the Figma
placement is a proposal, not proof of OS behavior.

The Motion study holds the expanded state until 0.35 seconds, transitions over
0.30 seconds, and retains the compact state. The player moves 52 points right
and 68 points down while narrowing from 350 to 246 points. Navigation crossfades;
artwork, title, and transport retain their identity. This is a timeline study,
not a live scroll simulation or a mandate to override native timing.

Follow the motion principles in `emil-design-eng`: subtle frequent transitions,
continuity, interruption without snapping, and reduced-motion alternatives.
Verify scroll reversal, fast direction changes, long titles, larger type, new
track selection, search keyboard, and play/pause hit targets. Do not impose this
iPhone minimization behavior on iPad or macOS.

## 5. Artist navigation

Confirmed: album artist text is a plain `Text`. Existing `artistList` destinations
show a song list, so there is no album-based artist detail target to scroll to.

Introduce an artist detail destination with album identities. Pass the origin
album ID when opening it from an album. Resolve the artist through the catalog
model rather than parsing display strings. For compilations or ambiguous credits,
do not invent an artist identity; define the destination or disable the link.

Scroll once after layout to center the origin album, with sufficient top/bottom
scroll space for first and last albums. Do not re-center on playback ticks or
later catalog updates. Retain normal back-navigation state and support entry
from the artist list without an origin. The Figma prototype shows the destination
position; runtime scrolling and navigation timing remain to be verified.

## Implementation work packages

Each package should remain reviewable on its own. Use the existing dedicated
worktree; inspect the new main baseline before implementation and before any
authorized integration. Preserve concurrent appearance and performance changes.

| Order | Package and principal files | Completion condition |
| --- | --- | --- |
| 1 | Lock-screen artwork: `apps/ios/Sources/PhonePlayback.swift`, existing image loading boundary | Correct artwork survives pause/resume and offline playback; late results cannot replace the next track's artwork |
| 2 | Album action layout and shuffle: `apps/ios/Sources/PhoneRoot.swift`, `apps/macos/Syncstr.swift`, `apps/macos/Library.swift`, icon assets | iPhone Play is centered; wide iPad/Mac actions meet the artwork baseline; shuffle starts the chosen album without duplicates or omissions |
| 3 | Save state presentation: `apps/macos/OfflineSaves.swift`, iOS track-row entry points | Fixed action width across all states; album cancellation is explicit; partial results, retry, removal, and accessibility remain available |
| 4 | Mini-player: `apps/ios/Sources/PhoneRoot.swift` and a placement-aware accessory view if needed | Native scrolling collapses and restores the player; all tabs and transport remain reachable; reduced-motion behavior is checked |
| 5 | Artist navigation: `PhoneRoot.swift`, `PhoneAlbumBrowser.swift`, existing artist/album grouping in `Library.swift` | Tapping a resolvable artist opens albums and centers the origin once, including the first/last album; back navigation retains position |
| 6a | Shared addition metadata: `Track.swift`, `LocalCatalog.swift`, `CatalogDatabase.swift`, `ClusterChanges.swift`, import/sync boundaries under `headless/src/`, affected client decoders | New and legacy data have deterministic shared ordering; old signed changes remain verifiable; supported clients preserve metadata |
| 6b | Recently Added UI: `PhoneRoot.swift`, album ordering/presentation in `Library.swift` | Landing content and the new menu use shared addition order; ordinary Albums sorting and the playback queue are unaffected |

Packages 1, 4, and 5 are behaviorally independent. Package 3 follows the geometry
established by package 2. Package 6b depends on 6a; do not temporarily ship local
receipt time as shared addition time. Begin the 6a compatibility audit early,
but keep its migration separate from the visual changes. This dependency split
does not request parallel agents.

### Playback and save contracts

`Library.play` currently respects the persisted shuffle mode. Add an explicit
album-start operation only if existing public operations cannot express the
required behavior safely. Normal album Play starts in disc/track order; Shuffle
starts from the selected album's shuffled queue. Do not accidentally preserve
the old queue or always force its first track to be first. Test queue membership
and navigation behavior without asserting a particular random permutation.

Keep state presentation separate from transfer ownership. A row displaying an
album-owned request must describe any album-wide cancellation before applying it.
Use an indeterminate progress indicator when actual progress is unavailable.

### Recorded implementation decisions

- Shared addition order and moving an album forward when a new track is added
  are confirmed. Restoring an existing object retains its original date; legacy
  unknown dates remain absent.
- The field is optional and omitted for historical records. Historical signed
  fixtures still pass on Swift and Rust. Updated shared Rust decoders preserve
  the field; older Rust binaries require an upgrade for newly dated signatures.
- Artist names that resolve to one catalog artist can navigate directly. For
  `V.A.` or ambiguous credits, prefer a noninteractive label unless a real artist
  destination exists; do not split a collaboration name on punctuation.
- Keep the shuffle glyph consistent across platforms and document its licensed
  source and the narrow exception to the current Regen-only guideline.

### Verification and acceptance

Extend existing test suites rather than introducing a second harness:
`apps/macos/Tests/OfflineSaveTests.swift`, `CatalogMigrationTests.swift`, relevant
cluster persistence/transfer tests, `LibraryCheck.swift`, and the existing
`SyncstrUITests` fixture. Locate the existing image/Now Playing checks before
adding coverage for the artwork race. Run focused tests after each package.

For UI acceptance, use iPhone normal and larger text, iPad regular and compact
width, and macOS album detail. Check both light and dark appearances for changed
controls, long titles, no current track, playing/paused, all save states, and the
last list row above the mini-player. Native tab-bar layout owns production icon
alignment; do not recreate the static Figma tab bar as custom navigation.

Build iOS and macOS when shared Swift changes. Package 6a additionally runs the
affected headless/client checks and a two-device synchronization scenario with
delayed delivery and restart. Validate the migration on temporary catalog copies,
not the production library. Any production migration or distribution is a later,
separately authorized step.

The final physical-iPhone acceptance sequence is: launch into Recently Added,
open an album, start normal and shuffled playback, save/cancel/retry, scroll the
mini-player down and back, open artist details and return, lock the phone, change
tracks from the lock screen, and repeat saved playback offline after restart.
Record device/build identity and unresolved gaps; a build or Figma export cannot
substitute for this sequence.

Use focused tests for state and persistence contracts, simulator checks for UI,
and physical iPhone checks for lock-screen/background playback and motion.
Build, visual acceptance, main integration, push, and distribution are separate
delivery steps. Production migration and distribution remain outside this
implementation's delivery scope.

## Design validation

The composed proposal uses editable text, frames, instances, and vectors rather
than screenshots of an interface. Composition screenshots were inspected and
layout problems corrected. Motion was exported to MP4 and sampled at the start,
two intermediate moments, and the settled state. Native glass, actual scrolling,
VoiceOver, and physical-device behavior have not been validated by those artifacts.

## Implementation verification

- iOS and macOS builds passed. The existing appearance implementation is retained.
- iOS focused tests: 38 XCTest cases and 9 Swift Testing cases passed, covering
  artwork publication/clearing, album queue replacement, save behavior, catalog
  migration, signed changes, and recently-added persistence/order.
- Rust focused tests: 26 cases passed across cluster changes, client, remote,
  replication, node, and contracts. The additional host-time/restore regression
  passed; uploader dates are ignored and metadata edits/restores preserve time.
- Rust Clippy passed for the library with P2P enabled and warnings denied.
- iPhone UI test passed for action ordering/centering, save-menu availability,
  centered artist navigation, and moving the mini-player lower on scrolling.
  Captured screenshots confirm the native compact library/player/search row.
- iPad landscape UI testing passed for album actions, centered artist navigation,
  and retaining the floating mini-player. A narrow iPad window also passed the
  interaction test. Simulator screenshots of iPad windows were clipped, so full
  visual acceptance of the wide layout still requires a device or clean capture.
- Full Rust testing reached the existing LAN-discovery process suite, where
  `cli_enrollment_discovers_the_pinned_host_without_an_ip_address` and
  `separate_lan_hosts_catch_up_after_offline_import_and_restart` timed out.
  Direct network/sync tests passed. The first failure was also reproduced on
  unmodified main, confirming that this discovery timeout predates the patch.
  The full LAN process suite remains unresolved.
- Physical lock-screen presentation, audible/background playback, VoiceOver,
  actual-device motion, and macOS visual acceptance remain unverified.

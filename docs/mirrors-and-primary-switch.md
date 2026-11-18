# Mirrors and switching the primary host

Status: Proposed 2026-11-17 for ASO-172 (mirrors) and ASO-173 (switching the primary). Nothing here is implemented. This document authorizes no production operation.

[ADR 0008](adr/0008-one-primary-host-over-a-private-network.md) decided that a library has one primary, that mirrors copy it and accept no change, and that only the owner switches the primary. This document gives the rules behind that decision, including how the switch number stops two hosts from both accepting changes once they have met. [The host API design](host-api-design.md) defines every route, field, header, error, and timeout that these rules use, chiefly [library information](host-api-design.md#library-information-and-the-change-marker), [what a mirror needs beyond a device](host-api-design.md#what-a-mirror-needs-beyond-a-device), and the refusals in [changes from devices](host-api-design.md#changes-from-devices-come-later). No route changes a role or a switch record.

This document predates the access decision in [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md). Devices no longer pair or hold tokens. The tailnet policy decides which devices reach each host, and the [host API](host-api-design.md) has no device list. The rules below for roles, switch numbers, markers, pulls, and held copies still apply. Their parts about device tokens, device lists, pairing, and revocation do not apply to devices. How hosts identify each other, which this document builds on tokens of kind `host` (known hosts, `follow` with a pairing link, and revoking a retired host), is not decided. ASO-172 and ASO-173 redesign it on the tailnet before either is built.

## What this design leaves out

The old design let several hosts accept changes. To make them agree it needed signed records, membership proofs, an order among writers, and an activation journal ([the activation control protocol](v5-activation-control-protocol.md), [the cluster model](cluster-model-design.md)). The owner gave up simultaneous writers to remove that machinery. Three rules follow:

- No host signs anything for another host.
- No host waits for all the others, and there is no quorum.
- Only the owner's command, run on the machine itself, makes a host the primary. A host may stop accepting changes on its own when it learns of a newer switch. It never makes itself the primary.

The price is a window in which changes can be lost and a window in which two hosts can both accept changes. Each is stated where it arises.

## A mirror is a copy, not a second writer

A mirror is a backup, a full and verified copy ready to become the primary. It is also a second place to download from when the primary is asleep or away.

A mirror refuses every change, including one from the person at its own keyboard. It is not a history. It copies deletions, so a track removed by mistake on the primary disappears from the mirror at the next pull, and file-system snapshots must cover that need. A mirror holds the whole library, never a part. It follows the primary directly and never another mirror, because a chain would add up the delays and complicate the switch rules. A library can have any number of mirrors.

## What each host stores

Each host keeps these in the database that holds its catalog:

- **Library id.** Today `Store::open` in [`headless/src/store.rs`](../headless/src/store.rs) writes a random UUID when the `library` table is empty. A new mirror instead writes the primary's library id first, and no host pulls from a host with another library id. This check keeps a mirror pointed at the wrong host from deleting its copy.
- **Host id.** A random id the host creates once. Addresses change, so hosts are named by host id.
- **Switch record.** The switch number, the host id of the primary at that number, and the starting marker. The starting marker is the change marker that the new primary's copy equaled when it became the primary.
- **Role.** Primary, mirror, replaced, or retired.
- **Known hosts.** The host id, address, and role of each other host of the library. A host knows every host whose device token record has kind `host` in its device list.
- **Held copies.** Copies of the library that the host set aside when it stepped down or followed a new primary.

The [host API design](host-api-design.md#library-information-and-the-change-marker) defines the change marker and how markers are ordered.

A copy is **included** in a switch record when the copy's marker has the switch number and primary of the record's starting marker, and a revision no higher than the starting marker's. An included copy holds nothing that the new primary lacks. A copy that is not included may hold changes the library lacks. A host that missed two or more switches cannot tell, so it treats its copy as not included. The cost is a held copy with no differences, which the owner discards.

The switch number never decreases. A host writes a new switch record to disk before it acts on it, and checks its record in the same transaction that applies a change, so no change commits after the host stored a record that forbids it. The number rises only when the owner runs `take-over` or `promote`, and that host sets it to one more than the highest number it has seen.

## Roles and transitions

| Role | Accepts changes | Serves devices | Pulls |
| --- | --- | --- | --- |
| Primary | Yes | Everything | No |
| Primary, handing over | No | Everything | No |
| Mirror | No | Everything | From its primary |
| Primary or mirror, in conflict | No | Everything | No |
| Replaced | No | Library information only | No |
| Retired | No | Library information only | No |

"Handing over" lasts from `hand-over` until the mirror takes over. "In conflict" lasts until the owner switches again. The host API design gives both as the `condition` of library information.

| From | To | Cause |
| --- | --- | --- |
| Nothing | Primary | The owner creates a library or migrates a store (ASO-161). The switch number is 1. |
| Nothing or retired | Mirror | The owner runs `follow` with a pairing link for a host. |
| Replaced | Mirror | The owner runs `follow`. Its token is already in the new primary's device list, so it pairs again only if that token was revoked. |
| Primary | Handing over | The owner runs `hand-over` naming a mirror. |
| Handing over | Primary | The owner runs `hand-over --cancel` before the mirror takes over. |
| Mirror, or primary in conflict | Primary | The owner runs `take-over` (planned) or `promote` (after loss, or to end a conflict). |
| Handing over | Mirror or retired | It learns that the named mirror took over from its final marker. |
| Primary | Replaced | It learns of a higher switch number naming another host, in any other case. |
| Primary or mirror | In conflict | It learns of its own switch number with a different primary. |
| Mirror | Mirror | It learns of a higher switch number and follows the primary it names. |
| Mirror or replaced | Retired | The owner runs `retire`. |

A higher switch number also ends a stored conflict, so the rows for a primary and a mirror that learn of a higher number apply in conflict too. Retiring a host also means revoking its token on the primary, because a retired machine, such as a sold NAS, must not keep access to the library. The primary then drops it from the known hosts.

The command names are working names for `syncstr-headless`, and ASO-162 gives them screens in the macOS app. Every command runs on the machine itself and none is an HTTPS route, so a stolen device token cannot move the primary.

## Create a mirror

1. The owner creates a host code on the primary with `syncstr-headless pair --host` or in the macOS app.
2. On the second machine, the owner starts a host with `follow`, the pairing link, and the mirror's own host address, such as `https://mac.example.ts.net`, given with `--address`.
3. The mirror pairs with the primary as a device does (ASO-164). It creates its own token, and its record has kind `host`, so the owner sees it as a mirror and can revoke it.
4. The mirror reads the primary's library information. If its data directory holds another library, `follow` refuses and changes nothing. Otherwise it stores the library id, the switch record, and the primary's host id and address.
5. The mirror makes its first copy. Until that copy is whole, it serves its library information and the files it holds, and it answers a catalog request with `mirror-incomplete`, because a half-copied catalog would show devices albums with missing tracks.

A device token is per device per library, and every host accepts it. At every pull a mirror copies the primary's device list, which holds token hashes and never tokens. A device paired once therefore downloads from every host and keeps working after a switch without pairing again. The cost is that a revocation reaches a mirror only at its next pull, and that nobody can pair or revoke a device while the primary is unreachable, because both are changes. The first primary of a library also creates a token of kind `host` for itself, so every host holds a token that the others accept.

## How a mirror pulls

A mirror reads its primary's library information once a minute by default. When the primary's marker differs from its own, it pulls:

1. Check the library id and apply [the meeting rules](#meeting-another-host). If the primary's marker is older than the mirror's, stop and report it. The primary was restored from an older backup, and pulling would delete newer data.
2. Read the catalog, with its playlists and organization, and the device list.
3. List the audio and artwork files that the catalog references and the mirror lacks. If they do not fit in free space, stop. The catalog states each audio file's size, and `Artwork::validate` in [`headless/src/artwork.rs`](../headless/src/artwork.rs) limits an image to 512 KiB.
4. Fetch each file into `staging/`, artwork first because it is small, then audio. Resume an interrupted file with `Range`. If the primary no longer has a file, the catalog has moved on, so go back to step 2 and keep the files already fetched.
5. Compute the SHA-256 of each whole file and compare it with the catalog. Add a verified file to the store, audio to `objects/<sha256>.<suffix>` and artwork to the `artwork_assets` table as today. Delete a file that fails and fetch it again from the start.
6. Replace the catalog, playlists, organization, and device list in one SQLite transaction, and record the new marker. This publishes the copy.
7. Remove each audio object and artwork asset that the published catalog no longer references. [ADR 0006](adr/0006-preserve-source-track-identity-independently-of-audio.md) lets two library tracks share one audio object, so removing one track never removes audio that another still uses.

A mirror publishes a catalog only when every file it references is verified, so it always serves the primary's catalog at some marker, complete with its audio. Deletions and edits arrive as part of the next catalog. A mirror that was offline for any length of time starts again at step 1, fetches only what it lacks, and serves the copy it published last until it publishes again.

### Caught up

A mirror is caught up when, at its most recent read of the primary's library information, the marker it serves equals the primary's marker and its device list equals the primary's. A published catalog always has every file, so nothing else is needed.

The mirror records the time of the latest read at which it was caught up. That time says the copy holds every change the primary made up to then, even if the primary changed nothing for a week. Times come from each host's clock and are only shown to people. Hosts order states by marker, never by time.

If the primary is lost, every change it accepted after the mirror was last caught up is lost, unless the old primary comes back. With a mirror that keeps up, that is about the last minute of changes plus the time to copy new audio, so a large import stays at risk until its audio is copied. A mirror that was offline for a week leaves a week at risk.

## What a mirror tells a device

A mirror's library information tells a device which primary the mirror follows, when it was last caught up, and the primary's marker at its most recent read. Under one switch record, the difference between that marker's revision and the mirror's is the number of changes the mirror lacked at that read. The pull state, which is copying, caught up, primary unreachable since a time, or stopped with a reason such as a full disk, is shown on the mirror's own machine and is not part of the API.

A device keeps the newest catalog it has seen, ordered by marker, and never replaces it with an older one from a mirror. A lost connection must not empty the album list or make tracks look deleted. When a mirror is the newest host the device can reach, the device shows the copy's age and, if the mirror is behind, how many changes it lacks.

## Devices paired with more than one host

Library information lists the known hosts, so a device paired once learns about the mirrors. At each refresh, the device reads the library information of every known host, within the time limit that the host API design sets. It takes the catalog and downloads files from the primary when the primary answers, and otherwise from the mirror with the newest marker. The primary is never behind, and choosing once per refresh avoids a timeout on every download. The device verifies every file by its hash, so the source does not affect correctness. If no reachable host has a file, the track shows as unavailable.

When only a mirror is reachable, the device plays from it, shows that the primary is unreachable and how old the copy is, and disables changes because they need the primary. When two hosts both report that they are the primary, the device uses the higher switch number. With the same number, it shows a conflict and sends no change to either. [Onboarding and connection states](onboarding-and-connection-states.md#on-a-device) gives the wording.

In the first release a device makes no changes. Once it can (ASO-168), it sends a change only to the host that the newest switch record it knows names as the primary, and the change carries that switch number. A host applies the change only if it is the primary at exactly that number and is neither handing over nor in conflict. Otherwise it refuses and names the primary's address. A host never changes its switch record because of what a device sends, so a lost phone cannot stop the primary.

## Meeting another host

Hosts learn each other's switch records only by reading library information with their tokens of kind `host`. No request carries a switch record. Host X meets host Y when X reads Y's library information.

- A primary, also while it is handing over or in conflict, reads every known host when it starts and once per pull interval after that. At start it does this before it accepts changes, within the time limit of the host API design, so an old primary that comes back while the new primary is reachable steps down before it accepts a change. This is not a quorum. The host starts when the time is up, whatever it heard.
- A mirror reads its primary once per pull interval, as the first step of its pull. When its primary does not answer, or while the mirror is in conflict, it reads every known host instead.
- A replaced or retired host reads nothing.

When host X, at switch number n, reads a record with number n' from host Y:

- If n' is lower than n, X changes nothing. Y applies these rules when it reads X.
- If n' equals n and names the same primary, nothing changes.
- If n' equals n and names another primary, the owner made two primaries under one number. X stores the conflict and keeps serving what it holds. A primary stops accepting changes and a mirror stops pulling. The owner ends the conflict with `promote` on the host that should be the primary. X never picks a winner by host id or clock, because that would silently discard the other host's changes, which [the conflict policy](cluster-model-design.md#agreed-conflict-policy) forbids.
- If n' is higher than n, X writes the new switch record to disk, which also ends any conflict it stored. If X's copy is not included in the new record, X sets it aside as a held copy. A mirror then follows the named primary, whose address it finds among Y's known hosts. A primary handing over to the named host, whose final marker equals the starting marker, becomes what the owner chose at `hand-over`. Any other primary becomes replaced. If the record names X itself, X was restored from a backup older than its own switch, so it stops accepting changes and says so.

### Why two hosts cannot both accept changes after they have met

1. A host accepts a change only when its switch record names itself and it is neither handing over nor in conflict. It checks this in the transaction that applies the change.
2. A switch record names one host.
3. Only a primary accepts changes, and every primary reads every known host at least once per pull interval. When it reads a higher record it stores that record, and when it reads its own number with another primary it stores a conflict. So after two primaries have read each other, both hold the higher of their two records, or both hold the same number with a stored conflict.
4. With the same record, only the host it names accepts changes. With a stored conflict, neither does. So at most one of the two accepts changes.
5. This lasts. Numbers never decrease, records survive restarts, and only an owner command raises a number. That command names the host it runs on, and the other host learns of it at their next meeting.

### What can still go wrong before they meet

The switch number makes a divergence visible and stops it at the first meeting. It does not prevent it, because prevention would need every host to agree before a switch, and that is the machinery the owner gave up. Before two hosts meet:

- A primary that cannot reach the new primary, and that the new primary cannot reach, keeps accepting changes. In the first release that means the owner editing on that machine, and later also devices that reach only that host. Mirrors that still reach only the old primary keep copying it. At the first meeting these changes go into a held copy, kept but not in the library.
- Two mirrors promoted under one number both accept changes until they meet, which happens within one pull interval once both are reachable.
- A copy of a host's data directory started next to the original has the same host id and switch record, and these rules cannot tell the two apart.
- Two hosts never meet if neither holds the other's record of kind `host`. For example, mirror C pairs with A after mirror B's last pull, A is lost, and the owner promotes both B and C under one number. B cannot read C, and C gets 401 from B, so both accept changes until the owner notices. The copy report of `promote` lists only the mirrors that answered, which is the owner's chance to notice.

## The planned switch

A is the primary at switch number N and B is a mirror of A.

1. The owner runs `hand-over --to https://mac.example.ts.net --then mirror` on A, or `--then retire`. A refuses unless B reports that it is a mirror of A at N and is not stopped by a file that fails its hash. A then stops accepting changes and records its final marker, the named mirror, and the chosen result.
2. B pulls until it is caught up at A's final marker.
3. The owner runs `take-over` on B. B refuses unless A reports that it is handing over to B and B is caught up at A's final marker. B writes switch number N+1, itself as the primary, and A's final marker as the starting marker, then accepts changes.
4. A reads B within one pull interval. A's copy is included in B's record, so A becomes a mirror of B or retired, as chosen. As a mirror it reads B's catalog and fetches no audio.

| After | A | B | Accepts changes |
| --- | --- | --- | --- |
| Start | Primary at N | Mirror of A at N | A |
| Step 1 | Handing over to B at N, final marker fixed | Mirror at N, catching up | Neither |
| Step 2 | Same | Mirror at N, caught up at A's final marker | Neither |
| Step 3 | Same, until it reads B | Primary at N+1 | B |
| Step 4 | Mirror of B at N+1, or retired | Primary at N+1 | B |

Only A and B take part. Other mirrors of A learn of N+1 when they read A after step 4, or when A does not answer and they read B, and then follow B.

If the owner stops after step 1 or 2, no host accepts changes, A stays handing over across restarts, and devices keep playing. The owner continues with `take-over` on B, or goes back with `hand-over --cancel` on A. The cancel reads B's library information. If B is still a mirror at N, A accepts changes again. If B has taken over, the cancel refuses and A goes on to step 4. If B cannot be reached, the cancel refuses unless repeated with `--force`, and if B had in fact taken over, both accept changes until they meet.

If `take-over` cannot reach A, it refuses. The owner can wait or promote B. That promotion loses nothing if B is caught up at A's final marker, and A still becomes what the owner chose. After step 3, A is handing over and accepts nothing, so stopping there risks nothing.

## Promotion after the primary is lost

1. The owner runs `promote` on mirror B. B reads the library information of A and every known host.
2. If A answers, `promote` refuses and points to the planned switch, which loses nothing while A is alive. To promote anyway, the owner shuts A down first. On a host in conflict, `promote` skips this check, because the other primary answering is the reason for the command.
3. Before it changes anything, B shows a copy report. It gives when B last reached A, the marker B serves, when B was last caught up, and how many changes A had made beyond that marker at B's last read. For every other mirror that answered, it gives the marker and caught-up time, and warns when one is newer than B.
4. The owner confirms explicitly.
5. B discards its unpublished pull, writes switch number N+1 with itself as the primary and its own marker as the starting marker, and accepts changes.

Other hosts learn of N+1 when they read B or a host that knows it. Devices learn it from whichever host they reach and move to B without pairing again.

Promotion loses every change A accepted after B's starting marker, the pull B discarded, and device pairings and revocations made on A after B's last pull. A device token revoked in that window works again on B until the owner revokes it there. If A, or a mirror that copied A's later changes, comes back, those changes return in a held copy, not in the library.

## When the old primary comes back

When A starts again, it reads its known hosts before it accepts changes, so if B answers, A steps down before it accepts a change. If none answers in time, A starts as the primary at N, and the steps below happen at the first meeting.

When A learns of N+1 and its copy is not included in B's record, A sets the copy aside before anything else. It creates `held/<N>/` in its data directory, copies its catalog database there, and hard-links every audio object it holds. Hard links cost no audio space and keep the audio if the object is removed later. A then becomes replaced, with or without a held copy.

A replaced host sends no change to B and writes nothing into the library, so nothing on B changes. It refuses changes and serves only its library information. That information names B, so devices move to B.

On A, the owner can list a held copy. The list compares it with the current library, read from the primary, and shows the tracks, playlists, and organization that differ, with the path of each differing track's audio file in the held copy. To keep the changes, the owner adds those files on the primary in the usual way and redoes edits by hand. Otherwise the owner discards the held copy. Syncstr never merges a held copy by itself, because the owner may have changed the same tracks on B since. The owner can then run `follow` to make A a mirror of B, or `retire`. Neither touches `held/`.

A mirror whose copy is not included in the new primary's record sets it aside the same way before it follows. This happens when the owner promoted a mirror that was further behind than another one.

## Failure cases

| Case | What happens | What the owner sees |
| --- | --- | --- |
| A mirror is offline for a long time | On return it reads the current catalog, fetches only what it lacks, and removes what the primary removed. It serves its old copy until it publishes. | The copy age and the pull's progress. |
| A file fails its hash | The mirror fetches it again. After a second failure it stops the pull, keeps serving its last copy, and retries at every pull. It never publishes a catalog without that file, so a promotion cannot silently lack it. The cost is that the copy ages, and the changes at risk grow, until the owner acts. `hand-over` refuses meanwhile. | The track and both hashes. The same wrong bytes twice usually mean the file is damaged on the primary. Once the owner adds the audio again there or removes the track, the pull goes on. |
| The mirror's disk is full | It checks free space before it fetches. If the disk fills anyway, it deletes its staged files and publishes nothing. It serves its last copy and retries at every pull. | The space it still needs, and the copy age. |
| Two hosts both believe they are the primary | With different numbers, the lower one sets its copy aside if needed and becomes replaced at the first meeting. With the same number, both stop accepting changes. Until they meet, both accept changes. | The conflict, on both hosts and on devices. The owner runs `promote` on the host that should be the primary. |
| A device holds a token for a retired host | The retired host serves only library information, which names the current primary. The device moves there, and its token works because tokens are per library. If the retired host is gone, the device uses the other hosts it knows. | With no reachable host, the device shows the "host unreachable" state of [onboarding](onboarding-and-connection-states.md#on-a-device). Offline saves keep playing. |
| A host is restored from an older backup | A restored primary at the same switch number has an older marker, so its mirrors stop pulling and keep their copies. A host restored from before a switch has a lower number and follows the meeting rules. | Both markers. The owner stops the restored primary and promotes the newest mirror, or runs `follow` on the mirror again, which first sets its newer copy aside. |
| A mirror is pointed at another library | `follow` or the pull refuses because the library ids differ. Nothing is removed. | Both library ids. |
| A device is lost while the primary is unreachable | Nobody can revoke its token, because a revocation is a change. | The owner stops the mirrors, or promotes one and revokes the token there. |

## What to test

The tests run two or three hosts on loopback addresses with short intervals, so CI runs them without mDNS or a LAN.

- A new mirror answers a catalog request with `mirror-incomplete` until its copy is whole, then serves the primary's catalog at the same marker with files that match their hashes.
- A mirror stopped while the primary adds, edits, and removes tracks catches up after it restarts. Removed audio is gone, audio shared with a remaining track stays, and no file it held is fetched again.
- A file with wrong bytes twice leaves the mirror serving its previous copy and reporting both hashes. A full disk leaves the previous copy in place too. Both pulls finish once the cause is gone.
- A mirror refuses every change and names the primary's address, and `follow` against another library removes nothing.
- In a planned switch, A refuses changes after `hand-over`, and `take-over` refuses while B is behind. After `take-over`, B accepts changes, and A refuses them and becomes a mirror with an equal catalog. `hand-over --cancel` reopens A after step 1 and refuses after step 3.
- `promote` refuses while A answers. With A stopped, it reports the copy age, and B accepts changes after confirmation.
- A, cut off from B while it accepts one change, becomes replaced at the first meeting, keeps that change in `held/`, and leaves B's catalog unchanged. An old primary that starts while B is reachable refuses its first change.
- Two mirrors promoted under one number both refuse changes after they meet, and `promote` on one makes the other replaced.
- A replaced host and a host in conflict keep their state after a restart. A lower switch number changes nothing. No change commits after a higher record is stored, even when the two race.
- A device paired once downloads from the mirror while the primary is stopped, keeps its newer catalog when the mirror is behind, and uses the new primary after a switch without pairing again.

## Open questions

- The macOS app's screens for these commands and held copies, and how the owner confirms a promotion. ASO-162.
- Whether the 1-minute pull interval and the retry counts need to change. Whether a mirror keeps removed files for some days against mistakes on the primary. Whether a host checks its own files on a schedule, since a damaged file is noticed only when a mirror or a device fetches it. ASO-172.
- Whether the owner needs a command that exports the differing tracks of a held copy as tagged files, whether re-adding from a held copy should keep library track ids, as [ADR 0007](adr/0007-preserve-track-addresses-when-sharing-audio.md) keeps track addresses, and the final command names. ASO-173.

Other documents answer the earlier questions. The host API design names the fields and headers and has a change carry its switch number in `If-Match`. How a headless mirror proves itself to the primary when it starts with `follow` is open again, as the note at the top says. The [migration plan](private-network-migration-plan.md#what-the-store-keeps-besides-the-library) says where the store keeps the host state and how the owner's store starts at switch number 1. [Onboarding and connection states](onboarding-and-connection-states.md#connection-states) gives what a device shows.

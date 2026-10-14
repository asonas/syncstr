# Cluster-aligned library interaction specification

Status: accepted. Q1–Q24 and the consolidated specification are confirmed. Application implementation has not started.

## Goal and scope

Listeners browse, play, and save music without routinely reasoning about connections between macOS, iPhone, and library hosts. Both Apple apps present one library and select authorized sources automatically, following the [cluster model](cluster-model-design.md).

Design both platforms together; delivery may be split by platform. Include daily playback and saving, initial entry, existing setup and diagnostics, legacy-flow relocation, and corresponding product documentation. Compilation metadata repair, idle-player simplification, and artist-list overlap remain separate work. New GUI cluster creation and library-host role assignment are also separate work.

## Evidence and current gap

The review captured six states in the running macOS app: albums, album details, legacy iPhone transfer, empty search results, artists, and tracks. Its executable and correspondence with main were not verified. These observations are not acceptance evidence for a new build.

Source inspection at `04ad188` found that macOS retains legacy transfer after enrollment; shared setup mixes invitations, legacy P2P, hosts, connection paths, and library actions; some iPhone empty/error states still require a Mac. Disconnected iPhone album saving can offer legacy pairing while track saving accepts retained membership. Shared playback requires local audio and otherwise asks the listener to connect to a Mac. Automatic source selection and local-copy removal exist; album-level save removal does not.

Sources: [macOS UI](../apps/macos/Syncstr.swift), [Settings](../apps/macos/SettingsView.swift), [setup](../apps/macos/PeerSetup.swift), [legacy setup](../apps/macos/LocalSetup.swift), [transfer](../apps/macos/LocalTransfer.swift), [playback](../apps/macos/Library.swift), and [iPhone UI](../apps/ios/Sources/PhoneRoot.swift). Recheck current code before implementation.

Compilation fragmentation and missing artwork belong to the existing data-repair work, not a visual redesign. Preserve the clear navigation, playback hierarchy, search feedback, and full accessibility labels observed. The idle player's disabled controls and its overlap with lower artist names are deferred observations; last-row reachability was not verified.

## Surface responsibilities

| Surface | Required behavior |
| --- | --- |
| Initial entry | Offer joining an existing library and adding music for local playback. Local playback does not require enrollment. Import does not implicitly assign the library-host role. |
| Daily library | Keep the retained catalog visible regardless of host connectivity. Remove Mac-to-iPhone transfer from daily navigation. Do not require host selection. |
| Track and album actions | Provide playback, explicit local save, and save removal on both platforms. Show preparation, saving, saved state, waiting, partial results, and actionable failures near the operation. |
| Settings | Organize existing enrollment, hosts, connection diagnostics, membership management, conflicts, and communication policy. Keep legacy transfer accessible for existing users. |
| Storage settings | Configure the playback-cache limit, default 10 GB. Show cache usage and explicit offline-save usage separately. This is not a total audio-storage limit. |

Future cluster creation and host-role controls belong in Settings, but creating those controls is outside this delivery. Preserve existing invitations, registrations, and saved audio without forced re-enrollment. Align README and relevant setup documentation with the same model.

## Audio retention

Use [Playback Cache and Offline Save](../GLOSSARY.md) consistently.

| Category | Retention |
| --- | --- |
| Playback cache | Automatically acquired for listening; eligible for automatic eviction. Does not imply an explicit offline save. |
| Explicit offline save | Protected until manually removed; excluded from automatic eviction and the cache budget. |
| Pre-upgrade saved audio | Preserve as protected audio. Do not infer that it is disposable cache. |
| Original import sources and library-host copies | Outside playback-cache eviction. Existing source and host-storage policies remain authoritative. |

Evict eligible cache by oldest last-played time, using acquisition time for never-played tracks. Exclude currently playing and acquiring tracks. A single track larger than the limit may temporarily exceed it for playback if device space permits; remove that cache after playback ends. Explicitly saving the track protects it under the offline-save contract.

If device free space prevents downloading, explain the capacity failure. Never evict protected audio to make room. Reuse verified local audio when possible; saving an already cached track must grant protection rather than leave it eligible for eviction.

## Playback transitions

| Event | Result |
| --- | --- |
| Play with valid local audio | Play without requiring connectivity. |
| Play without local audio | Automatically choose an available authorized source. Acquire and verify the whole track, showing preparation and cancellation; start only if the request is still current. |
| Cancel or select another track | Supersede the old request. Late acquisition completion must not start its track. |
| Acquisition fails or no source is available | Stop at that track, explain the reason, and offer manual retry. Do not skip automatically or start unexpectedly on reconnection. |
| Queue advances normally | Acquire the next requested track as needed under the same policy. |

Explicit track, album, and queue playback authorize necessary acquisition over cellular. Do not download an entire album ahead of playback. Unrelated automatic audio transfers remain Wi-Fi-only by default unless opted in. Progressive playback is deferred until whole-file startup latency is measured; do not describe this first version as streaming.

## Offline-save transitions

| Event | Result |
| --- | --- |
| Save a track or album | Request protected local audio without selecting a host. |
| No source available | Retain the request, show connection waiting and cancellation, and resume when possible. |
| Communication policy requires Wi-Fi | Show Wi-Fi waiting. Pending saves resume under the existing cellular policy. |
| Restart | Restore pending requests and completed results. This does not promise execution while the app is suspended. |
| Partial failure | Preserve successful tracks; show completed/total counts and retry unfinished items only. |
| Cancel saving | Stop remaining acquisition without undoing completed saves. |
| Remove a save | Delete its managed local copy to reclaim space rather than merely converting it to cache. Confirm the interruption if the affected track is playing. |

Album saving covers tracks present at the time of the request. Later additions do not automatically download; show partial save and let another Save request acquire missing tracks without downloading saved tracks again.

Save removal preserves shared-library items, other devices' copies, and original import sources. Later playback may reacquire audio. It is separate from host-authorized cluster deletion. Apply consistent membership and availability rules across both platforms and track/album actions.

## Implementation work packages

1. **Retention and migration:** distinguish cache and protected saves, conservatively migrate existing audio, and implement accounting, limits, and eviction.
2. **Playback acquisition:** use authorized source selection and verified acquisition; handle request supersession, preparation, cancellation, failure, and cellular queues.
3. **Save lifecycle:** persist intent and partial results; align track/album actions and implement retry, cancellation, protection, and removal.
4. **Apple UI and documentation:** apply the common model, relocate legacy transfer and diagnostics, expose storage settings, and align initial entry and product explanations.

Reuse existing persistence and transfer boundaries where suitable. Schema details, scheduling, and numeric-setting validation are implementation decisions constrained by these contracts. Reopen a product question only when implementation evidence requires a different observable behavior.

## Acceptance scenarios

Verify shared behavior and both platform interfaces. Record the actual executable/build and distribution variant. Builds alone do not prove UI correctness or audible playback.

| Scenario | Required result |
| --- | --- |
| Upgrade | Preserve registrations and old saved audio; no forced re-enrollment or automatic eviction of old saves. |
| Fresh local-only use | Import and play without enrollment or implicit host assignment. |
| All hosts offline | Retain catalog; play local audio; unsaved playback reports failure and manual retry. |
| One of several authorized sources fails | Acquire from an available source without prompting for a host. |
| Cancel preparation or switch tracks | Late completion never starts a cancelled or superseded track. |
| Cellular album/queue playback | Acquire as needed while unrelated automatic transfers retain Wi-Fi policy. |
| Cache exceeds budget | Evict least recently played eligible cache; protect saves, active transfers/playback, originals, and host copies. |
| Oversized track or insufficient device space | Apply the temporary exception and cleanup, or report capacity failure without deleting protected audio. |
| Save a cached track | Protect it against subsequent cache eviction. |
| Save offline, restart, reconnect | Preserve intent and results; resume under communication policy with accurate waiting feedback. |
| Partial album save, cancel, retry | Preserve successes, report counts, and acquire only unfinished tracks. |
| Album gains a track | Show partial save; download the addition only after an explicit Save request. |
| Track/album save removal | Reclaim managed local storage, confirm playback interruption, and preserve shared audio and originals. |
| Normal/narrow layouts on both platforms | Daily tasks need no Mac/host selection; settings and legacy access remain reachable. |
| Keyboard and accessibility | Names, focus order, progress/errors, save state, and cancellation are usable without relying on color alone. |

Use disposable catalogs for migration, capacity, cancellation, and removal checks. Report physical-device playback, actual cellular behavior, deployment, and production-data repair separately from automated checks.

## Decision closure

Q1–Q24 are resolved. Q10 was refined by Q13–Q16: the setting limits cache only, protects explicit saves, and defaults to 10 GB. Q20 was bounded by Q24: local-only entry and existing enrollment are included; new GUI cluster creation and role assignment are deferred.

The listener confirmed this consolidated specification as the shared understanding. Implementation, commits, main integration, push, deployment, and production-data repair remain separate actions.

## References

- [Cluster product model](cluster-model-design.md)
- [Apple integration and verification limits](cluster-apple-m3.md)
- [Retention decision](adr/0005-distinguish-playback-cache-from-offline-saves.md)
- [Platform design guidance](../DESIGN.md)

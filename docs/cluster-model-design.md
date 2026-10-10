# Cluster model discussion

This document records agreed product behavior from the design interview, not a claim of existing support. See [the implementation plan](cluster-implementation-plan.md) for the current source audit, technology comparison, proposed milestones, and unresolved technical details.

## Agreed product direction

- Syncstr playback applications run on iPhone and macOS, with Android and Windows planned. Headless Syncstr stores and supplies music without playback.
- A listener's cluster may contain multiple library hosts and playback devices. Library hosting is a storage role rather than a separate application type: a Windows desktop with ample storage can supply music to an iPhone or Mac, and can coexist with a NAS running headless Syncstr.
- Storage-constrained devices need not retain the full library. Devices should be able to exchange music, including host-to-host and host-to-playback-device transfers.
- Authorized devices on the same LAN should discover and communicate locally without external services or router port configuration. Sharing a LAN does not itself authorize music access.
- Remote access initially targets available library hosts. Supporting services are optional and user-operated, potentially on a separate reachable server. Syncstr's operator provides no central server dependency.
- Prefer direct transfer, with automatic encrypted relay fallback when configured. Remote-access setup should avoid manual router port configuration.

## Working terminology

Cluster membership describes a group of authorized devices rather than physical network location. Taking a phone outside the LAN changes its connection path, not its membership. Library hosts can also support playback; a relay or directory is a supporting service, not automatically a library host or a cluster member authorized to read music.

## Unresolved decisions

- Concrete conflict cases, detection, presentation, and application of user resolutions will be specified during implementation under the agreed conflict policy.
- The protocol for propagating and reconciling cluster membership and revocations.
- How catalogs, file availability, and successful durable storage are reconciled. Gossip is a suggested candidate for propagating state, not an accepted protocol choice or proof that audio has been replicated.
- Which user-operated services provide discovery, connection coordination, and optional relay, and how they are deployed and verified.

## Agreed storage policy

Every library host aims to retain the complete cluster library. An offline or capacity-constrained host is incompletely synchronized rather than silently assigned a smaller library; devices intended to retain only selected music use the playback-device role without the library-host role.

Importing music on any device automatically schedules storage on library hosts. The importing device retains its copy while hosts are unavailable. Once at least one library-host copy of each affected item is confirmed, ask whether to retain or remove the importing device's local copies, grouping the question by import operation rather than by track. Identify the confirmed host and any outstanding host replication; retain the copies until the user answers. Upload completion alone must not trigger automatic deletion. Removal applies only to Syncstr-managed local copies, never the original import source files.

Removing a local copy and deleting music from the cluster library are separate actions. Removing a playback device's local copy frees its storage without deleting host copies. Initially, only library hosts may initiate an explicit cluster-wide deletion; a playback device without the library-host role may remove only its local copies. Retain and share deletion records so an offline host applies deletions on reconnect rather than reintroducing its stale copies as newly imported music. Restoring the same audio requires an explicit user re-addition; a conflicting deletion and re-addition follows the user-resolved conflict policy below.

## Agreed library presentation

Present one cluster library rather than separate libraries for each host. Replicas of the same track on multiple hosts appear as one library item, and retrieval automatically selects an available source without requiring the listener to choose a host for each operation. Initially, merge replicas only when their complete file contents match. Different encodings, masters, or tag-modified files remain distinct even when their titles match; do not infer audio equivalence or discard variants automatically.

Keep previously received library information visible when all hosts are offline. Locally saved music remains playable; unsaved music reports that no source is currently reachable. A disconnection must not clear the album list or imply that tracks have been deleted.

## Agreed conflict policy

When a conflict is detected, warn the user, preserve the competing data and intentions until resolution, and let the user choose which to prioritize. Do not silently choose a winner by device wall-clock time, device role, or a blanket deletion-wins rule. This principle includes competing metadata edits and conflicting deletion/re-addition operations; individual cases and their resolution interfaces will be specified during implementation rather than exhaustively decided in this interview. Nonconflicting synchronization and playback continue while conflicts await resolution.

## Agreed cellular-data policy

On cellular networks, allow downloads explicitly requested by the user, but pause automatic audio transfers by default until Wi-Fi is available. Provide an opt-in setting for automatic transfers over cellular. This policy does not itself promise background execution on any platform.

## Agreed membership and initial verification scope

Enrollment approved by one library host authorizes the device across the cluster, without pairing separately with every host. Initially, library hosts issue invitations and revoke device membership, and propagate those decisions to other hosts. An offline host learns of revocation only after reconnecting and receiving the update.

The first implementation milestone includes two headless library hosts. Verify that music added to either host is replicated to the other and that a playback device can retrieve already-replicated music while one host is unavailable. This verification does not depend on completing the Windows application.

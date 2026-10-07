# Syncstr product specification

Syncstr lets people listen to their own audio files with a consistent experience across devices and operating systems. The current implementation supports macOS and iPhone without a hosted service, server account, or Internet connection during playback.

## User journey

1. Install Syncstr on a Mac and an iPhone.
2. Select the Mac folder containing DRM-free audio. Read tags and artwork without changing originals.
3. Open **Transfer to iPhone** on the Mac, with both apps on the same local network.
4. Select the Mac on the phone and scan its QR code or enter its pairing code.
5. Approve the phone on the Mac before exposing the catalog or files.
6. Save an album to the phone. Display transfer progress and allow cancellation and retry.
7. Close the Mac app, restart the iPhone app offline, browse the stored catalog, and play received audio.

No login or alternate server connection is part of onboarding. macOS Settings selects or changes the source folder. iPhone Settings manages pairing and can return to Mac discovery while retaining received files.

## Domain and storage

- **Source folder:** A user-selected Mac directory, read through a security-scoped bookmark.
- **Catalog:** A persisted library identity, track metadata, audio hashes, and artwork.
- **Track:** One indexed audio file. IDs derive from library identity and relative path; SHA-256 identifies the audio version.
- **Pairing:** Explicit Mac approval of a phone with a shared key retained in each device's nonsynchronizing Keychain.
- **Received audio:** A durable phone copy published only after exact size and SHA-256 verification. Partial staging files never count as available tracks.

The Mac plays originals directly. The iPhone plays received files and restores its catalog without contacting the Mac. A source deletion or tag edit does not remove completed phone copies. The transfer protocol and format limits are defined in [local music transfer](local-music-transfer.md).

## Playback and interface

Both apps browse albums, artists, and tracks and provide search, previous/next, pause/resume, seeking, and continuous playback in a queue. Album playback orders tracks by disc and track number. Search and navigation do not change the active queue. Playback stops after the final track and can restart it.

iPhone supports background audio and lock-screen controls. Saved and unsaved tracks are distinguishable. Unsaved tracks require a transfer before playback; there is no streaming fallback.

Follow [DESIGN.md](../DESIGN.md) for native platform controls, layout, colors, and accessibility. Use platform APIs for file authorization, playback, discovery, and camera access.

## Trust and execution

Discovery is Bonjour on the LAN. Transfer uses authenticated TLS with a random pairing key and first-connection approval. Never advertise the key, accept client filesystem paths, or send a catalog before approval. Revocation closes connections and removes the pairing key while retaining received audio.

Keep both apps available during transfer. Retrying skips verified completed tracks and restarts an interrupted file. There is no Internet rendezvous, relay, NAT traversal, or background transfer service.

## Acceptance and evidence

The user confirmed transfer from Mac to iPhone followed by offline cold-launch playback after closing the Mac through TestFlight on 2026-10-07. This establishes that journey for the tested build. Later changes need regression verification.

Automated checks cover TLS loopback pairing and authorization, indexing, original preservation, integrity, retry, catalog restoration, and real AVPlayer behavior. TestFlight distribution, visual checks, permissions on real devices, audible output, locked-screen behavior, and interruption recovery are separate evidence.

## Deferred work

Windows and Android clients, transfers outside the LAN, multiple peers, playback-state synchronization, playlists, favorites, metadata editing, Music XML migration, gapless playback, and compatibility transcoding are future product decisions. Earlier plans in [plans/](plans/README.md) preserve investigation history and do not impose server requirements on this implementation.

The application license remains undecided. Retain bundled dependency notices and select a license before an open-source release.

# M5 Android playback client

Status: first Android LAN playback slice accepted. Windows remains a subsequent slice.

## Initial scope

Enroll on the LAN using the existing expiring single-use invitation. Discover
library hosts with Android network service discovery using the existing
`_syncstr-cluster._udp` contract. Display the verified cluster library, explicitly
download selected originals, and play saved audio after an application restart
without network access. Do not replicate the entire music collection to a phone.

Use a native Kotlin Android interface and playback lifecycle. Reuse the Rust
membership, signed history, SHA-256 transfer verification, and SQLite state
through a concrete playback-client boundary. The existing Apple clients keep
their current implementation; no speculative cross-platform rewrite is needed.
The native client receives key material from Android secure storage instead of
persisting a plaintext device key or a consumed invitation secret.

## Agreed verification boundaries

The user agreed to test actual enrollment, catalog synchronization, and selected
audio transfer against headless components, followed by Android storage,
application restart, and offline playback. Test doubles are limited to external
boundaries; internal calls and implementation order are not assertions.

Start with enrollment and catalog restoration without an audio download. Then
verify selective download, integrity and retry, and add the Android integration
and playback checks. Preserve existing membership rejection, revocation and
conflict behavior. A build alone is not device acceptance.

## Acceptance

- A LAN invitation enrolls a playback device and is consumed once.
- A headless library is discovered without a manually entered IP address.
- Remote catalog synchronization does not automatically download every object.
- Explicit download verifies the original and makes it available for playback.
- Enrollment, catalog and saved music survive restart; saved music plays offline.
- Existing Apple and headless protocol checks continue to pass.

Android screen operation and real audio output must be verified on an Android
device or an explicitly identified emulator. M4's iPhone results do not prove
Android behavior. Store distribution and Windows UI are outside this first slice.

## Verification record

The ARM64 development APK and separate instrumentation APK were built with
Java 21, Gradle 8.13 and AGP 8.13.2. Android Lint passed; ChromeOS ABI coverage
and string-resource extraction remain outside this initial ARM64 slice.

On a physical Android 16 ARM64 device, the instrumentation check discovered a
real headless host through Android NSD, redeemed a playback invitation, fetched
the catalog without fetching the original, and explicitly downloaded a verified
MP3. Android MediaPlayer prepared it and its playback position advanced. A
second instrumentation process restored the catalog and verified saved audio,
then played the local original without invoking network operations.

The first physical download reproduced a native stack overflow in the transfer
future. Moving the 64 KiB receive buffer to the heap made the same physical
download and playback check pass.

The user subsequently disabled Wi-Fi and mobile communication, ended and
reopened the installed application, selected the saved fixture through its
screen, and confirmed audible playback. Enrollment, catalog and audio survived
the restart. No APK has been distributed through a store, and Windows is not
implemented here. Android remote access and QR scanning remain subsequent work.

Review follow-up checks cover a conflicting album without blocking unrelated
music and retrieval from a second authorized host when the first lacks the
original. The Android screen displays missing artist metadata safely after
refresh and restart. The updated APK preserves the previously enrolled identity
and saved audio; the separate-process local playback check was repeated after
the review fixes. Discovery startup and shutdown callbacks share the main thread
and a delayed start honors a prior stop request.

Further Android UI work moves to a Windows workstation; see the
[development handoff](android-ui-development-handoff.md). Native Windows client
implementation has its own [handoff](cluster-windows-m5.md).

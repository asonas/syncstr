# Syncstr

Terms for organizing owned music and making it available across a listener's devices.

## Language

**Library Track**:
A separately retained track in a listener's library, independent of its title or audio encoding. Separate source registrations remain separate library tracks, even when their audio is identical; different releases and versions remain distinct.
_Avoid_: Audio file or song title as a synonym for track identity

**Audio Copy**:
One file containing audio associated with a library track. A track may have multiple encodings or copies; sharing identical file content does not merge separate library tracks.

**Shared Audio**:
Identical audio-file content used by more than one library track. Each track retains its own identity, metadata and album membership.

**Source Track Reference**:
A reference to a track registration within a particular source library. It distinguishes separate registrations without depending on filenames or matching titles.

**Track Correspondence**:
A retained, evidenced relationship between a source track registration and a Syncstr library track. It can be reused when importing playlists or revisiting an earlier import.

**Album**:
One released or distributed edition of a collection of tracks. Different editions are distinct albums; multiple discs belonging to the same release form one album.
_Avoid_: Album title as a synonym for album identity

**Syncstr Album ID**:
The stable identifier of an album within Syncstr, independent of its name, artist credits, or location. It follows the album when transferred between devices.
_Avoid_: External release ID when referring to Syncstr's own album identity

**External Release ID**:
An identifier assigned to a release by an external catalog, interpreted together with its source. It is evidence for identifying a release, not the album's identity within Syncstr.
_Avoid_: Album ID without a qualifier when discussing external identifiers

**Compilation Album**:
A multi-artist collection released or distributed as one album, including a label compilation or multi-artist soundtrack. A listener's personal selection of existing tracks is a playlist instead.
_Avoid_: Playlist when referring to a released compilation album

**Track Artist**:
The artist or artists credited for an individual track. Different tracks on the same album may have different track artists.

**Album Artist**:
The artist credit for an album as a whole, when one is supplied. An absent album artist does not imply a credit of Various Artists.

**Album Membership**:
The relationship identifying which album a track belongs to, independently of the track's artist credit.

**Compilation Status**:
An assertion that music belongs to a compilation, does not belong to one, or has no known classification. Conflicting assertions from different tracks remain distinguishable.
_Avoid_: Non-compilation when the classification is merely unknown

**Imported Metadata**:
Information obtained from music files or a source music library, with its origin retained. It remains distinguishable from the listener's explicit organization choices made in Syncstr.

**Source Library Metadata**:
Track and album information held by the music library being migrated, including edits made there. It may differ from metadata embedded in the audio file.

**Eligible Migration Track**:
A personally imported or purchased track, including a matched or uploaded cloud copy, whose origin is established and whose audio is available without protection preventing transfer. Subscription-catalog entries and unresolved cases are outside this set.

**Cloud-Retrieved Copy**:
An audio file obtained from the listener's cloud library for an eligible track. Its encoding and quality may differ from the listener's original file.

**User Override**:
An explicit listener choice that takes precedence over imported metadata until the listener removes it.

**Playlist**:
A listener's selection of tracks that retains each track's original album membership.

**Playback Queue**:
The device-local ordered sequence of tracks selected for a listening session. Browsing or changing search results does not alter an already established queue.
_Avoid_: Playlist when referring to the active playback sequence

**Playback Attempt**:
One request to play a track, including the audio-source candidates and automatic retries needed to fulfill that request. A listener's manual retry starts a separate attempt linked to the preceding one.
_Avoid_: Connection attempt when referring to the complete playback request

**Album Artwork**:
The image used to represent an album. It may come from a participating track, an album image file, a music library, or an explicit listener choice; it does not establish album membership.
_Avoid_: Album identity

**Embedded Artwork**:
An image stored inside an audio file, independently of images associated with the same track by a music library.
_Avoid_: Every image shown by a music player

**Sync Conflict**:
Competing changes within a cluster that cannot be reconciled without choosing which data or intention takes precedence. The listener resolves the conflict by choosing what to prioritize.

## Device connectivity

**Cluster**:
A listener-managed group of Syncstr devices that share music through authorized relationships. A device remains part of its cluster when it moves between networks.
_Avoid_: LAN as a synonym for cluster membership

**Library Host**:
A device assigned to retain the complete cluster library and supply music to other devices, referred to as a mother ship in product discussions. A cluster may contain multiple library hosts, and a host may support playback or temporarily be incompletely synchronized.
_Avoid_: Headless Syncstr as a synonym for the library host role

**Playback Device**:
A Syncstr device used to listen to music, which may retain only part of the available library. A playback device may also act as a library host.

**Playback Cache**:
Audio retained on a playback device as a result of listening, which may be evicted and acquired again. Its presence does not mean the listener explicitly saved the music for offline use.
_Avoid_: Offline Save when referring only to automatically cached audio

**Offline Save**:
Music the listener explicitly chooses to retain on a device for offline playback until they remove that save. Removing an offline save does not delete music from the shared library or the original import source.
_Avoid_: Cluster deletion when referring to removal of a device's saved copy

**Headless Syncstr**:
The form of Syncstr that stores and supplies music without playback functionality.

**Remote Access**:
Access to a listener's music from outside the library-holding device's local network. It is an optional capability supported by infrastructure supplied by the listener.

**Device Pairing**:
The explicit authorization relationship that allows Syncstr devices to share music. Discovering a device or knowing its connection information does not by itself establish this relationship.

**Pairing Invitation**:
An expiring, single-use authorization to enroll a device in a listener's Syncstr installation. It is distinct from connection information, which alone grants no access.

**Peer Directory**:
The service through which Syncstr devices find a peer's current connection information. It is distinct from the service that carries relayed music transfers.
_Avoid_: Relay when referring only to finding a peer

**Transfer Relay**:
An intermediary carrying end-to-end encrypted communication between Syncstr devices when needed for connectivity. It is distinct from a library-holding device that supplies music.
_Avoid_: Music library server when referring to the transfer intermediary

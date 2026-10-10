# Syncstr

Terms for organizing owned music and making it available across a listener's devices.

## Language

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
Information read from the original music files. It remains distinguishable from the listener's choices about how to organize the music.

**User Override**:
An explicit listener choice that takes precedence over imported metadata until the listener removes it.

**Playlist**:
A listener's selection of tracks that retains each track's original album membership.

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

# Syncstr overview

Scope note (2026-11-06): this overview records the earlier local-transfer product. Its platform, native-integration and remote-access limitations are historical. See [current implementation](../README.md#current-implementation), the [cluster model](cluster-model-design.md), and the [v5 design draft](v5-completion-design.md) for the later direction and remaining work.

Syncstr is a native player for audio files you own. Select a music folder on a Mac, pair an iPhone on the same local network, and copy albums to listen offline. Users do not administer a server or create an account.

The Mac reads the original files without editing them. The phone retains its own verified audio, catalog, and artwork and can restart without the Mac or a network connection. Pairing requires a code or QR scan and explicit approval on the Mac.

macOS and iPhone are the current platforms. Windows, Android, playback-state synchronization, and transfers outside the LAN are deferred. See the [product specification](design-spec.md), [transfer contract](local-music-transfer.md), and [source map](../README.md#code-and-documentation-map).

The next product direction allows users to add music from any device and collect those originals on an always-on NAS running headless Syncstr. Devices do not have permanently assigned source or receiver roles. The NAS provides an always-available copy, rather than being the only place from which music can be added. The [headless node and CLI](../headless/README.md) implement authenticated HTTPS uploads, a persistent catalog, and downloads. Native app integration, automatic collection, cross-platform clients, and remote connectivity remain pending. The SQLite catalogs do not introduce distributed catalog editing or deletion propagation.

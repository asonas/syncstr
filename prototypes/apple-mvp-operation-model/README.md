# Apple MVP Operation Model Prototype

Throwaway prototype for comparing three structural approaches to the Apple client.

Run from the repository root:

```sh
python3 -m http.server 4173 --directory prototypes/apple-mvp-operation-model
```

Then open `http://localhost:4173/?variant=A`. Switch variants with the floating controls or the left and right arrow keys.

This prototype is read-only, stores no data, and is not production code.

## Decisions represented

- Variant A, Library first, is the selected foundation.
- Closing the macOS sidebar preserves the current destination.
- The mini player opens Now Playing in the same window.
- Albums are the default library view; search remains globally available.
- The iPhone tabs are Library, Search, Now Playing, and Settings.
- Favorites are binary and start empty. There is no active five-star rating state.
- Imported Music/iTunes ratings remain in an immutable Imported Metadata Snapshot and do not initialize favorites.
- Downloads are explicit and protected from automatic cache cleanup.
- Playback queues are device-local. History is read-only in the MVP.
- Offline is a normal state. Cached library data opens immediately.
- Removing a download affects only the device. The Apple client cannot delete the NAS original.
- A stream interruption preserves the current position and queue and offers recovery actions.

# Distinguish playback cache from explicit offline saves

Playback may automatically acquire music from the shared cluster library, so listening alone must not promise permanent offline retention. Distinguish evictable playback cache from explicit offline saves, protecting the latter until the listener removes them and preserving pre-existing saved audio conservatively during migration.

This accepts separate retention intent and storage accounting in exchange for bounded automatic acquisition without silently removing music the listener saved for offline use. A configurable playback-cache budget does not cap total offline-save storage. Original source files and library-host copies are outside eviction; removing a local save never implies shared-library deletion. See the accepted [interaction specification](../cluster-ui-review.md) for behavior.

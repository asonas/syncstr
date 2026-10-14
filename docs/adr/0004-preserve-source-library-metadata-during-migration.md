# Preserve source library metadata during migration

Music/iTunes library edits and artwork may not be embedded in the audio files, so file-only import can lose the listener's album organization and presentation. For this migration, prefer source-library metadata and artwork while retaining embedded evidence and source provenance; explicit Syncstr edits take precedence on later runs. This migration-specific precedence differs from ordinary folder artwork acquisition and avoids making repeated imports erase choices made after migration.

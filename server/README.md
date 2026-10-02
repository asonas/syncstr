# Syncstr Upload

A Rust service that receives audio from Syncstr and saves it in the music directory scanned by Navidrome. It does not proxy Navidrome APIs or edit existing audio files and tags.

## Deployment

Terminate HTTPS at a reverse proxy such as Cloudflare Tunnel and forward requests to the internal HTTP port 4545. Never expose the HTTP port directly to the internet. The macOS client accepts HTTPS URLs only.

`compose.yaml` is a standalone deployment example. Adjust its UID/GID and host path for your system. Create `/srv/syncstr/storage/music` and `/srv/syncstr/storage/staging` beforehand and allow the service user to write to them. Keep staging outside the music directory so unfinished uploads are not scanned.

Mount their common parent `/srv/syncstr/storage` at `/storage`. Publishing uses a hard link, so music and staging must be on the same filesystem and within the same mount. Separate bind mounts cause cross-device link failures even when their host directories are on the same filesystem. Put only music and staging under this writable parent; keep secrets elsewhere. Keep Navidrome's music mount read-only.

For the managed NAS deployment, use [syncstr-uploader-deployment](https://github.com/asonas/syncstr-uploader-deployment). It selects an implementation commit through `SYNCSTR_SOURCE_REF`; integrating source into main does not update a running server.

Store a dedicated random token in `server/secrets/upload-token`: at least 32 visible ASCII characters, preferably 32 random bytes encoded as hex. This directory is excluded from Git and the Docker build context. Give the container user read access to the file; Compose mounts it as a secret. The token is independent of Navidrome credentials. This version uses one shared token without per-device revocation. Replace the file, restart the service, and update each client to rotate it.

Environment variables:

| Variable | Value |
| --- | --- |
| `SYNCSTR_TOKEN_FILE` | Token file, required |
| `SYNCSTR_MUSIC_DIR` | Published music directory, required |
| `SYNCSTR_STAGING_DIR` | Temporary upload directory, required |
| `SYNCSTR_BIND` | Defaults to `127.0.0.1:4545` |
| `SYNCSTR_MAX_UPLOAD_BYTES` | Per-file limit, defaults to 1 GiB |

Install ffprobe on PATH; the Docker image includes it. The service processes at most two uploads concurrently, limits receipt to 15 minutes, and limits format validation to 30 seconds. Configure proxy size limits and timeouts accordingly. Cloudflare's plan limits also apply. Chunked application-level uploads and resumable transfers are not supported.

## API

Send the raw file body to `PUT /v1/uploads/{filename}` with:

- `Authorization: Bearer <token>`
- `Content-Length`: file size
- `X-Content-SHA256`: SHA-256 of the body as 64 hexadecimal characters

Success returns HTTP 201 and `{"filename":"song.mp3","bytes":123,"sha256":"…"}`. This confirms publication of the file, not completion of Navidrome's scan. Refresh the library after scanning.

Errors use JSON such as `{"error":"invalid_audio"}`.

| HTTP | Meaning |
| --- | --- |
| 400 | Invalid filename or checksum header, truncated upload, or declared size mismatch |
| 401 | Token mismatch |
| 409 | Destination already exists; no overwrite |
| 411 | Missing size header |
| 413 | Size limit exceeded or body larger than declared |
| 422 | Checksum mismatch or rejected audio format |
| 429 | Concurrent upload limit reached |
| 408 | Receipt timeout |
| 500 | Storage or ffprobe failure |

The destination is restricted to the configured music directory's root. Subdirectories, path separators, hidden filenames, and Windows reserved names are rejected. Supported extensions are mp3, aac, m4a, alac, wav, aiff, aif, flac, ogg, and opus.

ffprobe uses the expected demuxer for the extension. A file must contain an audio stream and no other streams except embedded cover images. Inputs are not interpreted as playlists or network sources. This is format validation, not antivirus scanning or a complete decode to check every audio frame.

Temporary files are invisible to Navidrome during receipt and validation, and removed on failure or cancellation. Only validated files are published, without replacing existing entries. Concurrent uploads with the same filename yield one success and one conflict. Forced termination or power loss can leave staging files; inspect and remove them while the service is stopped.

A connection lost before the response arrives can leave a successfully published file. A retry then returns 409; inspect the destination. Published files use mode 0644 on Unix. Administrators and host processes that can modify music or staging are within the service's trust boundary.

## Verification

ffprobe and ffmpeg must be available. Tests write only to temporary directories.

```sh
mise exec -- cargo test --locked --manifest-path server/Cargo.toml
mise exec -- cargo clippy --locked --manifest-path server/Cargo.toml --all-targets -- -D warnings
mise exec -- cargo fmt --manifest-path server/Cargo.toml --check
docker compose -f server/compose.yaml config --quiet
```

# Navidrome compatibility report

## Execution conditions

The runners only accept `http` URLs whose host is `127.0.0.1`, `::1`, or
`localhost`; the default is `http://127.0.0.1:4533`. They use only Python's
standard-library `urllib.request`, `json`, and `hashlib` facilities.

Validated on 2026-08-15 03:23:12 JST against parent commit
`b1cc7e8`: macOS 26.6.1 (25G76), Python 3.14.6, Docker 29.7.2, and Docker
Compose v5.3.1. Reproduce the credential-free result with
`make -C validation navidrome-api-test`; the explicit failure cases are
non-loopback URLs, missing fixtures, missing tracks, rejected playlist/rating/
play-count writes, invalid duration, and invalid Range responses.

The fake localhost contract test uses a subprocess timeout of 15 seconds. In
sandboxes that forbid loopback listeners its four fake-server cases are
skipped; the credential-free `BLOCKED`, non-loopback, and missing-fixture
cases still pass, and the Make target exits successfully in that environment.

Authentication is read only from `NAVIDROME_USER` and `NAVIDROME_PASSWORD`.
Neither value is written to stdout or this report. When either is absent, every
API and media case emits `BLOCKED` with `credentials unavailable` and exits
successfully, making the no-credential validation path safe for local and CI
execution.

Run the current validation with:

```sh
make -C validation navidrome-api-test
```

The command first validates Compose, regenerates and hashes fixtures, runs the
runner contract tests, then connects the API/media runners to the existing
localhost Navidrome process. Start and stop that process separately with
`make -C validation navidrome-test`; its healthcheck must be ready before an
authenticated API run. At this report's creation the credential-free result is
`BLOCKED` for every live API/media case.

## API cases

| Case | Credential-free result | Authenticated capability decision |
| --- | --- | --- |
| `library-scan` | BLOCKED: credentials unavailable | PASS when `getIndexes` succeeds |
| `search-metadata` | BLOCKED: credentials unavailable | PASS when `search3` finds `Validation Tone` |
| `artwork-folder` | BLOCKED: credentials unavailable | PASS when `getCoverArt` returns image data |
| `missing-file` | BLOCKED: credentials unavailable | PASS when a nonexistent stream ID returns a non-success response |
| `duration` | BLOCKED: credentials unavailable | PASS when the fixture track duration is 0.5–1.5 seconds |
| `playlists` | BLOCKED: credentials unavailable | PASS when `getPlaylists` succeeds |
| `rating` | BLOCKED: credentials unavailable | ADAPTER; Navidrome rating is per-user mutable state |
| `play-count` | BLOCKED: credentials unavailable | ADAPTER; `scrobble` updates an aggregate |
| `opensubsonic` | BLOCKED: credentials unavailable | PASS when OpenSubsonic `ping` succeeds |

An authenticated failure is printed as `REJECT` with its case ID and a
non-secret reason. The rating runner writes and clears a rating; the play-count
runner submits one fixture scrobble, so execute authenticated validation only
against the disposable Task 6 data volume.

## Media cases

| Case | Fixture | Credential-free result | Authenticated decision |
| --- | --- | --- | --- |
| `media.mp3` | `tagged/validation.mp3` | BLOCKED: credentials unavailable | PASS if metadata, Range 206, headers, and SHA-256 are available |
| `media.aac` | `untagged/validation.aac` | BLOCKED: credentials unavailable | PASS if metadata, Range 206, headers, and SHA-256 are available |
| `media.m4a` | `tagged/validation.m4a` | BLOCKED: credentials unavailable | PASS if metadata, Range 206, headers, and SHA-256 are available |
| `media.alac` | `tagged/validation-alac.m4a` | BLOCKED: credentials unavailable | PASS if metadata, Range 206, headers, and SHA-256 are available |
| `media.wav` | `untagged/validation.wav` | BLOCKED: credentials unavailable | PASS if metadata, Range 206, headers, and SHA-256 are available |
| `media.aiff` | `untagged/validation.aiff` | BLOCKED: credentials unavailable | PASS if metadata, Range 206, headers, and SHA-256 are available |

`--self-test --fixtures-root <path>` rejects missing fixtures without issuing a
network request. Authenticated media execution records the stream URL without
credentials, Content-Type, Content-Length, Range status, received-byte SHA-256,
duration, and title. Missing or unsupported formats are reported as `REJECT`
with a reason.

## Decision

Navidrome is an **ADAPTER**: retain it as the localhost music and streaming
server, and add a synchronization service for the product-specific state.
Navidrome's ratings and play counts are per-user/current aggregate values. They
are not the required immutable playback history or synchronization protocol;
they do not carry `operation_id`, `server_seq`, device counters, or offline
conflict-resolution events. The supplemental service must own those events and
their conflict semantics while Navidrome remains the media source.

Authenticated API and media probes have not been measured because validation
credentials are unavailable. Therefore no authenticated capability in this
report is an observed PASS; the table is a conditional acceptance criterion and
the current measured status remains BLOCKED.

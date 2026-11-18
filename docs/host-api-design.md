# Host API

Status: designed for [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md), accepted on 2026-11-18. Nothing in this document is implemented, and it authorizes no production operation.

This document defines the one HTTPS API that a host serves to devices and to mirrors. It is the only document that defines routes, fields, headers, status codes, ports, and timeouts. It answers ASO-160 and ASO-164, and it states what ASO-165, ASO-172, and ASO-173 may rely on. The [architecture overview](private-network-architecture.md) places it among the other designs. The owner is the person who runs the host.

In the first release the Mac or NAS host joins Tailscale, and the API listens only on loopback. Tailscale Serve publishes it to the tailnet over HTTPS, and the tailnet policy decides which devices reach it. The API has no Syncstr credential and no pairing. A device that reaches the host address can read the library, and a device that the policy keeps out cannot connect.

## One API replaces every way a device reaches a host

Devices and mirrors use the same routes under `/api/v1`. For devices, the API replaces:

- The `/v4` API in `headless/src/api.rs` and the `/v5` API in `headless/src/shared_audio_api.rs`. No Swift app calls either today.
- The cluster transport in `apps/macos/ClusterTransport.swift` and the Bonjour channel in `apps/macos/LocalTransfer.swift`.
- Invitations and enrollment. The tailnet policy takes their place.

The [migration plan](private-network-migration-plan.md) decides when each is removed. Until then each keeps its own listener.

## What the API reuses

| Part | Reused from | Change |
| --- | --- | --- |
| One byte range, `If-Range`, the content hash as a strong `ETag` | `download` and `range` in `headless/src/api.rs` | Keyed by content hash, not track ID |
| `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` | `authorize` in `headless/src/api.rs` | No token check |
| Catalog JSON `{id, name, entries, organization}` and entry JSON | `Catalog`, `Entry`, `Track` in `headless/src/model.rs`. Swift decodes them as `LocalCatalog`, `LocalEntry`, `Track`. `headless/fixtures/local-entry.json` pins both. | No image bytes |
| Organization stored without image bytes | `write_organization` in `headless/src/store.rs`, `writeOrganization` in `apps/macos/CatalogDatabase.swift` | None |
| Image ID as the SHA-256 of a JPEG of at most 512 KiB and 400 by 400 pixels | `validate` and `bounded_jpeg` in `headless/src/artwork.rs` | None |
| Playlist document | `Document` and `Item` in `headless/src/playlists.rs` | No signed envelope (`Body`, `Signed`) |

The `audio` handler in `shared_audio_api.rs` is not reused, because it sends no `ETag` and ignores `If-Range`. The `/v5` catalog is not reused, because it describes cluster state such as heads and conflicts.

On a device, `LocalTransfer.playbackFile` stays the one seam through which `Library` gets a remote file, and `PlaybackCache` already names files by content hash and checks the digest. ASO-165 puts the API behind that seam.

## Routes

| Method and path | Caller | Returns |
| --- | --- | --- |
| `GET /api/v1/library` | A device or host that reaches the host address | Library information and the change marker |
| `GET /api/v1/catalog` | Same | Tracks, organization, and playlists |
| `GET /api/v1/audio/{sha256}` | Same | One audio file, with ranges |
| `GET /api/v1/artwork/{id}` | Same | One image, with ranges |

### Versioning rule

The major version is part of the path. `/api/v1` cannot collide with the `/v1` to `/v3` routes that `api.rs` still answers with 426.

Within `/api/v1` the host may add routes, optional request fields, response fields, error codes, and new values of a field such as `role`. A reader ignores response fields it does not know and handles an unknown error code by its HTTP status. The Rust types in `shared_audio.rs` and `playlists.rs` use `deny_unknown_fields`, and readers of this API must not.

Any other change is breaking and goes to `/api/v2`. The host then serves both versions for at least one release, because a phone and a NAS host update at different times. A caller that asks for a route the host does not serve gets 404 `not-found`, so a device that needs a newer version asks the person to update Syncstr on the host.

### Library information and the change marker

`GET /api/v1/library` returns 200:

```json
{
	"library": "5b0c8f2e-6a1d-4c3b-9e7f-0d2a4b6c8e10",
	"name": "Music",
	"host": {"id": "2d7b9f41-c3a8-4e6d-b0f2-8a1c5e9d3b74", "address": "https://music.example.ts.net"},
	"role": "primary",
	"switchNumber": 1,
	"primary": "2d7b9f41-c3a8-4e6d-b0f2-8a1c5e9d3b74",
	"startingMarker": null,
	"marker": "1.2d7b9f41-c3a8-4e6d-b0f2-8a1c5e9d3b74.1842",
	"hosts": [
		{"id": "2d7b9f41-c3a8-4e6d-b0f2-8a1c5e9d3b74", "address": "https://music.example.ts.net", "role": "primary"}
	]
}
```

| Field | Meaning |
| --- | --- |
| `library` | The library ID, the UUID in the `library` table of `node.sqlite` (`store.rs`). It never changes. |
| `name` | The library name that the owner sets. |
| `host` | The answering host's ID, created once by the host, and its host address. |
| `role` | `primary`, `mirror`, `replaced`, or `retired`. A replaced host was a primary and learned that the owner made another host the primary. A retired host was retired by the owner. |
| `condition` | Present only in two states. `handing-over` is a primary from `hand-over` until the named mirror takes over. `in-conflict` is a primary or a mirror that learned of another primary under its own switch number. In both states the host accepts no change, and a mirror in conflict stops pulling. Absent otherwise. |
| `handingOverTo` | With `handing-over` only. The host ID of the mirror that is to take over. |
| `switchNumber` | The host's switch number. Starts at 1 and rises each time the owner switches the primary. |
| `primary` | The host ID of the primary at `switchNumber`. |
| `startingMarker` | The change marker that the primary's copy equaled when it became the primary at `switchNumber`. Null at switch number 1. |
| `marker` | The change marker of the copy that this host serves. |
| `mirror` | With role `mirror` only. `caughtUpAt` is the time of the latest read of the primary at which this host's marker equaled the primary's, and is null until the first copy is complete. `primaryMarker` and `readAt` are the primary's marker at the most recent successful read and the time of that read. |
| `hosts` | Every known host of the library with its ID, address, and role. In the first release it holds only the answering host, because nothing registers another host until ASO-172 decides how hosts identify each other. |

`switchNumber`, `primary`, and `startingMarker` are the host's switch record. A change marker is written `<switchNumber>.<primary>.<revision>`. The primary commits each change to the catalog, the organization, an image, or a playlist under its switch record and raises the revision by one. A new primary continues from the revision of its starting marker. A mirror serves the marker of the copy it holds unchanged, so its `marker` can name an older switch than its switch record. Markers are ordered by switch number, then by revision. Two markers with one switch number and different primaries come from two primaries under one number, and neither is newer. Times are RFC 3339 and are only shown to people. The [mirrors design](mirrors-and-primary-switch.md) owns the rules that use these fields.

Every response carries `Syncstr-Switch: <switchNumber>.<primary>` with the host's switch record, so a device notices a switch on any request.

### Catalog, refreshed with a conditional request

`GET /api/v1/catalog` returns 200 with `ETag: "<library>.<marker>"`. A request with a matching `If-None-Match` gets 304 and no body. The library ID is in the tag, so an address that now serves another library never answers 304 by mistake.

```json
{
	"id": "5b0c8f2e-6a1d-4c3b-9e7f-0d2a4b6c8e10",
	"name": "Music",
	"marker": "1.2d7b9f41-c3a8-4e6d-b0f2-8a1c5e9d3b74.1842",
	"entries": [
		{
			"track": {"id": "a3c1e5f7-2b4d-4f6a-8c0e-1d3b5a7c9e2f", "title": "Example track", "artist": "Example artist",
				"album": "Example album", "albumId": "7e9d1b3f-5a2c-4e6b-9d8f-0a1c3e5b7d9f", "duration": 241.3,
				"track": 2, "discNumber": 1, "suffix": "m4a", "size": 9214455, "addedAt": 1763370000000},
			"sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
		}
	],
	"organization": {"albums": [], "tracks": [], "aliases": {}, "choices": [], "preferred": {},
		"artwork": {"assets": {"6f2a9c1e4b7d0a3f5c8e2b1d4a7f0c3e6b9d2a5f8c1e4b7d0a3f6c9e2b5d8a1f": ""}, "candidates": [], "preferred": {}}},
	"playlists": []
}
```

- `id`, `name`, `entries`, and `organization` keep the JSON of `Catalog` in `model.rs`, with two differences. An entry has no `artwork` field. `organization.artwork.assets` maps each image ID to an empty string, and the image comes from the artwork route.
- The catalog holds everything in the library except audio and image bytes, including import evidence (`importedAlbum`), aliases, and choices. A mirror must be able to become the primary from it.
- `track.id` names the Library Track and `sha256` names its audio. Two entries may share a `sha256`, as [ADR 0006](adr/0006-preserve-source-track-identity-independently-of-audio.md) and [ADR 0007](adr/0007-preserve-track-addresses-when-sharing-audio.md) allow, and a device downloads that file once. If the store chosen in ASO-161 keeps several audio copies per track, the entry gains an optional list of them, an additive change.
- The host compresses the catalog with gzip when the request allows it.
- A device asks for the catalog at launch, on return to the foreground, when `Syncstr-Switch` changes, and when the person refreshes, always with `If-None-Match`. There is no push in the first version.
- A device shows the catalog before it has every image and fetches each image when it needs to show it.

The first version has no route for the changes since a marker, because the store at schema generation 4 keeps no change list. The catalog of a library of several thousand tracks, without image bytes, is estimated at a few megabytes before compression. That is an estimate, not a measurement, and ASO-160 measures a copy of the owner's library. `GET /api/v1/changes?after=<marker>` is reserved. It is added, as an additive change, once the store keeps a change list (ASO-161), or earlier if the compressed catalog exceeds 5 MB.

### Playlists travel in the catalog

`playlists` lists `Document` objects as `headless/src/playlists.rs` defines them, without the signed envelope. An item refers to a track by `trackId` and `sha256`. One marker covers tracks and playlists together, so a device or a mirror never holds them from two different states.

### Audio by content hash, with ranges

`GET /api/v1/audio/{sha256}` returns one audio file, 200 for the whole file and 206 for a range. The host serves every audio file it holds and has verified, whether or not the catalog it serves names it yet, because a caller may know a newer catalog than the host it asks. Files that exist only in a held copy are never served. An unknown hash gets 404.

| Header | Rule |
| --- | --- |
| `Range: bytes=<start>-[<end>]` or `bytes=-<suffix>` | Request. One range. Several ranges get 416. |
| `If-Range: "<sha256>"` | Request. The range applies only when this matches the `ETag`. Otherwise the whole file is returned. |
| `ETag: "<sha256>"`, `Accept-Ranges: bytes`, `Content-Length`, `Content-Type: application/octet-stream` | Response. Always present. |
| `Content-Range: bytes <start>-<end>/<size>` | Response. On 206. On 416 it is `bytes */<size>`. |

These headers meet Apple's conditions for resuming a download: a GET request, an `ETag`, and byte ranges ([`cancel(byProducingResumeData:)`](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/cancel(byproducingresumedata:))). The bytes behind a hash never change, so a partial file is always safe to continue.

Before the device puts a file in the playback cache or an offline save, it checks that the length equals `size` and the SHA-256 equals `sha256`. A file that fails is deleted and downloaded again from the first byte.

### Artwork by image hash

`GET /api/v1/artwork/{id}` returns one JPEG with `Content-Type: image/jpeg` and `ETag: "<id>"`, and it takes the same range headers as audio. The host serves every image it holds and has verified, except images that exist only in a held copy. The device checks that the SHA-256 of the bytes equals the ID. The catalog states no image sizes. Each image is at most 512 KiB, which bounds the space a full copy needs.

## Connecting by host address

A device opens a library by its host address, such as `https://music.example.ts.net`. The person types it once, or opens a `syncstr://open?host=<percent-encoded address>` link that the host shows as a QR code (ASO-162, ASO-164). The link only names the host and grants nothing. The device reads `GET /api/v1/library`, keeps the library ID and the known hosts, and shows the catalog.

- A host address is an `https` origin with an optional port and no path, query, fragment, or user info.
- The iPhone and macOS apps register the `syncstr` URL scheme, which no app target registers today, and a link opened from outside the app leads to the same confirmation as a scanned or typed address. The link uses a custom scheme because universal links need an association file on a public website, and Syncstr runs none.
- A device ignores link parameters it does not know.
- The confirmation shows the host name from the address, such as `studio.example.ts.net`, next to the library name, because only the address is not chosen by the host that answers.
- A host never redirects. A device refuses a redirect on every request it makes in the foreground, including library information and the catalog, and treats it like an address without a Syncstr library. A background download session follows redirects without asking the app, so background audio and artwork downloads rely on their hash check instead.
- The confirmation shows a port when the address has one other than 443.
- The first version does not offer hosts found on the tailnet. iOS has no official way for an app to list tailnet machines.
- A device that reads another library ID at an address it knew asks the person before it replaces the library it shows.
- A device keeps the address the person confirmed and sends every request there. The `host.address` in library information only names the host. If it differs from the confirmed address, the device keeps using the confirmed one.

### When the device cannot reach the host address

iOS gives an app no way to detect Tailscale. The device infers the cause from the failure and from the address. A `.ts.net` name or an address in 100.64.0.0/10 is a tailnet address. An interactive request, such as opening a host address or a refresh the person started, gives up after 15 seconds without a response, until the [device spike](validation/tailscale-device-spike.md) measures a better value.

| What the device sees | Likely cause | What the person can do |
| --- | --- | --- |
| `URLError.cannotFindHost` for a tailnet name | Tailscale is off on this device | Turn on Tailscale |
| `URLError.cannotConnectToHost` or `URLError.timedOut` | The host machine is off, asleep, or off the tailnet, or the tailnet policy does not let this device reach it | Wake the host machine, and check that the policy allows this device |
| An HTTP response without a Syncstr error body, such as a 502 from Serve | The machine answers, but Syncstr is not running on it | Start Syncstr on the host |
| A TLS failure such as `URLError.serverCertificateUntrusted` | The address is not the host's full tailnet name | Use the full name, such as `music.example.ts.net` |
| `URLError.notConnectedToInternet` | This device has no network | Connect this device |

A connection that the tailnet policy refuses looks the same as an unreachable machine, so the device names both causes. [Onboarding and connection states](onboarding-and-connection-states.md) owns the wording.

## Loopback only, published by Serve

- The host listens on `127.0.0.1:8441` with plain HTTP. Port 8441 avoids the legacy `serve`, which listens on 8443. The owner may choose another loopback port.
- The host refuses to start with a listener outside 127.0.0.0/8 and `::1`. A direct LAN or VPN listener is outside the first release.
- On a NAS the host shares its network namespace with a Tailscale container, or runs where Tailscale is installed on the NAS. In both cases its loopback is reachable only from that namespace.
- `tailscale serve` publishes the listener to the tailnet over HTTPS with a certificate from Let's Encrypt, which iOS trusts without an exception. [Tailscale setup](tailscale-setup.md) configures it. Do not use `tailscale funnel`, which publishes to the internet.
- The owner sets the host address with `--address`, and the Tailscale setup fills it in. The host puts it in library information.

Serve adds `Tailscale-User-Login`, `Tailscale-User-Name`, and `Tailscale-User-Profile-Pic` for devices that belong to a user. The first version never allows or refuses a request by them. A tagged device sends none, and on loopback any local process can set them.

### Owner actions stay on the host machine

Every command that changes a role or the switch number runs inside the host. The macOS app calls it in process. A headless host listens on `control.sock` in its data directory, a Unix socket with mode 0600, which the headless CLI uses, through `docker exec` in a container. None of these is an HTTPS route. A request that `tailscale serve` forwards comes from 127.0.0.1, so a loopback source proves nothing about the owner. The socket protocol is internal to one executable and is not part of the contract.

## What a mirror needs beyond a device

A mirror reads everything a device reads. The [mirrors design](mirrors-and-primary-switch.md) builds its pull on these rules.

- It reads the catalog, every audio file that an entry names, and every image in `organization.artwork.assets`, and checks each file by its hash.
- A mirror serves a catalog only at a marker for which it holds every referenced file. Until its first copy is complete, it answers `GET /api/v1/catalog` with 503 `mirror-incomplete` and still serves its library information and the files it holds. After that it serves its last complete catalog while it pulls the next.
- A mirror refuses every change with 409 `not-primary`.
- A host whose role is `replaced` or `retired` serves only library information. It answers the catalog, audio, and artwork routes with 503 `not-serving`, whose body names the primary's address.
- No route and no header changes a host's switch record. A host changes it only from what it reads in another host's library information, by the rules of the mirrors design.

How one host identifies another, and how a retired host loses access, is not decided. The mirrors design still describes it with host tokens, and ASO-172 and ASO-173 redesign it on the tailnet. Until then a host knows no other host, reads no other host's library information at start, and never changes its role or switch record. The first release has one primary and no mirror.

Until the changes route exists, a mirror reads the full catalog at the primary's marker and compares it with its copy.

## Changes from devices come later

The first version has no write route. The [migration plan](private-network-migration-plan.md) records which changes return first (ASO-168). The first version keeps these possible:

- A write goes to the primary. Any host that does not accept changes answers it with 409 `not-primary`, whose body names the host's role, its condition if it has one, and the primary's address.
- A write carries `If-Match` with the catalog `ETag`. The tag holds the switch number and the primary, so a write based on an old catalog or made under an old switch gets 412. These two answers cover every reason a host refuses a change, so the API has no other refusal code.
- Each write carries a request ID that the device chooses, so a retry after a lost response applies once.
- Adding music from a device uses `PUT /api/v1/audio/{sha256}`. The device knows the hash before it uploads, and the same path serves the download.
- A device never assumes that only the owner changes the catalog. It refreshes on the change marker either way.

Any device that reaches a host can read, so writes need their own decision about who may change the library. ASO-168 makes it.

## Errors, limits, and timeouts

Every error response except 304, 416, and an answer to `HEAD` has a JSON body. A device acts on `error` and writes its own wording. `message` is for logs and the CLI.

```json
{"error": "method-not-allowed", "message": "This route accepts only GET."}
```

| Status | `error` | When |
| --- | --- | --- |
| 404 | `not-found` | An audio hash or image ID that the host does not hold, or a route that it does not serve |
| 405 | `method-not-allowed` | Any method other than `GET` on a first-release route. `Allow: GET`. |
| 416 | none | An unsatisfiable range, or more than one range |
| 429 | `rate-limited` | Too many concurrent downloads. `Retry-After` gives seconds. |
| 500 | `storage-failed` | The host could not read its store or a file |

The 503 `mirror-incomplete` and `not-serving` answers of [what a mirror needs](#what-a-mirror-needs-beyond-a-device) join this table with mirrors (ASO-172), and the 409 `not-primary` and 412 answers of [changes from devices](#changes-from-devices-come-later) join this table with the first write route.

Limits: 16 concurrent file responses in total, with 429 and `Retry-After: 5` beyond that. The limit is global because the host cannot tell callers apart: every request through Serve arrives from loopback. 16 is provisional. ASO-160 sets it from measurements of a slow download, a whole-library save, and the start of playback running together. A device that gets 429 waits for `Retry-After` before its own backoff applies, and a device saving many files keeps at most 4 downloads open, so that one device cannot take every slot. Whether playback still starts while several devices save is part of the ASO-160 measurement. 20 GiB for an audio file (`MAX_AUDIO` in `model.rs`).

Today `api.rs` and `shared_audio_api.rs` end every request after two hours, and the cluster transport closes a download after 240 seconds (`ClusterTransport.swift`). A 20 GiB file on a slow cellular link needs more than either. The new rules limit idle time, not total time.

| Side | Rule |
| --- | --- |
| Host, files | Close the response when the caller accepts no bytes for 120 seconds. No total limit. |
| Host, other routes | 5 minutes in total, and 30 seconds to read the request headers. |
| Host, at start | From ASO-172 on, a primary reads the library information of every known host before it accepts changes, for at most 5 seconds in total across all hosts. It then starts, whatever it heard. |
| Device, library information of known hosts | 15 seconds without a response, the same as an interactive request. Reads of several hosts run in parallel. |
| Device, interactive | 15 seconds without a response, then show the cause. |
| Device, audio | `timeoutIntervalForRequest` of 60 seconds, which resets whenever data arrives. `timeoutIntervalForResource` no shorter than its 7-day default. After a failure, resume from the bytes held, waiting 2 seconds at first and doubling up to 5 minutes. |

## The contract is a file that tests enforce

The contract follows the accepted [API contract gate](api-contract-gate-design.md). The `contracts/` directory that the gate plans does not exist yet.

- `contracts/host-api-v1.yaml` is a hand-written OpenAPI 3.1 file (gate decision D2) that covers every first-release route, header, field, status, and error code above. The mirror fields and answers join it with ASO-172, and the write routes with ASO-168.
- `oasdiff breaking --fail-on ERR` compares it with the base branch (gate decision D4). It takes the place of the `/v5` contract that gate slice S5 planned.
- `contracts/fixtures/host-api-v1/` holds a JSON file for each response shape and each error, including a catalog with two entries that share a `sha256`. The catalog entry reuses `headless/fixtures/local-entry.json` without `artwork`. Rust and Swift tests decode every fixture, and a schema validator checks each one against the YAML file.
- A Rust integration test runs the real router on `127.0.0.1:0` with a temporary store. It covers library information, the catalog and its 304, an image, and audio whole, by range, resumed, with a stale `If-Range`, and with two ranges. It validates every JSON body against the contract. Another test checks that the host refuses a listener outside loopback.
- The Swift tests of ASO-165 start the executable that `SYNCSTR_HEADLESS_TEST_BINARY` names, on loopback. The host writes the address it bound to the file that `--address-out` names, like `--peer-address-out` today.
- From ASO-172 on, a mirror test runs two host processes on loopback with separate data directories.

No test needs multicast, a relay, a second machine, a certificate, or the Simulator's network. Whether the tailnet policy lets a device in is checked by hand on the owner's tailnet, as the [migration plan](private-network-migration-plan.md#the-test-that-says-the-library-runs-on-the-new-path) describes.

## Security considerations

The tailnet policy is the only control over who reads the library remotely. Every device that the effective policy lets reach the host's Serve port reads the whole library, including audio. That covers every device of the owner that the policy allows, other users of the tailnet whom a broad rule allows, and anyone the owner shares the host machine with. Before publishing, the owner checks the effective policy, as [Tailscale setup](tailscale-setup.md) describes.

The tailnet keeps the host off the public internet and encrypts traffic between machines. Syncstr adds no check of its own.

Neither protects:

- Files already on a device. Removing its access stops new requests and cannot erase saved music.
- The loopback listener, from other local users and processes of the host machine, or from other containers in the NAS host's network namespace. They read the library without going through the tailnet.
- Audio and images removed from the catalog. Until the host deletes the file, a device that kept its hash can still download it.
- The host's data directory. Whoever reads it has the audio and the catalog.
- The machine name, which Serve's certificate puts in public certificate transparency logs.

## Open questions

| Question | Owner |
| --- | --- |
| How do hosts identify each other, and how does a retired host lose access, on the tailnet? | ASO-172, ASO-173 |
| Who may change the library from a device, given that the read API has no per-device identity? | ASO-168 |
| Where does the store keep a change list, and what is the format of the reserved changes route? | ASO-161 |

Other documents answer these earlier questions. Whether background downloads continue over the Tailscale tunnel is Q2 of the [device spike](validation/tailscale-device-spike.md#questions). Music enters a headless primary through an import on the primary, as the [migration plan](private-network-migration-plan.md#devices-read-and-download-in-the-first-release) describes. The store keeps the host state in `node.sqlite`, as the [migration plan](private-network-migration-plan.md#what-the-store-keeps-besides-the-library) describes. A device that loses access keeps its offline saves ([onboarding](onboarding-and-connection-states.md#on-a-device)).

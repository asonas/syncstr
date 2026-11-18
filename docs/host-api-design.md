# Host API

Status: proposed 2026-11-17 with [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md). Nothing in this document is implemented, and it authorizes no production operation.

For the first release the Mac or NAS host joins Tailscale. The host exposes only library information, catalog, audio and artwork reads through Serve. These four GET routes accept requests without a Syncstr Authorization header. Tailnet policy controls access to the host and service port. The application listener binds to loopback. Owner commands remain local. Verify that a permitted phone can read and a restricted device cannot reach the service.

The November 17 draft below remains a reference for the data formats and future work. ADR 0008 supersedes its pairing exchange, device registry, token checks, per-device authorization errors, off-loopback listeners and associated tests. These are outside the first-release contract.

## One API replaces every way a device reaches a host

Devices and mirrors use the same routes under `/api/v1`. For devices, the API replaces:

- The `/v4` API in `headless/src/api.rs` and the `/v5` API in `headless/src/shared_audio_api.rs`. No Swift app calls either today.
- The cluster transport in `apps/macos/ClusterTransport.swift` and the Bonjour channel in `apps/macos/LocalTransfer.swift`.
- Invitations and enrollment.

The [migration plan](private-network-migration-plan.md) decides when each is removed. Until then each keeps its own listener.

## What the API reuses

| Part | Reused from | Change |
| --- | --- | --- |
| One byte range, `If-Range`, the content hash as a strong `ETag` | `download` and `range` in `headless/src/api.rs` | Keyed by content hash, not track ID |
| Token kept as a SHA-256 hash, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` | `authorize` in `headless/src/api.rs` | One hash per paired device, not one shared token |
| Token form, 32 random bytes as 64 lowercase hex characters | `initialize` in `headless/src/identity.rs` | The device creates it |
| Self-signed certificate for a listener off loopback | `initialize` and `tls` in `headless/src/identity.rs` | None |
| Catalog JSON `{id, name, entries, organization}` and entry JSON | `Catalog`, `Entry`, `Track` in `headless/src/model.rs`. Swift decodes them as `LocalCatalog`, `LocalEntry`, `Track`. `headless/fixtures/local-entry.json` pins both. | No image bytes |
| Organization stored without image bytes | `write_organization` in `headless/src/store.rs`, `writeOrganization` in `apps/macos/CatalogDatabase.swift` | None |
| Image ID as the SHA-256 of a JPEG of at most 512 KiB and 400 by 400 pixels | `validate` and `bounded_jpeg` in `headless/src/artwork.rs` | None |
| Playlist document | `Document` and `Item` in `headless/src/playlists.rs` | No signed envelope (`Body`, `Signed`) |

The `audio` handler in `shared_audio_api.rs` is not reused, because it sends no `ETag` and ignores `If-Range`. The `/v5` catalog is not reused, because it describes cluster state such as heads and conflicts.

On a device, `LocalTransfer.playbackFile` stays the one seam through which `Library` gets a remote file, and `PlaybackCache` already names files by content hash and checks the digest. ASO-165 puts the API behind that seam.

## Routes

| Method and path | Caller | Returns |
| --- | --- | --- |
| `GET /api/v1/library` | Allowed tailnet device | Library information and the change marker |
| `GET /api/v1/catalog` | Allowed tailnet device | Tracks, organization, and playlists |
| `GET /api/v1/audio/{sha256}` | Allowed tailnet device | One audio file, with ranges |
| `GET /api/v1/artwork/{id}` | Allowed tailnet device | One image, with ranges |

### Versioning rule

The major version is part of the path. `/api/v1` cannot collide with the `/v1` to `/v3` routes that `api.rs` still answers with 426.

Within `/api/v1` the host may add routes, optional request fields, response fields, error codes, and new values of a field such as `role`. A reader ignores response fields it does not know and handles an unknown error code by its HTTP status. The Rust types in `shared_audio.rs` and `playlists.rs` use `deny_unknown_fields`, and readers of this API must not.

Any other change is breaking and goes to `/api/v2`. The host then serves both versions for at least one release, because a phone and a NAS host update at different times. A paired caller that asks for a route the host does not serve gets 404 `not-found`, so a device that needs a newer version asks the person to update Syncstr on the host.

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
		{"id": "2d7b9f41-c3a8-4e6d-b0f2-8a1c5e9d3b74", "address": "https://music.example.ts.net", "role": "primary"},
		{"id": "8e4c0a6f-1b9d-4f37-a5e2-6d0b3c8f1a95", "address": "https://backup.example.ts.net", "role": "mirror"}
	],
	"caller": {"id": "0f6a2d41-93c8-4e1b-a7d5-2c9e8b4f1a36", "name": "iPhone", "kind": "device"}
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
| `mirror` | With role `mirror` only. `caughtUpAt` is the time of the latest read of the primary at which this host's marker and device list equaled the primary's, and is null until the first copy is complete. `primaryMarker` and `readAt` are the primary's marker at the most recent successful read and the time of that read. |
| `hosts` | Every known host of the library with its ID, address, and role. |
| `caller` | The record that the request's token belongs to, without `tokenSha256`. |

`switchNumber`, `primary`, and `startingMarker` are the host's switch record. A change marker is written `<switchNumber>.<primary>.<revision>`. The primary commits each change to the catalog, the organization, an image, or a playlist under its switch record and raises the revision by one. A new primary continues from the revision of its starting marker. A mirror serves the marker of the copy it holds unchanged, so its `marker` can name an older switch than its switch record. Markers are ordered by switch number, then by revision. Two markers with one switch number and different primaries come from two primaries under one number, and neither is newer. Times are RFC 3339 and are only shown to people. The [mirrors design](mirrors-and-primary-switch.md) owns the rules that use these fields.

Every response to a paired caller carries `Syncstr-Switch: <switchNumber>.<primary>` with the host's switch record, so a device notices a switch on any request.

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

`GET /api/v1/audio/{sha256}` returns one audio file, 200 for the whole file and 206 for a range. The host serves every audio file it holds and has verified, whether or not the catalog it serves names it yet. A caller may know a newer catalog than the host it asks, and only a caller that already knows the hash can ask for the file. An unknown hash gets 404.

| Header | Rule |
| --- | --- |
| `Range: bytes=<start>-[<end>]` or `bytes=-<suffix>` | Request. One range. Several ranges get 416. |
| `If-Range: "<sha256>"` | Request. The range applies only when this matches the `ETag`. Otherwise the whole file is returned. |
| `ETag: "<sha256>"`, `Accept-Ranges: bytes`, `Content-Length`, `Content-Type: application/octet-stream` | Response. Always present. |
| `Content-Range: bytes <start>-<end>/<size>` | Response. On 206. On 416 it is `bytes */<size>`. |

These headers meet Apple's conditions for resuming a download: a GET request, an `ETag`, and byte ranges ([`cancel(byProducingResumeData:)`](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/cancel(byproducingresumedata:))). The bytes behind a hash never change, so a partial file is always safe to continue.

Before the device puts a file in the playback cache or an offline save, it checks that the length equals `size` and the SHA-256 equals `sha256`. A file that fails is deleted and downloaded again from the first byte.

### Artwork by image hash

`GET /api/v1/artwork/{id}` returns one JPEG with `Content-Type: image/jpeg` and `ETag: "<id>"`, and it takes the same range headers as audio. The host serves every image it holds and has verified. The device checks that the SHA-256 of the bytes equals the ID. The catalog states no image sizes. Each image is at most 512 KiB, which bounds the space a full copy needs.

## Superseded device-token proposal

Each paired device has its own device token for the library, and every host of the library accepts it. A mirror pairs the same way, and its record has kind `host`. A primary that creates a library also creates a token of kind `host` for itself and records its hash, so that the other hosts of the library accept its requests.

- Every caller, the headless CLI included, sends the token in the `Syncstr-Token` header. Apple's URL Loading System reserves `Authorization` and "may ignore the value you set, or overwrite it with its own value, or simply not send it" ([Reserved HTTP headers](https://developer.apple.com/documentation/foundation/nsurlrequest#Reserved-HTTP-headers)), and background downloads must not depend on that. A token never appears in a URL.
- A token is 32 random bytes written as 64 lowercase hex characters. The device creates it from the system's secure random source.
- A host keeps only the SHA-256 of the token string, as `authorize` in `api.rs` does today, and finds the record by that hash. The hash of a 256-bit random token gives no useful timing signal.
- A device keeps its token in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background downloads can read it while the phone is locked and backups leave it out.

ASO-161 decides where the store keeps these fields:

| Field | Meaning |
| --- | --- |
| `id` | A UUID that the primary assigns. |
| `name` | 1 to 64 characters, from the pairing request. The owner can rename it. |
| `kind` | `device` or `host`. |
| `hostId`, `address` | Kind `host` only. The host's ID and host address. |
| `tokenSha256` | Lowercase hex SHA-256 of the token. |
| `pairedAt`, `revokedAt` | RFC 3339 times. `revokedAt` is null until revocation. |
| `tailscaleLogin` | Optional label taken at pairing. See [the transport rules](#loopback-by-default-https-everywhere-else). |

The owner revokes a device token on the primary. The record keeps its hash with a `revokedAt` time, and every later request with that token gets 401 `device-revoked`, so the device can ask the person to pair again. A mirror applies a revocation at its next pull.

A device ends its pairing on 401 `device-revoked` from any host, or on 401 `unauthorized` from the primary. A mirror answers 401 `unauthorized` to a device that paired after the mirror's last pull. The device then keeps its token and uses another host.

A caller without a valid token can reach only `POST /api/v1/pairing`. The host checks the token before it matches a route, so every other path, existing or not, returns 401 `unauthorized`. A 401 names no library, host, or version.

## Superseded pairing exchange

Only a primary that accepts changes pairs. Any other host answers a pairing request with 409 `not-primary`.

### What the host shows

The owner asks the primary for a pairing code. The macOS app shows a QR code, the same link as text, and the time left (ASO-162). On a headless host, `syncstr-headless pair --data data` prints the link and the QR code as text, waits, and prints the name of the device that paired. The host keeps serving throughout.

- A code is 16 random bytes written as unpadded base64url, 22 characters.
- A code is for a device or for a host, and the owner chooses which when creating it. `syncstr-headless pair` creates a device code, and `syncstr-headless pair --host` a host code. The primary keeps the kind with the code, and an exchange that asks for the other kind gets `pairing-code-invalid`.
- A code expires after 10 minutes and works once. The owner can cancel it.
- At most 5 codes are open at a time.
- The host keeps only the hash of each open code, in memory. A restart cancels every open code, and no code reaches the disk.
- A device token cannot create a code. A stolen token could otherwise add devices.

### The pairing link

```text
syncstr://pair?v=1&host=https%3A%2F%2Fmusic.example.ts.net&code=q3Vb7cX1nQe0rT5yU8wZ2a
```

| Parameter | Meaning |
| --- | --- |
| `v` | Link format version, `1`. |
| `host` | The host address, percent-encoded. An `https` origin with an optional port and no path, query, fragment, or user info. |
| `code` | The pairing code. |
| `pin` | Optional. The unpadded base64url SHA-256 of the certificate's public key (SubjectPublicKeyInfo). Present only when the host uses a self-signed certificate. |

- The QR code holds the link exactly. The iPhone app registers the `syncstr` URL scheme, which no app target registers today, and its own scanner reads the same text. The macOS app accepts a pasted link.
- The link uses a custom scheme because universal links need an association file on a public website, and Syncstr runs none.
- A device ignores parameters it does not know. If `v` is higher than it supports, it asks the person to update Syncstr.
- The person never types or compares an address, a certificate, or an ID.
- A headless mirror takes the same link as an argument of the command that starts it, `follow` in the mirrors design.

### The exchange

`POST /api/v1/pairing` takes a body of at most 4 KiB. A host sends `"kind": "host"` and adds `"hostId"` and `"address"`.

```json
{"code": "q3Vb7cX1nQe0rT5yU8wZ2a", "token": "<64 hex characters>", "kind": "device", "name": "iPhone"}
```

1. The device creates its token and sends it with the code and its name.
2. In one transaction, the primary checks that the code is open, marks it used, and records the device with the hash of its token.
3. The primary returns 201 with `{"device": <record without tokenSha256>, "library": <library information>}`.

If the response is lost, the device calls `GET /api/v1/library` with its new token. A 200 means that pairing succeeded. A 401 means that it did not, and the device repeats the exchange while the code is open. The device creates the token so that a lost response cannot leave it with a used code and no token.

An unknown, expired, or used code, or a code of the other kind, gets 403 `pairing-code-invalid`. In every case the person's next step is to show a new code on the host.

Nobody types the code, so it is long enough that guessing is no threat, and the rate limit is a second defense. After 20 failed exchanges in one minute, counted across all callers, the host answers 429 until the minute ends. A limit per source address would not work, because every request through `tailscale serve` arrives from loopback.

The device keeps the link until the code expires, so a person who turns on Tailscale after a failure can retry without a new code.

The first version does not offer hosts found on the tailnet. iOS has no official way for an app to list tailnet machines, and a host found that way would still need a code.

### Owner actions go through the running host

Creating and cancelling a code, listing, renaming, and revoking device tokens happen inside the running primary. The macOS app calls them in process. A headless host listens on `control.sock` in its data directory, a Unix socket with mode 0600, which `syncstr-headless pair`, `devices`, and `revoke` use, through `docker exec` in a container. The host no longer has to stop, as `node.lock` forces for invitations today.

These actions are not HTTPS routes, and neither is any command that changes a role or the switch number. A request that `tailscale serve` forwards also comes from 127.0.0.1, so a loopback source proves nothing about the owner. The socket protocol is internal to one executable and is not part of the contract.

### When the device cannot reach the host address

iOS gives an app no way to detect Tailscale. The device infers the cause from the failure and from the address. A `.ts.net` name or an address in 100.64.0.0/10 is a tailnet address. An interactive request, such as pairing or a refresh the person started, gives up after 15 seconds without a response, until the [device spike](validation/tailscale-device-spike.md) measures a better value.

| What the device sees | Likely cause | What the person can do |
| --- | --- | --- |
| `URLError.cannotFindHost` for a tailnet name | Tailscale is off on this device | Turn on Tailscale |
| `URLError.cannotConnectToHost` or `URLError.timedOut` | The host machine is off, asleep, or off the private network | Wake the host machine and check its network |
| An HTTP response without a Syncstr error body, such as a 502 from a proxy | The machine answers, but Syncstr is not running on it | Start Syncstr on the host |
| A TLS failure such as `URLError.serverCertificateUntrusted` | The device does not trust the certificate | Check the host's certificate setup |
| `URLError.notConnectedToInternet` | This device has no network | Connect this device |

[Onboarding and connection states](onboarding-and-connection-states.md) owns the wording.

## Loopback by default, HTTPS everywhere else

- By default the host listens on `127.0.0.1:8441` with plain HTTP. `tailscale serve` publishes it to the tailnet over HTTPS, and [Tailscale setup](tailscale-setup.md) configures that. Port 8441 avoids the legacy `serve`, which listens on 8443.
- The owner picks another address with `--listen` or a setting in the macOS app. A listener outside 127.0.0.0/8 and `::1` requires TLS, and the host refuses to start without it.
- A host has one listener in the first version.
- The owner sets the host address with `--address`, and the Tailscale setup fills it in on a tailnet. Without one the host creates no pairing code, because the link carries it.

| Network | Listener | Certificate | On an iPhone |
| --- | --- | --- | --- |
| Tailscale with Serve, preferred | Loopback, HTTP | Let's Encrypt, through Serve | Trusted. The machine name appears in public certificate transparency logs. |
| LAN, another VPN, or Tailscale without Serve | That network's address, HTTPS | From a public authority for a domain the owner controls, or from the owner's own authority whose root the person installed on the iPhone | Trusted |
| Same | Same | Self-signed, from `identity.rs` | Only through `pin`, if ASO-159 shows that it works |

A pin covers the public key, so a renewed certificate with the same key keeps working.

A device that reaches a host at a LAN address needs the iOS local network permission. A device that reaches a host over a VPN interface, such as Tailscale, does not.

Serve adds `Tailscale-User-Login`, `Tailscale-User-Name`, and `Tailscale-User-Profile-Pic` for devices that belong to a user. The host reads them only when it listens on loopback, because on any other listener a caller can set them. At pairing the primary copies `Tailscale-User-Login` into `tailscaleLogin`, so the owner's device list shows whose device it is. The headers never allow or refuse a request. A later version may refuse a token that arrives with another login, and that needs no API change.

## What a mirror needs beyond a device

A mirror reads everything a device reads. The [mirrors design](mirrors-and-primary-switch.md) builds its pull on these rules.

- A mirror pairs with the primary through a host code, sending kind `host`, its host ID, and its host address.
- It reads the catalog, every audio file that an entry names, and every image in `organization.artwork.assets`, and checks each file by its hash.
- It also reads `GET /api/v1/devices`, which returns every record with `tokenSha256` and `revokedAt`. A token of kind `device` gets 403 `host-token-required` there. The list has its own `ETag` for 304. With it, a device token works at every host of the library, and a revocation on the primary reaches the mirror.
- A mirror serves a catalog only at a marker for which it holds every referenced file. Until its first copy is complete, it answers `GET /api/v1/catalog` with 503 `mirror-incomplete` and still serves its library information and the files it holds. After that it serves its last complete catalog while it pulls the next.
- A mirror refuses pairing, and later every change, with 409 `not-primary`.
- A host whose role is `replaced` or `retired` serves only library information. It answers the catalog, audio, artwork, and device list routes with 503 `not-serving`, whose body names the primary's address.
- Hosts read each other's library information with their own tokens of kind `host`. No route and no header changes a host's switch record. A host changes it only from what it reads in another host's library information, by the rules of the mirrors design.

Until the changes route exists, a mirror reads the full catalog at the primary's marker and compares it with its copy.

## Changes from devices come later

The first version has no write route. The [migration plan](private-network-migration-plan.md) records which changes return first (ASO-168). The first version keeps these possible:

- A write goes to the primary. Any host that does not accept changes answers it with 409 `not-primary`, whose body names the host's role, its condition if it has one, and the primary's address.
- A write carries `If-Match` with the catalog `ETag`. The tag holds the switch number and the primary, so a write based on an old catalog or made under an old switch gets 412. These two answers cover every reason a host refuses a change, so the API has no other refusal code.
- Each write carries a request ID that the device chooses, so a retry after a lost response applies once.
- Adding music from a device uses `PUT /api/v1/audio/{sha256}`. The device knows the hash before it uploads, and the same path serves the download.
- A record can gain permissions per device, because each device has its own token.
- A device never assumes that only the owner changes the catalog. It refreshes on the change marker either way.

## Errors, limits, and timeouts

Every error response except 304, 416, and an audio body has a JSON body. A device acts on `error` and writes its own wording. `message` is for logs and the CLI.

```json
{"error": "not-primary", "message": "This host is a mirror. Changes go to the primary.", "role": "mirror", "primary": "https://music.example.ts.net"}
```

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad-request` | A malformed body, a token that is not 64 hex characters, or a name outside 1 to 64 characters |
| 401 | `unauthorized` | A missing or unknown token |
| 401 | `device-revoked` | A revoked token |
| 403 | `pairing-code-invalid` | An unknown, expired, or used code, or a code of the other kind |
| 403 | `host-token-required` | A token of kind `device` on `/api/v1/devices` |
| 404 | `not-found` | An audio hash or image ID that the host does not hold, or a route that it does not serve, for a paired caller |
| 409 | `not-primary` | Pairing or a write at a host that does not accept changes: a mirror, a replaced or retired host, or a primary that is handing over or in conflict. The body gives `role`, and `condition` when the host has one. It names the primary only to a paired caller. |
| 409 | `token-in-use` | A pairing token whose hash is already recorded |
| 413 | `too-large` | A request body above its limit |
| 416 | none | An unsatisfiable range, or more than one range |
| 429 | `rate-limited` | Too many failed pairings or concurrent downloads. `Retry-After` gives seconds. |
| 500 | `storage-failed` | The host could not read its store or a file |
| 503 | `mirror-incomplete` | A catalog request to a mirror without a complete copy |
| 503 | `not-serving` | A catalog, audio, artwork, or device list request to a replaced or retired host |

Limits: 4 concurrent file responses per token, with 429 and `Retry-After: 5` for the fifth. 20 failed pairing exchanges per minute across all callers. 5 open pairing codes. 4 KiB for a pairing request body. 20 GiB for an audio file (`MAX_AUDIO` in `model.rs`).

Today `api.rs` and `shared_audio_api.rs` end every request after two hours, and the cluster transport closes a download after 240 seconds (`ClusterTransport.swift`). A 20 GiB file on a slow cellular link needs more than either. The new rules limit idle time, not total time.

| Side | Rule |
| --- | --- |
| Host, files | Close the response when the caller accepts no bytes for 120 seconds. No total limit. |
| Host, other routes | 5 minutes in total, and 30 seconds to read the request headers. |
| Host, at start | A primary reads the library information of every known host before it accepts changes, for at most 5 seconds in total. It then starts, whatever it heard. |
| Device or host, library information of known hosts | 15 seconds without a response, the same as an interactive request. Reads of several hosts run in parallel. |
| Device, interactive | 15 seconds without a response, then show the cause. |
| Device, audio | `timeoutIntervalForRequest` of 60 seconds, which resets whenever data arrives. `timeoutIntervalForResource` no shorter than its 7-day default. After a failure, resume from the bytes held, waiting 2 seconds at first and doubling up to 5 minutes. |

## The contract is a file that tests enforce

The contract follows the accepted [API contract gate](api-contract-gate-design.md). The `contracts/` directory that the gate plans does not exist yet.

- `contracts/host-api-v1.yaml` is a hand-written OpenAPI 3.1 file (gate decision D2) that covers every route, header, field, status, and error code above.
- `oasdiff breaking --fail-on ERR` compares it with the base branch (gate decision D4). It takes the place of the `/v5` contract that gate slice S5 planned.
- `contracts/fixtures/host-api-v1/` holds a JSON file for each response shape and each error, including a catalog with two entries that share a `sha256`. The catalog entry reuses `headless/fixtures/local-entry.json` without `artwork`. Rust and Swift tests decode every fixture, and a schema validator checks each one against the YAML file.
- A Rust integration test runs the real router on `127.0.0.1:0` with a temporary store. It covers pairing, library information, the catalog and its 304, an image, audio whole, by range, resumed, with a stale `If-Range`, and with two ranges, and revocation. It validates every JSON body against the contract. Another test checks that the host refuses a non-loopback listener without TLS.
- The Swift tests of ASO-165 start the executable that `SYNCSTR_HEADLESS_TEST_BINARY` names, on loopback. The host writes the address it bound to the file that `--address-out` names, like `--peer-address-out` today. The tests pair through `control.sock`.
- A mirror test runs two host processes on loopback with separate data directories.

No test needs multicast, a relay, a second machine, or the Simulator's network. Most tests need no certificate, because the default listener is plain HTTP on loopback. One test covers TLS with a certificate from `identity.rs`.

## Security considerations

The device token protects the library from anyone who reaches a host address without pairing. That includes other machines on a home LAN, other users of a tailnet, and a tailnet that the owner shares the machine with. A host keeps no token, only its hash.

The private network keeps the host off the public internet, limits who can try a token or a code, and encrypts traffic between machines. Tailscale ACLs can narrow who reaches the host further. That is the owner's choice.

Neither protects:

- Files already on a device. Revocation stops new requests and cannot erase saved music.
- A mirror, against a revoked token, until the mirror's next pull.
- A pairing link during its 10 minutes. Anyone who photographs the QR code, or another app that claims the `syncstr` scheme, can use the code first. The owner sees the extra device in the list and can revoke it. A device code cannot create a host record. A host record could read the device list and would appear in `hosts`, where devices would send it their tokens. That is why a host code is a separate owner action.
- Pairing, against someone on the private network who fails 20 exchanges a minute. That blocks pairing until the minute ends.
- The host's data directory. Whoever reads it has the audio, the catalog, and the token hashes.
- The loopback listener, from other local users of the host machine. They still need a token.
- The machine name, which Serve's certificate puts in public certificate transparency logs.

## Open questions

| Question | Owner |
| --- | --- |
| Does a pinned self-signed certificate work without an App Transport Security exception, in the foreground and in a background session? Until it does, devices ignore `pin`, and a LAN host needs a certificate that the iPhone trusts without one. | ASO-159 |
| Where does the store keep a change list, and what is the format of the reserved changes route? | ASO-161 |

Other documents answer these earlier questions. Whether background downloads continue over the Tailscale tunnel is Q2 of the [device spike](validation/tailscale-device-spike.md#questions). Music enters a headless primary through an import on the primary, as the [migration plan](private-network-migration-plan.md#devices-read-and-download-in-the-first-release) describes. The store keeps the device records and the host state in `node.sqlite`, as the [migration plan](private-network-migration-plan.md#what-the-store-keeps-besides-the-library) describes. A mirror pulls once a minute by default, which bounds how long a revoked token still works there ([mirrors design](mirrors-and-primary-switch.md#how-a-mirror-pulls)). A revoked device keeps its offline saves ([onboarding](onboarding-and-connection-states.md#on-a-device)).

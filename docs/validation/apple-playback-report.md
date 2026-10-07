# Apple playback validation report

Historical validation record. Commands and paths below refer to the evaluated commit, not the current main tree. See the [current app guides](../../README.md#code-and-documentation-map) for present-day verification.

## Environment and fixture contract

Recorded 2026-08-15 03:52:35 JST on macOS 26.6.1 (25G76), Apple Swift 6.3.3,
and Command Line Tools only (no Xcode.app selected). The evaluated parent
commit is `cc22d81`. `swift build --package-path validation/apple/AudioValidation`
succeeded for that commit; `swift test --package-path validation/apple/AudioValidation`
is BLOCKED because the active Command Line Tools installation does not provide XCTest.

The original fixture generator and validation package are preserved in Git history, outside the current source tree. Use the current app guides for executable checks.

`PlaybackProbe.probe` uses `AVAudioPlayerDelegate` to await natural completion;
decode errors and its five-second timer become `REJECT` results rather than an
immediate `stop`. `PlaybackProbe.probeAll` emits all 11 fixed case IDs and
`writeJSON` atomically persists Codable `PlaybackResult` values. On iPhone,
`IPhonePlaybackProbe.probeAll` configures `AVAudioSession` and media commands
before invoking that same plan; non-iOS builds expose the equivalent BLOCKED
results. Gapless, background, media-key, and HTTPS Range remain explicitly
BLOCKED because no automated device or authenticated endpoint probe exists.

| Fixture | SHA-256 |
| --- | --- |
| MP3 | `831c8d4df7c5e2e28ad1c1376f076f0e2ff45c8b6d56ae7e2ffc7d9108a013b8` |
| AAC | `9c55ff620a6f2129cdee4e1e33de9038f65b5a211d9a564c4ff0431727536dc8` |
| M4A | `0425a8c3bffdde96649bc8da8d7ec243966606aaf919f79a30a9eae203730616` |
| ALAC | `c7b39bd6148ff10190bc42bc4d181e59e82b88010eac763812796ab9275f2c57` |
| WAV | `c087187ef80798631ceac4eee8d43c8d4d441451576abdf45a8d7b7bd2269129` |
| AIFF | `8cdf21107c6c4472304ba700f1cfc49183b1cd8278f576772091ae3146dd66f3` |

## Results and decisions

| Case ID | macOS | iPhone | Decision |
| --- | --- | --- | --- |
| `mp3` | BLOCKED: XCTest unavailable; probe not executed | BLOCKED: device not connected | Prefer original local file |
| `aac` | BLOCKED: XCTest unavailable; probe not executed | BLOCKED: device not connected | Prefer original local file |
| `m4a` | BLOCKED: XCTest unavailable; probe not executed | BLOCKED: device not connected | Prefer original local file |
| `alac` | BLOCKED: XCTest unavailable; probe not executed | BLOCKED: device not connected | Prefer original local file |
| `wav` | BLOCKED: XCTest unavailable; probe not executed | BLOCKED: device not connected | Prefer original local file |
| `aiff` | BLOCKED: XCTest unavailable; probe not executed | BLOCKED: device not connected | Prefer original local file |
| `original-local` | BLOCKED: XCTest unavailable; fixture probe not executed | BLOCKED: device not connected | Original file is first choice |
| `https-range` | BLOCKED: no authenticated HTTPS fixture endpoint | BLOCKED: device not connected | Server transcode only if native stream fails |
| `gapless` | BLOCKED: automated boundary measurement not implemented | BLOCKED: device not connected | Manual device measurement required |
| `background` | ADAPTER: macOS has no iOS background-mode equivalent | BLOCKED: device not connected | iOS `AVAudioSession` configuration is defined |
| `media-key` | BLOCKED: interactive media-key assertion not automated | BLOCKED: device not connected | iOS remote command configuration is defined |

No format is marked PASS until the AVFoundation probe runs. Non-native formats
must use a compatibility copy or server transcode only after a native playback
failure; do not transcode an original preemptively.

## iPhone rerun procedure

Run the same package on a connected iPhone test target, set
`AUDIO_VALIDATION_FIXTURES` to the generated library, invoke
`IPhonePlaybackProbe.probeAndWriteJSON(root:to:)`, which persists the returned
11 case IDs directly (or use
`PlaybackProbe.probeAndWriteJSON(root:to:)` on macOS). Test gapless
transitions, backgrounding, media keys, and authenticated HTTPS Range manually.
Failed cases: macOS SwiftPM execution is blocked because the active
Command Line Tools installation does not expose XCTest to the SwiftPM test
target (the initial run also reported Swift 6.3.3 compiler versus Swift 6.3.2
SDK interface mismatch); no iPhone device was connected.

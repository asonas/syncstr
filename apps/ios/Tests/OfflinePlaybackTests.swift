import AVFoundation
import MediaPlayer
import XCTest
@testable import Syncstr

final class OfflinePlaybackTests: XCTestCase {
    @MainActor
    func testSavedTrackIsRestoredAndPlayedLocallyOnlyForItsAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = OfflineTracks(root: root)
        let account = "https://fixture.invalid\u{1f}listener"
        let temporary = root.appendingPathComponent("test.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        do {
            let audio = try AVAudioFile(forWriting: temporary, settings: format.settings)
            try audio.write(from: buffer)
        }
        try files.save(temporary, account: account, id: "voyager", suffix: "wav")
        XCTAssertTrue(files.contains(account: account, id: "voyager", suffix: "wav"))
        XCTAssertFalse(files.contains(account: "https://other.invalid\u{1f}listener", id: "voyager", suffix: "wav"))
        XCTAssertFalse(files.contains(account: "https://fixture.invalid\u{1f}someone-else", id: "voyager", suffix: "wav"))

        let store = CredentialStore(service: "as.ason.syncstr.offline-test." + UUID().uuidString)
        defer { Task { try? await store.remove() } }
        try await store.save(LoginCredentials(server: "https://fixture.invalid", username: "listener", password: "fixture-password"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneAPIProtocol.self]
        var playbackURL: URL?
        var player: AVPlayer?
        let library = Library(session: URLSession(configuration: configuration), credentials: store, makePlayer: {
            playbackURL = $0
            let created = AVPlayer(url: $0)
            player = created
            return created
        }, localStore: LocalMusicStore(root: root.appendingPathComponent("local")))
        library.offlineTracks = OfflineTracks(root: root)
        await library.restoreCredentials()
        XCTAssertEqual(library.downloaded, ["voyager"])
        library.play(library.tracks[0])
        XCTAssertEqual(playbackURL, files.url(account: account, id: "voyager", suffix: "wav"))
        XCTAssertTrue(playbackURL!.isFileURL)
        for _ in 0..<100 where player?.currentItem?.status == .unknown {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player?.currentItem?.status, .readyToPlay)
        library.disconnect()
        XCTAssertTrue(library.downloaded.isEmpty)
        XCTAssertTrue(files.contains(account: account, id: "voyager", suffix: "wav"))
    }

    @MainActor
    func testNowPlayingTracksSelectionPositionAndLogout() async throws {
        let library = Library()
        let playback = PhonePlayback(library: library)
        library.current = Track(id: "fixture", title: "Voyager", artist: "Daft Punk", duration: 262)
        library.duration = 262
        library.position = 7
        library.playing = true
        for _ in 0..<10 { await Task.yield() }
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Voyager")
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 7)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        library.current = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        withExtendedLifetime(playback) {}
    }
}

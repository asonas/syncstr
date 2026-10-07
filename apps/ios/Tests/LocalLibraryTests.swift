import AVFoundation
import CryptoKit
import XCTest
@testable import Syncstr

final class LocalLibraryTests: XCTestCase {
    @MainActor
    func testFirstLaunchIsReadyForPairingAndUnsavedAudioCannotPlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalMusicStore(root: root)
        var createdPlayer = false
        let library = Library(makePlayer: { url in
            createdPlayer = true
            return AVPlayer(url: url)
        }, localStore: files)
        await library.restoreLibrary()
        XCTAssertFalse(library.connected)
        XCTAssertFalse(library.restoringSession)
        XCTAssertNil(library.message)
        let track = Track(id: "unsaved", title: "Not Copied", artist: "Fixture Artist", suffix: "wav", size: 3)
        try library.openLocal(LocalCatalog(id: UUID().uuidString, name: "Fixture Music", entries: [
            LocalEntry(track: track, sha256: String(repeating: "a", count: 64), artwork: nil)
        ]))
        library.play(track)
        XCTAssertFalse(createdPlayer)
        XCTAssertTrue(library.downloaded.isEmpty)
        XCTAssertNotNil(library.message)
        library.closeLibrary()
    }

    @MainActor
    func testColdLaunchMigratesLegacyCatalogAndPlaysReceivedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalMusicStore(root: root)
        try files.prepare()
        let temporary = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            try file.write(from: buffer)
        }
        let audio = try Data(contentsOf: temporary)
        let hash = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let track = Track(id: "local-fixture", title: "First", artist: "Fixture Artist", album: "Fixture Album",
            duration: 1, track: 1, suffix: "wav", size: UInt64(audio.count))
        let entry = LocalEntry(track: track, sha256: hash, artwork: nil)
        try files.importFile(temporary, entry: entry)
        let catalog = LocalCatalog(id: UUID().uuidString, name: "Fixture Music", entries: [entry])
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("catalog.json"))
        try Data().write(to: root.appendingPathComponent("active"))

        var playbackURL: URL?
        var player: AVPlayer?
        let restored = Library(makePlayer: { url in
            playbackURL = url
            let value = AVPlayer(url: url)
            player = value
            return value
        }, localStore: files)
        await restored.restoreLibrary()
        XCTAssertTrue(restored.connected)
        XCTAssertEqual(restored.albums.first?.title, "Fixture Album")
        XCTAssertEqual(restored.downloaded, [track.id])
        restored.play(restored.tracks[0])
        XCTAssertEqual(playbackURL, files.fileURL(entry))
        for _ in 0..<100 where player?.currentItem?.status == .unknown {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player?.currentItem?.status, .readyToPlay)
        restored.pause()
        restored.closeLibrary()
        XCTAssertTrue(files.hasFile(entry))
    }
}

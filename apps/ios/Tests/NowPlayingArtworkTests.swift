import MediaPlayer
import UIKit
import XCTest
@testable import Syncstr

@MainActor
final class NowPlayingArtworkTests: XCTestCase {
    func testArtworkIsPublishedAndClearedForTheNextTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let entry = LocalEntry(track: Track(id: "art", title: "With artwork", artist: "Artist", album: "With artwork", coverArt: "art", suffix: "mp3", size: 4),
                               sha256: String(repeating: "a", count: 64), artwork: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)))
        let plain = LocalEntry(track: Track(id: "plain", title: "Without artwork", artist: "Artist", album: "Without artwork", suffix: "mp3", size: 4),
                               sha256: String(repeating: "b", count: 64), artwork: nil)
        let store = LocalMusicStore(root: root)
        let catalog = LocalCatalog(id: "fixture", name: "Fixture", entries: [entry, plain])
        try store.save(catalog)
        let library = Library(localStore: store)
        defer { library.closeLibrary() }
        try library.openLocal(catalog)
        let playback = PhonePlayback(library: library)
        library.play(try XCTUnwrap(library.tracks.first(where: { $0.id == "art" })), in: library.tracks)
        for _ in 0..<100 {
            if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        library.pause()
        await Task.yield()
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        library.play(try XCTUnwrap(library.tracks.first(where: { $0.id == "plain" })))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        withExtendedLifetime(playback) {}
    }
}

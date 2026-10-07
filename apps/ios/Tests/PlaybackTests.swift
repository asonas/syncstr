import AVFoundation
import MediaPlayer
import XCTest
@testable import Syncstr

final class OfflinePlaybackTests: XCTestCase {
    @MainActor
    func testNowPlayingTracksSelectionPositionAndLibraryClosure() async throws {
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
        library.closeLibrary()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        withExtendedLifetime(playback) {}
    }
}

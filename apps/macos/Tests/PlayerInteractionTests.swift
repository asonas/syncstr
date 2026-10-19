import AVFoundation
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
final class PlayerInteractionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func library() throws -> Library {
        let library = Library(localStore: LocalMusicStore(root: root))
        let entries = (1...5).map { number in
            LocalEntry(track: Track(id: "track-\(number)", title: "Track \(number)", artist: "Artist",
                duration: 20, suffix: "wav", size: 4), sha256: String(repeating: String(number), count: 64), artwork: nil)
        }
        try library.openLocal(LocalCatalog(id: "fixture-library", name: "Fixture", entries: entries))
        return library
    }

    func testAlbumPlaybackReplacesQueueAndNormalPlayClearsShuffle() throws {
        let library = try library()
        defer { library.closeLibrary() }
        let album = Array(library.tracks.prefix(3))
        library.startAlbum(album, shuffled: true)
        XCTAssertTrue(library.shuffled)
        XCTAssertEqual(Set(library.queue.map(\.id)), Set(album.map(\.id)))
        XCTAssertEqual(library.queue.count, album.count)
        XCTAssertEqual(library.current?.id, library.queue.first?.id)
        library.pause()
        library.startAlbum(album)
        XCTAssertFalse(library.shuffled)
        XCTAssertEqual(library.queue.map(\.id), album.map(\.id))
        XCTAssertEqual(library.current?.id, album.first?.id)
    }

    func testPausedNavigationThresholdAndStableSourceQueue() throws {
        let library = try library()
        let source = library.tracks
        library.play(source[1], in: source)
        library.pause()
        library.search = "Track 5"
        library.navigate(.artists)
        XCTAssertEqual(library.queue.map(\.id), source.map(\.id))
        library.position = 3
        library.previous()
        XCTAssertEqual(library.current?.id, source[1].id)
        XCTAssertEqual(library.position, 0)
        library.position = 2.99
        library.previous()
        XCTAssertEqual(library.current?.id, source[0].id)
        XCTAssertTrue(library.canGoPrevious)
        library.next()
        XCTAssertEqual(library.current?.id, source[1].id)
        XCTAssertFalse(library.playing)
        XCTAssertFalse(library.loading)
        XCTAssertNil(library.playbackFailure)
        library.closeLibrary()
    }

    func testAlbumPlayKeepsPendingAcquisitionOfItsFirstTrack() async throws {
        let library = try library()
        let album = Array(library.tracks.prefix(3))
        library.play(album[0])
        XCTAssertTrue(library.loading)
        library.togglePlayback(in: album)
        XCTAssertTrue(library.loading)
        XCTAssertEqual(library.queue.map(\.id), album.map(\.id))
        let traces = await library.diagnostics.recent()
        XCTAssertEqual(traces.count, 1)
        XCTAssertFalse(traces.first?.events.contains { $0.event == "stop_or_replace" } == true)
        library.closeLibrary()
    }

    func testAlbumPlayRestartsAndQueueSelectionDoesNotRebuild() throws {
        let library = try library()
        let source = library.tracks
        library.play(source[2], in: Array(source.prefix(4)))
        library.pause()
        library.position = 9
        library.togglePlayback(in: Array(source.prefix(2)))
        XCTAssertEqual(library.current?.id, source[0].id)
        XCTAssertEqual(library.position, 0)
        XCTAssertEqual(library.queue.map(\.id), Array(source.prefix(2)).map(\.id))
        library.play(source[1])
        XCTAssertEqual(library.queue.count, 2)
        library.closeLibrary()
    }

    func testShufflePreservesTraversedPrefixAndRestoresExactOrderPaused() throws {
        let library = try library()
        let source = library.tracks
        library.play(source[2], in: source)
        library.pause()
        library.position = 7
        library.setShuffle(true)
        XCTAssertEqual(library.queue.prefix(3).map(\.id), source.prefix(3).map(\.id))
        XCTAssertEqual(Set(library.queue.map(\.id)), Set(source.map(\.id)))
        XCTAssertEqual(library.position, 7)
        XCTAssertFalse(library.playing)
        library.setShuffle(false)
        XCTAssertEqual(library.queue.map(\.id), source.map(\.id))
        XCTAssertEqual(library.position, 7)
        library.closeLibrary()
    }

    func testColdRestoreRetainsQueueOptionsAndPositionWithoutAcquiring() throws {
        let first = try library()
        first.play(first.tracks[2], in: first.tracks)
        first.pause()
        first.position = 8
        first.setShuffle(true)
        first.repeatMode = .all
        let order = first.queue.map(\.id)
        let restored = try library()
        XCTAssertEqual(restored.current?.id, first.current?.id)
        XCTAssertEqual(restored.position, 8)
        XCTAssertEqual(restored.queue.map(\.id), order)
        XCTAssertTrue(restored.shuffled)
        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertFalse(restored.playing)
        XCTAssertFalse(restored.loading)
        XCTAssertNil(restored.playbackFailure)
        restored.closeLibrary()
        first.closeLibrary()
    }

    func testDeletedCurrentTrackIsRetainedAsUnavailableAndNeverSubstituted() throws {
        let library = try library()
        let selected = library.tracks[1]
        library.play(selected, in: library.tracks)
        library.pause()
        var catalog = try XCTUnwrap(library.localCatalog)
        catalog.entries.removeAll { $0.track.id == selected.id }
        try library.openLocal(catalog)
        XCTAssertEqual(library.current?.id, selected.id)
        XCTAssertNotNil(library.playbackFailure)
        library.resumePlayback()
        XCTAssertFalse(library.loading)
        XCTAssertFalse(library.playing)
        library.closeLibrary()
    }

    func testCancelledPreparationCannotPublishLateFailureOrResume() async throws {
        let library = try library()
        library.play(library.tracks[0], in: library.tracks)
        XCTAssertTrue(library.loading)
        library.pause()
        library.next()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(library.current?.id, "track-2")
        XCTAssertFalse(library.loading)
        XCTAssertFalse(library.playing)
        XCTAssertNil(library.playbackFailure)
        library.closeLibrary()
    }

    func testCacheBudgetEvictsOldAudioButProtectsActiveAndSavedFiles() throws {
        let cache = PlaybackCache(root: root.appendingPathComponent("cache"))
        try cache.store.prepare()
        let saved = root.appendingPathComponent("saved.wav")
        try Data([1, 2, 3]).write(to: saved)
        let old = cache.store.root.appendingPathComponent(String(repeating: "a", count: 64) + ".wav")
        let recent = cache.store.root.appendingPathComponent(String(repeating: "b", count: 64) + ".wav")
        for url in [old, recent] {
            try Data(repeating: 0, count: 6).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        cache.protectedURL = recent
        try cache.setLimit(1)
        try cache.trim(incoming: 999_999_994)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(try Data(contentsOf: saved), Data([1, 2, 3]))
        let reopened = PlaybackCache(root: cache.store.root)
        XCTAssertEqual(reopened.limitGB, 1)
        try cache.trim(incoming: 1_000_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        cache.protectedURL = nil
        try cache.trim(incoming: 1_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recent.path))
    }

    func testBackgroundAcquisitionStopsUntilExplicitForegroundRetry() async throws {
        let library = try library()
        library.play(library.tracks[0], in: library.tracks)
        library.setBackgrounded(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(library.loading)
        XCTAssertFalse(library.playing)
        XCTAssertNotNil(library.playbackFailure)
        library.setBackgrounded(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(library.loading)
        XCTAssertFalse(library.playing)
        library.closeLibrary()
    }
}

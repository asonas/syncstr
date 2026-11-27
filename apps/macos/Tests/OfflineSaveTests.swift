import AVFoundation
import Combine
import Foundation
import SQLite3
import XCTest
#if os(macOS)
import Network
#endif
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
extension XCTestCase {
    private func addTimedTeardown(_ description: String, _ cleanup: @escaping @MainActor () async throws -> Void) {
        addTeardownBlock { @MainActor in
            let finished = XCTestExpectation(description: description)
            let task = Task {
                defer { finished.fulfill() }
                try await cleanup()
            }
            guard await XCTWaiter.fulfillment(of: [finished], timeout: 15) == .completed else {
                task.cancel()
                return XCTFail("Timed out during teardown: \(description)")
            }
            try await task.value
        }
    }

    func removeStoreAfterTest(_ root: URL) {
        addTimedTeardown("remove store") {
            await CatalogStorage.shared.closeDatabase(at: root)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    func makeLibrary(makePlayer: @escaping (URL) -> AVPlayer = { SharedAudioPlayback.player($0) },
                     localStore: LocalMusicStore, hostConfiguration: URLSessionConfiguration = .ephemeral) -> Library {
        let library = Library(makePlayer: makePlayer, localStore: localStore, hostConfiguration: hostConfiguration, pathMonitor: nil)
        addTimedTeardown("stop library and drain background work") {
            await library.transfer.stopAndWait()
            library.closeLibrary()
            await library.inventoryTask?.value
            await library.transfer.playbackCache.maintenance?.value
            // The diagnostics writer shares the store directory.
            _ = await library.diagnostics.recent()
            await CatalogStorage.shared.closeDatabase(at: localStore.root)
        }
        return library
    }

    func makeTransfer(store: LocalMusicStore, hostConfiguration: URLSessionConfiguration = .ephemeral) -> LocalTransfer {
        let transfer = LocalTransfer(store: store, hostConfiguration: hostConfiguration, pathMonitor: nil)
        addTimedTeardown("stop transfer and close database") {
            await transfer.stopAndWait()
            await CatalogStorage.shared.closeDatabase(at: store.root)
        }
        return transfer
    }

    func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the expected state", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

func saveHostFixture(_ entries: [LocalEntry], in store: LocalMusicStore) throws {
    let database = try store.database()
    let catalog = LocalCatalog(id: "fixture", name: "Library", entries: entries, source: .host)
    let host = try HostConnection(address: HostAddress("https://music.example.test"), library: catalog.id,
                                  name: catalog.name, hosts: [])
    try database.saveHostCatalog(CatalogUpdate(catalog: catalog, etag: "fixture"), connection: host,
                                 replacing: database.hostConnection())
}

/// Overwrites one stored host entry with a payload that cannot be decoded.
func breakStoredHostEntry(_ id: String, in store: LocalMusicStore) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection) == SQLITE_OK else {
        sqlite3_close(connection)
        throw LocalMusicError.invalidData
    }
    defer { sqlite3_close(connection) }
    let id = id.replacingOccurrences(of: "'", with: "''")
    guard sqlite3_exec(connection, "UPDATE host_entries SET payload = '{' WHERE id = '\(id)'", nil, nil, nil) == SQLITE_OK,
          sqlite3_changes(connection) == 1 else { throw LocalMusicError.invalidData }
}

/// Clears the key of one stored host entry, as a database written by an older build may hold.
func clearStoredHostEntryKey(_ id: String, in store: LocalMusicStore) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection) == SQLITE_OK else {
        sqlite3_close(connection)
        throw LocalMusicError.invalidData
    }
    defer { sqlite3_close(connection) }
    let id = id.replacingOccurrences(of: "'", with: "''")
    guard sqlite3_exec(connection, "UPDATE host_entries SET id = NULL WHERE id = '\(id)'", nil, nil, nil) == SQLITE_OK,
          sqlite3_changes(connection) == 1 else { throw LocalMusicError.invalidData }
}

/// Stores the catalog as a host's and shows it without contacting the host, for tests about browsing and playback state.
@MainActor
func showHostCatalog(_ catalog: LocalCatalog, in library: Library) throws {
    var catalog = catalog
    catalog.source = .host
    catalog.organize()
    let database = try library.localStore.database()
    let host = try HostConnection(address: HostAddress("https://music.example.test"), library: catalog.id,
                                  name: catalog.name, hosts: [])
    try database.saveHostCatalog(CatalogUpdate(catalog: catalog, etag: "fixture"), connection: host,
                                 replacing: database.hostConnection())
    try showStoredCatalog(in: library)
}

@MainActor
func showStoredCatalog(in library: Library) throws {
    guard let snapshot = try library.localStore.snapshot() else { throw LocalMusicError.invalidData }
    try library.transfer.onCatalog?(PreparedLocalCatalog(snapshot.catalog, store: library.localStore))
}

/// Holds an async step until the test opens it.
@MainActor
final class Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
final class OfflineSaveTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testDeletingAllSavedMusicAfterCompletedSavesFreesEveryFile() async throws {
        let (store, entries) = try fixture()
        for (number, entry) in entries.enumerated() {
            try Data(repeating: UInt8(number + 1), count: 1024).write(to: store.fileURL(entry))
            try store.database().saveAudioPin(entry)
        }
        // A file placed by a save that never pinned it, and a playback cache file that must stay.
        let unpinned = store.root.appendingPathComponent(String(repeating: "e", count: 64) + ".mp3")
        try Data(repeating: 7, count: 512).write(to: unpinned)
        let transfer = try await hostTransfer(store)
        try cache(entries[0], transfer: transfer, number: 1)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [
            OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]],
                               completed: [entries[0].trackSaveIdentity], state: .complete),
            OfflineSaveRequest(id: "album:a", library: library, entries: [entries[1], entries[2]],
                               completed: Set(entries[1...2].map(\.trackSaveIdentity)), state: .complete)
        ]
        await transfer.refreshSavedAudio()
        XCTAssertEqual(transfer.savedAudio.bytes, 3 * 1024 + 512)

        try await transfer.removeAllSavedAudio()

        for entry in entries { XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(entry).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpinned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transfer.playbackCache.store.fileURL(entries[0]).path))
        XCTAssertTrue(try store.database().savedAudioPinList().isEmpty)
        XCTAssertTrue(transfer.saveRequests.isEmpty)
        let persisted = try JSONDecoder().decode([OfflineSaveRequest].self,
                                                 from: Data(contentsOf: store.root.appendingPathComponent("offline-saves.json")))
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(transfer.savedAudio, SavedAudioSummary())
    }

    func testDeletingAllSavedMusicWaitsForASaveThatPinsAfterCancellation() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]], state: .saving)]
        let latch = Latch()
        // A download that has already written its file pins it even though the save was just cancelled.
        transfer.saveWorker = Task {
            await latch.wait()
            try? Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
            try? store.database().saveAudioPin(entries[0])
        }
        let pinning = transfer.saveWorker
        let removal = Task { try await transfer.removeAllSavedAudio() }
        try await waitFor { transfer.saveWorker == nil }
        // Long enough for a removal that does not wait for the worker to finish first.
        try await Task.sleep(for: .milliseconds(200))
        latch.open()
        try await removal.value
        await pinning?.value
        XCTAssertTrue(try store.database().savedAudioPinList().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(entries[0]).path))
    }

    func testSecondDeletionWaitsForTheFirstSoNoSaveStartsHalfway() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        let latch = Latch()
        transfer.saveWorker = Task { await latch.wait() }
        let first = Task { try await transfer.removeAllSavedAudio() }
        try await waitFor { transfer.saveWorker == nil }
        let second = Task { try await transfer.removeAllSavedAudio() }
        try await Task.sleep(for: .milliseconds(100))
        // The first removal still waits for the old worker; no new worker may start in the meantime.
        transfer.saveRequests = [OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]])]
        transfer.resumeSaves()
        XCTAssertNil(transfer.saveWorker)
        latch.open()
        try await first.value
        try await second.value
        XCTAssertTrue(transfer.saveRequests.isEmpty)
    }

    func testSaveAskedForDuringDeletionGoesAheadAfterIt() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        let latch = Latch()
        transfer.saveWorker = Task { await latch.wait() }
        let removal = Task { try await transfer.removeAllSavedAudio() }
        try await waitFor { transfer.saveWorker == nil }
        let save = Task { await transfer.requestSave([entries[0].track], scope: "track:track-1") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transfer.saveRequests.isEmpty, "The save waits until the removal ends")
        latch.open()
        try await removal.value
        await save.value
        XCTAssertEqual(transfer.saveRequests.map(\.id), ["track:track-1"])
    }

    func testSaveBeingPreparedWhenEverythingIsRemovedIsDropped() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        // Occupying the catalog queue holds the save's catalog read until the removal has started.
        let hold = DispatchSemaphore(value: 0)
        // Released on every exit, so a failure cannot leave the shared catalog queue blocked for later tests.
        defer { hold.signal() }
        let entered = DispatchSemaphore(value: 0)
        let blocker = Task.detached { try await CatalogStorage.shared.perform { entered.signal(); hold.wait() } }
        // The save starts only once the queue is held; otherwise its read can finish before the removal.
        let holding = await Task.detached { entered.wait(timeout: .now() + 15) }.value
        guard holding == .success else { return XCTFail("The catalog queue was not held") }
        let save = Task { await transfer.requestSave([entries[0].track], scope: "track:track-1") }
        try await waitFor { !transfer.preparingSaves.isEmpty }
        let removal = Task { try await transfer.removeAllSavedAudio() }
        // The queue stays held until the removal has dropped the preparation, so a later request cannot hide a missing cancel.
        try await waitFor { transfer.preparingSaves.isEmpty }
        hold.signal()
        try await blocker.value
        try await removal.value
        await save.value
        XCTAssertTrue(transfer.saveRequests.isEmpty)
    }

    func testUnreadableSavedFolderIsNotTakenForAnEmptyOne() throws {
        let (store, entries) = try fixture(host: false)
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        XCTAssertEqual(try store.audioFiles().keys.sorted(), [entries[0].sha256])
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: store.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.root.path) }
        // Removing everything would otherwise drop every pin while the files stay.
        XCTAssertThrowsError(try store.audioFiles())
        XCTAssertTrue(try LocalMusicStore(root: root.appendingPathComponent("missing")).audioFiles().isEmpty)
    }

    func testFileThatCannotBeDeletedKeepsItsPinAndRequestForAnotherTry() async throws {
        let (fixtureStore, entries) = try fixture()
        var store = fixtureStore
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let undeletable = store.fileURL(entries[0])
        store.removeFile = { url in
            if url.lastPathComponent == undeletable.lastPathComponent { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let transfer = try await hostTransfer(store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]],
                                                    completed: [entries[0].trackSaveIdentity], state: .complete)]
        let pin = SavedAudioPin(track: entries[0].track.id, hash: entries[0].sha256)
        do {
            try await transfer.removeAllSavedAudio()
            XCTFail("Reported success while the file remained")
        } catch LocalMusicError.removalIncomplete {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: undeletable.path))
        transfer.store.removeFile = { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(try store.database().savedAudioPinList(), [pin])
        XCTAssertEqual(transfer.savedAudio.pins, [pin])
        XCTAssertEqual(transfer.saveRequests.map(\.id), ["track:track-1"])
        try await transfer.removeAllSavedAudio()
        XCTAssertTrue(try store.database().savedAudioPinList().isEmpty)
        XCTAssertTrue(transfer.saveRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(entries[0]).path))
    }

    func testSaveRequestKeepsSelectionOrderWithoutDuplicates() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        let tracks = [entries[1].track, entries[0].track, entries[1].track, entries[0].track]
        await transfer.requestSave(tracks, scope: "playlist")
        XCTAssertEqual(transfer.saveRequests.first?.entries.map(\.track.id), [entries[1].track.id, entries[0].track.id])
        transfer.stopSaveWorker()
    }

    func testTrackThatCannotBeSavedDoesNotEndARequestStillWaitingForAnother() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try breakStoredHostEntry(entries[1].track.id, in: store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        // The host now has other content under the first track, so that track cannot be saved; the second
        // only waits for its unreadable row to come back.
        let changed = LocalEntry(track: entries[0].track, sha256: String(repeating: "f", count: 64))
        transfer.saveRequests = [OfflineSaveRequest(id: "album", library: library, entries: [changed, entries[1]])]
        transfer.saveRetryInterval = .seconds(60)
        transfer.resumeSaves()
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .waiting)
        XCTAssertEqual(transfer.saveRequests.first?.failedTracks, [entries[0].track.id])
        transfer.stopSaveWorker()
    }

    func testPendingSaveOfAnUnresolvedTrackKeepsTheAlbumFromLookingSaved() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        await library.inventoryTask?.value
        XCTAssertTrue(library.hasManagedCopy(entries[0].track))
        let catalog = try XCTUnwrap(library.localCatalog?.id)
        library.transfer.saveRequests = [OfflineSaveRequest(id: "album", library: catalog, entries: [entries[0]],
                                                            completed: [entries[0].trackSaveIdentity], unresolved: [entries[1].track])]
        let progress = library.saveProgress(for: [entries[0].track], scope: "album")
        XCTAssertEqual(progress, SaveProgress(saved: 1, total: 2, pending: true))
        XCTAssertFalse(progress.allSaved)
    }

    func testRetryKeepsATrackTheListNoLongerShowsAsFailed() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        // The album failed because one track left the host; the list now shows only the track that remains.
        var failed = OfflineSaveRequest(id: "album", library: library, entries: [entries[0]], state: .failed)
        failed.failedTracks = ["track-gone"]
        transfer.saveRequests = [failed]
        await transfer.requestSave([entries[0].track], scope: "album")
        transfer.stopSaveWorker()
        let retried = try XCTUnwrap(transfer.saveRequests.first)
        XCTAssertEqual(retried.entries.map(\.track.id), [entries[0].track.id])
        XCTAssertEqual(retried.failedTracks, ["track-gone"])
        XCTAssertEqual(retried.trackCount, 2)
        XCTAssertNotEqual(retried.state, .complete)
    }

    func testOnlyUnreadableRowsKeepAMissingTrackWaiting() async throws {
        let (store, entries) = try fixture()
        try breakStoredHostEntry(entries[1].track.id, in: store)
        let transfer = try await hostTransfer(store)
        transfer.catalogRepairInterval = .seconds(3600)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        let gone = Track(id: "track-gone", title: "Gone", artist: "Artist", suffix: "wav", size: 3)
        transfer.saveRequests = [OfflineSaveRequest(id: "album", library: library, entries: [],
                                                    unresolved: [entries[1].track, gone], manual: true)]
        let settledState = expectation(description: "worker finished one pass")
        let observation = transfer.$saveRequests.filter { $0.first?.failedTracks.isEmpty == false }.first()
            .sink { _ in settledState.fulfill() }
        transfer.resumeSaves()
        await fulfillment(of: [settledState], timeout: 15)
        observation.cancel()
        transfer.stopSaveWorker()
        let request = try XCTUnwrap(transfer.saveRequests.first)
        // The keyed unreadable row waits; a track that is simply gone does not.
        XCTAssertEqual(request.failedTracks, [gone.id])
        XCTAssertEqual(request.unresolved.map(\.id), [entries[1].track.id])
        XCTAssertEqual(request.state, .waiting)
    }

    func testRowTheWholeCatalogLeftUnreadableFailsUntilAskedAgain() async throws {
        let (store, entries) = try fixture()
        try breakStoredHostEntry(entries[1].track.id, in: store)
        let transfer = try await hostTransfer(store)
        transfer.catalogRepairInterval = .seconds(3600)
        transfer.unrepairableIDs = [entries[1].track.id]
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [OfflineSaveRequest(id: "track", library: library, entries: [],
                                                    unresolved: [entries[1].track], manual: true)]
        let failed = expectation(description: "save failed")
        let observation = transfer.$saveRequests.filter { $0.first?.state == .failed }.first().sink { _ in failed.fulfill() }
        transfer.resumeSaves()
        await fulfillment(of: [failed], timeout: 15)
        observation.cancel()
        transfer.stopSaveWorker()
        XCTAssertEqual(transfer.saveRequests.first?.failedTracks, [entries[1].track.id])
        XCTAssertEqual(transfer.saveRequests.first?.error, "ホストのライブラリにあるこの曲の情報を読み込めないため、保存できません。")

        // Asking again gives the row another repair, so the save waits for it instead of failing at once.
        await transfer.requestSave([entries[1].track], scope: "track")
        transfer.stopSaveWorker()
        XCTAssertTrue(transfer.unrepairableIDs.isEmpty)
        XCTAssertEqual(transfer.saveRequests.first?.unresolved.map(\.id), [entries[1].track.id])
        XCTAssertTrue(transfer.saveRequests.first?.isPending ?? false)
    }

    func testTrackMenuDescribesAnAlbumRequestByThatTracksOwnState() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        await library.inventoryTask?.value
        let catalog = try XCTUnwrap(library.localCatalog?.id)
        var album = OfflineSaveRequest(id: "album", library: catalog, entries: Array(entries.prefix(3)),
                                       completed: [entries[0].trackSaveIdentity], state: .failed)
        album.failedTracks = [entries[1].track.id]
        library.transfer.saveRequests = [album]
        // Saved, so the album's failure is not this track's.
        XCTAssertNil(library.saveRequest(for: [entries[0].track], scope: "track:\(entries[0].track.id)"))
        XCTAssertEqual(library.saveRequest(for: [entries[1].track], scope: "track:\(entries[1].track.id)")?.state, .failed)
        // Not saved and not failed: it can be saved on its own.
        XCTAssertNil(library.saveRequest(for: [entries[2].track], scope: "track:\(entries[2].track.id)"))
    }

    func testPartialDeletionKeepsLeftoverRequestsFromSavingAgain() async throws {
        let (fixtureStore, entries) = try fixture()
        var store = fixtureStore
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let undeletable = store.fileURL(entries[0])
        store.removeFile = { url in
            if url.lastPathComponent == undeletable.lastPathComponent { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let transfer = try await hostTransfer(store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        var album = OfflineSaveRequest(id: "album", library: library, entries: [entries[0], entries[1]], state: .waiting)
        album.failedTracks = [entries[1].track.id]
        transfer.saveRequests = [album]
        do {
            try await transfer.removeAllSavedAudio()
            XCTFail("Reported success while the file remained")
        } catch LocalMusicError.removalIncomplete {}
        try await settled(transfer)
        let kept = try XCTUnwrap(transfer.saveRequests.first)
        XCTAssertEqual(kept.entries.map(\.track.id), [entries[0].track.id])
        XCTAssertTrue(kept.failedTracks.isEmpty, "The failure of a track whose request was removed does not stay")
        XCTAssertFalse(kept.isPending)
        XCTAssertNil(transfer.saveWorker)
        let queue = try JSONDecoder().decode([OfflineSaveRequest].self, from: Data(contentsOf: store.root.appendingPathComponent("offline-saves.json")))
        XCTAssertEqual(queue.first?.isPending, false)
        transfer.store.removeFile = { try FileManager.default.removeItem(at: $0) }
    }

    func testQueueWrittenBeforeUnresolvedTracksStillDecodes() throws {
        let (store, entries) = try fixture()
        let entry = String(decoding: try JSONEncoder().encode(entries[0]), as: UTF8.self)
        let old = #"[{"id":"track:track-1","library":"library","entries":["# + entry + #"],"completed":[],"state":"waiting"}]"#
        try store.prepare()
        try Data(old.utf8).write(to: store.root.appendingPathComponent("offline-saves.json"))
        let transfer = LocalTransfer(store: store, pathMonitor: nil)
        let request = try XCTUnwrap(transfer.saveRequests.first)
        XCTAssertEqual(request.entries, [entries[0]])
        XCTAssertTrue(request.unresolved.isEmpty)
        XCTAssertFalse(request.manual)
        XCTAssertTrue(request.failedTracks.isEmpty)
        XCTAssertEqual(request.state, .waiting)
    }

    func testRequestWithATrackGoneFromTheWholeCatalogStaysFailedAfterRestart() async throws {
        let (store, _) = try fixture()
        let transfer = try await hostTransfer(store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        let gone = Track(id: "track-gone", title: "Gone", artist: "Artist", suffix: "mp3", size: 3)
        // The catalog has no unreadable rows, so a track it lacks has left the host.
        transfer.saveRequests = [OfflineSaveRequest(id: "album", library: library, entries: [], unresolved: [gone], manual: true)]
        let failed = expectation(description: "request failed")
        let observation = transfer.$saveRequests.filter { $0.first?.state == .failed }.first().sink { _ in failed.fulfill() }
        transfer.resumeSaves()
        await fulfillment(of: [failed], timeout: 15)
        observation.cancel()
        transfer.stopSaveWorker()
        XCTAssertEqual(transfer.saveRequests.first?.failedTracks, [gone.id])

        let reopened = LocalTransfer(store: store, pathMonitor: nil)
        let restored = try XCTUnwrap(reopened.saveRequests.first)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(restored.failedTracks, [gone.id])
        XCTAssertEqual(restored.trackCount, 1)

        let shown = makeLibrary(localStore: store)
        await shown.openSavedLocalLibrary()
        shown.transfer.saveRequests = reopened.saveRequests
        let progress = shown.saveProgress(for: [], scope: "album")
        XCTAssertTrue(progress.failed)
        XCTAssertFalse(progress.allSaved)
    }

    func testPartialDeletionKeepsOnlyRequestsForFilesLeftBehind() async throws {
        let (fixtureStore, entries) = try fixture()
        var store = fixtureStore
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let undeletable = store.fileURL(entries[0])
        store.removeFile = { url in
            if url.lastPathComponent == undeletable.lastPathComponent { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let transfer = try await hostTransfer(store)
        try breakStoredHostEntry(entries[1].track.id, in: store)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [
            OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]],
                               completed: [entries[0].trackSaveIdentity], state: .complete),
            OfflineSaveRequest(id: "track:broken", library: library, entries: [], unresolved: [entries[1].track])
        ]
        do {
            try await transfer.removeAllSavedAudio()
            XCTFail("Reported success while the file remained")
        } catch LocalMusicError.removalIncomplete {}
        try await settled(transfer)
        // The waiting save for the unreadable track is gone, so nothing fetches it again; the request for
        // the file that stayed is kept so a later removal can try it.
        XCTAssertEqual(transfer.saveRequests.map(\.id), ["track:track-1"])
        XCTAssertEqual(transfer.saveRequests.first?.state, .complete)
        let queue = try JSONDecoder().decode([OfflineSaveRequest].self, from: Data(contentsOf: store.root.appendingPathComponent("offline-saves.json")))
        XCTAssertEqual(queue.map(\.id), ["track:track-1"])
        XCTAssertTrue(queue.allSatisfy { $0.unresolved.isEmpty })
        XCTAssertNil(transfer.saveWorker)
        transfer.store.removeFile = { try FileManager.default.removeItem(at: $0) }
    }

    func testDeletingAllSavedMusicDoesNotWaitForAHostRefresh() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let transfer = try await hostTransfer(store)
        transfer.busy = true
        defer { transfer.busy = false }
        try await transfer.removeAllSavedAudio()
        XCTAssertTrue(try store.database().savedAudioPinList().isEmpty)
    }

    func testDeletingAllSavedMusicStopsOnlyPlaybackFromTheSavedFolder() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        library.current = library.tracks.first { $0.id == entries[0].track.id }
        library.playing = true
        library.transfer.playbackCache.protectedURL = library.transfer.playbackCache.store.fileURL(entries[1])
        await library.removeAllSavedMusic()
        XCTAssertTrue(library.playing, "Audio from the playback cache keeps playing")
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        library.transfer.playbackCache.protectedURL = store.fileURL(entries[0])
        await library.removeAllSavedMusic()
        XCTAssertFalse(library.playing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(entries[0]).path))
    }

    func testRemovingOneSaveComparesTheAudioThePlayerHolds() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        await library.inventoryTask?.value
        let track = try XCTUnwrap(library.tracks.first { $0.id == entries[0].track.id })
        library.current = track
        library.playing = true
        // The player still holds audio from before a catalog update gave this track new content.
        library.transfer.playbackCache.protectedURL = library.transfer.playbackCache.store.fileURL(entries[1])
        library.removeLocalCopies([track])
        try await waitFor { library.pendingLocalCopyRemovals.isEmpty }
        XCTAssertTrue(library.playing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(entries[0]).path))
    }

    func testRemovingOneSaveKeepsAudioAnotherLibraryStillWantsToSave() throws {
        let (store, entries) = try fixture(host: false)
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        let transfer = makeTransfer(store: store)
        var shared = entries[0]
        shared.track.id = "other-library-track"
        transfer.saveRequests = [OfflineSaveRequest(id: "track:other", library: "other-library", entries: [shared])]
        try transfer.removeSavedCopy(entries[0])
        XCTAssertTrue(try store.database().savedAudioPinList().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(entries[0]).path))
    }

    func testCancelledFirstSaveLeavesNoFileOutsideTheSavedTotal() async throws {
        let (store, entries) = try fixture()
        // The file is already in place, as after a download whose save is cancelled before it pins.
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().recordReceived(entries[0])
        let transfer = try await hostTransfer(store)
        let source = try XCTUnwrap(transfer.makeLibrarySource())
        defer { source.stop() }
        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await source.download(entries[0], cache: nil, diagnostic: nil) { _ in }
        }
        _ = await save.result
        await transfer.refreshSavedAudio()
        XCTAssertEqual(try store.database().savedAudioPinList(), [SavedAudioPin(track: entries[0].track.id, hash: entries[0].sha256)])
        XCTAssertEqual(transfer.savedAudio.bytes, 1024)
    }

    func testCancelledSaveReleasesTheCacheFileItWasReading() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try cache(entries[0], transfer: transfer, number: 1)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]])]
        transfer.resumeSaves(explicit: "track:track-1")
        let worker = transfer.saveWorker
        await Task.yield()
        transfer.stopSaveWorker()
        await worker?.value
        XCTAssertTrue(transfer.playbackCache.protectedPaths.isEmpty)
    }

    func testRestoreRunsAgainWhenTheAppReturnsDuringARestore() async throws {
        let (store, entries) = try fixture()
        _ = try store.database().forgetHost()
        let library = makeLibrary(localStore: store)
        let latch = Latch()
        var attempts = 0
        library.transfer.beforeRestoringHost = {
            attempts += 1
            if attempts == 1 { await latch.wait() }
        }
        let first = Task { await library.restoreLibrary() }
        try await waitFor { attempts == 1 }
        // Going to the background cancels the restore; returning to the foreground asks for it again.
        library.transfer.cancel()
        let second = Task { await library.restoreLibrary() }
        try await Task.sleep(for: .milliseconds(50))
        latch.open()
        await first.value
        await second.value
        // Opening the retained catalog reads the host state once more after the retry.
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertEqual(library.localCatalog?.source, .host)
        XCTAssertEqual(library.tracks.count, entries.count)
    }

    func testRetainedCatalogWithAnUnreadableEntryStillOpensItsSavedMusic() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        _ = try store.database().forgetHost()
        try breakStoredHostEntry(entries[1].track.id, in: store)
        let library = makeLibrary(localStore: store)
        await library.restoreLibrary()
        XCTAssertEqual(library.localCatalog?.source, .host)
        XCTAssertEqual(Set(library.tracks.map(\.id)), [entries[0].track.id, entries[2].track.id])
        try await waitFor { library.localFiles[entries[0].track.id] != nil }
        let url = try await library.transfer.playbackFile(entries[0].track, allowAcquisition: false)
        XCTAssertEqual(url.resolvingSymlinksInPath().path, store.fileURL(entries[0]).resolvingSymlinksInPath().path)
    }

    func testRestoreRetriesAfterTheTaskThatStartedItIsCancelled() async throws {
        let (store, entries) = try fixture()
        _ = try store.database().forgetHost()
        let library = makeLibrary(localStore: store)
        let latch = Latch()
        var attempts = 0
        library.transfer.beforeRestoringHost = {
            attempts += 1
            if attempts == 1 { await latch.wait() }
        }
        let first = Task { await library.restoreLibrary() }
        try await waitFor { attempts == 1 }
        library.transfer.cancel()
        // The window task that started the restore ends; a later call must still finish the restore.
        first.cancel()
        let second = Task { await library.restoreLibrary() }
        try await Task.sleep(for: .milliseconds(50))
        latch.open()
        await first.value
        await second.value
        XCTAssertEqual(library.localCatalog?.source, .host)
        XCTAssertEqual(library.tracks.count, entries.count)
    }

    func testFailedRestoreRunsAgainOnTheNextActivation() async throws {
        let (store, entries) = try fixture()
        _ = try store.database().forgetHost()
        let library = makeLibrary(localStore: store)
        var attempts = 0
        library.transfer.beforeRestoringHost = {
            attempts += 1
            if attempts == 1 { library.transfer.cancel() }
        }
        await library.restoreLibrary()
        XCTAssertNil(library.localCatalog)
        // The Mac calls this whenever the app becomes active.
        await library.restoreLibrary()
        XCTAssertEqual(library.localCatalog?.source, .host)
        XCTAssertEqual(library.tracks.count, entries.count)
        let restored = attempts
        await library.restoreLibrary()
        XCTAssertEqual(attempts, restored)
    }

    func testDeletingAllSavedMusicCoversUnpinnedFilesAndWaitingRequests() async throws {
        let (store, entries) = try fixture()
        let leftover = store.root.appendingPathComponent(String(repeating: "d", count: 64) + ".mp3")
        try Data(repeating: 9, count: 256).write(to: leftover)
        let transfer = try await hostTransfer(store)
        await transfer.refreshSavedAudio()
        XCTAssertTrue(transfer.savedAudio.pins.isEmpty)
        XCTAssertEqual(transfer.savedAudio.unpinnedFiles, 1)
        XCTAssertEqual(transfer.savedAudio.bytes, 256)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [OfflineSaveRequest(id: "track:track-1", library: library, entries: [entries[0]], state: .wifi)]

        try await transfer.removeAllSavedAudio()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(transfer.saveRequests.isEmpty)
        XCTAssertEqual(transfer.savedAudio, SavedAudioSummary())
    }

    func testDeletingAllSavedMusicLeavesADirectoryWithAnAudioName() async throws {
        let (store, _) = try fixture()
        let directory = store.root.appendingPathComponent(String(repeating: "f", count: 64) + ".mp3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inside = directory.appendingPathComponent("inside")
        try Data([1]).write(to: inside)
        let transfer = try await hostTransfer(store)
        await transfer.refreshSavedAudio()
        XCTAssertEqual(transfer.savedAudio.unpinnedFiles, 0)

        try await transfer.removeAllSavedAudio()

        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testUsageCountsEveryFileOfTheSameAudio() async throws {
        let (store, entries) = try fixture()
        let bytes = Data(repeating: 1, count: 1024)
        try bytes.write(to: store.fileURL(entries[0]))
        try bytes.write(to: store.root.appendingPathComponent(entries[0].sha256 + ".audio"))
        try store.database().saveAudioPin(entries[0])
        let transfer = try await hostTransfer(store)
        await transfer.refreshSavedAudio()
        XCTAssertEqual(transfer.savedAudio.bytes, 2048)
    }

    func testBusyTransferReportsRemovalBusyInsteadOfInvalidData() throws {
        let (store, entries) = try fixture(host: false)
        let transfer = makeTransfer(store: store)
        transfer.busy = true
        XCTAssertThrowsError(try transfer.removeSavedCopy(entries[0])) { error in
            guard case LocalMusicError.transferBusy = error else {
                return XCTFail("Expected transferBusy, received \(error)")
            }
        }
        transfer.busy = false
        let invalid = LocalEntry(track: entries[0].track, sha256: "invalid", artwork: nil)
        XCTAssertThrowsError(try transfer.removeSavedCopy(invalid)) { error in
            guard case LocalMusicError.invalidData = error else {
                return XCTFail("Expected invalidData, received \(error)")
            }
        }
    }

    func testConfirmedRemovalResumesAfterSaveWorkerFinishesWithoutBusyChanging() async throws {
        let (store, entries) = try fixture()
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try Data(repeating: 2, count: 1024).write(to: store.fileURL(entries[1]))
        try store.database().saveAudioPin(entries[0])
        try store.database().saveAudioPin(entries[1])
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        await library.inventoryTask?.value
        library.transfer.setSavesBackgrounded(true)
        try cache(entries[2], transfer: library.transfer, number: 3)
        await library.transfer.requestSave([entries[2].track], scope: "track:track-3")
        library.transfer.setSavesBackgrounded(false)

        XCTAssertFalse(library.transfer.busy)
        XCTAssertNotNil(library.transfer.saveWorker)
        XCTAssertFalse(library.transfer.readyForLocalCopyRemoval)
        library.removeLocalCopies([entries[0].track])
        XCTAssertTrue(library.isLocalCopyRemovalPending(entries[0].track))
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertTrue(library.hasManagedCopy(entries[1].track))
        XCTAssertNotNil(library.transfer.saveWorker, "Confirmation must not cancel the active save")

        let completed = expectation(description: "Removal resumes after the real save worker finishes")
        let observation = library.$pendingLocalCopyRemovals.dropFirst().filter { $0.isEmpty }.prefix(1).sink { _ in
            completed.fulfill()
        }
        defer { observation.cancel() }
        await fulfillment(of: [completed], timeout: 2)

        await library.inventoryTask?.value
        XCTAssertFalse(library.transfer.busy)
        XCTAssertNil(library.transfer.saveWorker)
        XCTAssertTrue(library.transfer.readyForLocalCopyRemoval)
        XCTAssertTrue(library.pendingLocalCopyRemovals.isEmpty)
        XCTAssertFalse(store.hasFile(entries[0]))
        XCTAssertFalse(library.hasManagedCopy(entries[0].track))
        XCTAssertTrue(store.hasFile(entries[1]))
        XCTAssertTrue(library.hasManagedCopy(entries[1].track))
        XCTAssertTrue(store.hasFile(entries[2]))
        XCTAssertEqual(library.saveRequest(for: [entries[2].track], scope: "track:track-3")?.state, .complete)
        XCTAssertNil(library.message)
    }

    private func fixture(host: Bool = true) throws -> (LocalMusicStore, [LocalEntry]) {
        let store = LocalMusicStore(root: root.appendingPathComponent("library"))
        let entries = (1...3).map { number in
            let bytes = Data(repeating: UInt8(number), count: 1024)
            return LocalEntry(track: Track(id: "track-\(number)", title: "Track \(number)", artist: "Artist", album: "Album",
                suffix: "wav", size: UInt64(bytes.count)), sha256: LocalMusicStore.digest(bytes), artwork: nil)
        }
        if host { try saveHostFixture(entries, in: store) } else { try store.prepare() }
        return (store, entries)
    }

    private func hostTransfer(_ store: LocalMusicStore) async throws -> LocalTransfer {
        let transfer = makeTransfer(store: store)
        await transfer.restoreHost()
        let host = try XCTUnwrap(transfer.hostConnection)
        transfer.hostAudioGate.deferRequests(to: host.address.origin, for: .seconds(300))
        return transfer
    }

    func testSaveControlsFollowDisplayedCatalogSource() async throws {
        let (store, entries) = try fixture(host: false)
        let library = makeLibrary(localStore: store)
        XCTAssertFalse(library.showsOfflineSaveControls)
        try saveHostFixture(entries, in: store)
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        try store.database().saveAudioPin(entries[0])
        await library.openSavedLocalLibrary()
        XCTAssertTrue(library.showsOfflineSaveControls)
        try await library.transfer.disconnectHost()
        XCTAssertTrue(library.transfer.retainsHostCatalog)
        XCTAssertTrue(library.showsOfflineSaveControls)
        await library.inventoryTask?.value
        XCTAssertTrue(library.canRemoveLocalCopy(entries[0].track))
        await library.transfer.requestSave([entries[1].track], scope: "track:track-2")
        XCTAssertEqual(library.saveRequest(for: [entries[1].track], scope: "track:track-2")?.state, .waiting)
        library.removeLocalCopies([entries[0].track])
        await library.inventoryTask?.value
        XCTAssertFalse(library.canRemoveLocalCopy(entries[0].track))
        XCTAssertFalse(try store.database().hasAudioPin(entries[0]))
        XCTAssertFalse(store.hasFile(entries[0]))
    }

    func testRequestSaveRefusesWithoutHostCatalog() async throws {
        let (store, entries) = try fixture(host: false)
        let transfer = makeTransfer(store: store)
        transfer.setSavesBackgrounded(true)
        await transfer.requestSave([entries[0].track], scope: "track:track-1")
        XCTAssertTrue(transfer.saveRequests.isEmpty)
        XCTAssertTrue(makeTransfer(store: store).saveRequests.isEmpty)
    }

    func testRestoredHostSaveKeepsWaitingForRetry() async throws {
        let (store, entries) = try fixture()
        let request = OfflineSaveRequest(id: "album:fixture", library: "fixture", entries: entries)
        try JSONEncoder().encode([request]).write(to: store.root.appendingPathComponent("offline-saves.json"))
        let transfer = try await hostTransfer(store)
        transfer.resumeSaves()
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.map(\.state), [.waiting])
        XCTAssertNotNil(transfer.saveRetry)
    }

    private func cache(_ entry: LocalEntry, transfer: LocalTransfer, number: UInt8) throws {
        try transfer.playbackCache.store.prepare()
        try Data(repeating: number, count: 1024).write(to: transfer.playbackCache.store.fileURL(entry))
    }

    private func settled(_ transfer: LocalTransfer) async throws {
        for _ in 0..<400 {
            if transfer.saveWorker == nil { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Save worker did not settle")
    }

    private func lockCatalog(_ store: LocalMusicStore) throws -> OpaquePointer {
        var writer: OpaquePointer?
        guard sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &writer) == SQLITE_OK,
              let writer else { sqlite3_close(writer); throw LocalMusicError.invalidData }
        guard sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(writer)
            throw LocalMusicError.invalidData
        }
        return writer
    }

    func testEmptySaveQueueDoesNotReadUnavailableCatalogOnForeground() async throws {
        let (store, _) = try fixture()
        let transfer = makeTransfer(store: store)
        transfer.setSavesBackgrounded(true)
        try Data("unavailable catalog".utf8).write(to: store.root.appendingPathComponent("catalog.sqlite"), options: .atomic)
        let status = transfer.status
        transfer.setSavesBackgrounded(false)
        try await settled(transfer)
        XCTAssertEqual(transfer.status, status)
        XCTAssertTrue(transfer.saveRequests.isEmpty)
    }

    func testHealthySaveCompletesWhileAnUnreadableTrackWaits() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try breakStoredHostEntry(entries[1].track.id, in: store)
        try cache(entries[0], transfer: transfer, number: 1)
        let library = try XCTUnwrap(transfer.hostConnection?.library)
        transfer.saveRequests = [
            OfflineSaveRequest(id: "track:broken", library: library, entries: [entries[1]]),
            OfflineSaveRequest(id: "track:healthy", library: library, entries: [entries[0]])
        ]
        transfer.saveRetryInterval = .seconds(60)
        transfer.resumeSaves()
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.map(\.state), [.waiting, .complete])
        XCTAssertNotNil(transfer.saveRetry, "The unreadable track waits for the next try")
        transfer.saveRetry?.cancel()
    }

    func testPendingSaveRetriesAfterUnreadableSnapshotRecovers() async throws {
        let (store, entries) = try fixture()
        let transfer = makeTransfer(store: store)
        await transfer.restoreHost()
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE host_entries SET payload = 'unreadable'; COMMIT", nil, nil, nil), SQLITE_OK)
        try cache(entries[0], transfer: transfer, number: 1)
        transfer.saveRequests = [OfflineSaveRequest(id: "waiting", library: "fixture", entries: [entries[0]])]
        transfer.saveRetryInterval = .milliseconds(250)
        transfer.resumeSaves()
        try await settled(transfer)
        let retry = try XCTUnwrap(transfer.saveRetry)
        try saveHostFixture(entries, in: store)
        await retry.value
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .complete)
    }

    func testCatalogContentionDoesNotPreventMainActorFromReleasingWriter() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        transfer.setSavesBackgrounded(true)
        try cache(entries[0], transfer: transfer, number: 1)
        await transfer.requestSave([entries[0].track], scope: "track:track-1")
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer) }
        let started = ContinuousClock.now
        let unlock = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(sqlite3_exec(writer, "COMMIT", nil, nil, nil), SQLITE_OK)
            XCTAssertLessThan(started.duration(to: .now), .seconds(2), "Catalog I/O must not hold the main actor until SQLite times out")
        }
        transfer.setSavesBackgrounded(false)
        try await unlock.value
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .complete, transfer.status ?? "")
        XCTAssertTrue(store.hasFile(entries[0]))
    }

    func testSaveStartWaitsForCatalogWithoutBlockingMainActor() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        transfer.setSavesBackgrounded(true)
        try cache(entries[0], transfer: transfer, number: 1)
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer) }
        let started = ContinuousClock.now
        let save = Task { await transfer.requestSave([entries[0].track], scope: "track:track-1") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        await save.value
        transfer.setSavesBackgrounded(false)
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .complete, transfer.status ?? "")
    }

    func testCancelDuringRetryPreparationDoesNotRecreateSaveIntent() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        transfer.setSavesBackgrounded(true)
        await transfer.requestSave([entries[0].track], scope: "track:track-1")
        let request = try XCTUnwrap(transfer.saveRequests.first)
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer) }
        let retry = Task { await transfer.requestSave([entries[0].track], scope: request.id) }
        try await Task.sleep(for: .milliseconds(100))
        transfer.cancelSave(request)
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT", nil, nil, nil), SQLITE_OK)
        await retry.value
        transfer.setSavesBackgrounded(false)
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .cancelled)
        XCTAssertFalse(store.hasFile(entries[0]))
        let restored = try await hostTransfer(store)
        XCTAssertEqual(restored.saveRequests.first?.state, .cancelled)
    }

    func testOfflineIntentAndPartialResultsSurviveRestartAndAlbumGrowth() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try cache(entries[0], transfer: transfer, number: 1)
        await transfer.requestSave(Array(entries.prefix(2)).map(\.track), scope: "album:fixture")
        try await settled(transfer)
        let request = try XCTUnwrap(transfer.saveRequests.first)
        XCTAssertEqual(request.state, .waiting)
        XCTAssertEqual(request.entries.count, 2)
        XCTAssertEqual(request.completed, [entries[0].trackSaveIdentity])
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertFalse(store.hasFile(entries[1]))
        transfer.stopSaveWorker()
        let restored = try await hostTransfer(store)
        XCTAssertEqual(restored.saveRequests.first?.entries.count, 2, "Later album additions are not automatically requested")
        XCTAssertEqual(restored.saveRequests.first?.completed, [entries[0].trackSaveIdentity])
        try cache(entries[1], transfer: restored, number: 2)
        restored.resumeSaves()
        try await settled(restored)
        XCTAssertEqual(restored.saveRequests.first?.state, .complete)
        XCTAssertTrue(store.hasFile(entries[1]))
        XCTAssertFalse(store.hasFile(entries[2]))
        let firstDate = try FileManager.default.attributesOfItem(atPath: store.fileURL(entries[0]).path)[.modificationDate] as? Date
        try cache(entries[2], transfer: restored, number: 3)
        await restored.requestSave(entries.map(\.track), scope: "album:fixture")
        try await settled(restored)
        XCTAssertEqual(restored.saveRequests.first?.completed.count, 3)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.fileURL(entries[0]).path)[.modificationDate] as? Date, firstDate)
    }

    func testCancelRetainsCompletedAudioAndDoesNotResumeRemainingItems() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try cache(entries[0], transfer: transfer, number: 1)
        await transfer.requestSave(entries.map(\.track), scope: "album:fixture")
        try await settled(transfer)
        transfer.cancelSave(try XCTUnwrap(transfer.saveRequests.first))
        try cache(entries[1], transfer: transfer, number: 2)
        transfer.resumeSaves()
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .cancelled)
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertFalse(store.hasFile(entries[1]))
        let restored = try await hostTransfer(store)
        XCTAssertEqual(restored.saveRequests.first?.state, .cancelled)
    }

    func testRemovingOneTrackKeepsOtherAlbumSaveIntentAfterRestart() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try cache(entries[0], transfer: transfer, number: 1)
        await transfer.requestSave(entries.map(\.track), scope: "album:fixture")
        try await settled(transfer)
        try transfer.cancelSaves(containing: [entries[1].track])
        let restored = try await hostTransfer(store)
        let request = try XCTUnwrap(restored.saveRequests.first)
        XCTAssertEqual(request.entries.map { $0.track.id }, ["track-1", "track-3"])
        XCTAssertEqual(request.completed, [entries[0].trackSaveIdentity])
        XCTAssertEqual(request.state, .waiting)
        try cache(entries[2], transfer: restored, number: 3)
        restored.resumeSaves()
        try await settled(restored)
        XCTAssertEqual(restored.saveRequests.first?.state, .complete)
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertFalse(store.hasFile(entries[1]))
        XCTAssertTrue(store.hasFile(entries[2]))
    }

    func testRemovingOneRegistrationKeepsSharedHashCompletionForOtherRegistration() async throws {
        let (store, entries) = try fixture(host: false)
        var other = entries[0]
        other.track.id = "other-registration"
        let registrations = [entries[0], other, entries[1]]
        try saveHostFixture(registrations, in: store)
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(other))
        let legacyQueue = [OfflineSaveRequest(id: "album:fixture", library: "fixture", entries: registrations,
                                              completed: [other.sha256])]
        try JSONEncoder().encode(legacyQueue).write(to: store.root.appendingPathComponent("offline-saves.json"))
        let transfer = makeTransfer(store: store)
        try transfer.cancelSaves(containing: [entries[0].track])
        let restored = makeTransfer(store: store)
        let request = try XCTUnwrap(restored.saveRequests.first)
        XCTAssertEqual(request.entries.map { $0.track.id }, [other.track.id, entries[1].track.id])
        XCTAssertEqual(request.completed, [entries[0].sha256])
        XCTAssertEqual(request.state, .waiting)
        XCTAssertEqual(try LocalMusicStore.digest(file: store.fileURL(other)), other.sha256)
    }

    func testWaitingAlbumStillProtectsLaterCachedTracks() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        try cache(entries[2], transfer: transfer, number: 3)
        await transfer.requestSave(entries.map(\.track), scope: "album:fixture")
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .waiting)
        XCTAssertTrue(store.hasFile(entries[2]))
        XCTAssertEqual(transfer.saveRequests.first?.completed, [entries[2].trackSaveIdentity])
    }

    func testFailurePreservesSuccessAndRetryUsesCurrentCatalog() async throws {
        let (store, entries) = try fixture()
        let transfer = try await hostTransfer(store)
        transfer.setSavesBackgrounded(true)
        await transfer.requestSave(Array(entries.prefix(2)).map(\.track), scope: "album:fixture")
        try saveHostFixture([entries[0], entries[2]], in: store)
        try cache(entries[0], transfer: transfer, number: 1)
        transfer.setSavesBackgrounded(false)
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .failed)
        XCTAssertEqual(transfer.saveRequests.first?.completed, [entries[0].trackSaveIdentity])
        try saveHostFixture(entries, in: store)
        try cache(entries[1], transfer: transfer, number: 2)
        await transfer.requestSave(Array(entries.prefix(2)).map(\.track), scope: "album:fixture")
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .complete)
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertTrue(store.hasFile(entries[1]))
    }

    func testRemovalReclaimsManagedAndCachedAudioWithoutDeletingCatalogOrOriginal() async throws {
        let (store, entries) = try fixture()
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        await library.inventoryTask?.value
        let original = root.appendingPathComponent("original.wav")
        try Data(repeating: 1, count: 1024).write(to: original)
        try cache(entries[0], transfer: library.transfer, number: 1)
        await library.transfer.requestSave([entries[0].track], scope: "track:track-1")
        try await settled(library.transfer)
        XCTAssertEqual(library.saveRequest(for: [entries[0].track], scope: "track:track-1")?.state, .complete)
        await library.inventoryTask?.value
        XCTAssertTrue(library.canRemoveLocalCopy(entries[0].track))
        library.removeLocalCopies([entries[0].track])
        XCTAssertFalse(store.hasFile(entries[0]))
        XCTAssertFalse(library.transfer.playbackCache.store.hasFile(entries[0]))
        XCTAssertEqual(try Data(contentsOf: original), Data(repeating: 1, count: 1024))
        XCTAssertEqual(try store.load()?.entries.count, 3)
        XCTAssertEqual(library.transfer.saveRequests.first?.state, .cancelled)
        library.closeLibrary()
    }

    func testRemovalKeepsConfirmedTargetAfterAlertDismissalClearsPendingTracks() async throws {
        let (store, entries) = try fixture()
        let library = makeLibrary(localStore: store)
        await library.openSavedLocalLibrary()
        await library.inventoryTask?.value
        for index in 0..<2 {
            try cache(entries[index], transfer: library.transfer, number: UInt8(index + 1))
            await library.transfer.requestSave([entries[index].track], scope: "track:" + entries[index].track.id)
            try await settled(library.transfer)
            await library.inventoryTask?.value
            XCTAssertTrue(library.canRemoveLocalCopy(entries[index].track))
        }

        library.localCopiesToRemove = [entries[0].track]
        let confirmedTracks = library.localCopiesToRemove
        // SwiftUI can dismiss the alert before invoking its destructive action.
        library.localCopiesToRemove = []
        library.removeLocalCopies(confirmedTracks)
        await library.inventoryTask?.value

        XCTAssertNil(library.message)
        XCTAssertFalse(store.hasFile(entries[0]))
        XCTAssertFalse(library.transfer.playbackCache.store.hasFile(entries[0]))
        XCTAssertFalse(library.hasManagedCopy(entries[0].track))
        XCTAssertEqual(library.saveRequest(for: [entries[0].track], scope: "track:track-1")?.state, .cancelled)
        XCTAssertTrue(store.hasFile(entries[1]))
        XCTAssertTrue(library.hasManagedCopy(entries[1].track))
        XCTAssertEqual(library.saveRequest(for: [entries[1].track], scope: "track:track-2")?.state, .complete)
        XCTAssertEqual(try store.load()?.entries.map(\.track.id), entries.map(\.track.id))
    }
}

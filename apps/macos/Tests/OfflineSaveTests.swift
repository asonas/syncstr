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

@MainActor
final class OfflineSaveTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

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
        if host {
            try saveHostFixture(entries, in: store)
        } else {
            try store.save(LocalCatalog(id: "fixture", name: "Library", entries: entries))
        }
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
        try library.openLocal(try XCTUnwrap(store.load()))
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
    }

    func testRequestSaveRefusesLocalCatalog() async throws {
        let (store, entries) = try fixture(host: false)
        let transfer = makeTransfer(store: store)
        transfer.setSavesBackgrounded(true)
        await transfer.requestSave([entries[0].track], scope: "track:track-1")
        XCTAssertTrue(transfer.saveRequests.isEmpty)
        XCTAssertTrue(makeTransfer(store: store).saveRequests.isEmpty)
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

    func testPendingSaveRetriesAfterUnreadableSnapshotRecovers() async throws {
        let (source, entries) = try fixture(host: false)
        let catalog = try XCTUnwrap(source.load())
        let store = LocalMusicStore(root: root.appendingPathComponent("recovering"))
        try store.prepare()
        let legacy = store.root.appendingPathComponent("catalog.json")
        try Data("unreadable".utf8).write(to: legacy)
        let transfer = makeTransfer(store: store)
        try cache(entries[0], transfer: transfer, number: 1)
        transfer.saveRequests = [OfflineSaveRequest(id: "waiting", library: catalog.id, entries: [entries[0]])]
        transfer.saveRetryInterval = .milliseconds(250)
        transfer.resumeSaves()
        try await settled(transfer)
        let retry = try XCTUnwrap(transfer.saveRetry)
        try JSONEncoder().encode(catalog).write(to: legacy, options: .atomic)
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
        try store.save(LocalCatalog(id: "fixture", name: "Library", entries: registrations))
        let legacyQueue = [OfflineSaveRequest(id: "album:fixture", library: "fixture", entries: registrations)]
        try JSONEncoder().encode(legacyQueue).write(to: store.root.appendingPathComponent("offline-saves.json"))
        let transfer = makeTransfer(store: store)
        try cache(entries[0], transfer: transfer, number: 1)
        transfer.resumeSaves()
        try await settled(transfer)
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

#if os(macOS)
    func testFolderRestorationRetainsImportedManagedFilesWithoutImplicitHosting() async throws {
        let store = LocalMusicStore(root: root.appendingPathComponent("library"))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("untagged.m4a"), to: source.appendingPathComponent("source.m4a"))
        let library = makeLibrary(localStore: store)
        await library.chooseFolder(source)
        await library.addMusic([fixtures.appendingPathComponent("untagged.mp3")])
        XCTAssertEqual(library.tracks.count, 2)
        let restored = makeLibrary(localStore: store)
        await restored.openSavedLocalLibrary()
        XCTAssertEqual(Set(restored.tracks.map(\.id)), Set(library.tracks.map(\.id)))
        XCTAssertTrue(restored.tracks.allSatisfy { restored.localFiles[$0.id] != nil })
    }

    func testFreshFileImportNeedsNeitherEnrollmentNorLegacyHosting() async throws {
        let store = LocalMusicStore(root: root.appendingPathComponent("library"))
        let library = makeLibrary(localStore: store)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.m4a")
        let bytes = try Data(contentsOf: source)
        await library.addMusic([source])
        XCTAssertTrue(library.connected, library.message ?? "")
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertTrue(library.hasManagedCopy(try XCTUnwrap(library.tracks.first)))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let restored = makeLibrary(localStore: store)
        await restored.openSavedLocalLibrary()
        XCTAssertEqual(restored.tracks.map(\.id), library.tracks.map(\.id))
        restored.closeLibrary()
    }
#endif
}

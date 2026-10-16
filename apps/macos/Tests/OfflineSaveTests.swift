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
final class OfflineSaveTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func fixture() throws -> (LocalMusicStore, [LocalEntry]) {
        let store = LocalMusicStore(root: root.appendingPathComponent("library"))
        let entries = (1...3).map { number in
            let bytes = Data(repeating: UInt8(number), count: 1024)
            return LocalEntry(track: Track(id: "track-\(number)", title: "Track \(number)", artist: "Artist", album: "Album",
                suffix: "wav", size: UInt64(bytes.count)), sha256: LocalMusicStore.digest(bytes), artwork: nil)
        }
        try store.save(LocalCatalog(id: "fixture", name: "Library", entries: entries))
        return (store, entries)
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
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
        transfer.setSavesBackgrounded(true)
        try Data("unavailable catalog".utf8).write(to: store.root.appendingPathComponent("catalog.sqlite"), options: .atomic)
        let status = transfer.status
        transfer.setSavesBackgrounded(false)
        try await settled(transfer)
        XCTAssertEqual(transfer.status, status)
        XCTAssertTrue(transfer.saveRequests.isEmpty)
    }

    func testCatalogContentionDoesNotPreventMainActorFromReleasingWriter() async throws {
        let (store, entries) = try fixture()
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
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
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
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
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
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
        let restored = LocalTransfer(store: store)
        defer { restored.stopSaveWorker() }
        XCTAssertEqual(restored.saveRequests.first?.state, .cancelled)
    }

    func testOfflineIntentAndPartialResultsSurviveRestartAndAlbumGrowth() async throws {
        let (store, entries) = try fixture()
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
        try cache(entries[0], transfer: transfer, number: 1)
        await transfer.requestSave(Array(entries.prefix(2)).map(\.track), scope: "album:fixture")
        try await settled(transfer)
        let request = try XCTUnwrap(transfer.saveRequests.first)
        XCTAssertEqual(request.state, .waiting)
        XCTAssertEqual(request.entries.count, 2)
        XCTAssertEqual(request.completed, [entries[0].sha256])
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertFalse(store.hasFile(entries[1]))
        transfer.stopSaveWorker()
        let restored = LocalTransfer(store: store)
        defer { restored.stopSaveWorker() }
        XCTAssertEqual(restored.saveRequests.first?.entries.count, 2, "Later album additions are not automatically requested")
        XCTAssertEqual(restored.saveRequests.first?.completed, [entries[0].sha256])
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
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
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
        let restored = LocalTransfer(store: store)
        defer { restored.stopSaveWorker() }
        XCTAssertEqual(restored.saveRequests.first?.state, .cancelled)
    }

    func testWaitingAlbumStillProtectsLaterCachedTracks() async throws {
        let (store, entries) = try fixture()
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
        try cache(entries[2], transfer: transfer, number: 3)
        await transfer.requestSave(entries.map(\.track), scope: "album:fixture")
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .waiting)
        XCTAssertTrue(store.hasFile(entries[2]))
        XCTAssertEqual(transfer.saveRequests.first?.completed, [entries[2].sha256])
    }

    func testFailurePreservesSuccessAndRetryUsesCurrentCatalog() async throws {
        let (store, entries) = try fixture()
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
        transfer.setSavesBackgrounded(true)
        await transfer.requestSave(Array(entries.prefix(2)).map(\.track), scope: "album:fixture")
        try store.save(LocalCatalog(id: "fixture", name: "Library", entries: [entries[0], entries[2]]))
        try cache(entries[0], transfer: transfer, number: 1)
        transfer.setSavesBackgrounded(false)
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .failed)
        XCTAssertEqual(transfer.saveRequests.first?.completed, [entries[0].sha256])
        try store.save(LocalCatalog(id: "fixture", name: "Library", entries: entries))
        try cache(entries[1], transfer: transfer, number: 2)
        await transfer.requestSave(Array(entries.prefix(2)).map(\.track), scope: "album:fixture")
        try await settled(transfer)
        XCTAssertEqual(transfer.saveRequests.first?.state, .complete)
        XCTAssertTrue(store.hasFile(entries[0]))
        XCTAssertTrue(store.hasFile(entries[1]))
    }

    func testRemovalReclaimsManagedAndCachedAudioWithoutDeletingCatalogOrOriginal() async throws {
        let (store, entries) = try fixture()
        let library = Library(localStore: store)
        defer { library.transfer.stopSaveWorker() }
        try library.openLocal(try XCTUnwrap(store.load()))
        let original = root.appendingPathComponent("original.wav")
        try Data(repeating: 1, count: 1024).write(to: original)
        try cache(entries[0], transfer: library.transfer, number: 1)
        await library.transfer.requestSave([entries[0].track], scope: "track:track-1")
        try await settled(library.transfer)
        XCTAssertEqual(library.saveRequest(for: [entries[0].track], scope: "track:track-1")?.state, .complete)
        XCTAssertTrue(library.canRemoveLocalCopy(entries[0].track))
        library.localCopiesToRemove = [entries[0].track]
        library.removeLocalCopies()
        XCTAssertFalse(store.hasFile(entries[0]))
        XCTAssertFalse(library.transfer.playbackCache.store.hasFile(entries[0]))
        XCTAssertEqual(try Data(contentsOf: original), Data(repeating: 1, count: 1024))
        XCTAssertEqual(try store.load()?.entries.count, 3)
        XCTAssertEqual(library.transfer.saveRequests.first?.state, .cancelled)
        library.closeLibrary()
    }

#if os(macOS)
    func testColdRestoreKeepsClusterCatalogWhenOriginalFolderCannotBeOpened() async throws {
        let (store, entries) = try fixture()
        let catalog = try XCTUnwrap(store.load())
        try store.database().save(catalog, sourceRoot: root.appendingPathComponent("unavailable"), sourcePaths: [:])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cluster-signed", withExtension: "json"))
        let fixture = try JSONDecoder().decode(ClusterMembershipTests.Fixture.self, from: Data(contentsOf: url))
        let grant = try fixture.membership.authorize(fixture.client)
        try store.database().enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Library")
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        let library = Library(localStore: store)
        defer { library.closeLibrary() }
        await library.openSavedLocalLibrary()
        XCTAssertTrue(library.connected)
        XCTAssertEqual(Set(library.tracks.map(\.id)), Set(entries.map { $0.track.id }))
        XCTAssertTrue(library.hasManagedCopy(entries[0].track))
        XCTAssertEqual(try store.database().clusterRegistration()?.localGrant, grant.id)
    }

    func testFolderRestorationRetainsImportedManagedFilesWithoutImplicitHosting() async throws {
        let store = LocalMusicStore(root: root.appendingPathComponent("library"))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("untagged.m4a"), to: source.appendingPathComponent("source.m4a"))
        let library = Library(localStore: store)
        defer { library.closeLibrary() }
        await library.chooseFolder(source)
        XCTAssertNil(library.transfer.advertisedPort)
        await library.addMusic([fixtures.appendingPathComponent("untagged.mp3")])
        XCTAssertEqual(library.tracks.count, 2)
        let restored = Library(localStore: store)
        defer { restored.closeLibrary() }
        await restored.openSavedLocalLibrary()
        XCTAssertEqual(Set(restored.tracks.map(\.id)), Set(library.tracks.map(\.id)))
        XCTAssertTrue(restored.tracks.allSatisfy { restored.localFiles[$0.id] != nil })
        XCTAssertNil(restored.transfer.advertisedPort)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Transfer did not reach expected state")
        throw LocalMusicError.disconnected
    }

    func testQueuedAlbumResumesAfterPairingAndCancelKeepsCompletedTrack() async throws {
        let (store, entries) = try fixture()
        let source = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var files: [String: URL] = [:]
        for (index, entry) in entries.enumerated() {
            let file = source.appendingPathComponent(entry.track.id + ".wav")
            try Data(repeating: UInt8(index + 1), count: 1024).write(to: file)
            files[entry.track.id] = file
        }
        var catalog = try XCTUnwrap(store.load())
        catalog.id = UUID().uuidString
        try store.save(catalog)
        let senderCredentials = CredentialStore(service: "syncstr-save-sender-" + UUID().uuidString)
        let receiverCredentials = CredentialStore(service: "syncstr-save-receiver-" + UUID().uuidString)
        let sender = LocalTransfer(store: LocalMusicStore(root: root.appendingPathComponent("sender")), secrets: senderCredentials)
        let receiver = LocalTransfer(store: store, secrets: receiverCredentials)
        defer { sender.stopHosting(); sender.cancel(); receiver.stopSaveWorker(); receiver.cancel() }
        await receiver.requestSave(entries.map(\.track), scope: "album:fixture")
        try await settled(receiver)
        XCTAssertEqual(receiver.saveRequests.first?.state, .waiting)
        receiver.onSaved = {
            if let request = receiver.saveRequests.first, request.completed.count == 1 { receiver.cancelSave(request) }
        }
        try await sender.host(LocalFolder(root: source, catalog: catalog, files: files, skipped: []))
        try await wait { sender.advertisedPort != nil }
        let device = NearbyMusicDevice(id: "Syncstr-" + catalog.id, name: "Fixture host",
            endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(sender.advertisedPort)))
        receiver.connect(device, code: sender.code, name: "Fixture listener")
        try await wait { sender.pendingName != nil }
        sender.approve(true)
        try await wait { !receiver.busy && receiver.saveRequests.first?.state == .cancelled }
        XCTAssertEqual(entries.filter(store.hasFile).count, 1)
        receiver.onSaved = nil
        await receiver.requestSave(entries.map(\.track), scope: "album:fixture")
        try await wait { receiver.saveRequests.first?.state == .complete }
        XCTAssertTrue(entries.allSatisfy(store.hasFile))
        XCTAssertTrue(files.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await sender.forget()
        await receiver.forget()
    }

    func testHostCopyCannotBeRemovedThroughOfflineSaveAction() async throws {
        let (store, entries) = try fixture()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cluster-signed", withExtension: "json"))
        let fixture = try JSONDecoder().decode(ClusterMembershipTests.Fixture.self, from: Data(contentsOf: url))
        let grant = try fixture.membership.authorize(fixture.host)
        XCTAssertTrue(grant.host)
        try store.database().enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.host, name: "Library")
        try Data(repeating: 1, count: 1024).write(to: store.fileURL(entries[0]))
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
        XCTAssertThrowsError(try transfer.removeClusterCopy(entries[0]))
        XCTAssertTrue(store.hasFile(entries[0]))
    }

    func testFreshFileImportNeedsNeitherEnrollmentNorLegacyHosting() async throws {
        let store = LocalMusicStore(root: root.appendingPathComponent("library"))
        let library = Library(localStore: store)
        defer { library.transfer.stopSaveWorker(); library.closeLibrary() }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.m4a")
        let bytes = try Data(contentsOf: source)
        await library.addMusic([source])
        XCTAssertTrue(library.connected, library.message ?? "")
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertTrue(library.hasManagedCopy(try XCTUnwrap(library.tracks.first)))
        XCTAssertNil(try store.database().clusterRegistration())
        XCTAssertNil(library.transfer.advertisedPort)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let restored = Library(localStore: store)
        await restored.openSavedLocalLibrary()
        XCTAssertEqual(restored.tracks.map(\.id), library.tracks.map(\.id))
        restored.closeLibrary()
    }
#endif
}

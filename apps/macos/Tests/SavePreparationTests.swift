import Foundation
import SQLite3
import Testing
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct SavePreparationTests {
    private func fixture(root: URL) throws -> (LocalMusicStore, LocalEntry) {
        let store = LocalMusicStore(root: root)
        let data = Data(repeating: 7, count: 1024)
        let entry = LocalEntry(track: Track(id: "track", title: "Track", artist: nil, suffix: "wav", size: 1024),
            sha256: LocalMusicStore.digest(data), artwork: nil)
        try store.save(LocalCatalog(id: "fixture", name: "Fixture", entries: [entry]))
        return (store, entry)
    }

    private func lockCatalog(_ store: LocalMusicStore) throws -> OpaquePointer {
        var connection: OpaquePointer?
        guard sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection) == SQLITE_OK,
              let connection else { sqlite3_close(connection); throw LocalMusicError.invalidData }
        guard sqlite3_exec(connection, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw LocalMusicError.invalidData
        }
        return connection
    }

    @Test
    func closingLibraryWhilePreparingSaveDoesNotRestartSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, entry) = try fixture(root: root)
        let library = Library(localStore: store)
        defer { library.closeLibrary() }
        try library.openLocal(try #require(try store.load()))
        try library.transfer.playbackCache.store.prepare()
        try Data(repeating: 7, count: 1024).write(to: library.transfer.playbackCache.store.fileURL(entry))
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer) }
        let save = Task { await library.transfer.requestSave([entry.track], scope: "track:track") }
        try await Task.sleep(for: .milliseconds(100))
        library.closeLibrary()
        #expect(sqlite3_exec(writer, "COMMIT", nil, nil, nil) == SQLITE_OK)
        await save.value
        await library.transfer.saveWorker?.value
        #expect(!library.connected)
        #expect(library.transfer.saveRequests.isEmpty)
        #expect(!store.hasFile(entry))
    }

    @Test
    func repeatedSaveWhilePreparingDoesNotWaitForAnotherCatalogRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, entry) = try fixture(root: root)
        let transfer = LocalTransfer(store: store)
        defer { transfer.stopSaveWorker() }
        transfer.setSavesBackgrounded(true)
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer) }
        let first = Task { await transfer.requestSave([entry.track], scope: "track:track") }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        await transfer.requestSave([entry.track], scope: "track:track")
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(sqlite3_exec(writer, "COMMIT", nil, nil, nil) == SQLITE_OK)
        await first.value
        #expect(transfer.saveRequests.count == 1)
        #expect(transfer.saveRequests.first?.entries.map(\.track.id) == ["track"])
        #expect(transfer.saveRequests.first?.state == .waiting)
    }
}

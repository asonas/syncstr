import Foundation
import SQLite3
import Testing
import AVFoundation
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
    func backgroundPlaybackUsesVerifiedCacheWithoutConnecting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, entry) = try fixture(root: root)
        var playerInput: URL?
        let library = Library(makePlayer: { playerInput = $0; return AVPlayer() }, localStore: store)
        defer { library.closeLibrary() }
        try library.openLocal(try #require(try store.load()))
        let cache = library.transfer.playbackCache.store
        try cache.prepare()
        try Data(repeating: 7, count: 1024).write(to: cache.fileURL(entry))
        library.setBackgrounded(true)
        library.play(entry.track, in: library.tracks)
        for _ in 0..<100 where playerInput == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(playerInput == cache.fileURL(entry))
        #expect(library.playbackFailure == nil)
        #expect(!library.transfer.connected)
    }

    #if os(macOS)
    @Test
    func playbackWaitsForApprovalAndCancellingOneWaiterPreservesConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (files, entry) = try fixture(root: root)
        var catalog = try #require(try files.load())
        catalog.id = UUID().uuidString
        try files.save(catalog)
        let source = root.appendingPathComponent("source.wav")
        try Data(repeating: 7, count: 1024).write(to: source)
        let folder = LocalFolder(root: root, catalog: catalog, files: [entry.track.id: source], skipped: [])
        let sender = LocalTransfer(store: LocalMusicStore(root: root.appendingPathComponent("sender")),
            secrets: CredentialStore(service: "syncstr-test-" + UUID().uuidString))
        let receiver = LocalTransfer(store: files, secrets: CredentialStore(service: "syncstr-test-" + UUID().uuidString))
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<1200 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(predicate())
        }
        do {
            try await sender.host(folder)
            try await wait { sender.advertisedPort != nil }
            receiver.connect(NearbyMusicDevice(id: "Syncstr-" + catalog.id, name: "Fixture Mac",
                endpoint: .hostPort(host: "127.0.0.1", port: try #require(sender.advertisedPort))), code: sender.code, name: "Fixture Phone")
            try await wait { sender.pendingName != nil }
            let cancelled = Task { try await receiver.playbackFile(entry.track) }
            try await Task.sleep(for: .milliseconds(100))
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("Cancelled playback continued") }
            catch is CancellationError { }
            #expect(receiver.busy)
            var finished = false
            let playback = Task {
                defer { finished = true }
                return try await receiver.playbackFile(entry.track)
            }
            try await Task.sleep(for: .milliseconds(150))
            #expect(!finished)
            sender.approve(true)
            let url = try await playback.value
            #expect(try LocalMusicStore.digest(file: url) == entry.sha256)
            #expect(receiver.connected)
            await sender.forget()
            await receiver.forget()
        } catch {
            await sender.forget()
            await receiver.forget()
            throw error
        }
    }
    #endif

    @Test
    func playbackRemainsCancellableWhileCatalogIsLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, entry) = try fixture(root: root)
        let library = Library(localStore: store)
        try library.openLocal(try #require(try store.load()))
        let writer = try lockCatalog(store)
        defer { sqlite3_close(writer); library.closeLibrary() }
        let started = ContinuousClock.now
        library.play(entry.track, in: library.tracks)
        #expect(started.duration(to: .now) < .seconds(1))
        let heartbeat = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(100))
        #expect(heartbeat.duration(to: .now) < .seconds(1))
        #expect(library.loading)
        library.pause()
        #expect(!library.loading)
        #expect(sqlite3_exec(writer, "COMMIT", nil, nil, nil) == SQLITE_OK)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!library.playing)
        #expect(library.playbackFailure == nil)
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

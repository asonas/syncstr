import Foundation
import SwiftUI
import Darwin

actor PlaybackDownload {
    private let executor = StorageExecutor(label: "as.ason.syncstr.audio")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let store: LocalMusicStore
    private let temporary: URL
    private var handle: FileHandle?

    init(store: LocalMusicStore) {
        self.store = store
        temporary = store.root.appendingPathComponent(".partial-" + UUID().uuidString)
    }

    func prepare() throws {
        try Task.checkCancellation()
        if handle == nil {
            try store.prepare()
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: temporary)
        }
    }

    func append(_ bytes: Data) throws {
        try prepare()
        try handle?.write(contentsOf: bytes)
    }

    func finish(_ entry: LocalEntry, diagnostic: PlaybackDiagnosticContext?, durable: Bool = false) throws -> URL {
        defer { discard() }
        if durable { try handle?.synchronize() }
        try handle?.close()
        handle = nil
        try Task.checkCancellation()
        try store.importFile(temporary, entry: entry, recordReceipt: false, diagnostic: diagnostic)
        if durable {
            let descriptor = Darwin.open(store.root.path, O_RDONLY)
            guard descriptor >= 0 else { throw LocalMusicError.invalidData }
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else { throw LocalMusicError.invalidData }
        }
        return store.fileURL(entry)
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: temporary)
    }
}

@MainActor
final class PlaybackCache {
    let store: LocalMusicStore
    var protectedURL: URL?
    private let settings: URL
    private(set) var limitGB: Int
    private var maintenance: Task<Void, Never>?
    private var maintenanceID = UUID()

    func requestTrim(after acquisition: Task<Void, Never>?, onError: @escaping (Error) -> Void) {
        let previous = maintenance
        let token = UUID()
        maintenanceID = token
        maintenance = Task { [weak self] in
            await previous?.value
            await acquisition?.value
            guard let self else { return }
            do { try await Self.makeRoom(store: store, incoming: 0, limitGB: limitGB, protectedURL: protectedURL) }
            catch {
                if maintenanceID == token { onError(error) }
            }
        }
    }

    var usedBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { ClusterIdentity.isLowercaseHex256($0.deletingPathExtension().lastPathComponent) }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    init(root: URL) {
        store = LocalMusicStore(root: root)
        settings = root.appendingPathComponent("limit.json")
        limitGB = (try? JSONDecoder().decode(Int.self, from: Data(contentsOf: settings))) ?? 10
        limitGB = min(1000, max(1, limitGB))
    }

    func setLimit(_ value: Int) throws {
        try store.prepare()
        limitGB = min(1000, max(1, value))
        try JSONEncoder().encode(limitGB).write(to: settings, options: .atomic)
        try trim()
    }

    func file(_ entry: LocalEntry, diagnostic: PlaybackDiagnosticContext? = nil) throws -> URL? {
        try Self.verifiedFile(entry, store: store, diagnostic: diagnostic)
    }

    func fileInBackground(_ entry: LocalEntry, diagnostic: PlaybackDiagnosticContext? = nil) async throws -> URL? {
        await maintenance?.value
        try Task.checkCancellation()
        return try await Self.verifyInBackground(entry, store: store, diagnostic: diagnostic)
    }

    @concurrent
    private static func verifyInBackground(_ entry: LocalEntry, store: LocalMusicStore, diagnostic: PlaybackDiagnosticContext?) async throws -> URL? {
        try Task.checkCancellation()
        return try verifiedFile(entry, store: store, diagnostic: diagnostic)
    }

    nonisolated private static func verifiedFile(_ entry: LocalEntry, store: LocalMusicStore, diagnostic: PlaybackDiagnosticContext?) throws -> URL? {
        do {
            diagnostic?.file(store.fileURL(entry), role: "cache")
            guard store.hasFile(entry) else {
                diagnostic?.record("cache", "miss", fields: ["reason": "missing_or_size_mismatch"])
                return nil
            }
            let url = store.fileURL(entry)
            guard try LocalMusicStore.digest(file: url) == entry.sha256 else {
                diagnostic?.record("cache", "hash", outcome: "mismatch")
                try FileManager.default.removeItem(at: url)
                return nil
            }
            diagnostic?.record("cache", "hit", fields: ["hash": "verified"])
            return url
        } catch { diagnostic?.failure("cache", error); throw error }
    }

    func markPlayed(_ url: URL) throws {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == store.root.resolvingSymlinksInPath().path else { return }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func makeRoom(for entry: LocalEntry) throws {
        try store.prepare()
        try trim(incoming: entry.track.size ?? 0)
    }

    func makeRoomInBackground(for entry: LocalEntry) async throws {
        await maintenance?.value
        try Task.checkCancellation()
        try await Self.makeRoom(store: store, incoming: entry.track.size ?? 0, limitGB: limitGB, protectedURL: protectedURL)
    }

    @concurrent
    private static func makeRoom(store: LocalMusicStore, incoming: UInt64, limitGB: Int, protectedURL: URL?) async throws {
        try Task.checkCancellation()
        if incoming > 0 { try store.prepare() }
        try trimFiles(store: store, incoming: incoming, limitGB: limitGB, protectedURL: protectedURL)
    }

    func trim(incoming: UInt64 = 0) throws {
        try Self.trimFiles(store: store, incoming: incoming, limitGB: limitGB, protectedURL: protectedURL)
    }

    nonisolated private static func trimFiles(store: LocalMusicStore, incoming: UInt64, limitGB: Int, protectedURL: URL?) throws {
        try Task.checkCancellation()
        let directory = store.root
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        let entries = try files.compactMap { url -> (URL, UInt64, Date)? in
            guard ClusterIdentity.isLowercaseHex256(url.deletingPathExtension().lastPathComponent),
                  ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac"].contains(url.pathExtension) else { return nil }
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard info.isRegularFile == true else { return nil }
            return (url, UInt64(info.fileSize ?? 0), info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(UInt64(0)) { $0 + $1.1 }
        let budget = UInt64(limitGB) * 1_000_000_000
        for (url, size, _) in entries where total + incoming > budget {
            try Task.checkCancellation()
            guard url.resolvingSymlinksInPath().path != protectedURL?.resolvingSymlinksInPath().path else { continue }
            try FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

struct PlaybackStorageSettings: View {
    @ObservedObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("再生キャッシュの上限: \(library.transfer.playbackCache.limitGB) GB", value: Binding(
                get: { library.transfer.playbackCache.limitGB },
                set: { value in
                    do { try library.transfer.playbackCache.setLimit(value); library.objectWillChange.send() }
                    catch { library.message = "キャッシュ容量を変更できませんでした。\(error.localizedDescription)" }
                }
            ), in: 1...1000)
            Text("明示的に保存した音楽は、この上限と自動削除の対象外です。")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("再生キャッシュ", value: ByteCountFormatter.string(fromByteCount: library.transfer.playbackCache.usedBytes, countStyle: .decimal))
            LabeledContent("保存済み音源", value: ByteCountFormatter.string(fromByteCount: library.savedAudioBytes, countStyle: .decimal))
        }
    }
}

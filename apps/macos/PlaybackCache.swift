import Foundation

@MainActor
class PlaybackCache {
    let store: LocalMusicStore
    var protectedURL: URL?
    private let settings: URL
    private(set) var limitGB: Int
    private(set) var maintenance: Task<Void, Never>?
    private var maintenanceID = UUID()

    /// Every trim, including clearing, goes through this chain so two passes never walk the folder at once.
    @discardableResult
    func requestTrim(after acquisition: Task<Void, Never>?, emptying: Bool = false,
                     onError: @escaping (Error) -> Void) -> Task<Void, Never> {
        let previous = maintenance
        let token = UUID()
        maintenanceID = token
        let task = Task { [weak self] in
            await previous?.value
            await acquisition?.value
            guard let self else { return }
            do { try await Self.makeRoom(store: store, incoming: 0, limitGB: emptying ? 0 : limitGB, protectedURL: protectedURL) }
            catch {
                if maintenanceID == token || emptying { onError(error) }
            }
        }
        maintenance = task
        return task
    }

    var usedBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { SHA256Hex.isValid($0.deletingPathExtension().lastPathComponent) }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    init(root: URL) {
        store = LocalMusicStore(root: root)
        settings = root.appendingPathComponent("limit.json")
        limitGB = (try? JSONDecoder().decode(Int.self, from: Data(contentsOf: settings))) ?? 10
        limitGB = min(1000, max(1, limitGB))
    }

    func setLimit(_ value: Int, onTrimError: @escaping (Error) -> Void = { _ in }) throws {
        try store.prepare()
        limitGB = min(1000, max(1, value))
        try JSONEncoder().encode(limitGB).write(to: settings, options: .atomic)
        requestTrim(after: nil, onError: onTrimError)
    }

    func file(_ entry: LocalEntry, diagnostic: PlaybackDiagnosticContext? = nil) throws -> URL? {
        try Self.verifiedFile(entry, store: store, diagnostic: diagnostic)
    }

    func fileInBackground(_ entry: LocalEntry, diagnostic: PlaybackDiagnosticContext? = nil) async throws -> URL? {
        // A trim scheduled by stop() may be waiting for this acquisition.
        try Task.checkCancellation()
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
            let digest: String
            do { digest = try LocalMusicStore.digest(file: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // A trim or clear removed the file after the size check.
                diagnostic?.record("cache", "miss", fields: ["reason": "removed_during_verification"])
                return nil
            }
            guard digest == entry.sha256 else {
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
        try Task.checkCancellation()
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

    /// Keeps the file that is playing now. Saved music lives in a different store and is not touched.
    func clear() async throws {
        var failure: Error?
        await requestTrim(after: nil, emptying: true) { failure = $0 }.value
        if let failure { throw failure }
    }

    nonisolated private static func trimFiles(store: LocalMusicStore, incoming: UInt64, limitGB: Int, protectedURL: URL?) throws {
        try Task.checkCancellation()
        let directory = store.root
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        let entries = files.compactMap { url -> (URL, UInt64, Date)? in
            guard SHA256Hex.isValid(url.deletingPathExtension().lastPathComponent),
                  ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "audio"].contains(url.pathExtension) else { return nil }
            // Another pass may have removed the file after the listing.
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  info.isRegularFile == true else { return nil }
            return (url, UInt64(info.fileSize ?? 0), info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(UInt64(0)) { $0 + $1.1 }
        let budget = UInt64(limitGB) * 1_000_000_000
        for (url, size, _) in entries where total + incoming > budget {
            try Task.checkCancellation()
            guard url.resolvingSymlinksInPath().path != protectedURL?.resolvingSymlinksInPath().path else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile {}
            total -= size
        }
    }
}

import Foundation

@MainActor
class PlaybackCache {
    let store: LocalMusicStore
    var protectedURL: URL?
    private let settings: URL
    private(set) var limitGB: Int
    private(set) var maintenance: Task<Void, Never>?
    private var maintenanceID = UUID()
    /// Files between the start of their verification and the moment the player or a save protects them.
    private var leases: [String: Int] = [:]

    /// The playing file and every leased file. Trims and removals skip these paths.
    var protectedPaths: Set<String> {
        var paths = Set(leases.keys)
        if let protectedURL { paths.insert(protectedURL.resolvingSymlinksInPath().path) }
        return paths
    }

    func release(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        guard let count = leases[path] else { return }
        leases[path] = count > 1 ? count - 1 : nil
    }

    func lease(_ url: URL) {
        leases[url.resolvingSymlinksInPath().path, default: 0] += 1
    }

    /// Every trim, including clearing and making room for a download, goes through this chain so two passes
    /// never walk the folder at once. The protected paths are read when the pass starts.
    @discardableResult
    func requestTrim(after acquisition: Task<Void, Never>?, emptying: Bool = false, incoming: UInt64? = nil,
                     onError: @escaping (Error) -> Void) -> Task<Void, Never> {
        let previous = maintenance
        let token = UUID()
        // Clearing and making room report to their own caller; a routine trim reports only if it is the latest.
        let reportsOwnError = emptying || incoming != nil
        if !reportsOwnError { maintenanceID = token }
        let task = Task { [weak self] in
            await previous?.value
            await acquisition?.value
            guard let self else { return }
            do {
                try await Self.makeRoom(store: store, incoming: incoming ?? 0, limitGB: emptying ? 0 : limitGB, protected: protectedPaths)
            } catch {
                if maintenanceID == token || reportsOwnError { onError(error) }
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

    /// A returned file stays leased until the caller passes it to `release(_:)`, so a trim cannot remove it
    /// between verification and the player or save taking it over.
    func fileInBackground(_ entry: LocalEntry, diagnostic: PlaybackDiagnosticContext? = nil) async throws -> URL? {
        // A trim scheduled by stop() may be waiting for this acquisition.
        try Task.checkCancellation()
        let url = store.fileURL(entry)
        lease(url)
        do {
            await maintenance?.value
            try Task.checkCancellation()
            guard let verified = try await Self.verifyInBackground(entry, store: store, diagnostic: diagnostic) else {
                release(url)
                return nil
            }
            return verified
        } catch {
            release(url)
            throw error
        }
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

    func makeRoomInBackground(for entry: LocalEntry) async throws {
        // Checked before joining the chain: stop() cancels the acquisition and then queues a trim that waits for it.
        try Task.checkCancellation()
        var failure: Error?
        await requestTrim(after: nil, incoming: entry.track.size ?? 0) { failure = $0 }.value
        try Task.checkCancellation()
        if let failure { throw failure }
    }

    @concurrent
    private static func makeRoom(store: LocalMusicStore, incoming: UInt64, limitGB: Int, protected: Set<String>) async throws {
        try Task.checkCancellation()
        if incoming > 0 { try store.prepare() }
        try trimFiles(store: store, incoming: incoming, limitGB: limitGB, protected: protected)
    }

    func trim(incoming: UInt64 = 0) throws {
        try Self.trimFiles(store: store, incoming: incoming, limitGB: limitGB, protected: protectedPaths)
    }

    /// Keeps the file that is playing now. Saved music lives in a different store and is not touched.
    func clear() async throws {
        var failure: Error?
        await requestTrim(after: nil, emptying: true) { failure = $0 }.value
        if let failure { throw failure }
    }

    nonisolated private static func trimFiles(store: LocalMusicStore, incoming: UInt64, limitGB: Int, protected: Set<String>) throws {
        try Task.checkCancellation()
        let directory = store.root
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        let entries = files.compactMap { url -> (URL, UInt64, Date)? in
            guard LocalMusicStore.isAudioFileName(url) else { return nil }
            // Another pass may have removed the file after the listing.
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  info.isRegularFile == true else { return nil }
            return (url, UInt64(info.fileSize ?? 0), info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(UInt64(0)) { $0 + $1.1 }
        let budget = UInt64(limitGB) * 1_000_000_000
        for (url, size, _) in entries where total + incoming > budget {
            try Task.checkCancellation()
            guard !protected.contains(url.resolvingSymlinksInPath().path) else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile {}
            total -= size
        }
    }
}

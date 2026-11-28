import CryptoKit
import Foundation

final class StorageExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

actor CatalogStorage {
    static let shared = CatalogStorage()
    private let executor = StorageExecutor(label: "as.ason.syncstr.catalog")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var databases: [URL: CatalogDatabase] = [:]

    func perform<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        let result = try operation()
        try Task.checkCancellation()
        return result
    }

    // A committed write must reach its caller even if cancellation arrives while it is running.
    func commit<T: Sendable>(_ write: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try write()
    }

    /// Runs a write that places a saved file and records its pin. Cancellation is checked only before it starts:
    /// the write runs in a task that the caller's cancellation does not reach, because opening the database and
    /// hashing stop in a cancelled task and would leave a placed file without its pin. Callers still wait for it.
    func commitSavedFile<T: Sendable>(_ write: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await Task { try self.run(write) }.value
    }

    private func run<T: Sendable>(_ write: @Sendable () throws -> T) throws -> T { try write() }

    func commitHostCatalog(_ update: CatalogUpdate, host: HostConnection, replacing previous: HostConnection?, refreshedAt: Date,
                           store: LocalMusicStore, didCommit: (@Sendable () async -> Void)?) async throws -> PreparedLocalCatalog {
        try Task.checkCancellation()
        let prepared = try PreparedLocalCatalog(update.catalog, store: store)
        try Task.checkCancellation()
        try store.database().saveHostCatalog(update, connection: host, replacing: previous, refreshedAt: refreshedAt)
        await didCommit?()
        return prepared
    }

    private func database(_ store: LocalMusicStore) throws -> CatalogDatabase {
        let root = store.root.standardizedFileURL
        if let database = databases[root] { return database }
        let database = try store.database()
        databases[root] = database
        return database
    }

    func closeDatabase(at root: URL) {
        databases.removeValue(forKey: root.standardizedFileURL)
    }

    func entry(store: LocalMusicStore, track: String, hash: String? = nil) throws -> (library: String, entry: LocalEntry)? {
        try Task.checkCancellation()
        let result = try database(store).playbackEntry(track, hash: hash)
        try Task.checkCancellation()
        return result
    }

    func snapshot(store: LocalMusicStore) throws -> CatalogSnapshot? {
        try Task.checkCancellation()
        guard store.hasCatalog else { return nil }
        let result = try store.snapshot(database: database(store))
        try Task.checkCancellation()
        return result
    }

    func savedHostFiles(in catalog: LocalCatalog, store: LocalMusicStore) async throws -> [String: URL] {
        try Task.checkCancellation()
        let inventory = try database(store)
        let pins = try inventory.savedAudioPins()
        var files: [String: URL] = [:]
        for entry in catalog.entries {
            try Task.checkCancellation()
            guard pins.contains(entry.trackSaveIdentity) else { continue }
            files[entry.track.id] = try store.verifiedFile(entry, host: true, inventory: inventory)
            await Task.yield()
        }
        return files
    }

}

struct PreparedLocalCatalog {
    let catalog: LocalCatalog
    let tracks: [Track]
    let albums: [Album]
    let artworkURLs: [String: URL]

    init(_ catalog: LocalCatalog, store: LocalMusicStore) throws {
        self.catalog = catalog
        tracks = catalog.displayTracks()
        albums = Library.preparedAlbums(tracks, organization: catalog.organization)
        var artworkURLs = Dictionary(catalog.entries.compactMap { entry in
            entry.track.coverArt.map { ($0, store.artworkURL(entry)) }
        }, uniquingKeysWith: { first, _ in first })
        for asset in catalog.organization?.artwork?.assets.keys.map({ $0 }) ?? [] { artworkURLs[asset] = store.artworkURL(asset: asset) }
        self.artworkURLs = artworkURLs
    }
}

struct LocalEntry: Codable, Equatable {
    var track: Track
    var sha256: String
    var artwork: Data?
    var importedAlbum: ImportedAlbumMetadata? = nil
}

struct LocalCatalog: Codable {
    var id: String
    var name: String
    var entries: [LocalEntry]
    var organization: AlbumOrganization? = nil
    enum Source: String, Codable { case host }
    var source: Source? = nil
    var remoteArtwork: Set<String>? = nil

    mutating func organize(folders: [String: String] = [:]) {
        var organization = organization ?? AlbumOrganization()
        organization.importEntries(entries, folders: folders, sourceID: id)
        organization.retainLegacyArtwork(entries)
        self.organization = organization
    }
}

enum LocalMusicError: LocalizedError {
    case invalidData, disconnected
    case backgroundAcquisition
    case transferBusy
    case removalIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidData: "音楽の情報を確認できませんでした。もう一度転送してください。"
        case .transferBusy: "転送中のため保存を解除できません。転送が終わってからもう一度お試しください。"
        case .removalIncomplete: "一部の保存を削除できませんでした。もう一度お試しください。"
        case .disconnected: "接続が切れました。保存済みの音楽は引き続き聴けます。接続を確認して再試行してください。"
        case .backgroundAcquisition: "バックグラウンドでは次の音源を取得できません。アプリを開いて再試行してください。"
        }
    }
}

enum SHA256Hex {
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct LocalMusicStore {
    var inventoryDigest: @Sendable (URL) throws -> String = { try LocalMusicStore.digest(file: $0) }
    /// Tests make a removal fail through this. Folder permissions cannot: on iOS a read-only folder also
    /// fails the database's own setup before any removal is tried.
    var removeFile: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    /// Tests stop a save here, after `importFile` has moved a file into place and before it writes the records.
    var afterPlacingFile: @Sendable (URL) -> Void = { _ in }
    var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalMusic", isDirectory: true)

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 262144), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    func load() throws -> LocalCatalog? {
        try snapshot()?.catalog
    }

    func snapshotInBackground() async throws -> CatalogSnapshot? {
        try await CatalogStorage.shared.snapshot(store: self)
    }

    var hasCatalog: Bool {
        guard hasStorage else { return false }
        return (try? CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).containsCatalog()) ?? true
    }

    private var hasStorage: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path)
    }

    func snapshot(database: CatalogDatabase? = nil) throws -> CatalogSnapshot? {
        guard hasStorage else { return nil }
        let snapshot = try (database ?? self.database()).snapshot()
        if let catalog = snapshot?.catalog { try writeArtwork(catalog) }
        return snapshot
    }

    func database() throws -> CatalogDatabase {
        try prepare()
        return try CatalogDatabase(root.appendingPathComponent("catalog.sqlite"))
    }

    private func writeArtwork(_ catalog: LocalCatalog) throws {
        guard Set(catalog.entries.map { $0.track.id }).count == catalog.entries.count else {
            throw LocalMusicError.invalidData
        }
        try prepare()
        for (id, data) in catalog.organization?.artwork?.assets ?? [:] {
            try Task.checkCancellation()
            guard LocalMusicStore.digest(data) == id, ArtworkImage.valid(data) else { throw LocalMusicError.invalidData }
            let url = artworkURL(asset: id)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        }
        for entry in catalog.entries {
            try Task.checkCancellation()
            guard Self.valid(entry) else { throw LocalMusicError.invalidData }
            if let artwork = entry.artwork {
                let url = artworkURL(entry)
                if (try? Data(contentsOf: url)) != artwork { try artwork.write(to: url, options: .atomic) }
            }
        }
    }

    static func valid(_ entry: LocalEntry) -> Bool {
        entry.sha256.count == 64 && entry.sha256.allSatisfy { "0123456789abcdef".contains($0) }
            && (entry.track.addedAt.map { $0 >= 0 } ?? true)
            && entry.track.size != nil && entry.track.size! > 0
            && entry.track.size! <= 20 * 1024 * 1024 * 1024
            && !entry.track.id.isEmpty && entry.track.id.utf8.count <= 1024
            && (entry.track.coverArt == nil || entry.track.coverArt == entry.track.id)
            && (entry.artwork?.count ?? 0) <= 512 * 1024
            && ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac"].contains(entry.track.suffix ?? "")
    }

    func fileURL(_ entry: LocalEntry) -> URL {
        root.appendingPathComponent(entry.sha256).appendingPathExtension(entry.track.suffix ?? "audio")
    }

    func hostFileURLs(_ entry: LocalEntry) -> [URL] {
        let current = fileURL(entry)
        let legacy = root.appendingPathComponent(entry.sha256 + ".audio")
        return legacy == current ? [current] : [current, legacy]
    }

    private func fileStamp(_ attributes: [FileAttributeKey: Any]) -> String? {
        guard let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(inode):\(size):\(modified.timeIntervalSinceReferenceDate)"
    }

    func verifiedFile(_ entry: LocalEntry, host: Bool, inventory: CatalogDatabase? = nil, requireHash: Bool = false) throws -> URL? {
        guard Self.valid(entry) else { return nil }
        for url in host ? hostFileURLs(entry) : [fileURL(entry)] {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
            guard let size = attributes[.size] as? NSNumber, size.uint64Value == entry.track.size else { continue }
            let stamp = fileStamp(attributes)
            if !requireHash, let inventory, let stamp, inventory.matchesVerifiedAudio(url, stamp: stamp, hash: entry.sha256) { return url }
            let digest = try inventory == nil ? Self.digest(file: url) : inventoryDigest(url)
            if digest == entry.sha256 {
                if let inventory, let stamp { inventory.recordVerifiedAudio(url, stamp: stamp, hash: digest) }
                return url
            }
        }
        return nil
    }

    func artworkURL(_ entry: LocalEntry) -> URL {
        root.appendingPathComponent(Self.digest(entry.artwork ?? Data()) + ".jpg")
    }

    func artworkURL(asset: String) -> URL { root.appendingPathComponent(asset + ".jpg") }

    func hasFile(_ entry: LocalEntry) -> Bool {
        guard Self.valid(entry), let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(entry).path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.uint64Value == entry.track.size
    }

    func importCachedFile(_ source: URL, entry: LocalEntry, host: Bool, pin: Bool = false) throws -> Bool {
        let temporary = root.appendingPathComponent(".cache-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            if access(source.path, F_OK) == -1, errno == ENOENT { return false }
            throw error
        }
        try importFile(temporary, entry: entry, host: host, pin: pin)
        return true
    }

    /// Verifies `temporary` and moves it into the store. With `recordReceipt`, the receipt, the verification and,
    /// with `pin`, the saved pin are written in one transaction; if that fails, a file this call placed is removed
    /// again, so a saved file never stays without its pin. Run it through `CatalogStorage.commitSavedFile` when a
    /// cancellation must not stop it between the move and the records.
    func importFile(_ temporary: URL, entry: LocalEntry, recordReceipt: Bool = true, host: Bool = false, pin: Bool = false,
                    diagnostic: PlaybackDiagnosticContext? = nil) throws {
        var stage = "verification"
        do {
            guard Self.valid(entry) else { throw LocalMusicError.invalidData }
            let actualSize = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.uint64Value
            diagnostic?.record(stage, "size", outcome: actualSize == entry.track.size ? "matched" : "mismatch",
                fields: ["actual_size": actualSize.map(String.init) ?? "unknown", "expected_size": entry.track.size.map(String.init) ?? "unknown"])
            guard actualSize == entry.track.size else { throw LocalMusicError.invalidData }
            let matches = try Self.digest(file: temporary) == entry.sha256
            diagnostic?.record(stage, "hash", outcome: matches ? "matched" : "mismatch")
            guard matches else { throw LocalMusicError.invalidData }
            diagnostic?.record("verification", "size_and_hash", outcome: "succeeded")
            stage = "save"
            try prepare()
            let destination = fileURL(entry)
            var placed = false
            if FileManager.default.fileExists(atPath: destination.path) {
                if try Self.digest(file: destination) != entry.sha256 {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    placed = true
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
                placed = true
            }
            if placed { afterPlacingFile(destination) }
            if recordReceipt {
                do {
                    let database = try database()
                    try database.transaction {
                        try database.recordReceived(entry)
                        if host, let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                           let stamp = fileStamp(attributes) {
                            database.recordVerifiedAudio(destination, stamp: stamp, hash: entry.sha256)
                        }
                        if pin { try database.saveAudioPin(entry) }
                    }
                } catch {
                    if placed && pin { try? removeFile(destination) }
                    throw error
                }
            }
            diagnostic?.record("save", "import", outcome: "succeeded")
        } catch { diagnostic?.failure(stage, error); throw error }
    }
}

extension LocalCatalog {
    func displayTracks() -> [Track] {
        let catalog = self
        let organization = catalog.organization
        let images = organization.map(AlbumArtworkLookup.init)
        let albums = Dictionary(uniqueKeysWithValues: (organization?.albums ?? []).map { ($0.id, $0) })
        var covers: [String: String] = [:]
        if let organization, let images {
            for album in Set(images.albumIDs.values).union(catalog.entries.compactMap(\.track.albumId)) {
                covers[album] = images.coverAsset(for: album, in: organization)
            }
        }
        return catalog.entries.map { entry in
            var track = entry.track
            let id = organization?.canonicalTrack(track.id) ?? track.id
            track.albumId = images?.albumIDs[id] ?? track.albumId
            if let id = track.albumId, let album = albums[id] { track.album = album.title }
            if let album = track.albumId, let asset = covers[album] { track.coverArt = asset }
            return track
        }
    }
}

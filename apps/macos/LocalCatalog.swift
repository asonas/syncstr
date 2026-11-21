import AVFoundation
import CryptoKit
import Foundation
import AudioTags
import ImageIO

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

    func commitHostCatalog(_ update: CatalogUpdate, host: HostConnection, replacing previous: HostConnection?,
                           store: LocalMusicStore, didCommit: (@Sendable () async -> Void)?) async throws -> PreparedLocalCatalog {
        try Task.checkCancellation()
        let prepared = try PreparedLocalCatalog(update.catalog, store: store)
        try Task.checkCancellation()
        try store.database().saveHostCatalog(update, connection: host, replacing: previous)
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
    let files: [String: URL]
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
        self.files = catalog.source != .host ? try store.savedLocalFiles(in: catalog) : [:]
    }
}
import UniformTypeIdentifiers

struct LocalEntry: Codable, Equatable {
    var track: Track
    var sha256: String
    var artwork: Data?
    var importedAlbum: ImportedAlbumMetadata? = nil
}

enum UploadedMusic {
    static func prepare(_ files: [URL], organization: AlbumOrganization, sourceID: String) async throws -> (entries: [LocalEntry], organization: AlbumOrganization) {
        var entries: [LocalEntry] = []
        var folders: [String: String] = [:]
        for original in files {
            let scoped = original.startAccessingSecurityScopedResource()
            defer { if scoped { original.stopAccessingSecurityScopedResource() } }
            var entry = try await entry(file: original, original: original)
            let matches = organization.tracks.filter { $0.sha256 == entry.sha256 && organization.canonicalTrack($0.id) == $0.id }
            if matches.count == 1 {
                entry.track.id = matches[0].id
                if entry.track.coverArt != nil { entry.track.coverArt = entry.track.id }
            }
            guard LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
            let directory = original.standardizedFileURL.deletingLastPathComponent()
            // Opaque, source-scoped components retain sibling relationships without sharing paths.
            func component(_ url: URL) -> String { LocalMusicStore.digest(Data((sourceID + url.path).utf8)) }
            folders[entry.track.id] = component(directory.deletingLastPathComponent()) + "/" + component(directory)
            entries.append(entry)
        }
        var updated = organization
        updated.importEntries(entries, folders: folders, sourceID: sourceID)
        let originals = Dictionary(zip(entries.map { $0.track.id }, files), uniquingKeysWith: { first, _ in first })
        let scoped = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        try ArtworkAcquisition.collect(entries: entries, originals: originals, organization: &updated, music: ArtworkAcquisition.musicReader())
        try updated.validate()
        return (entries, updated)
    }

    static func entry(file: URL, original: URL) async throws -> LocalEntry {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        var fields: [String: String] = [:]
        var artwork: Data?
        let tags = try AudioTags.readFile(file)
        for key in ["TITLE", "ARTIST", "ALBUM", "TRACKNUMBER", "DISCNUMBER"] {
            if let value = (tags[key] as? [String])?.first, !value.isEmpty { fields[key] = value }
        }
        artwork = (tags["artwork"] as? Data).flatMap(ArtworkImage.normalize)

        func number(_ key: String) -> Int? { fields[key]?.split(separator: "/").first.flatMap { Int($0) } }
        let id = UUID().uuidString
        let track = Track(id: id, title: fields["TITLE"] ?? original.deletingPathExtension().lastPathComponent,
            artist: fields["ARTIST"], album: fields["ALBUM"], coverArt: artwork == nil ? nil : id,
            duration: duration.isFinite ? duration : nil, track: number("TRACKNUMBER"), discNumber: number("DISCNUMBER"),
            suffix: original.pathExtension.lowercased(), size: UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        var entry = LocalEntry(track: track, sha256: try LocalMusicStore.digest(file: file), artwork: artwork)
        entry.importedAlbum = ImportedAlbumMetadata.read(tags)
        return entry
    }
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
    case invalidData, disconnected, noMusic
    case readOnlyCatalog
    case backgroundAcquisition
    case transferBusy

    var errorDescription: String? {
        switch self {
        case .invalidData: "音楽の情報を確認できませんでした。もう一度転送してください。"
        case .transferBusy: "転送中のため保存を解除できません。転送が終わってからもう一度お試しください。"
        case .disconnected: "接続が切れました。保存済みの音楽は引き続き聴けます。接続を確認して再試行してください。"
        case .noMusic: "再生できる音源が見つかりませんでした。別のフォルダを選んでください。"
        case .readOnlyCatalog: "この接続では音源の追加、アルバム情報や表示・非表示の変更、競合の解消、アルバム名の選択は利用できません。"
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

    @concurrent
    func setAlbumHidden(_ id: String, hidden: Bool, libraryID: String) async throws -> AlbumOrganization {
        return try await setAlbumsHidden([id], hidden: hidden, libraryID: libraryID)
    }

    @concurrent
    func setAlbumsHidden(_ ids: Set<String>, hidden: Bool, libraryID: String) async throws -> AlbumOrganization {
        let database = try database()
        let organization = try database.setAlbumsHidden(ids, hidden: hidden, libraryID: libraryID)
        return organization
    }

    var hasCatalog: Bool {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path) { return true }
        guard hasStorage else { return false }
        return (try? CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).containsCatalog()) ?? true
    }

    private var hasStorage: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path)
    }

    func snapshot(database: CatalogDatabase? = nil) throws -> CatalogSnapshot? {
        guard hasStorage else { return nil }
        let snapshot = try (database ?? self.database()).snapshot()
        if let catalog = snapshot?.catalog { try writeArtwork(catalog) }
        return snapshot
    }

    func database() throws -> CatalogDatabase {
        try prepare()
        let database = try CatalogDatabase(root.appendingPathComponent("catalog.sqlite"))
        let legacy = root.appendingPathComponent("catalog.json")
        if FileManager.default.fileExists(atPath: legacy.path), try database.hostConnection() == nil, try !database.containsCatalog() {
            let catalog = try JSONDecoder().decode(LocalCatalog.self, from: Data(contentsOf: legacy))
            try writeArtwork(catalog)
            try database.save(catalog, received: catalog.entries.filter(hasFile))
        }
        return database
    }

    func save(_ catalog: LocalCatalog) throws {
        let database = try database()
        try writeArtwork(catalog)
        let received = catalog.entries.filter(hasFile)
        try database.save(catalog, received: received)
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

    func savedLocalFiles(in catalog: LocalCatalog) throws -> [String: URL] {
        var files: [String: URL] = [:]
        for entry in catalog.entries {
            try Task.checkCancellation()
            if hasFile(entry) {
                files[entry.track.id] = fileURL(entry)
            }
        }
        return files
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

    func importCachedFile(_ source: URL, entry: LocalEntry, host: Bool) throws -> Bool {
        let temporary = root.appendingPathComponent(".cache-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            if access(source.path, F_OK) == -1, errno == ENOENT { return false }
            throw error
        }
        try importFile(temporary, entry: entry, host: host)
        return true
    }

    func importFile(_ temporary: URL, entry: LocalEntry, recordReceipt: Bool = true, host: Bool = false, diagnostic: PlaybackDiagnosticContext? = nil) throws {
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
            if FileManager.default.fileExists(atPath: destination.path) {
                if try Self.digest(file: destination) != entry.sha256 {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            if recordReceipt {
                let database = try database()
                try database.recordReceived(entry)
                if host, let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                   let stamp = fileStamp(attributes) {
                    database.recordVerifiedAudio(destination, stamp: stamp, hash: entry.sha256)
                }
            }
            diagnostic?.record("save", "import", outcome: "succeeded")
        } catch { diagnostic?.failure(stage, error); throw error }
    }

#if os(macOS)
    func save(_ folder: LocalFolder) throws {
        let database = try database()
        try writeArtwork(folder.catalog)
        let prefix = folder.root.path + "/"
        var paths: [String: String] = [:]
        for (id, url) in folder.files {
            guard url.path.hasPrefix(prefix) else { throw LocalMusicError.invalidData }
            paths[id] = String(url.path.dropFirst(prefix.count))
        }
        try database.save(folder.catalog, sourceRoot: folder.root, sourcePaths: paths)
    }
#endif
}

#if os(macOS)
struct LocalFolder {
    var root: URL
    var catalog: LocalCatalog
    var files: [String: URL]
    var skipped: [String]

    static func scan(_ root: URL, id: String, previous: CatalogSnapshot? = nil) async throws -> LocalFolder {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw LocalMusicError.noMusic }
        var entries: [LocalEntry] = []
        var files: [String: URL] = [:]
        var skipped: [String] = []
        let extensions = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac"]
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let legacyRelative = String(url.path.dropFirst(root.path.count))
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            guard extensions.contains(url.pathExtension.lowercased()) else {
                if ["ogg", "opus", "wma", "ape"].contains(url.pathExtension.lowercased()) { skipped.append(url.lastPathComponent) }
                continue
            }
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { continue }
            do {
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { skipped.append(url.lastPathComponent); continue }
                let duration = try await asset.load(.duration).seconds
                let tags = try AudioTags.readFile(url)
                func tag(_ key: String) -> String? {
                    guard let value = (tags[key] as? [String])?.first, !value.isEmpty else { return nil }
                    return value
                }
                func number(_ key: String) -> Int? { tag(key)?.split(separator: "/").first.flatMap { Int($0) } }
                let trackID = LocalMusicStore.digest(Data((id + legacyRelative).utf8))
                var artwork: Data?
                artwork = (tags["artwork"] as? Data).flatMap(ArtworkImage.normalize)
                let track = Track(id: trackID, title: tag("TITLE") ?? url.deletingPathExtension().lastPathComponent,
                    artist: tag("ARTIST"), album: tag("ALBUM") ?? url.deletingLastPathComponent().lastPathComponent,
                    coverArt: artwork == nil ? nil : trackID, duration: duration.isFinite ? duration : nil,
                    track: number("TRACKNUMBER"), discNumber: number("DISCNUMBER"),
                    suffix: url.pathExtension.lowercased(), size: UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                let entry = LocalEntry(track: track, sha256: try LocalMusicStore.digest(file: url), artwork: artwork, importedAlbum: ImportedAlbumMetadata.read(tags))
                guard LocalMusicStore.valid(entry) else { skipped.append(url.lastPathComponent); continue }
                entries.append(entry)
                files[trackID] = url
            } catch is CancellationError { throw CancellationError() }
            catch { skipped.append(url.lastPathComponent) }
        }
        if let enumerationError { throw enumerationError }
        guard !entries.isEmpty else { throw LocalMusicError.noMusic }
        let old = previous?.catalog.id == id ? previous : nil
        let oldEntries = Dictionary(uniqueKeysWithValues: (old?.catalog.entries ?? []).map { ($0.track.id, $0) })
        let oldPaths = Dictionary(uniqueKeysWithValues: (old?.sourcePaths ?? [:]).map { ($0.value, $0.key) })
        var retained: [String: String] = [:]
        for entry in entries {
            let path = String(files[entry.track.id]!.path.dropFirst(root.path.count + 1))
            if let existing = oldPaths[path], oldEntries[existing]?.sha256 == entry.sha256 { retained[entry.track.id] = existing }
            else if old?.sourceRoot == nil, oldEntries[entry.track.id]?.sha256 == entry.sha256 {
                // The first SQLite scan preserves IDs derived from legacy relative paths.
                retained[entry.track.id] = entry.track.id
            }
        }
        let used = Set(retained.values)
        let retainedIdentities = old?.catalog.organization?.tracks ?? oldEntries.values.map {
            OrganizationTrack(id: $0.track.id, sha256: $0.sha256,
                imported: $0.importedAlbum ?? ImportedAlbumMetadata(title: $0.track.album, artist: $0.track.artist,
                    albumArtist: nil, compilationValues: [], release: nil), importedAlbumID: "")
        }
        let missing = Dictionary(grouping: retainedIdentities.filter { !used.contains($0.id) && (old?.catalog.organization?.canonicalTrack($0.id) ?? $0.id) == $0.id }, by: \.sha256)
        let added = Dictionary(grouping: entries.filter { retained[$0.track.id] == nil }, by: \.sha256)
        var stableFiles: [String: URL] = [:]
        entries = entries.map { entry in
            let matches = missing[entry.sha256] ?? []
            let renamedID = matches.count == 1 && added[entry.sha256]?.count == 1 ? matches[0].id : nil
            let stableID = retained[entry.track.id] ?? renamedID ?? UUID().uuidString
            stableFiles[stableID] = files[entry.track.id]
            var updated = entry
            updated.track.id = stableID
            if let previous = oldEntries[stableID] {
                updated.track.addedAt = previous.track.addedAt
            } else {
                updated.track.addedAt = Int64(Date().timeIntervalSince1970 * 1000)
            }
            if updated.track.coverArt != nil { updated.track.coverArt = stableID }
            return updated
        }
        var catalog = LocalCatalog(id: id, name: root.lastPathComponent,
            entries: entries.sorted { $0.track.id < $1.track.id }, organization: old?.catalog.organization)
        let folders = stableFiles.mapValues { String($0.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        catalog.organize(folders: folders)
        try ArtworkAcquisition.collect(entries: entries, originals: stableFiles, organization: &catalog.organization!, music: ArtworkAcquisition.musicReader())
        return LocalFolder(root: root, catalog: catalog, files: stableFiles, skipped: skipped)
    }
}
#endif

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

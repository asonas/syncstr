import AVFoundation
import CryptoKit
import Foundation
import AudioTags
import ImageIO
import UniformTypeIdentifiers

struct LocalEntry: Codable, Equatable {
    var track: Track
    var sha256: String
    var artwork: Data?
    var importedAlbum: ImportedAlbumMetadata? = nil
}

enum UploadedMusic {
    static func entry(file: URL, original: URL) async throws -> LocalEntry {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        var fields: [String: String] = [:]
        var artwork: Data?
        let tags = try AudioTags.readFile(file)
        for key in ["TITLE", "ARTIST", "ALBUM", "TRACKNUMBER", "DISCNUMBER"] {
            if let value = (tags[key] as? [String])?.first, !value.isEmpty { fields[key] = value }
        }
        if let data = tags["artwork"] as? Data, data.count <= 10 * 1024 * 1024,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 400
           ] as CFDictionary) {
            let output = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(destination) { artwork = output as Data }
            }
        }

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

    mutating func organize(folders: [String: String] = [:]) {
        var organization = organization ?? AlbumOrganization()
        organization.importEntries(entries, folders: folders)
        self.organization = organization
    }
}

enum LocalMusicError: LocalizedError {
    case invalidData, disconnected, unauthorized, changedFile, noMusic, invalidCode, incompatiblePeer

    var errorDescription: String? {
        switch self {
        case .invalidData: "音楽の情報を確認できませんでした。もう一度転送してください。"
        case .disconnected: "接続が切れました。両方のアプリを開き、同じWi-Fiで再接続してください。"
        case .unauthorized: "ペアリングが承認されませんでした。Macで新しいコードを表示してやり直してください。"
        case .changedFile: "音源が変更されたか読み込めません。Macのライブラリを更新してください。"
        case .noMusic: "再生できる音源が見つかりませんでした。別のフォルダを選んでください。"
        case .invalidCode: "Macに表示された32文字のコードを入力してください。"
        case .incompatiblePeer: "接続先のSyncstrを更新してください。アルバムの整理情報に対応していません。"
        }
    }
}

struct LocalMusicStore {
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

    var hasCatalog: Bool {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path) { return true }
        guard hasStorage else { return false }
        return (try? CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).containsCatalog()) ?? true
    }

    private var hasStorage: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path)
    }

    func snapshot() throws -> CatalogSnapshot? {
        guard hasStorage else { return nil }
        return try database().snapshot()
    }

    private func database() throws -> CatalogDatabase {
        try prepare()
        let database = try CatalogDatabase(root.appendingPathComponent("catalog.sqlite"))
        let legacy = root.appendingPathComponent("catalog.json")
        if try !database.containsCatalog(), FileManager.default.fileExists(atPath: legacy.path) {
            let catalog = try JSONDecoder().decode(LocalCatalog.self, from: Data(contentsOf: legacy))
            try writeArtwork(catalog)
            try database.save(catalog, received: catalog.entries.filter(hasFile))
        }
        return database
    }

    func save(_ catalog: LocalCatalog) throws {
        let database = try database()
        try writeArtwork(catalog)
        try database.save(catalog, received: catalog.entries.filter(hasFile))
    }

    private func writeArtwork(_ catalog: LocalCatalog) throws {
        guard Set(catalog.entries.map { $0.track.id }).count == catalog.entries.count else {
            throw LocalMusicError.invalidData
        }
        try prepare()
        for entry in catalog.entries {
            guard Self.valid(entry) else { throw LocalMusicError.invalidData }
            if let artwork = entry.artwork { try artwork.write(to: artworkURL(entry), options: .atomic) }
        }
    }

    static func valid(_ entry: LocalEntry) -> Bool {
        entry.sha256.count == 64 && entry.sha256.allSatisfy { "0123456789abcdef".contains($0) }
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

    func artworkURL(_ entry: LocalEntry) -> URL {
        root.appendingPathComponent(Self.digest(entry.artwork ?? Data()) + ".jpg")
    }

    func hasFile(_ entry: LocalEntry) -> Bool {
        guard Self.valid(entry), let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(entry).path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.uint64Value == entry.track.size
    }

    func importFile(_ temporary: URL, entry: LocalEntry) throws {
        guard Self.valid(entry),
              (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.uint64Value == entry.track.size,
              try Self.digest(file: temporary) == entry.sha256 else { throw LocalMusicError.invalidData }
        try prepare()
        let destination = fileURL(entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            if try Self.digest(file: destination) != entry.sha256 {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            }
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try database().recordReceived(entry)
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
                if let data = tags["artwork"] as? Data, data.count <= 10 * 1024 * 1024,
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 400
                   ] as CFDictionary) {
                    let output = NSMutableData()
                    if let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                        if CGImageDestinationFinalize(destination) { artwork = output as Data }
                    }
                }
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
            else if old?.sourceRoot == nil, oldEntries[entry.track.id] != nil {
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
            if updated.track.coverArt != nil { updated.track.coverArt = stableID }
            return updated
        }
        var catalog = LocalCatalog(id: id, name: root.lastPathComponent,
            entries: entries.sorted { $0.track.id < $1.track.id }, organization: old?.catalog.organization)
        let folders = stableFiles.mapValues { String($0.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        catalog.organize(folders: folders)
        return LocalFolder(root: root, catalog: catalog, files: stableFiles, skipped: skipped)
    }
}
#endif

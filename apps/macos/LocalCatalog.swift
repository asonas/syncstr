import AVFoundation
import CryptoKit
import Foundation
#if os(macOS)
import AudioTags
import ImageIO
import UniformTypeIdentifiers
#endif

struct LocalEntry: Codable, Equatable {
    var track: Track
    var sha256: String
    var artwork: Data?
}

struct LocalCatalog: Codable {
    var id: String
    var name: String
    var entries: [LocalEntry]
}

enum LocalMusicError: LocalizedError {
    case invalidData, disconnected, unauthorized, changedFile, noMusic, invalidCode

    var errorDescription: String? {
        switch self {
        case .invalidData: "音楽の情報を確認できませんでした。もう一度転送してください。"
        case .disconnected: "接続が切れました。両方のアプリを開き、同じWi-Fiで再接続してください。"
        case .unauthorized: "ペアリングが承認されませんでした。Macで新しいコードを表示してやり直してください。"
        case .changedFile: "音源が変更されたか読み込めません。Macのライブラリを更新してください。"
        case .noMusic: "再生できる音源が見つかりませんでした。別のフォルダを選んでください。"
        case .invalidCode: "Macに表示された32文字のコードを入力してください。"
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
        let url = root.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LocalCatalog.self, from: Data(contentsOf: url))
    }

    func save(_ catalog: LocalCatalog) throws {
        guard Set(catalog.entries.map { $0.track.id }).count == catalog.entries.count else {
            throw LocalMusicError.invalidData
        }
        try prepare()
        for entry in catalog.entries {
            guard Self.valid(entry) else { throw LocalMusicError.invalidData }
            if let artwork = entry.artwork { try artwork.write(to: artworkURL(entry), options: .atomic) }
        }
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
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
            if try Self.digest(file: destination) == entry.sha256 { return }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

#if os(macOS)
struct LocalFolder {
    var root: URL
    var catalog: LocalCatalog
    var files: [String: URL]
    var skipped: [String]

    static func scan(_ root: URL, id: String) async throws -> LocalFolder {
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
                let relative = String(url.path.dropFirst(root.path.count))
                let trackID = LocalMusicStore.digest(Data((id + relative).utf8))
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
                let entry = LocalEntry(track: track, sha256: try LocalMusicStore.digest(file: url), artwork: artwork)
                guard LocalMusicStore.valid(entry) else { skipped.append(url.lastPathComponent); continue }
                entries.append(entry)
                files[trackID] = url
            } catch is CancellationError { throw CancellationError() }
            catch { skipped.append(url.lastPathComponent) }
        }
        if let enumerationError { throw enumerationError }
        guard !entries.isEmpty else { throw LocalMusicError.noMusic }
        return LocalFolder(root: root, catalog: LocalCatalog(id: id, name: root.lastPathComponent,
            entries: entries.sorted { $0.track.id < $1.track.id }), files: files, skipped: skipped)
    }
}
#endif

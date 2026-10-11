import Foundation
#if os(macOS)
import iTunesLibrary
#endif

enum ArtworkAcquisition {
    static func fileImage(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 10 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return ArtworkImage.normalize(data)
    }

    static func folderImage(_ directory: URL) -> Data? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for name in ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png"] {
            for url in files.filter({ $0.lastPathComponent.lowercased() == name }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let data = fileImage(url) { return data }
            }
        }
        return nil
    }

    static func collect(entries: [LocalEntry], originals: [String: URL], organization: inout AlbumOrganization,
                        music: (URL) -> Data?) throws {
        var folders: [URL: Data] = [:]
        var attempted = Set<URL>()
        func folder(_ directory: URL) -> Data? {
            if attempted.insert(directory).inserted { folders[directory] = folderImage(directory) }
            return folders[directory]
        }
        for entry in entries {
            let id = organization.canonicalTrack(entry.track.id)
            guard let record = organization.tracks.first(where: { $0.id == id }), let original = originals[entry.track.id] else { continue }
            if let embedded = entry.artwork, let image = ArtworkImage.normalize(embedded) {
                try organization.captureArtwork(image, track: id, source: "embedded", context: entry.sha256)
                continue
            }
            let directory = original.standardizedFileURL.deletingLastPathComponent()
            var imageDirectory = directory
            var image = folder(directory)
            if image == nil, let album = organization.albumID(for: id) {
                let members = organization.tracks.filter { organization.canonicalTrack($0.id) == $0.id && organization.albumID(for: $0.id) == album }
                let contexts = members.compactMap(\.importContext)
                let locations = members.compactMap { originals[$0.id]?.standardizedFileURL.deletingLastPathComponent() }
                if contexts.count == members.count, locations.count == members.count,
                   members.allSatisfy({ ($0.discNumber ?? 0) > 0 }),
                   Dictionary(grouping: members, by: { $0.importContext?.folder }).values.allSatisfy({ Set($0.compactMap(\.discNumber)).count == 1 }),
                   Set(members.compactMap(\.discNumber)).count == Set(contexts.map(\.folder)).count,
                   Set(contexts.map { [$0.sourceID, $0.parent] }).count == 1,
                   Set(contexts.map(\.folder)).count > 1,
                   Set(locations.map { $0.deletingLastPathComponent() }).count == 1, Set(locations).count > 1 {
                    imageDirectory = directory.deletingLastPathComponent()
                    image = folder(imageDirectory)
                }
            }
            if let image {
                let context = LocalMusicStore.digest(Data(((record.importContext?.sourceID ?? "") + imageDirectory.path).utf8))
                try organization.captureArtwork(image, track: id, source: "folder", context: context)
            } else if let data = music(original), let image = ArtworkImage.normalize(data) {
                try organization.captureArtwork(image, track: id, source: "music", context: entry.sha256)
            }
        }
    }

    static func musicReader() -> (URL) -> Data? {
#if os(macOS)
        return musicReader {
            guard let library = try? ITLibrary(apiVersion: "1.0") else { return [] }
            return library.allMediaItems.compactMap { item in
                guard let location = item.location, location.isFileURL else { return nil }
                return (location, { _ = library; return item.artwork?.imageData })
            }
        }
#else
        return { _ in nil }
#endif
    }

    static func musicReader(snapshot: @escaping () -> [(URL, () -> Data?)]) -> (URL) -> Data? {
        var attempted = false
        var index: [URL: [() -> Data?]] = [:]
        return { url in
            if !attempted {
                attempted = true
                for (location, image) in snapshot() where location.isFileURL {
                    index[location.standardizedFileURL.resolvingSymlinksInPath(), default: []].append(image)
                }
            }
            guard let items = index[url.standardizedFileURL.resolvingSymlinksInPath()], items.count == 1 else { return nil }
            return items[0]()
        }
    }
}

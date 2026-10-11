import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArtworkImage {
    static func normalize(_ data: Data) -> Data? {
        if valid(data) { return data }
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(400, max(width, height))
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 512 * 1024 else { return nil }
        return output as Data
    }

    static func valid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 512 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 400 && height <= 400
            && data.suffix(2) == Data([0xff, 0xd9])
            && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

struct ArtworkCandidate: Codable, Equatable, Identifiable {
    var id: String
    var track: String
    var source: String
    var context: String
    var asset: String
    var parents: [String]

    var key: String { [track, source, context].map { "\($0.utf8.count):\($0)" }.joined() }
    var priority: Int { ["embedded": 0, "folder": 1, "music": 2, "legacy": 3][source] ?? 4 }
}

struct AlbumArtwork: Codable, Equatable {
    var assets: [String: Data] = [:]
    var candidates: [ArtworkCandidate] = []
    var preferred: [String: String] = [:]

    var heads: [ArtworkCandidate] {
        let superseded = Set(candidates.flatMap(\.parents))
        return candidates.filter { !superseded.contains($0.id) }
    }

    mutating func merge(_ incoming: AlbumArtwork) throws {
        for (id, data) in incoming.assets {
            guard assets[id] == nil || assets[id] == data else { throw LocalMusicError.invalidData }
            assets[id] = data
        }
        for revision in incoming.candidates {
            if let existing = candidates.first(where: { $0.id == revision.id }) {
                guard existing == revision else { throw LocalMusicError.invalidData }
            } else { candidates.append(revision) }
        }
        for (key, asset) in incoming.preferred where preferred[key] == nil { preferred[key] = asset }
    }

    func validate(tracks: Set<String>) throws {
        guard assets.count <= 100000, candidates.count <= 200000,
              Set(candidates.map(\.id)).count == candidates.count,
              assets.allSatisfy({ LocalMusicStore.digest($0.value) == $0.key && ArtworkImage.valid($0.value) }) else { throw LocalMusicError.invalidData }
        let records = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var remaining: [String: Int] = [:]
        var children: [String: [String]] = [:]
        for candidate in candidates {
            guard tracks.contains(candidate.track), assets[candidate.asset] != nil,
                  candidate.id.utf8.count <= 128, candidate.context.utf8.count <= 4096,
                  ["embedded", "folder", "music", "legacy"].contains(candidate.source),
                  candidate.parents.count <= 10000, Set(candidate.parents).count == candidate.parents.count else { throw LocalMusicError.invalidData }
            remaining[candidate.id] = candidate.parents.count
            for parent in candidate.parents {
                guard records[parent]?.key == candidate.key else { throw LocalMusicError.invalidData }
                children[parent, default: []].append(candidate.id)
            }
        }
        var ready = candidates.filter { $0.parents.isEmpty }.map(\.id)
        var index = 0
        while index < ready.count {
            let id = ready[index]; index += 1
            for child in children[id] ?? [] {
                remaining[child]! -= 1
                if remaining[child] == 0 { ready.append(child) }
            }
        }
        guard ready.count == candidates.count else { throw LocalMusicError.invalidData }
    }
}

extension AlbumOrganization {
    mutating func captureArtwork(_ data: Data, track: String, source: String, context: String) throws {
        guard ArtworkImage.valid(data) else { throw LocalMusicError.invalidData }
        let asset = LocalMusicStore.digest(data)
        var images = artwork ?? AlbumArtwork()
        let revision = ArtworkCandidate(id: UUID().uuidString, track: canonicalTrack(track), source: source, context: context, asset: asset, parents: [])
        let heads = images.heads.filter { $0.key == revision.key }
        // Concurrent acquisitions require a listener choice, even when a new scan can read one image.
        guard Set(heads.map(\.asset)).count <= 1 else { return }
        if heads.contains(where: { $0.asset == asset }) { return }
        images.assets[asset] = data
        var update = revision
        update.parents = heads.map(\.id).sorted()
        let sourceKey = artworkSourceKey(revision)
        let independent = images.heads.contains { artworkSourceKey($0) == sourceKey && $0.key != revision.key && $0.asset != asset }
        images.candidates.append(update)
        images.preferred[revision.key] = asset
        if !independent || images.preferred[sourceKey] == nil { images.preferred[sourceKey] = asset }
        artwork = images
    }

    mutating func chooseArtwork(_ data: Data, album: String) throws {
        guard let normalized = ArtworkImage.normalize(data) else { throw LocalMusicError.invalidData }
        let id = LocalMusicStore.digest(normalized)
        if artwork == nil { artwork = AlbumArtwork() }
        artwork?.assets[id] = normalized
        set(subject: album, kind: "artwork", value: id)
    }

    func artworkCandidates(for album: String) -> [ArtworkCandidate] {
        let records = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return (artwork?.heads ?? []).filter { albumID(for: $0.track) == canonical(album) }.sorted {
            let left = records[canonicalTrack($0.track)]
            let right = records[canonicalTrack($1.track)]
            return ($0.priority, left?.discNumber ?? 1, left?.trackNumber ?? Int.max, canonicalTrack($0.track), $0.context, $0.id)
                < ($1.priority, right?.discNumber ?? 1, right?.trackNumber ?? Int.max, canonicalTrack($1.track), $1.context, $1.id)
        }
    }

    func coverAsset(for album: String) -> String? {
        if let manual = choice(subject: album, kind: "artwork")?.value { return manual }
        guard let first = artworkCandidates(for: album).first else { return nil }
        let key = artworkSourceKey(first)
        let peers = artworkCandidates(for: album).filter { artworkSourceKey($0) == key }
        let preferred = artwork?.preferred[key] ?? artwork?.preferred[first.key]
        return peers.first { $0.asset == preferred }?.asset ?? first.asset
    }

    private func artworkSourceKey(_ candidate: ArtworkCandidate) -> String {
        [canonicalTrack(candidate.track), candidate.source].map { "\($0.utf8.count):\($0)" }.joined()
    }

    func hasArtworkConflict(_ album: String) -> Bool {
        if hasConflict(subject: album, kind: "artwork") { return true }
        if choice(subject: album, kind: "artwork")?.value != nil { return false }
        return Dictionary(grouping: artworkCandidates(for: album), by: artworkSourceKey).values.contains { Set($0.map(\.asset)).count > 1 }
    }

    mutating func retainLegacyArtwork(_ entries: [LocalEntry]) {
        for entry in entries {
            let id = canonicalTrack(entry.track.id)
            guard !(artwork?.candidates.contains { canonicalTrack($0.track) == id } ?? false),
                  let data = entry.artwork, let normalized = ArtworkImage.normalize(data) else { continue }
            try? captureArtwork(normalized, track: id, source: "legacy", context: entry.sha256)
        }
    }
}

import AudioTags
import Foundation

struct MusicMetadata: Equatable, Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var track = ""
    var artwork: Data?
    var artworkMIME: String?

    static func read(_ url: URL) throws -> MusicMetadata {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let tags = try AudioTags.readFile(url)
        func first(_ key: String) -> String { (tags[key] as? [String])?.first ?? "" }
        return MusicMetadata(title: first("TITLE"), artist: first("ARTIST"), album: first("ALBUM"),
                             track: first("TRACKNUMBER"), artwork: tags["artwork"] as? Data)
    }

    func writeChanges(from original: MusicMetadata, to copy: URL) throws {
        guard track == original.track || track.isEmpty || track.range(of: #"^[1-9][0-9]*(/[1-9][0-9]*)?$"#, options: .regularExpression) != nil else {
            throw MetadataError.invalidTrack
        }
        var fields: [String: String] = [:]
        for (key, before, after) in [("TITLE", original.title, title), ("ARTIST", original.artist, artist),
                                     ("ALBUM", original.album, album), ("TRACKNUMBER", original.track, track)] where before != after {
            fields[key] = after
        }
        let changeArtwork = artwork != original.artwork
        guard !fields.isEmpty || changeArtwork else { return }
        try AudioTags.writeFile(copy, fields: fields, artwork: artwork, mimeType: artworkMIME,
                                changeArtwork: changeArtwork)
    }
}

enum MetadataError: LocalizedError {
    case invalidTrack, invalidArtwork
    var errorDescription: String? {
        switch self {
        case .invalidTrack: return "曲番号は正の整数、または「1/12」の形式で入力してください。"
        case .invalidArtwork: return "ジャケットには10MB以下のJPEGまたはPNG画像を選んでください。"
        }
    }
}

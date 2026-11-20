import Foundation

struct Track: Codable, Identifiable, Equatable {
    var id: String
    let title: String
    let artist: String?
    var album: String? = nil
    var albumId: String? = nil
    var coverArt: String? = nil
    var duration: Double? = nil
    var track: Int? = nil
    var discNumber: Int? = nil
    var suffix: String? = nil
    var size: UInt64? = nil
    var addedAt: Int64? = nil

    var albumKey: String { albumId ?? "\(artist ?? "")\u{1f}\(album ?? "")" }
    var albumDisplayTitle: String {
        guard let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "アルバム未設定" : title
        }
        return album
    }
}

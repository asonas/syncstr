import Foundation
struct PlaylistItem: Codable, Equatable, Identifiable {
    let id: String
    let sourceTrack: String
    let title: String
    let artist: String?
    let album: String?
    let trackId: String?
    let sha256: String?
}

struct PlaylistDocument: Codable, Equatable, Identifiable {
    let id: String
    let sourceLibrary: String
    let sourcePlaylist: String
    let sourceFingerprint: String
    let name: String
    let kind: String
    let parent: String?
    let definition: [String: String]
    var items: [PlaylistItem]

    func validate() throws {
        func identity(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard identity(sourceLibrary), identity(sourcePlaylist), !sourceLibrary.contains(":"), !sourcePlaylist.contains(":"),
              id == "\(sourceLibrary):\(sourcePlaylist)", SHA256Hex.isValid(sourceFingerprint),
              ["folder", "manual", "snapshot"].contains(kind), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 4096, items.count <= 100_000,
              parent.map({ identity($0) && $0 != id }) ?? true,
              kind != "folder" || items.isEmpty, Set(items.map(\.id)).count == items.count,
              try JSONEncoder().encode(self).count <= 8 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        for item in items {
            guard identity(item.id), identity(item.sourceTrack), item.title.utf8.count <= 4096,
                  (item.artist?.utf8.count ?? 0) <= 4096, (item.album?.utf8.count ?? 0) <= 4096,
                  (item.trackId == nil) == (item.sha256 == nil),
                  item.trackId.map(identity) ?? true,
                  item.sha256.map(SHA256Hex.isValid) ?? true else { throw LocalMusicError.invalidData }
        }
    }
}

struct PlaylistOutlineRow: Identifiable {
    let document: PlaylistDocument
    let depth: Int
    var id: String { document.id }
}

extension Array where Element == PlaylistDocument {
    func outline(expanding folders: Set<String>) -> [PlaylistOutlineRow] {
        let children = Dictionary(grouping: self, by: \.parent)
        func rows(under parent: String?, depth: Int) -> [PlaylistOutlineRow] {
            (children[parent] ?? []).flatMap { document in
                [PlaylistOutlineRow(document: document, depth: depth)]
                    + (folders.contains(document.id) ? rows(under: document.id, depth: depth + 1) : [])
            }
        }
        return rows(under: nil, depth: 0)
    }

    func ancestors(of id: String) -> [String] {
        var ancestors: [String] = []
        var parent = first { $0.id == id }?.parent
        while let current = parent, !ancestors.contains(current) {
            ancestors.append(current)
            parent = first { $0.id == current }?.parent
        }
        return ancestors
    }
}

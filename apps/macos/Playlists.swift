import Foundation

enum PlaylistImportError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self { case .rejected(let reason): "プレイリストを取り込めませんでした。\(reason)" }
    }
}

struct PlaylistRequest: Encodable {
    let operation: String
    var after: Int64? = nil
    var cluster: String? = nil
    var documents: [PlaylistDocument]? = nil
}

struct PlaylistResponse: Decodable {
    let status: String
    let cluster: String?
    let entries: [LocalEntry]?
    let next: Int64?
    let record: PlaylistRecord?
    let added: Int?
    let reason: String?
}

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
    let items: [PlaylistItem]

    func validate() throws {
        func identity(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard identity(sourceLibrary), identity(sourcePlaylist), !sourceLibrary.contains(":"), !sourcePlaylist.contains(":"),
              id == "\(sourceLibrary):\(sourcePlaylist)", ClusterIdentity.isLowercaseHex256(sourceFingerprint),
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
                  item.sha256.map(ClusterIdentity.isLowercaseHex256) ?? true else { throw LocalMusicError.invalidData }
        }
    }
}

struct PlaylistRecord: Codable, Equatable {
    struct Body: Codable {
        let version: Int
        let cluster: String
        let author: String
        let grant: String
        let document: PlaylistDocument
    }
    let id: String
    let payload: String
    let signature: String

    func decode(membership: ClusterMembership) throws -> Body {
        let prefix = "syncstr-playlist-v1\n"
        guard payload.hasPrefix(prefix), payload.utf8.count <= 8 * 1024 * 1024 + 4096 else { throw LocalMusicError.invalidData }
        let body = try JSONDecoder().decode(Body.self, from: Data(payload.dropFirst(prefix.count).utf8))
        guard body.version == 1 else { throw LocalMusicError.incompatiblePeer }
        try ClusterCrypto.verify(id: id, author: body.author, signature: signature, payload: Data(payload.utf8))
        let authority = try membership.verify(body.grant)
        guard authority.host, authority.member == body.author, authority.cluster == body.cluster else { throw LocalMusicError.unauthorized }
        try body.document.validate()
        return body
    }
}

struct PlaylistMatchingCatalog: Codable {
    let cluster: String
    let entries: [LocalEntry]
}

struct PlaylistDraft {
    struct Source: Identifiable {
        let id: String
        let name: String
        let kind: String
        let parent: String?
        let definition: [String: String]
        let items: [String]
        var ancestors: [String] = []
        var path: String = ""
    }
    struct Song: Identifiable {
        let id: String
        let persistentID: String?
        let title: String
        let artist: String?
        let album: String?
        let candidates: [LocalEntry]
    }
    let sourceLibrary: String
    let fingerprint: String
    let cluster: String
    let playlists: [Source]
    let songs: [String: Song]

    static func parse(_ data: Data, catalog: PlaylistMatchingCatalog) throws -> Self {
        guard data.count <= 32 * 1024 * 1024, let xml = String(data: data, encoding: .utf8),
              !xml.uppercased().contains("<!ENTITY"),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let library = root["Library Persistent ID"] as? String,
              let tracks = root["Tracks"] as? [String: [String: Any]],
              let lists = root["Playlists"] as? [[String: Any]], tracks.count <= 100_000, lists.count <= 10000 else { throw LocalMusicError.invalidData }
        func normalized(_ value: String?) -> String { (value ?? "").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines) }
        func key(_ title: String?, _ artist: String?, _ album: String?) -> [String] { [normalized(title), normalized(artist), normalized(album)] }
        let index = Dictionary(grouping: catalog.entries, by: { key($0.track.title, $0.track.artist, $0.track.album) })
        var songs: [String: Song] = [:]
        var persistentIDs: Set<String> = []
        for (id, source) in tracks {
            let persistent = source["Persistent ID"] as? String
            if let persistent, !persistentIDs.insert(persistent).inserted { throw LocalMusicError.invalidData }
            let title = source["Name"] as? String ?? "不明な曲"
            let artist = source["Artist"] as? String
            let album = source["Album"] as? String
            let fields = key(title, artist, album)
            var candidates: [LocalEntry] = []
            if fields.allSatisfy({ !$0.isEmpty }), let duration = source["Total Time"] as? Double {
                candidates = (index[fields] ?? []).filter { entry in
                    guard let seconds = entry.track.duration, abs(seconds * 1000 - duration) <= 2000 else { return false }
                    if let number = source["Track Number"] as? Int, entry.track.track != number { return false }
                    if let disc = source["Disc Number"] as? Int, (entry.track.discNumber ?? 1) != disc { return false }
                    return true
                }
            }
            var seen: Set<String> = []
            candidates = candidates.filter { seen.insert($0.track.id + ":" + $0.sha256).inserted }.sorted { $0.track.id < $1.track.id }
            songs[id] = Song(id: id, persistentID: persistent, title: title, artist: artist, album: album, candidates: candidates)
        }
        var playlists: [Source] = []
        var ids: Set<String> = []
        for source in lists {
            guard let id = source["Playlist Persistent ID"] as? String, ids.insert(id).inserted else { throw LocalMusicError.invalidData }
            let folder = source["Folder"] as? Bool == true
            if !folder && (source["Master"] as? Bool == true || source["Distinguished Kind"] != nil) { continue }
            let definition = ["Smart Info", "Smart Criteria"].reduce(into: [String: String]()) { result, name in
                if let bytes = source[name] as? Data { result[name] = bytes.base64EncodedString() }
            }
            let items = folder ? [] : try (source["Playlist Items"] as? [[String: Any]] ?? []).map { item -> String in
                guard let id = item["Track ID"] as? Int else { throw LocalMusicError.invalidData }
                return String(id)
            }
            playlists.append(Source(id: id, name: source["Name"] as? String ?? "名称未設定",
                kind: folder ? "folder" : definition.isEmpty ? "manual" : "snapshot",
                parent: source["Parent Persistent ID"] as? String, definition: definition, items: items))
        }
        guard playlists.reduce(0, { $0 + $1.items.count }) <= 1_000_000 else { throw LocalMusicError.invalidData }
        let byID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        for i in playlists.indices {
            var seen: Set<String> = [playlists[i].id]
            var parent = playlists[i].parent
            while let id = parent {
                guard seen.insert(id).inserted, let folder = byID[id], folder.kind == "folder" else { throw LocalMusicError.invalidData }
                playlists[i].ancestors.insert(id, at: 0)
                parent = folder.parent
            }
            playlists[i].path = (playlists[i].ancestors.compactMap { byID[$0]?.name } + [playlists[i].name]).joined(separator: " / ")
        }
        return Self(sourceLibrary: library, fingerprint: LocalMusicStore.digest(data), cluster: catalog.cluster, playlists: playlists, songs: songs)
    }

    func documents(selected: Set<String>, accepted: [String: String]) throws -> [PlaylistDocument] {
        let lists = playlists.filter { selected.contains($0.id) && $0.kind != "folder" }
        guard !lists.isEmpty else { throw LocalMusicError.invalidData }
        let needed = selected.union(lists.flatMap(\.ancestors))
        return try playlists.filter { needed.contains($0.id) }.map { source in
            let items = try source.items.enumerated().map { position, id -> PlaylistItem in
                let song = songs[id]
                let candidate: LocalEntry?
                if let choice = accepted[id] {
                    guard let found = song?.candidates.first(where: { $0.track.id + ":" + $0.sha256 == choice }) else { throw LocalMusicError.invalidData }
                    candidate = found
                } else { candidate = nil }
                return PlaylistItem(id: "\(source.id):\(position)", sourceTrack: song?.persistentID ?? id,
                    title: song?.title ?? "不明な曲", artist: song?.artist, album: song?.album,
                    trackId: candidate?.track.id, sha256: candidate?.sha256)
            }
            let document = PlaylistDocument(id: "\(sourceLibrary):\(source.id)", sourceLibrary: sourceLibrary,
                sourcePlaylist: source.id, sourceFingerprint: fingerprint, name: source.name, kind: source.kind,
                parent: source.parent.map { "\(sourceLibrary):\($0)" }, definition: source.definition, items: items)
            try document.validate()
            return document
        }
    }
}

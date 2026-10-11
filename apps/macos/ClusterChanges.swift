import Foundation

struct ClusterMetadataEdit: Codable {
    let id: String
    let entry: LocalEntry
    let organization: AlbumOrganization
    var parents: [String]
}

extension AlbumOrganization {
    func forClusterObject(_ object: String) throws -> AlbumOrganization {
        try validate()
        let tracks = tracks.filter { $0.sha256 == object }
        let trackIDs = Set(tracks.map(\.id))
        var albumIDs = Set(tracks.map { canonical($0.importedAlbumID) })
        for choice in choices where choice.kind == "membership" && trackIDs.contains(choice.subject) {
            if let value = choice.value { albumIDs.insert(canonical(value)) }
        }
        let choices = choices.filter { choice in
            switch choice.kind {
            case "membership": return trackIDs.contains(choice.subject)
            case "classification", "artwork": return albumIDs.contains(canonical(choice.subject))
            case "proposal": return choice.subject.split(separator: ",").contains { albumIDs.contains(canonical(String($0))) }
            default: return false
            }
        }
        let choiceIDs = Set(choices.map(\.id))
        var artwork = artwork
        if var subset = artwork {
            subset.candidates.removeAll { !trackIDs.contains($0.track) }
            let assets = Set(subset.candidates.map(\.asset) + choices.filter { $0.kind == "artwork" }.compactMap(\.value))
            subset.assets = subset.assets.filter { assets.contains($0.key) }
            subset.preferred = subset.preferred.filter { assets.contains($0.value) }
            artwork = subset
        }
        let result = AlbumOrganization(albums: albums.filter { albumIDs.contains($0.id) }, tracks: tracks,
            aliases: aliases.filter { albumIDs.contains(canonical($0.key)) }, choices: choices,
            preferred: preferred.filter { choiceIDs.contains($0.value) },
            trackAliases: trackAliases?.filter { trackIDs.contains(canonicalTrack($0.key)) },
            automaticAliases: automaticAliases?.filter { albumIDs.contains(canonical($0.key)) }, artwork: artwork)
        try result.validate()
        return result
    }
}

struct ClusterChange: Codable {
    struct Action: Codable {
        enum Kind: String, Codable { case `import`, delete, restore, edit, resolve }
        let kind: Kind
        let entry: LocalEntry?
        let organization: AlbumOrganization?
        let selected: String?
    }
    let version: Int
    let id: String
    let cluster: String
    let author: String
    let grant: String
    let previous: [String]
    let object: String
    let parents: [String]
    let action: Action
    let signature: String

    func authorized(by membership: ClusterMembership, history: [ClusterChange]) throws -> Bool {
        guard Set(history.map(\.id)).count == history.count else { throw LocalMusicError.invalidData }
        if (try? membership.verify(grant)) != nil { return true }
        let state = try membership.revocationState()
        guard !state.disputed.contains(author) else { return false }
        let boundaries = state.active.map { membership.revocations[$0] }.filter { $0.member == author }
        guard !boundaries.isEmpty else { return false }
        let records = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        for boundary in boundaries {
            var pending = boundary.changeHeads
            var visited = Set<String>()
            var observed = false
            while let next = pending.popLast() {
                guard visited.insert(next).inserted else { continue }
                if next == id { observed = true; break }
                if let record = records[next], record.author == author { pending.append(contentsOf: record.previous) }
            }
            if !observed { return false }
        }
        return true
    }
}

/// Preserve the signed bytes rather than re-encoding floating-point metadata.
struct ClusterSignedChange: Codable, Equatable {
    let id: String
    let signature: String
    let payload: String

    func decode(membership: ClusterMembership) throws -> ClusterChange {
        let prefix = "syncstr-cluster-change-v1\n"
        guard payload.utf8.count <= 1024 * 1024, payload.hasPrefix(prefix),
              let fields = try JSONSerialization.jsonObject(with: Data(payload.dropFirst(prefix.count).utf8)) as? [Any],
              fields.count == 8 else { throw LocalMusicError.invalidData }
        let names = ["version", "cluster", "author", "grant", "previous", "object", "parents", "action"]
        var object = Dictionary(uniqueKeysWithValues: zip(names, fields))
        object["id"] = id
        object["signature"] = signature
        let change = try JSONDecoder().decode(ClusterChange.self, from: JSONSerialization.data(withJSONObject: object))
        guard change.version == 1, ClusterIdentity.isLowercaseHex256(change.object),
              change.parents.count <= 64, change.previous.count <= 64,
              Set(change.parents).count == change.parents.count, Set(change.previous).count == change.previous.count,
              (change.parents + change.previous).allSatisfy({ ClusterIdentity.isLowercaseHex256($0) && $0 != id }) else {
            throw LocalMusicError.invalidData
        }
        try ClusterCrypto.verify(id: id, author: change.author, signature: signature, payload: Data(payload.utf8))
        let authority = try membership.chain(change.grant)[0]
        guard authority.member == change.author, authority.cluster == change.cluster, authority.host else { throw LocalMusicError.unauthorized }
        guard let action = fields[7] as? [String: Any] else { throw LocalMusicError.invalidData }
        switch change.action.kind {
        case .import, .restore, .edit:
            guard Set(action.keys) == Set(["kind", "entry", "organization"]),
                  let entry = change.action.entry, let organization = change.action.organization,
                  LocalMusicStore.valid(entry), entry.sha256 == change.object,
                  !entry.track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.track.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  organization.tracks.allSatisfy({ $0.sha256 == change.object }) else { throw LocalMusicError.invalidData }
            try organization.validate()
        case .delete:
            guard Set(action.keys) == Set(["kind"]) else { throw LocalMusicError.invalidData }
        case .resolve:
            guard Set(action.keys) == Set(["kind", "selected"]), let selected = change.action.selected,
                  change.parents.contains(selected) else { throw LocalMusicError.invalidData }
        }
        return change
    }
}

struct ClusterObjectState {
    let object: String
    let heads: [ClusterChange]
    var conflicted: Bool { heads.count > 1 }

    func selected(in records: [ClusterChange]) throws -> ClusterChange? {
        guard !conflicted else { throw LocalMusicError.invalidData }
        guard var selected = heads.first else { return nil }
        for _ in 0...records.count {
            switch selected.action.kind {
            case .delete: return nil
            case .import, .restore, .edit: return selected
            case .resolve:
                guard let parent = records.first(where: { $0.id == selected.action.selected }) else { throw LocalMusicError.invalidData }
                selected = parent
            }
        }
        throw LocalMusicError.invalidData
    }

    static func project(_ records: [ClusterChange], membership: ClusterMembership) throws -> [Self] {
        guard Set(records.map(\.id)).count == records.count else { throw LocalMusicError.invalidData }
        let active = try records.filter { try $0.authorized(by: membership, history: records) }
        let superseded = Set(active.flatMap(\.parents))
        return Set(active.map(\.object)).sorted().map { object in
            let matching = active.filter { $0.object == object }
            let explicit = matching.contains { $0.action.kind != .import }
            let heads = matching.filter { !superseded.contains($0.id) && !(explicit && $0.action.kind == .import) }
            return Self(object: object, heads: heads.sorted { $0.id < $1.id })
        }
    }
}

struct ClusterAlbumConflict: Identifiable {
    let id: String
    let titles: [String]
    let objects: [String]

    static func project(_ records: [ClusterChange], organization: AlbumOrganization) throws -> [Self] {
        var merged = organization
        for record in records {
            if let incoming = record.action.organization { try merged.merge(incoming) }
        }
        var names: [String: Set<String>] = [:]
        var objects: [String: Set<String>] = [:]
        for record in records {
            for album in record.action.organization?.albums ?? [] {
                let id = merged.canonical(album.id)
                names[id, default: []].insert(album.title)
                objects[id, default: []].insert(record.object)
            }
        }
        return names.filter { $0.value.count > 1 }.map { id, titles in
            Self(id: id, titles: titles.sorted(), objects: objects[id, default: []].sorted())
        }.sorted { $0.id < $1.id }
    }
}

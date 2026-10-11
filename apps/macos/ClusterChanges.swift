import Foundation

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

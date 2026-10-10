import Foundation

struct ReleaseIdentifier: Codable, Equatable, Hashable {
    var source: String
    var value: String
}

struct ImportedAlbumMetadata: Codable, Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var compilationValues: [String]
    var release: ReleaseIdentifier?
    var tagValues: [String: [String]]? = nil

    static func read(_ tags: [String: Any]) -> ImportedAlbumMetadata {
        func values(_ key: String) -> [String] { tags[key] as? [String] ?? [] }
        let releaseValues = values("MUSICBRAINZ_ALBUMID")
        let normalized = Set(releaseValues.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        let release = normalized.count == 1 && releaseValues.allSatisfy({ UUID(uuidString: $0) != nil })
            ? normalized.first.map { ReleaseIdentifier(source: "musicbrainz-release", value: $0) } : nil
        return ImportedAlbumMetadata(title: values("ALBUM").first, artist: values("ARTIST").first,
            albumArtist: values("ALBUMARTIST").first, compilationValues: values("COMPILATION"), release: release,
            tagValues: Dictionary(uniqueKeysWithValues: ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "COMPILATION", "MUSICBRAINZ_ALBUMID"]
                .filter { tags[$0] != nil }.map { ($0, values($0)) }))
    }

    var compilation: Bool? {
        let assertions = compilationValues.compactMap { value -> Bool? in
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: return nil
            }
        }
        guard let first = assertions.first, assertions.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

struct OrganizationAlbum: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var releases: [ReleaseIdentifier] = []
}

struct OrganizationTrack: Codable, Equatable {
    var id: String
    var sha256: String
    var imported: ImportedAlbumMetadata
    var importedAlbumID: String
    var title: String? = nil
    var folderEvidence: String? = nil
}

struct OrganizationChoice: Codable, Equatable, Identifiable {
    var id: String
    var subject: String
    var kind: String
    var value: String?
    var parents: [String]
}

struct AlbumOrganization: Codable, Equatable {
    var albums: [OrganizationAlbum] = []
    var tracks: [OrganizationTrack] = []
    var aliases: [String: String] = [:]
    var choices: [OrganizationChoice] = []
    var preferred: [String: String] = [:]
    var trackAliases: [String: String]? = nil

    func canonicalTrack(_ id: String) -> String {
        var cursor = id
        var seen = Set<String>()
        while let next = trackAliases?[cursor], seen.insert(cursor).inserted { cursor = next }
        return cursor
    }

    var proposals: [[OrganizationAlbum]] {
        Dictionary(grouping: albums.filter { canonical($0.id) == $0.id && $0.releases.isEmpty }, by: \.title)
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
            .values.map { $0.sorted { $0.id < $1.id } }
            .filter { group in
                let records = tracks.filter { group.map(\.id).contains(canonical($0.importedAlbumID)) }
                let folders = records.compactMap(\.folderEvidence)
                return folders.count == records.count && Set(folders.map { URL(fileURLWithPath: "/" + $0).deletingLastPathComponent().path }).count == 1
            }
            .filter { choice(subject: $0.map(\.id).joined(separator: ","), kind: "proposal") == nil }
            .sorted { $0[0].title < $1[0].title }
    }

    mutating func join(_ ids: [String], confirmed: Bool) throws {
        let ids = Set(ids.map(canonical)).sorted()
        guard let survivor = ids.first, ids.count > 1 else { return }
        let members = tracks.filter { ids.contains(albumID(for: $0.id) ?? "") }
        guard members.allSatisfy({ !hasConflict(subject: $0.id, kind: "membership") }),
              ids.allSatisfy({ !hasConflict(subject: $0, kind: "classification") }) else { throw LocalMusicError.invalidData }
        let classifications = ids.compactMap { choice(subject: $0, kind: "classification") }.map(\.value)
        guard Set(classifications).count <= 1 else { throw LocalMusicError.invalidData }
        if !confirmed {
            let explicitMemberships = members.compactMap { choice(subject: $0.id, kind: "membership")?.value }.map(canonical)
            guard Set(explicitMemberships).count <= 1 else { throw LocalMusicError.invalidData }
        }
        if confirmed {
            for member in members { set(subject: member.id, kind: "membership", value: survivor) }
        }
        if let classification = classifications.first { set(subject: survivor, kind: "classification", value: classification) }
        for id in ids.dropFirst() {
            aliases[id] = survivor
            if preferred[key(survivor, "classification")] == nil { preferred[key(survivor, "classification")] = preferred[key(id, "classification")] }
        }
        if let index = albums.firstIndex(where: { $0.id == survivor }) {
            albums[index].releases = Array(Set(albums.filter { ids.contains($0.id) }.flatMap(\.releases)))
                .sorted { ($0.source, $0.value) < ($1.source, $1.value) }
        }
    }

    mutating func reconcileReleases() {
        let releases = Set(albums.flatMap(\.releases))
        for release in releases {
            let ids = Set(albums.filter { $0.releases.contains(release) }.map { canonical($0.id) }).sorted()
            if ids.count > 1 { try? join(ids, confirmed: false) }
        }
    }

    func canonical(_ id: String) -> String {
        var id = id
        var visited = Set<String>()
        while let next = aliases[id], visited.insert(id).inserted { id = next }
        return id
    }

    private func key(_ subject: String, _ kind: String) -> String { kind + ":" + subject }

    func heads(subject: String, kind: String) -> [OrganizationChoice] {
        let subject = kind == "membership" ? canonicalTrack(subject) : kind == "classification" ? canonical(subject) : subject
        let revisions = choices.filter { ($0.kind == "membership" ? canonicalTrack($0.subject) : $0.kind == "classification" ? canonical($0.subject) : $0.subject) == subject && $0.kind == kind }
        let superseded = Set(revisions.flatMap(\.parents))
        return revisions.filter { !superseded.contains($0.id) }.sorted { $0.id < $1.id }
    }

    func choice(subject: String, kind: String) -> OrganizationChoice? {
        let subject = kind == "membership" ? canonicalTrack(subject) : kind == "classification" ? canonical(subject) : subject
        let heads = heads(subject: subject, kind: kind)
        return heads.first { $0.id == preferred[key(subject, kind)] } ?? heads.first
    }

    func hasConflict(subject: String, kind: String) -> Bool {
        Set(heads(subject: subject, kind: kind).map(\.value)).count > 1
    }

    mutating func set(subject: String, kind: String, value: String?) {
        let subject = kind == "membership" ? canonicalTrack(subject) : kind == "classification" ? canonical(subject) : subject
        if kind == "membership", value == nil,
           let record = tracks.first(where: { $0.id == subject }),
           canonical(record.importedAlbumID) != record.importedAlbumID, record.imported.release == nil {
            let id = UUID().uuidString
            albums.append(OrganizationAlbum(id: id, title: record.imported.title ?? ""))
            for index in tracks.indices where tracks[index].importedAlbumID == record.importedAlbumID {
                tracks[index].importedAlbumID = id
            }
        }
        let revision = OrganizationChoice(id: UUID().uuidString, subject: subject, kind: kind,
            value: value, parents: heads(subject: subject, kind: kind).map(\.id))
        choices.append(revision)
        preferred[key(subject, kind)] = revision.id
    }

    func albumID(for track: String) -> String? {
        let id = canonicalTrack(track)
        guard let record = tracks.first(where: { $0.id == id }) else { return nil }
        return canonical(choice(subject: id, kind: "membership")?.value ?? record.importedAlbumID)
    }

    mutating func importEntries(_ entries: [LocalEntry], folders: [String: String] = [:]) {
        var provisional: [String: String] = [:]
        for record in tracks where record.imported.release == nil {
            let credit = record.imported.albumArtist.flatMap { $0.lowercased() == "various artists" ? nil : $0 } ?? record.imported.artist ?? ""
            let title = record.imported.title ?? albums.first { $0.id == record.importedAlbumID }?.title ?? ""
            provisional[[record.folderEvidence ?? "", title, credit].joined(separator: "\u{1f}")] = record.importedAlbumID
        }
        for entry in entries {
            let imported = entry.importedAlbum ?? ImportedAlbumMetadata(title: entry.track.album,
                artist: entry.track.artist, albumArtist: nil, compilationValues: [], release: nil)
            if let index = tracks.firstIndex(where: { $0.id == canonicalTrack(entry.track.id) }) {
                tracks[index].imported = imported
                tracks[index].sha256 = entry.sha256
                tracks[index].title = entry.track.title
                if let release = imported.release {
                    tracks[index].importedAlbumID = releaseAlbum(release, title: imported.title ?? entry.track.album ?? "")
                }
                continue
            }
            let albumID: String
            if let release = imported.release {
                albumID = releaseAlbum(release, title: imported.title ?? entry.track.album ?? "")
            } else {
                let credit = imported.albumArtist.flatMap { $0.lowercased() == "various artists" ? nil : $0 } ?? imported.artist ?? ""
                let group = entry.track.albumId ?? [folders[entry.track.id] ?? "", imported.title ?? entry.track.album ?? "", credit].joined(separator: "\u{1f}")
                if let existing = provisional[group] { albumID = existing }
                else {
                    albumID = UUID().uuidString
                    provisional[group] = albumID
                    albums.append(OrganizationAlbum(id: albumID, title: imported.title ?? entry.track.album ?? ""))
                    if let former = entry.track.albumId, former != albumID { aliases[former] = albumID }
                }
            }
            tracks.append(OrganizationTrack(id: entry.track.id, sha256: entry.sha256,
                imported: imported, importedAlbumID: albumID, title: entry.track.title,
                folderEvidence: folders[entry.track.id]))
        }
        for index in albums.indices {
            let titles = tracks.filter { $0.importedAlbumID == albums[index].id }.compactMap(\.imported.title)
            if let title = titles.first, !title.isEmpty, titles.allSatisfy({ $0 == title }) { albums[index].title = title }
        }
    }

    private mutating func releaseAlbum(_ release: ReleaseIdentifier, title: String) -> String {
        if let album = albums.first(where: { $0.releases.contains(release) }) { return canonical(album.id) }
        let album = OrganizationAlbum(id: UUID().uuidString, title: title, releases: [release])
        albums.append(album)
        return album.id
    }

    mutating func merge(_ incoming: AlbumOrganization) throws {
        try incoming.validate()
        for album in incoming.albums {
            if let index = albums.firstIndex(where: { $0.id == album.id }) {
                albums[index].releases = Array(Set(albums[index].releases + album.releases)).sorted { ($0.source, $0.value) < ($1.source, $1.value) }
            } else { albums.append(album) }
        }
        for record in incoming.tracks {
            if let index = tracks.firstIndex(where: { $0.id == record.id }) {
                tracks[index].imported = record.imported
                tracks[index].importedAlbumID = record.importedAlbumID
                tracks[index].sha256 = record.sha256
                tracks[index].title = record.title
                tracks[index].folderEvidence = record.folderEvidence
            }
            else {
                let matches = tracks.filter { $0.sha256 == record.sha256 && canonicalTrack($0.id) == $0.id }
                if matches.count == 1, incoming.tracks.filter({ $0.sha256 == record.sha256 }).count == 1 {
                    if trackAliases == nil { trackAliases = [:] }
                    trackAliases?[record.id] = matches[0].id
                }
                tracks.append(record)
            }
        }
        for revision in incoming.choices {
            if let existing = choices.first(where: { $0.id == revision.id }) {
                guard existing == revision else { throw LocalMusicError.invalidData }
            } else { choices.append(revision) }
        }
        for (former, survivor) in incoming.aliases {
            if let existing = aliases[former], canonical(existing) != canonical(survivor) { continue }
            let members = tracks.filter { albumID(for: $0.id) == canonical(former) || albumID(for: $0.id) == canonical(survivor) }
            let classifications = [former, survivor].compactMap { choice(subject: $0, kind: "classification") }.map(\.value)
            if members.contains(where: { hasConflict(subject: $0.id, kind: "membership") }) || Set(classifications).count > 1 { continue }
            if canonical(survivor) == former { continue }
            aliases[former] = survivor
        }
        for (former, survivor) in incoming.trackAliases ?? [:] {
            if let existing = trackAliases?[former], canonicalTrack(existing) != canonicalTrack(incoming.canonicalTrack(survivor)) { throw LocalMusicError.invalidData }
            if trackAliases == nil { trackAliases = [:] }
            trackAliases?[former] = survivor
        }
        for revision in incoming.choices {
            let selectionKey = key(revision.subject, revision.kind)
            let active = heads(subject: revision.subject, kind: revision.kind)
            if !active.contains(where: { $0.id == preferred[selectionKey] }) {
                preferred[selectionKey] = active.first?.id
            }
        }
        try validate()
        reconcileReleases()
    }

    func validate() throws {
        guard albums.count <= 100000, tracks.count <= 100000, choices.count <= 200000,
              Set(albums.map(\.id)).count == albums.count, Set(tracks.map(\.id)).count == tracks.count,
              Set(choices.map(\.id)).count == choices.count else { throw LocalMusicError.invalidData }
        let albumIDs = Set(albums.map(\.id))
        let trackIDs = Set(tracks.map(\.id))
        for (former, _) in trackAliases ?? [:] {
            var cursor = former
            var seen = Set<String>()
            while let next = trackAliases?[cursor] {
                guard seen.insert(cursor).inserted else { throw LocalMusicError.invalidData }
                cursor = next
            }
            guard trackIDs.contains(cursor) else { throw LocalMusicError.invalidData }
        }
        let byID = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
        for (former, _) in aliases {
            var cursor = former
            var visited = Set<String>()
            while let next = aliases[cursor] {
                guard visited.insert(cursor).inserted else { throw LocalMusicError.invalidData }
                cursor = next
            }
            guard albumIDs.contains(cursor) else { throw LocalMusicError.invalidData }
        }
        guard tracks.allSatisfy({ albumIDs.contains(canonical($0.importedAlbumID)) }) else { throw LocalMusicError.invalidData }
        var remaining: [String: Int] = [:]
        var children: [String: [String]] = [:]
        for revision in choices {
            guard revision.id.utf8.count <= 128, revision.parents.count <= 10000,
                  revision.kind == "membership" || revision.kind == "classification" || revision.kind == "proposal" else { throw LocalMusicError.invalidData }
            if revision.kind == "membership" {
                guard trackIDs.contains(canonicalTrack(revision.subject)), revision.value.map({ albumIDs.contains(canonical($0)) }) ?? true else { throw LocalMusicError.invalidData }
            } else if revision.kind == "classification" {
                guard albumIDs.contains(canonical(revision.subject)), revision.value == nil || revision.value == "true" || revision.value == "false" else { throw LocalMusicError.invalidData }
            }
            guard Set(revision.parents).count == revision.parents.count else { throw LocalMusicError.invalidData }
            remaining[revision.id] = revision.parents.count
            for parent in revision.parents {
                guard let ancestor = byID[parent], ancestor.kind == revision.kind,
                      (revision.kind == "membership" ? canonicalTrack(ancestor.subject) == canonicalTrack(revision.subject) : revision.kind == "classification" ? canonical(ancestor.subject) == canonical(revision.subject) : ancestor.subject == revision.subject) else { throw LocalMusicError.invalidData }
                children[parent, default: []].append(revision.id)
            }
        }
        var ready = choices.filter { $0.parents.isEmpty }.map(\.id)
        var index = 0
        while index < ready.count {
            let id = ready[index]
            index += 1
            for child in children[id] ?? [] {
                remaining[child]! -= 1
                if remaining[child] == 0 { ready.append(child) }
            }
        }
        guard ready.count == choices.count else { throw LocalMusicError.invalidData }

    }

    func artistCredit(for members: [Track]) -> String {
        let records = members.compactMap { member in tracks.first { $0.id == canonicalTrack(member.id) } }
        let albumArtists = records.compactMap(\.imported.albumArtist)
        if albumArtists.count == members.count, let first = albumArtists.first,
           !first.isEmpty, first.lowercased() != "various artists", albumArtists.allSatisfy({ $0 == first }) { return first }
        var seen = Set<String>()
        let credit = members.compactMap(\.artist).filter { seen.insert($0).inserted }.joined(separator: "、")
        return credit.isEmpty ? "アーティスト不明" : credit
    }

    func classificationEvidence(_ id: String) -> String {
        let assertions = tracks.filter { canonicalTrack($0.id) == $0.id && albumID(for: $0.id) == canonical(id) }.flatMap { record -> [Bool?] in
            if record.imported.compilationValues.isEmpty { return [nil] }
            return record.imported.compilationValues.map { value in
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true": return true
                case "0", "false": return false
                default: return nil
                }
            }
        }
        let positive = assertions.contains(true)
        let negative = assertions.contains(false)
        let missing = assertions.contains(nil)
        if positive && negative { return "元タグにコンピレーションと通常アルバムの指定が混在しています。" }
        if positive { return missing ? "コンピレーションの指定と未指定の曲があります。" : "元タグはコンピレーションです。" }
        if negative { return missing ? "通常アルバムの指定と未指定の曲があります。" : "元タグは通常アルバムです。" }
        return "元タグに分類の指定がありません。"
    }
}

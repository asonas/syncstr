import Foundation

struct AlbumImportContext: Codable, Equatable, Hashable {
    var sourceID: String
    var folder: String

    var isValid: Bool {
        !sourceID.isEmpty && sourceID.utf8.count <= 1024 && folder.utf8.count <= 4096
            && !folder.hasPrefix("/") && !folder.contains("\0")
            && !folder.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
    }

    var parent: String { folder.split(separator: "/").dropLast().joined(separator: "/") }
}

extension AlbumOrganization {
    /// Rebuild derived links from the complete retained catalog, including unavailable tracks.
    /// Original memberships, explicit aliases and causal listener choices are never rewritten.
    mutating func repairMembership(established: Set<String>? = nil) {
        let previous = automaticAliases ?? [:]
        let established = established ?? Set(albums.map { canonical($0.id) })
        automaticAliases = nil
        let records = tracks.filter { canonicalTrack($0.id) == $0.id }

        func positiveCompilation(_ members: [OrganizationTrack]) -> Bool {
            let values = members.flatMap(\.imported.compilationValues)
            return !values.isEmpty && values.allSatisfy {
                ["1", "true"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }

        // A release identifier is stronger than directory evidence, but never stronger than a choice.
        let releases = Dictionary(grouping: records.filter { $0.imported.release != nil }, by: { $0.imported.release! })
        for release in releases.keys.sorted(by: { ($0.source, $0.value) < ($1.source, $1.value) }) {
            inferMembership(releases[release]!, records: records, established: established, previous: previous)
        }

        let scoped = records.filter { $0.importContext != nil && !($0.imported.title ?? "").isEmpty }
        let directories = Dictionary(grouping: scoped) { [$0.importContext!.sourceID, $0.importContext!.folder, $0.imported.title! ] }
        for key in directories.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let members = directories[key]!
            if positiveCompilation(members) {
                inferMembership(members, records: records, established: established, previous: previous)
            }
        }

        let parents = Dictionary(grouping: scoped.filter { !$0.importContext!.folder.isEmpty }) {
            [$0.importContext!.sourceID, $0.importContext!.parent, $0.imported.title!]
        }
        for key in parents.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let members = parents[key]!
            let folders = Dictionary(grouping: members, by: { $0.importContext!.folder })
            guard folders.count > 1 else { continue }
            var discs = Set<Int>()
            let numbered = folders.values.allSatisfy { tracks in
                guard let number = tracks.first?.discNumber, number > 0,
                      tracks.allSatisfy({ $0.discNumber == number }) else { return false }
                return discs.insert(number).inserted
            }
            let credits = members.compactMap { $0.imported.albumArtist }
            let sharedCredit = credits.count == members.count && Set(credits).count == 1
                && credits.first.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.lowercased() != "various artists" } == true
            if numbered && (sharedCredit || positiveCompilation(members)) {
                inferMembership(members, records: records, established: established, previous: previous)
            }
        }
    }

    private mutating func inferMembership(_ members: [OrganizationTrack], records: [OrganizationTrack],
                                         established: Set<String>, previous: [String: String]) {
        let ids = Set(members.map { canonical($0.importedAlbumID) })
        guard ids.count > 1 else { return }
        // Never pull the rest of a provisional album across an unproven boundary.
        let memberIDs = Set(members.map(\.id))
        guard records.allSatisfy({ !ids.contains(canonical($0.importedAlbumID)) || memberIDs.contains($0.id) }),
              Set(members.compactMap(\.imported.release)).count <= 1 else { return }
        let rawReleaseValues = members.flatMap { $0.imported.tagValues?["MUSICBRAINZ_ALBUMID"] ?? [] }
        guard rawReleaseValues.allSatisfy({ UUID(uuidString: $0) != nil }),
              Set(rawReleaseValues.map { $0.lowercased() }).count <= 1 else { return }
        guard members.allSatisfy({
            !hasConflict(subject: $0.id, kind: "membership") && choice(subject: $0.id, kind: "membership")?.value == nil
        }) else { return }
        let classifications = ids.flatMap { heads(subject: $0, kind: "classification") }.map(\.value)
        guard Set(classifications).count <= 1 else { return }
        let rejected = choices.filter { $0.kind == "proposal" && $0.value != nil && heads(subject: $0.subject, kind: "proposal").contains($0) }
        guard !rejected.contains(where: { revision in
            Set(revision.subject.split(separator: ",").map { canonical(String($0)) }).intersection(ids).count > 1
        }) else { return }
        let formerSurvivors = Set(previous.values).intersection(ids)
        let survivor = (formerSurvivors.isEmpty ? established.intersection(ids) : formerSurvivors).sorted().first ?? ids.sorted()[0]
        if automaticAliases == nil { automaticAliases = [:] }
        for id in ids where id != survivor { automaticAliases?[id] = survivor }
    }
}

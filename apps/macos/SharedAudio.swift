import Foundation

// The original snapshot is stored separately, including metadata unknown to this client.
struct SharedAudioSnapshot: Decodable {
    struct Catalog: Decodable {
        struct LogicalTrack: Decodable {
            struct Metadata: Decodable {
                var title: String?
                var artist: String?
                var album: String?
                var suffix: String?
                var duration: Double?
                var track: Int?
                var discNumber: Int?
                var legacyEntry: Track?
                var organization: OrganizationTrack?
            }
            let id: String
            let metadata: Metadata
            let album_id: String?
            let added_at: Int64?
            let retired: Bool
            let audio: [String]
            let preferred: String?
        }
        struct Object: Decodable {
            let sha256: String
            let bytes: UInt64?
            let locators: [String]
        }
        let version: Int
        let cluster: String
        let library: String
        let baseline: String
        let tracks: [String: LogicalTrack]
        let addresses: [String: String]
        let objects: [String: Object]
        let pins: [String: Set<String>]
        let conflicts: Set<String>
        let incomplete: [String]

        func entry(_ id: String, hash: String? = nil) throws -> LocalEntry {
            let canonical = addresses[id] ?? id
            guard let logical = tracks[canonical], logical.id == canonical else { throw LocalMusicError.invalidData }
            let metadata = logical.metadata
            let old = metadata.legacyEntry
            let hash = hash ?? logical.preferred
            if let hash, !pins[canonical, default: []].contains(hash) { throw LocalMusicError.invalidData }
            let object = hash.flatMap { objects[$0] }
            let blocked = logical.retired || conflicts.contains("track:" + canonical) || !incomplete.isEmpty
            var track = Track(id: id, title: metadata.title ?? old?.title ?? metadata.organization?.title ?? "",
                artist: metadata.artist ?? old?.artist ?? metadata.organization?.imported.artist,
                album: metadata.album ?? old?.album ?? metadata.organization?.imported.title,
                albumId: logical.album_id, duration: metadata.duration ?? old?.duration,
                track: metadata.track ?? old?.track, discNumber: metadata.discNumber ?? old?.discNumber,
                suffix: metadata.suffix ?? old?.suffix, size: object?.bytes, addedAt: logical.added_at)
            track.audioHash = hash
            track.unavailable = blocked || object?.bytes == nil || hash == nil
            return LocalEntry(track: track, sha256: hash ?? "", artwork: nil)
        }

        func localCatalog(name: String) throws -> LocalCatalog {
            let entries = try tracks.keys.sorted().map { try entry($0) }
            return LocalCatalog(id: library, name: name, entries: entries, logicalAudio: true)
        }
    }
    let catalog: Catalog
    let playlists: [PlaylistSnapshot]
    let playlist_history: [PlaylistRecord]
}

#if DEBUG
@MainActor
enum SharedAudioUIFixture {
    static func library() throws -> Library? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--v5-fixture"), arguments.indices.contains(index + 1) else { return nil }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let store = LocalMusicStore(root: root.appendingPathComponent("apple-ui"))
        let database = try store.database()
        struct Enrollment: Decodable { let grant: String; let proof: ClusterMembership; let member: String }
        let enrollment = try JSONDecoder().decode(Enrollment.self, from: Data(contentsOf: root.appendingPathComponent("reader-enrollment.json")))
        let grant = try enrollment.proof.verify(enrollment.grant)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: enrollment.proof, ownID: enrollment.member, name: "V5 Fixture")
        let firstLaunch = try database.sharedAudioSnapshot() == nil
        if firstLaunch {
            try database.receiveSharedAudio(Data(contentsOf: root.appendingPathComponent("snapshot.json")), peer: grant.issuer)
            for entry in try database.clusterCatalog().entries {
                if !store.hasFile(entry) { try FileManager.default.copyItem(at: root.appendingPathComponent("tone.wav"), to: store.fileURL(entry)) }
                try database.saveAudioPin(entry)
            }
        }
        let service = "syncstr-v5-ui-" + LocalMusicStore.digest(Data(root.path.utf8))
        let library = Library(localStore: store, pairingSecrets: CredentialStore(service: service + ".pair"),
            peerSecrets: CredentialStore(service: service + ".identity"), peerPairing: CredentialStore(service: service + ".peer"))
        try library.openLocal(database.clusterCatalog())
        return library
    }
}
#endif

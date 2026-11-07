import Foundation
import AVFoundation
import AudioToolbox

enum SharedAudioPlayback {
    static func player(_ url: URL) -> AVPlayer {
        guard url.isFileURL, url.pathExtension == "audio" else { return AVPlayer(url: url) }
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return AVPlayer(url: url) }
        defer { AudioFileClose(file) }
        var format: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &format) == noErr else { return AVPlayer(url: url) }
        var types: Unmanaged<CFArray>?
        var typesSize = UInt32(MemoryLayout.size(ofValue: types))
        guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_MIMETypesForType, size, &format, &typesSize, &types) == noErr,
              let mime = (types?.takeRetainedValue() as? [String])?.first else { return AVPlayer(url: url) }
        // Hash paths deliberately omit the encoding; identify it from verified local bytes.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}

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
        let legacy_organization: AlbumOrganization?
        let heads: [String: [String]]?
        let candidates: [String: [String: LogicalTrack]]?

        func entry(_ id: String, hash: String? = nil) throws -> LocalEntry {
            try entry(id, hash: hash, organization: organization())
        }

        private func entry(_ id: String, hash: String?, organization: AlbumOrganization) throws -> LocalEntry {
            let canonical = addresses[id] ?? id
            guard let logical = tracks[canonical], logical.id == canonical else { throw LocalMusicError.invalidData }
            let metadata = logical.metadata
            let old = metadata.legacyEntry
            let hash = hash ?? logical.preferred
            if let hash, !pins[canonical, default: []].contains(hash) { throw LocalMusicError.invalidData }
            let object = hash.flatMap { objects[$0] }
            let blocked = logical.retired || conflicts.contains("track:" + canonical)
            let albumID = organization.albumID(for: canonical)
            let album = organization.albums.first { $0.id == albumID }
            let record = organization.tracks.first { $0.id == canonical }
            let artwork = albumID.flatMap { organization.coverAsset(for: $0) }
                .flatMap { organization.artwork?.assets[$0] }
            var track = Track(id: id, title: metadata.title ?? old?.title ?? record?.title ?? "",
                artist: metadata.artist ?? old?.artist ?? record?.imported.artist,
                album: metadata.album ?? album?.title ?? old?.album ?? metadata.organization?.imported.title,
                albumId: albumID, coverArt: artwork.map(LocalMusicStore.digest), duration: metadata.duration ?? old?.duration,
                track: metadata.track ?? old?.track ?? record?.trackNumber,
                discNumber: metadata.discNumber ?? old?.discNumber ?? record?.discNumber,
                suffix: metadata.suffix ?? old?.suffix, size: object?.bytes, addedAt: logical.added_at)
            track.audioHash = hash
            track.unavailable = blocked || object?.bytes == nil || hash == nil
            return LocalEntry(track: track, sha256: hash ?? "", artwork: artwork, importedAlbum: record?.imported)
        }

        func localCatalog(name: String) throws -> LocalCatalog {
            let organization = try organization()
            let entries = try tracks.keys.sorted().map { try entry($0, hash: nil, organization: organization) }
            return LocalCatalog(id: library, name: name, entries: entries, organization: organization, logicalAudio: true)
        }

        private func organization() throws -> AlbumOrganization {
            var result = legacy_organization ?? AlbumOrganization()
            for id in tracks.keys.sorted() {
                guard let logical = tracks[id], logical.id == id else { throw LocalMusicError.invalidData }
                let metadata = logical.metadata
                let existing = result.tracks.first { $0.id == id }
                let albumID = logical.album_id ?? metadata.organization?.importedAlbumID
                    ?? existing?.importedAlbumID ?? "v5-unassigned:" + id
                var record = metadata.organization ?? existing ?? OrganizationTrack(id: id,
                    sha256: logical.preferred ?? "", imported: ImportedAlbumMetadata(title: metadata.album ?? metadata.legacyEntry?.album,
                        artist: metadata.artist ?? metadata.legacyEntry?.artist, compilationValues: []), importedAlbumID: albumID)
                // Project logical identity directly; AlbumOrganization.merge would alias by hash.
                record.id = id
                record.sha256 = logical.preferred ?? ""
                record.importedAlbumID = albumID
                if let previous = result.albumID(for: id), previous != result.canonical(albumID) {
                    let replaced = Set(result.choices.filter {
                        $0.kind == "membership" && result.canonicalTrack($0.subject) == id
                    }.map(\.id))
                    result.choices.removeAll { replaced.contains($0.id) }
                    result.preferred.removeValue(forKey: "membership:" + id)
                }
                if let index = result.tracks.firstIndex(where: { $0.id == id }) { result.tracks[index] = record }
                else { result.tracks.append(record) }
                let canonicalAlbum = result.canonical(albumID)
                if !result.albums.contains(where: { $0.id == canonicalAlbum }) {
                    result.albums.append(OrganizationAlbum(id: canonicalAlbum,
                        title: metadata.album ?? metadata.legacyEntry?.album ?? record.imported.title ?? "",
                        releases: record.imported.release.map { [$0] } ?? []))
                }
            }
            result.trackAliases = addresses.filter { $0.key != $0.value }
            if var artwork = result.artwork {
                let missing = Set(artwork.assets.filter { $0.value.isEmpty }.keys)
                if !missing.isEmpty {
                    // Empty asset payloads are references, not downloadable images.
                    // Remove only the affected presentation graph; raw history stays retained.
                    let albums = Set(artwork.candidates.filter { missing.contains($0.asset) }
                        .compactMap { result.albumID(for: $0.track) })
                        .union(result.choices.filter { $0.kind == "artwork" && $0.value.map(missing.contains) == true }
                            .map { result.canonical($0.subject) })
                    let removedChoices = Set(result.choices.filter {
                        $0.kind == "artwork" && albums.contains(result.canonical($0.subject))
                    }.map(\.id))
                    result.choices.removeAll { removedChoices.contains($0.id) }
                    result.preferred = result.preferred.filter { !removedChoices.contains($0.value) }
                    artwork.assets = artwork.assets.filter { !missing.contains($0.key) }
                    let removed = Set(artwork.candidates.filter {
                        result.albumID(for: $0.track).map(albums.contains) == true
                    }.map(\.id))
                    artwork.candidates.removeAll { removed.contains($0.id) }
                    artwork.preferred = artwork.preferred.filter { !missing.contains($0.value) }
                    result.artwork = artwork
                }
            }
            try result.validate()
            return result
        }
    }
    let catalog: Catalog
    let playlists: [PlaylistSnapshot]
    let playlist_history: [PlaylistRecord]
}

#if DEBUG
@MainActor
enum SharedAudioUIFixture {
    static var resolutionEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--v5-fixture-state"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] == "resolution"
        }
        return Bundle.main.object(forInfoDictionaryKey: "SyncstrV5FixtureState") as? String == "resolution"
    }
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("--v5-fixture") || Bundle.main.object(forInfoDictionaryKey: "SyncstrV5FixtureRoot") is String
    }

    static func library() throws -> Library? {
        let arguments = ProcessInfo.processInfo.arguments
        let path: String
        if let index = arguments.firstIndex(of: "--v5-fixture"), arguments.indices.contains(index + 1) {
            path = arguments[index + 1]
        } else if let configured = Bundle.main.object(forInfoDictionaryKey: "SyncstrV5FixtureRoot") as? String {
            path = configured
        } else { return nil }
        let root: URL
        if path.hasPrefix("/") { root = URL(fileURLWithPath: path, isDirectory: true) }
        else {
            root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false).appendingPathComponent(path, isDirectory: true)
        }
        let stateIndex = arguments.firstIndex(of: "--v5-fixture-state")
        let state = stateIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? (Bundle.main.object(forInfoDictionaryKey: "SyncstrV5FixtureState") as? String) ?? "normal"
        guard ["normal", "conflict", "incomplete", "metadata", "resolution", "resolution-unsupported"].contains(state) else { throw LocalMusicError.invalidData }
        let store = LocalMusicStore(root: root.appendingPathComponent("apple-ui-" + state))
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
            if state == "metadata" {
                guard let entry = try database.clusterCatalog().entries.first(where: { $0.track.title == "TRACK-A" }) else {
                    throw LocalMusicError.invalidData
                }
                let draft = try database.trackMetadataDraft(entry.track.id)
                let edit = try database.enqueueTrackMetadata(draft, title: "Edited fixture title", artist: "Edited artist")
                _ = try database.beginMetadataMutation(edit.id, host: grant.issuer)
                try database.finishMetadataMutation(edit.id, reply: .rejected(request: edit.id, reason: .revoked))
            }
        }
        if state == "conflict" || state == "incomplete" || state.hasPrefix("resolution") {
            let data = try Data(contentsOf: root.appendingPathComponent("snapshot.json"))
            var snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var catalog = snapshot["catalog"] as! [String: Any]
            if state == "incomplete" { catalog["incomplete"] = [String(repeating: "f", count: 64)] }
            else {
                let tracks = catalog["tracks"] as! [String: [String: Any]]
                guard let id = tracks.first(where: { ($0.value["metadata"] as? [String: Any])?["title"] as? String == "TRACK-A" })?.key else { throw LocalMusicError.invalidData }
                catalog["conflicts"] = ["track:" + id]
                if state.hasPrefix("resolution") {
                    let live = String(repeating: "a", count: 64)
                    let deleted = String(repeating: "b", count: 64)
                    var retired = tracks[id]!
                    retired["retired"] = true
                    catalog["heads"] = ["track:" + id: [live, deleted]]
                    catalog["candidates"] = [id: [live: tracks[id]!, deleted: retired]]
                }
            }
            snapshot["catalog"] = catalog
            try database.receiveSharedAudio(JSONSerialization.data(withJSONObject: snapshot), peer: grant.issuer)
        }
        let service = "syncstr-v5-ui-" + LocalMusicStore.digest(Data(root.path.utf8))
        let library = Library(localStore: store, pairingSecrets: CredentialStore(service: service + ".pair"),
            peerSecrets: CredentialStore(service: service + ".identity"), peerPairing: CredentialStore(service: service + ".peer"))
        try library.openLocal(database.clusterCatalog())
        return library
    }
}
#endif

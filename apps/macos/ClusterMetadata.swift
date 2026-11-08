import Foundation
import CryptoKit
import Darwin

struct ClusterAudioAddition: Codable {
    static let maximumBytes: UInt64 = 20 * 1024 * 1024 * 1024
    let upload: ClusterMutationRequest
    var receipt: ClusterMutationReply?

    static func supported(by operations: Set<ClusterOperation>) -> Bool {
        operations.contains(.putObject) && operations.contains(.registerTrack)
    }

    static func stagedFile(root: URL, request: String) throws -> URL {
        guard UUID(uuidString: request) != nil else { throw LocalMusicError.invalidData }
        return root.appendingPathComponent(".addition-" + request + ".audio")
    }

    static func validateSize(_ bytes: UInt64) throws {
        guard bytes > 0, bytes <= maximumBytes else { throw LocalMusicError.invalidData }
    }

    @TransportActor
    static func prepare(_ original: URL, store: LocalMusicStore, sourceLibrary: String) async throws -> ClusterMetadataEdit {
        let scoped = original.startAccessingSecurityScopedResource()
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
        let size = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw LocalMusicError.invalidData }
        try validateSize(UInt64(size))
        let id = UUID().uuidString.lowercased()
        let temporary = store.root.appendingPathComponent(".import-" + id).appendingPathExtension(original.pathExtension)
        let staged = try stagedFile(root: store.root, request: id)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: original, to: temporary)
        let entry = try await UploadedMusic.entry(file: temporary, original: original)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: staged)
        do {
            let file = try FileHandle(forWritingTo: staged)
            defer { try? file.close() }
            try file.synchronize()
            let directory = Darwin.open(store.root.path, O_RDONLY)
            guard directory >= 0 else { throw LocalMusicError.invalidData }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else { throw LocalMusicError.invalidData }
            return try store.database().enqueueAudioAddition(entry, requestID: id, sourceLibrary: sourceLibrary)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func stream(file: URL, hash: String, bytes: UInt64,
                       write: (Data) async throws -> Void, finish: () async throws -> Void) async throws {
        try validateSize(bytes)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var digest = SHA256()
        var sent: UInt64 = 0
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard UInt64(chunk.count) <= bytes - sent else { throw LocalMusicError.changedFile }
            digest.update(data: chunk)
            try await write(chunk)
            sent += UInt64(chunk.count)
        }
        guard sent == bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else {
            throw LocalMusicError.changedFile
        }
        try await finish()
    }
}

extension CatalogDatabase {
    func enqueueAudioAddition(_ entry: LocalEntry, requestID: String, sourceLibrary: String) throws -> ClusterMetadataEdit {
        guard let shared = try sharedAudioSnapshot(), let bytes = entry.track.size,
              ClusterIdentity.isLowercaseHex256(entry.sha256), UUID(uuidString: requestID) != nil,
              !sourceLibrary.isEmpty else {
            throw LocalMusicError.invalidData
        }
        try ClusterAudioAddition.validateSize(bytes)
        let upload = try ClusterMutationRequest(cluster: shared.catalog.cluster, baseline: shared.catalog.baseline,
            operation: .putObject, expected: [:],
            payload: JSONValue.object(["hash": .string(entry.sha256), "bytes": .unsignedInteger(bytes)]), confirmed: [String]())
        struct Source: Encodable { let library: String; let track: String }
        struct Metadata: Encodable {
            let title: String; let artist: String?; let album: String?; let suffix: String?
            let duration: Double?; let track: Int?; let discNumber: Int?
        }
        struct Payload: Encodable { let source: Source; let metadata: Metadata; let hash: String }
        let track = entry.track
        let registration = try ClusterMutationRequest(request: requestID, cluster: shared.catalog.cluster,
            baseline: shared.catalog.baseline, operation: .registerTrack, expected: [:],
            payload: Payload(source: Source(library: sourceLibrary, track: UUID().uuidString.lowercased()),
                metadata: Metadata(title: track.title, artist: track.artist, album: track.album, suffix: track.suffix,
                    duration: track.duration, track: track.track, discNumber: track.discNumber), hash: entry.sha256),
            confirmed: [["audio": entry.sha256]])
        let edit = ClusterMetadataEdit(id: requestID, entry: entry, organization: AlbumOrganization(), parents: [],
            mutation: registration, mutationState: .queued, addition: ClusterAudioAddition(upload: upload))
        guard try !clusterMetadataEdits().contains(where: { $0.id == requestID }) else { throw LocalMusicError.invalidData }
        try saveMetadataMutation(edit, replacing: nil)
        return edit
    }

    func finishAudioUpload(_ id: String, reply: ClusterMutationReply, peer: String) throws {
        try transaction {
            guard var edit = try clusterMetadataEdits().first(where: { $0.id == id }),
                  var addition = edit.addition, addition.receipt == nil,
                  edit.mutationState == .sending, edit.mutationHost == peer else { throw LocalMusicError.invalidData }
            _ = try reply.validated(for: addition.upload.request)
            switch reply {
            case .objectStored(_, let hash, let bytes, let host):
                guard hash == edit.entry.sha256, bytes == edit.entry.track.size, host == peer else {
                    throw LocalMusicError.invalidData
                }
                addition.receipt = reply
                edit.addition = addition
                edit.mutationState = .queued
                edit.mutationReply = nil
            case .accepted: throw LocalMusicError.invalidData
            case .needsReview: edit.mutationState = .needsReview; edit.mutationReply = reply
            case .rejected, .unsupported: edit.mutationState = .rejected; edit.mutationReply = reply
            case .deferred: edit.mutationState = .queued; edit.mutationReply = reply
            }
            edit.mutationError = nil
            try saveClusterMetadataEdit(edit)
        }
    }
}

@MainActor
enum ClusterAudioDelivery {
    static func send(_ original: ClusterMetadataEdit, host: String, database: CatalogDatabase,
                     stateChanged: () async -> Void = {},
                     upload: (ClusterMutationRequest) async throws -> ClusterMutationReply,
                     register: (ClusterMutationRequest) async throws -> ClusterMutationReply) async throws {
        do {
            guard let addition = original.addition else { throw LocalMusicError.invalidData }
            if addition.receipt == nil {
                _ = try await CatalogStorage.shared.perform { try database.beginMetadataMutation(original.id, host: host) }
                await stateChanged()
                let reply = try await upload(addition.upload)
                try await Task { @TransportActor in try database.finishAudioUpload(original.id, reply: reply, peer: host) }.value
                await stateChanged()
            }
            guard let ready = try await CatalogStorage.shared.perform({ try database.clusterMetadataEdits().first { $0.id == original.id } }),
                  ready.addition?.receipt != nil, ready.canRetryMutation else { return }
            try await ClusterMetadataDelivery.send(ready, host: host, database: database, stateChanged: stateChanged, exchange: register)
        } catch {
            let reason = error.localizedDescription
            try? await Task { @TransportActor in try database.metadataMutationInterrupted(original.id, reason: reason) }.value
            await stateChanged()
            throw error
        }
    }
}

struct TrackMetadataDraft: Identifiable {
    let id = UUID()
    let entry: LocalEntry
    let cluster: String
    let baseline: String
    let expected: [String: [String]]
    let title: String
    let artist: String
    let replacing: String?
}

extension ClusterMetadataEdit {
    var albumVisibility: (album: String, hidden: Bool)? {
        guard let mutation, mutation.operation == .setAlbumVisibility,
              case .object(let payload) = mutation.payload,
              case .string(let album)? = payload["album"],
              case .bool(let hidden)? = payload["hidden"] else { return nil }
        return (album, hidden)
    }

    var metadataValues: [String: String] {
        guard let mutation, case .object(let payload) = mutation.payload,
              case .object(let metadata)? = payload["metadata"] else { return [:] }
        return metadata.compactMapValues {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    var mutationLabel: String {
        if addition != nil {
            if mutationState == .queued { return addition?.receipt == nil ? "音源の送信待ち" : "曲の登録待ち" }
            if mutationState == .sending { return addition?.receipt == nil ? "音源を送信中" : "曲を登録中" }
        }
        return switch mutationState {
        case .queued: "送信待ち"
        case .sending: "送信中"
        case .accepted: "反映済み"
        case .needsReview: "確認が必要"
        case .rejected: "送信できません"
        case .outcomeUnknown: "結果を確認できません"
        case nil: "送信待ち"
        }
    }

    var mutationDetail: String? {
        if mutationState == .outcomeUnknown {
            return "送信した保存先から結果を確認できません。別の保存先には再送せず、変更内容を保持しています。"
        }
        switch mutationReply {
        case .needsReview:
            return "先に別の変更がありました。入力した内容は保持しています。ライブラリを更新して確認してください。"
        case .rejected(_, let reason):
            switch reason {
            case .revoked: return "この端末の登録が無効になりました。変更内容は保持しています。"
            case .unauthorized: return "この変更は許可されていません。変更内容は保持しています。"
            case .baselineMismatch, .clusterMismatch: return "接続先のライブラリが変わりました。変更内容は保持しています。"
            case .invalid: return "変更内容を送信できませんでした。入力した内容は保持しています。"
            }
        case .unsupported:
            if addition != nil { return "接続先は音源の追加に対応していません。音源はこの端末に保持しています。" }
            if albumVisibility != nil {
                return "接続先はアルバムの表示変更に対応していません。変更内容は保持しています。"
            }
            return "接続先は曲の情報の編集に対応していません。変更内容は保持しています。"
        case .deferred:
            return "保存先で受け付ける準備ができていません。同じ保存先への接続後に再送します。"
        default:
            return mutationError
        }
    }
}

extension AlbumOrganization {
    func albumVisibilityNotice(_ album: String, operations: Set<ClusterOperation>) -> String? {
        let canonical = canonical(album)
        if sharedVisibilityConflicts?.contains("album-visibility:" + canonical) == true {
            return "アルバムの表示設定が競合しています（album-visibility:\(canonical)）。保存先で解消するまで変更できません。"
        }
        guard sharedAlbumVisibility != nil, operations.contains(.setAlbumVisibility) else {
            return "アルバムの表示変更には、対応する保存先への接続が必要です。ライブラリを更新して対応状況を確認してください。"
        }
        return nil
    }
}

extension CatalogDatabase {
    func albumVisibilityNotice(_ album: String, operations: Set<ClusterOperation>) throws -> String? {
        guard let shared = try sharedAudioSnapshot() else { return nil }
        return try shared.catalog.localCatalog(name: "Library").organization?.albumVisibilityNotice(album, operations: operations)
    }

    func enqueueAlbumsVisibility(_ ids: Set<String>, hidden: Bool, operations: Set<ClusterOperation>) -> (saved: Int, failures: [String]) {
        var saved = 0
        var failures: [String] = []
        for id in ids.sorted() {
            do {
                if let notice = try albumVisibilityNotice(id, operations: operations) {
                    failures.append(notice)
                    continue
                }
                _ = try enqueueAlbumVisibility(id, hidden: hidden)
                saved += 1
            } catch { failures.append(error.localizedDescription) }
        }
        return (saved, failures)
    }

    func enqueueAlbumVisibility(_ album: String, hidden: Bool) throws -> ClusterMetadataEdit {
        guard let shared = try sharedAudioSnapshot(), let registration = try clusterRegistration() else {
            throw LocalMusicError.invalidData
        }
        _ = try registration.membership.verify(registration.localGrant)
        let catalog = try shared.catalog.localCatalog(name: registration.name)
        guard let organization = catalog.organization else { throw LocalMusicError.invalidData }
        let canonical = organization.canonical(album)
        guard organization.albums.contains(where: { organization.canonical($0.id) == canonical }),
              !shared.catalog.conflicts.contains("album-visibility:" + canonical),
              let entry = catalog.entries.first(where: { organization.albumID(for: $0.track.id) == canonical }) else {
            throw LocalMusicError.invalidData
        }
        // Do not create overlapping requests with stale heads for one album.
        guard try !clusterMetadataEdits().contains(where: {
            guard $0.albumVisibility?.album == canonical else { return false }
            if $0.canRetryMutation || $0.mutationState == .sending { return true }
            if case .accepted? = $0.mutationReply {
                let subject = "album-visibility:" + canonical
                return (shared.catalog.heads?[subject] ?? []) == ($0.mutation?.expected[subject] ?? [])
                    && shared.catalog.album_visibility?[canonical]?.hidden != $0.albumVisibility?.hidden
            }
            return false
        }) else { throw LocalMusicError.invalidData }
        struct Payload: Encodable { let album: String; let hidden: Bool }
        let subject = "album-visibility:" + canonical
        let request = try ClusterMutationRequest(cluster: shared.catalog.cluster, baseline: shared.catalog.baseline,
            operation: .setAlbumVisibility, expected: [subject: shared.catalog.heads?[subject] ?? []],
            payload: Payload(album: canonical, hidden: hidden), confirmed: [String]())
        let edit = ClusterMetadataEdit(id: request.request, entry: entry, organization: AlbumOrganization(),
            parents: shared.catalog.heads?[subject] ?? [], mutation: request, mutationState: .queued)
        try saveMetadataMutation(edit, replacing: nil)
        return edit
    }

    func trackMetadataDraft(_ track: String, replacing edit: ClusterMetadataEdit? = nil) throws -> TrackMetadataDraft {
        guard let shared = try sharedAudioSnapshot(),
              let entry = try playbackEntry(track)?.entry else { throw LocalMusicError.invalidData }
        let canonical = shared.catalog.addresses[track] ?? track
        let values = edit?.metadataValues ?? [:]
        return TrackMetadataDraft(entry: entry, cluster: shared.catalog.cluster, baseline: shared.catalog.baseline,
            expected: ["track:" + canonical: shared.catalog.heads?["track:" + canonical] ?? []],
            title: values["title"] ?? entry.track.title, artist: values["artist"] ?? entry.track.artist ?? "",
            replacing: edit?.mutation?.request)
    }

    func enqueueTrackMetadata(_ draft: TrackMetadataDraft, title: String, artist: String) throws -> ClusterMetadataEdit {
        guard let shared = try sharedAudioSnapshot(), shared.catalog.cluster == draft.cluster,
              shared.catalog.baseline == draft.baseline, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalMusicError.invalidData
        }
        let canonical = shared.catalog.addresses[draft.entry.track.id] ?? draft.entry.track.id
        guard let logical = shared.catalog.tracks[canonical], !logical.retired else { throw LocalMusicError.invalidData }
        struct Payload: Encodable { let track: String; let metadata: [String: String] }
        let request = try ClusterMutationRequest(cluster: draft.cluster, baseline: draft.baseline, operation: .editTrack,
            expected: draft.expected, payload: Payload(track: canonical, metadata: ["title": title, "artist": artist]),
            confirmed: [String]())
        let edit = ClusterMetadataEdit(id: request.request, entry: draft.entry, organization: AlbumOrganization(),
            parents: draft.expected["track:" + canonical] ?? [], mutation: request, mutationState: .queued)
        try saveMetadataMutation(edit, replacing: draft.replacing)
        return edit
    }
}

@MainActor
enum ClusterMetadataDelivery {
    static func send(_ edit: ClusterMetadataEdit, host: String, database: CatalogDatabase,
                     stateChanged: () async -> Void = {},
                     exchange: (ClusterMutationRequest) async throws -> ClusterMutationReply) async throws {
        guard let request = edit.mutation else { throw LocalMusicError.invalidData }
        do {
            _ = try await CatalogStorage.shared.perform { try database.beginMetadataMutation(request.request, host: host) }
            await stateChanged()
            let reply = try await exchange(request)
            // A UI cancellation must not prevent storing a reply already received.
            try await Task { @TransportActor in try database.finishMetadataMutation(request.request, reply: reply) }.value
        } catch {
            let reason = error.localizedDescription
            // Recovery also runs after cancellation so Sending does not remain stuck.
            try? await Task { @TransportActor in try database.metadataMutationInterrupted(request.request, reason: reason) }.value
            await stateChanged()
            throw error
        }
        await stateChanged()
    }
}

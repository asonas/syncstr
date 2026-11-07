import Foundation

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
    var metadataValues: [String: String] {
        guard let mutation, case .object(let payload) = mutation.payload,
              case .object(let metadata)? = payload["metadata"] else { return [:] }
        return metadata.compactMapValues {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    var mutationLabel: String {
        switch mutationState {
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
            return "接続先は曲の情報の編集に対応していません。変更内容は保持しています。"
        case .deferred:
            return "保存先で受け付ける準備ができていません。同じ保存先への接続後に再送します。"
        default:
            return mutationError
        }
    }
}

extension CatalogDatabase {
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

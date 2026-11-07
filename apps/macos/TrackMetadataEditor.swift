import SwiftUI

enum TrackMetadataPresentation: Identifiable {
    case edit(TrackMetadataDraft)
    case changes

    var id: String {
        switch self {
        case .edit(let draft): draft.id.uuidString
        case .changes: "metadata-changes"
        }
    }
}

extension Library {
    func presentTrackMetadata(_ track: Track, replacing edit: ClusterMetadataEdit? = nil) {
        do {
            let draft = try transfer.trackMetadataDraft(track.id, replacing: edit)
            message = nil
            trackMetadataPresentation = .edit(draft)
        } catch { message = transfer.trackMetadataNotice ?? error.localizedDescription }
    }
}

struct TrackMetadataMenu: View {
    @ObservedObject var library: Library
    let track: Track

    var body: some View {
        if library.localCatalog?.logicalAudio == true || library.transfer.clusterMutationsUnavailable {
            Button("曲の情報を編集…") { library.presentTrackMetadata(track) }
                .disabled(library.transfer.trackMetadataNotice != nil)
            if let notice = library.transfer.trackMetadataNotice { Text(notice) }
            if !library.transfer.trackMetadataEdits.isEmpty {
                Button("曲情報の変更を確認…") { library.trackMetadataPresentation = .changes }
            }
        }
    }
}

struct TrackMetadataEditing: ViewModifier {
    @ObservedObject var library: Library
    var enabled = true

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { enabled ? library.trackMetadataPresentation : nil },
            set: { if enabled { library.trackMetadataPresentation = $0 } }
        )) { presentation in
            switch presentation {
            case .edit(let draft): TrackMetadataEditor(library: library, draft: draft)
            case .changes: TrackMetadataChanges(library: library)
            }
        }
    }
}

private struct TrackMetadataEditor: View {
    @ObservedObject var library: Library
    let draft: TrackMetadataDraft
    @State private var title: String
    @State private var artist: String
    @State private var error: String?

    init(library: Library, draft: TrackMetadataDraft) {
        self.library = library
        self.draft = draft
        _title = State(initialValue: draft.title)
        _artist = State(initialValue: draft.artist)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("曲の情報") {
                    TextField("曲名", text: $title).accessibilityIdentifier("metadata-title")
                    TextField("アーティスト", text: $artist).accessibilityIdentifier("metadata-artist")
                }
                if draft.replacing != nil {
                    Section("ライブラリの現在の内容") {
                        Text(draft.entry.track.title)
                        Text(draft.entry.track.artist ?? "アーティスト不明")
                        Text("確認した内容を、新しい変更として送信します。").foregroundStyle(.secondary)
                    }
                }
                Text("変更はこの端末に保存してから送信します。保存先から反映の確認が届くまで、元の曲情報を表示します。")
                    .font(.caption).foregroundStyle(.secondary)
                if let notice = library.transfer.trackMetadataNotice { Text(notice).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle("曲の情報を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { library.trackMetadataPresentation = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("変更を送信") {
                        do {
                            try library.transfer.queueTrackMetadata(draft, title: title, artist: artist)
                            library.trackMetadataPresentation = .changes
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        library.transfer.trackMetadataNotice != nil)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
#endif
    }
}

struct TrackMetadataChanges: View {
    @ObservedObject var library: Library
    @State private var discard: ClusterMetadataEdit?
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.transfer.trackMetadataEdits, id: \.id) { edit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(edit.metadataValues["title"] ?? edit.entry.track.title)
                        if let artist = edit.metadataValues["artist"] { Text(artist).foregroundStyle(.secondary) }
                        Text(edit.mutationLabel).foregroundStyle(.secondary)
                        if let detail = edit.mutationDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        if edit.canRetryMutation {
                            Button(edit.mutationHost == nil ? "変更を送信" : "同じ保存先に再送") { library.transfer.connectCluster() }
                                .disabled(library.transfer.busy)
                        }
                        if edit.mutationState == .needsReview {
                            Button("ライブラリを更新") { library.transfer.connectCluster() }.disabled(library.transfer.busy)
                            Button("内容を確認して再送…") { library.presentTrackMetadata(edit.entry.track, replacing: edit) }
                                .disabled(library.transfer.busy || library.transfer.trackMetadataNotice != nil)
                        }
                        if edit.mutationState == .needsReview || edit.mutationState == .rejected ||
                            (edit.mutationState == .queued && edit.mutationHost == nil) {
                            Button("変更を破棄…", role: .destructive) { discard = edit; confirmingDiscard = true }
                        }
                    }.accessibilityIdentifier("metadata-change-" + edit.id)
                }
                if library.transfer.trackMetadataEdits.isEmpty { Text("送信待ちの変更はありません。") }
                if let message = library.message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("曲情報の変更")
            .toolbar { Button("閉じる") { library.trackMetadataPresentation = nil } }
            .alert("変更内容を破棄しますか？", isPresented: $confirmingDiscard, presenting: discard) { edit in
                Button("キャンセル", role: .cancel) {}
                Button("破棄", role: .destructive) { library.transfer.discardTrackMetadata(edit) }
            } message: { _ in Text("この端末に保持した変更内容を削除します。ライブラリの曲情報は変わりません。") }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
#endif
    }
}

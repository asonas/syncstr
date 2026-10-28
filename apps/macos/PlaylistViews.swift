import SwiftUI
import UniformTypeIdentifiers

struct PlaylistBrowser: View {
    @ObservedObject var library: Library
    var parent: String? = nil
    @State private var importing = false

    private var children: [PlaylistDocument] { library.playlists.filter { $0.parent == parent } }

    private var title: String { parent == nil ? "すべてのプレイリスト" : library.playlists.first { $0.id == parent }?.name ?? "フォルダ" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    Text(title).font(.title2.bold()).fixedSize().accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 20)
                    actions
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    HStack { actions; Spacer(minLength: 0) }
                }
            }.padding(.horizontal, 32).padding(.vertical, 20)
            #endif
            if let message = library.playlistMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32).padding(.bottom, 16)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppearanceColors.content)
        #if os(iOS)
        .navigationTitle(title)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions } }
        #endif
        .sheet(isPresented: $importing) { PlaylistMigrationView(library: library) }
        .task {
            await library.refreshPlaylists()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await library.refreshPlaylists()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("XMLから移行") { importing = true }.disabled(!library.transfer.canSyncPlaylists)
        Button("更新") { Task { await library.refreshPlaylists() } }
            .disabled(library.refreshingPlaylists || !library.transfer.canSyncPlaylists)
    }

    private var content: some View {
        List {
            if children.isEmpty {
                Text(library.refreshingPlaylists ? "プレイリストを同期中…" : "プレイリストはありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(["folder", "snapshot", "manual"], id: \.self) { kind in
                let values = children.filter { $0.kind == kind }
                if !values.isEmpty {
                    Section(kind == "folder" ? "フォルダ" : kind == "snapshot" ? "スマートプレイリストのスナップショット" : "プレイリスト") {
                        ForEach(values) { document in
                            NavigationLink {
                                if document.kind == "folder" {
                                    AnyView(PlaylistBrowser(library: library, parent: document.id).navigationTitle(document.name))
                                } else {
                                    AnyView(PlaylistDetail(library: library, document: document))
                                }
                            } label: {
                                HStack(spacing: 16) {
                                    PlaylistArtwork(library: library, document: document).frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(document.name)
                                        if document.kind != "folder" { Text("\(document.items.count)曲").font(.caption).foregroundStyle(.secondary) }
                                        if library.playlistConflicts.contains(document.id) { Text("競合があります").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppearanceColors.content)
    }
}

private struct PlaylistArtwork: View {
    @ObservedObject var library: Library
    let document: PlaylistDocument
    private var covers: [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []
        for item in document.items {
            if let url = library.playlistTrack(item)?.coverArt.flatMap({ library.artworkURLs[$0] }), seen.insert(url).inserted {
                result.append(url)
                if result.count == 4 { break }
            }
        }
        return result
    }
    var body: some View {
        GeometryReader { geometry in
            let urls = covers
            if urls.count >= 4 {
                VStack(spacing: 0) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 0) { ForEach(0..<2) { column in image(urls[row * 2 + column]).frame(width: geometry.size.width / 2, height: geometry.size.height / 2).clipped() } }
                    }
                }
            } else { image(urls.first) }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
    private func image(_ url: URL?) -> some View {
        MusicImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            AppearanceColors.control.overlay { Image("regen-music").renderingMode(.template).resizable().scaledToFit().padding(12).foregroundStyle(.secondary) }
        }
    }
}

private struct PlaylistDetail: View {
    @ObservedObject var library: Library
    let document: PlaylistDocument
    @State private var search = ""
    private var playable: [(item: PlaylistItem, track: Track)] { document.items.compactMap { item in library.playlistTrack(item).map { (item, $0) } } }
    var body: some View {
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 20) {
                        PlaylistArtwork(library: library, document: document).frame(width: 160, height: 160)
                        heading.frame(minWidth: 280, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        PlaylistArtwork(library: library, document: document).frame(width: 160, height: 160).frame(maxWidth: .infinity)
                        heading
                    }
                }.padding(.vertical, 16)
                if library.playlistConflicts.contains(document.id) { Text("同じプレイリストに異なる取り込みがあります。解決するまで再生できません。") }
            }
            ForEach(document.items.filter { search.isEmpty || $0.title.localizedStandardContains(search) || ($0.artist?.localizedStandardContains(search) ?? false) }) { item in
                Button {
                    if let index = playable.firstIndex(where: { $0.item.id == item.id }) { library.playPlaylist(playable.map(\.track), at: index) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            if let artist = item.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if library.playlistTrack(item) == nil { Text("未解決").font(.caption).foregroundStyle(.secondary) }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.playlistTrack(item) == nil || library.playlistConflicts.contains(document.id))
            }
        }
        .searchable(text: $search, prompt: "プレイリストを検索")
        .scrollContentBackground(.hidden)
        .background(AppearanceColors.content)
        .navigationTitle(document.name)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(document.name).font(.title2.bold())
            Text("\(document.items.count)曲・再生可能 \(playable.count)曲").font(.caption).foregroundStyle(.secondary)
            if document.kind == "snapshot" { Text("取り込み時点の曲一覧です。条件の自動更新には未対応です。").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 16) {
                Button { library.startAlbum(playable.map(\.track), shuffled: true) } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("シャッフル再生")
                Button { library.startAlbum(playable.map(\.track)) } label: {
                    Label { Text("再生") } icon: { Image("regen-filled-play").renderingMode(.template) }.frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.borderedProminent)
                OfflineSaveControls(library: library, tracks: playable.map(\.track), scope: "playlist:" + document.id, iconOnly: true).frame(width: 44)
            }
            .disabled(playable.isEmpty || library.playlistConflicts.contains(document.id))
        }
    }

}

struct PlaylistMigrationView: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var draft: PlaylistDraft?
    @State private var selected: Set<String> = []
    @State private var accepted: [String: String] = [:]
    @State private var reviewing = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var completed: Int?
    @State private var search = ""
    @State private var snapshots: [PlaylistSnapshot] = []
    @State private var matchingEntries: [LocalEntry] = []
    @State private var confirmingReplacement = false

    private func reconciliation(_ draft: PlaylistDraft) throws -> PlaylistReconciliation {
        try PlaylistReconciliation(documents: draft.documents(selected: selected, accepted: accepted), snapshots: snapshots, entries: matchingEntries)
    }

    private var selectedSongs: [PlaylistDraft.Song] {
        guard let draft else { return [] }
        let ids = Set(draft.playlists.filter { selected.contains($0.id) && $0.kind != "folder" }.flatMap(\.items))
        return ids.compactMap { draft.songs[$0] }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if busy { ProgressView("サーバーと通信中…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 20) }
                if draft != nil && errorMessage != nil { Button("XMLを読み直す") { choosing = true } }
                if let completed {
                    Text("\(completed)件を取り込みました。各端末でプレイリストを更新すると表示されます。")
                        .padding(32)
                    Button("閉じる") { dismiss() }
                } else if let draft {
                    if reviewing { review(draft) } else { selection(draft) }
                } else {
                    VStack(spacing: 20) {
                        Text("Music／iTunesから書き出したXMLを選択してください。サーバーにある音源と照合します。")
                        Button("XMLを選択") { choosing = true }.buttonStyle(.borderedProminent)
                    }.padding(32)
                    Spacer()
                }
            }
            .navigationTitle("プレイリストを移行")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(completed == nil ? "キャンセル" : "閉じる") { dismiss() }.disabled(busy) } }
            .disabled(busy)
            .confirmationDialog("採用済みの音源を変更しますか？", isPresented: $confirmingReplacement, titleVisibility: .visible) {
                Button("音源を変更して更新") { if let draft { Task { await importSelection(draft) } } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("確認画面に表示した変更を適用します。プレイリストの曲順と未選択の照合結果は保持されます。")
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.xml], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { Task { await read(url) } }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 560)
        #endif
    }

    private func selection(_ draft: PlaylistDraft) -> some View {
        VStack {
            HStack {
                Button("すべて選択") { selected = Set(draft.playlists.filter { $0.kind != "folder" }.map(\.id)) }
                Button("選択解除") { selected = [] }
                Spacer()
                Button("照合を確認") { reviewing = true; search = "" }.disabled(selected.isEmpty)
            }.padding(.horizontal, 20)
            List(draft.playlists.filter { search.isEmpty || $0.path.localizedStandardContains(search) }) { source in
                Toggle(isOn: Binding(get: {
                    source.kind == "folder" ? draft.playlists.contains { $0.ancestors.contains(source.id) && selected.contains($0.id) } : selected.contains(source.id)
                }, set: { enabled in
                    let ids = source.kind == "folder" ? draft.playlists.filter { $0.ancestors.contains(source.id) && $0.kind != "folder" }.map(\.id) : [source.id]
                    if enabled { selected.formUnion(ids) } else { selected.subtract(ids) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.path)
                        Text(source.kind == "folder" ? "フォルダ" : "\(source.items.count)曲\(source.kind == "snapshot" ? "・固定スナップショット" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.searchable(text: $search, prompt: "プレイリストを検索")
        }
    }

    private func review(_ draft: PlaylistDraft) -> some View {
        let items = draft.playlists.filter { selected.contains($0.id) }.flatMap(\.items)
        let result = Result { try reconciliation(draft) }
        let preview = try? result.get()
        let resolved = preview?.documents.flatMap(\.items).filter { $0.trackId != nil }.count ?? 0
        let existingTracks = Set(snapshots.filter { $0.document.sourceLibrary == draft.sourceLibrary && selected.contains($0.document.sourcePlaylist) }
            .flatMap { $0.document.items }.filter { $0.trackId != nil }.map(\.sourceTrack))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(selected.count)プレイリスト・\(items.count)曲中\(resolved)曲を照合済み")
                if let preview, preview.updatedCount > 0 {
                    Text("登録済み\(preview.previousResolved)曲 → 更新後\(resolved)曲・\(preview.updatedCount)プレイリストを更新")
                }
                if case .failure(let error) = result { Text(error.localizedDescription).foregroundStyle(.secondary) }
                Text("候補は曲名・アーティスト・アルバム・曲番号・長さで照合しています。未選択の曲は登録済みの照合結果を保持し、未解決の曲は元の位置に残ります。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("戻る") { reviewing = false; search = "" }
                    Button("一意の候補を採用") {
                        for song in selectedSongs where song.candidates.count == 1 && !existingTracks.contains(song.persistentID ?? song.id) {
                            let entry = song.candidates[0]
                            accepted[song.id] = entry.track.id + ":" + entry.sha256
                        }
                    }
                    Spacer()
                }
                if let preview, !preview.replacements.isEmpty {
                    Text("採用済み音源の変更：\(preview.replacements.count)曲").font(.headline)
                    ScrollView { Text(preview.replacements.joined(separator: "\n")).textSelection(.enabled) }.frame(maxHeight: 100)
                }
                Button((preview?.updatedCount ?? 0) > 0 ? "プレイリストを更新" : "\(selected.count)プレイリストを移行") {
                    if let preview, !preview.replacements.isEmpty { confirmingReplacement = true }
                    else { Task { await importSelection(draft) } }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview == nil)
            }.padding(.horizontal, 20)
            List(selectedSongs.filter { search.isEmpty || $0.title.localizedStandardContains(search) || ($0.artist?.localizedStandardContains(search) ?? false) }) { song in
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                    Text([song.artist, song.album].compactMap { $0 }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                    if song.candidates.isEmpty { Text("照合候補なし").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Picker("照合候補", selection: Binding(get: { accepted[song.id] ?? "" }, set: { accepted[song.id] = $0.isEmpty ? nil : $0 })) {
                            Text(existingTracks.contains(song.persistentID ?? song.id) ? "登録済みの音源を保持" : "未解決のまま残す").tag("")
                            ForEach(Array(song.candidates.enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.track.title)・\(Int(entry.track.duration ?? 0))秒・\(entry.track.suffix ?? "")・\(ByteCountFormatter.string(fromByteCount: Int64(entry.track.size ?? 0), countStyle: .file))")
                                    .tag(entry.track.id + ":" + entry.sha256)
                            }
                        }.pickerStyle(.menu)
                    }
                }
            }.searchable(text: $search, prompt: "曲を検索")
        }
    }

    private func read(_ url: URL) async {
        busy = true; errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            let response = try await library.transfer.playlistReconciliationPreview()
            draft = try await CatalogStorage.shared.perform {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) else { throw LocalMusicError.invalidData }
                return try PlaylistDraft.parse(data, catalog: response.catalog)
            }
            snapshots = response.snapshots
            matchingEntries = response.catalog.entries
            accepted = [:]; selected = []; reviewing = false; search = ""
        } catch { errorMessage = "XMLを読み込めませんでした。接続先の更新とXMLファイルを確認してください。\(error.localizedDescription)" }
    }

    private func importSelection(_ draft: PlaylistDraft) async {
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let preview = try reconciliation(draft)
            _ = try await library.transfer.reconcilePlaylists(preview, cluster: draft.cluster)
            await library.loadPlaylists()
            completed = selected.count
        } catch { errorMessage = error.localizedDescription }
    }
}

import SwiftUI

extension Library {
    func playlistCovers(_ document: PlaylistDocument) -> [URL] {
        var seen = Set<String>()
        var ids: [String] = []
        for item in document.items {
            guard let id = playlistTrack(item)?.coverArt, seen.insert(id).inserted else { continue }
            ids.append(id)
            if ids.count == 4 { break }
        }
        return ids.prefix(ids.count == 4 ? 4 : 1).compactMap { artworkURL(for: $0) }
    }
}

#if os(iOS)
struct PlaylistBrowser: View {
    @ObservedObject var library: Library
    var parent: String? = nil

    private var children: [PlaylistDocument] { library.playlists.filter { $0.parent == parent } }

    private var title: String { parent == nil ? "すべてのプレイリスト" : library.playlists.first { $0.id == parent }?.name ?? "フォルダ" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .navigationTitle(title)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions } }
        .task { await library.refreshPlaylists() }
    }

    private var actions: some View {
        Button("更新", action: library.transfer.refreshConnection)
            .disabled(library.transfer.hostConnection == nil)
    }

    private var content: some View {
        List {
            if children.isEmpty {
                Text(library.refreshingPlaylists ? "プレイリストを同期中…" : "プレイリストはありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(PlaylistDocument.kindOrder, id: \.self) { kind in
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
    var body: some View {
        GeometryReader { geometry in
            let urls = library.playlistCovers(document)
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
                if library.showsOfflineSaveControls {
                    OfflineSaveControls(library: library, tracks: playable.map(\.track), scope: "playlist:" + document.id, iconOnly: true).frame(width: 44)
                }
            }
            .disabled(playable.isEmpty || library.playlistConflicts.contains(document.id))
        }
    }

}
#endif

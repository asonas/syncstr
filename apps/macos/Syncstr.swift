import SwiftUI
import UniformTypeIdentifiers

enum Studio {
    static let carbon = AppearanceColors.sidebar
    static let graphite = AppearanceColors.content
    static let iron = AppearanceColors.separator
    static let control = AppearanceColors.control
    static let fog = AppearanceColors.secondary
    static let signal = AppearanceColors.accent
    static let button = AppearanceColors.action
}

struct StudioButton: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .foregroundStyle(enabled ? (primary ? Color.white : AppearanceColors.primary) : Studio.fog)
            .background(primary && enabled ? Studio.button : Studio.carbon)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(primary && enabled ? Color.clear : Studio.iron, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct LibraryView: View {
    @ObservedObject var library: Library
    @State private var importingAudio = false
    @State private var showingPeerSetup = false
    @State private var showingUploadStatus = false
    @State private var showingClusterResults = false
    @State private var hoveredTrack: String?
    @State private var selectedAlbums = Set<String>()
    @State private var albumScrollPosition = ScrollPosition(idType: String.self)
    @FocusState private var albumGridFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if library.connected {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Studio.iron).frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                        .overlay(alignment: .bottom) {
                            if library.current != nil { playbackBar.padding(.horizontal, 20).padding(.bottom, 20) }
                        }
                }
            } else if library.restoringSession {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("ライブラリに接続中…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 20) {
                    Text("自分の音楽を、どの端末でも").font(.title)
                    Text("ライブラリに参加するか、この端末に音楽を追加して聴き始められます。")
                    Button("既存のライブラリに参加") { showingPeerSetup = true }.buttonStyle(.borderedProminent)
                    LocalFolderButton(library: library).buttonStyle(.borderedProminent)
                    AddMusicButton(library: library)
                    if library.hasSavedLocalLibrary {
                        Button("保存したライブラリを開く") { Task { await library.openSavedLocalLibrary() } }
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = library.message ?? (showingUploadStatus ? library.transfer.status : nil) {
                HStack(alignment: .top, spacing: 8) {
                    MacIcon("circle-alert").accessibilityHidden(true)
                    Text(message).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppearanceColors.primary)
                .padding(16)
                .background(Studio.graphite)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 14))
        .tracking(-0.21)
        .foregroundStyle(AppearanceColors.primary)
        .background(Studio.graphite)
        .tint(Studio.signal)
        .frame(minWidth: 640, minHeight: 560)
        .navigationTitle("")
        .focusedSceneObject(library)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: library.destination) { _, _ in selectedAlbums.removeAll() }
        .onChange(of: showingAlbumGrid) { _, showing in
            if !showing { selectedAlbums.removeAll() }
        }
        .onChange(of: library.visibleAlbums.map(\.id)) { _, ids in
            selectedAlbums.formIntersection(ids)
        }
        .task { await library.restoreLibrary() }
        .modifier(OfflineSaveRemoval(library: library))
        .sheet(isPresented: $showingPeerSetup) {
            ScrollView { PeerSetupView(transfer: library.transfer).padding(24) }
                .frame(width: 500, height: 600)
                .toolbar { Button("閉じる") { showingPeerSetup = false } }
        }
        .sheet(isPresented: $showingClusterResults) { ClusterImportResults(transfer: library.transfer) }
        .onChange(of: library.transfer.busy) { _, busy in
            if !busy && !showingPeerSetup && library.transfer.clusterResultsPending {
                library.transfer.clusterResultsPending = false
                showingClusterResults = true
            }
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files):
                showingUploadStatus = true
                Task { await library.addMusic(files) }
            case .failure(let error): library.message = error.localizedDescription
            }
        }
    }

    private var rule: some View { Rectangle().fill(Studio.iron).frame(height: 1) }

    private var contentHeader: some View {
        HStack(spacing: 16) {
            if !library.showingNowPlaying, library.search.isEmpty, let albumID = library.selectedAlbum {
                Button {
                    albumScrollPosition = ScrollPosition(id: albumID, anchor: .center)
                    library.selectedAlbum = nil
                } label: {
                    MacIcon("chevron-left").frame(width: 32, height: 32)
                }
                .buttonBorderShape(.circle)
                .help("アルバムへ戻る")
                .accessibilityLabel("アルバムへ戻る")
            }
            Spacer(minLength: 0)
            if showingAlbumGrid {
                if !selectedAlbums.isEmpty {
                    Text("\(selectedAlbums.count)枚を選択中").foregroundStyle(.secondary)
                    Button(albumVisibilityLabel) { changeAlbumVisibility(selectedAlbums) }
                        .disabled(selectedAlbums.contains(where: library.isSavingAlbumVisibility))
                }
                if library.destination != .recentlyAdded { albumSortMenu }
            }
            LibrarySearchField(text: $library.search, placeholder: "\(library.destination.rawValue)を検索")
                .frame(minWidth: 120, idealWidth: 240, maxWidth: 240)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ライブラリ").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            ForEach(LibraryDestination.allCases, id: \.self) { destination in
                if destination == .playlists {
                    Text("プレイリスト").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 16)
                }
                Button { library.navigate(destination); library.search = "" } label: {
                    HStack(spacing: 8) {
                        MacIcon((destination == .recentlyAdded || destination == .albums || destination == .hiddenAlbums) ? "layers" : destination == .artists ? "users" : "music")
                        Text(destination.rawValue)
                    }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(library.destination == destination && !library.showingNowPlaying ? Studio.graphite : Color.clear)
                        .foregroundStyle(library.destination == destination && !library.showingNowPlaying ? Studio.signal : AppearanceColors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityAddTraits(library.destination == destination && !library.showingNowPlaying ? .isSelected : [])
            }
            rule.padding(.vertical, 16)
            Button {
                importingAudio = true
            } label: {
                HStack(spacing: 8) { MacIcon("cloud-upload"); Text("音源ファイルを追加") }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(library.transfer.busy)
            .help("ライブラリに音源を追加します。未登録の場合もこの端末で再生できます")
            if showingUploadStatus && library.transfer.busy {
                ProgressView(value: library.transfer.progress).padding(.horizontal, 8)
                Button("中断する") { library.transfer.cancel() }.buttonStyle(.plain).padding(.horizontal, 8)
            }
            Button(action: library.reload) {
                HStack(spacing: 8) { MacIcon("refresh"); Text(library.refreshing ? "更新中…" : "ライブラリを更新") }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(library.refreshing)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.top, 20)
        .frame(width: 208)
        .background(Studio.carbon)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if library.destination != .playlists || library.showingNowPlaying { contentHeader }
            ZStack {
                libraryContent
                    .opacity(library.showingNowPlaying ? 0 : 1)
                    .allowsHitTesting(!library.showingNowPlaying)
                    .accessibilityHidden(library.showingNowPlaying)
                if library.showingNowPlaying { nowPlaying }
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if library.search.isEmpty, let albumID = library.selectedAlbum,
                  let album = library.album(id: albumID) {
            albumDetail(album)
        } else {
            switch library.destination {
            case .recentlyAdded, .albums, .hiddenAlbums: albums
            case .artists: artists
            case .songs: songs
            case .playlists: NavigationStack { PlaylistBrowser(library: library) }
            }
        }
    }

    private var albums: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20, alignment: .top)],
                      alignment: .leading, spacing: 32) {
                if library.destination == .recentlyAdded {
                    ForEach(library.visibleRecentlyAddedSections) { section in
                        Section {
                            albumGridItems(section.albums)
                        } header: {
                            Group {
                                if let month = section.month {
                                    Text(month, format: .dateTime.year().month(.wide))
                                } else { Text("追加日不明") }
                            }
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        }
                    }
                } else { albumGridItems(library.visibleAlbums) }
            }.scrollTargetLayout().padding(32)
            if library.visibleAlbums.isEmpty {
                Text(library.search.isEmpty ? "アルバムがありません。" : "一致するアルバムがありません。")
                    .foregroundStyle(Studio.fog).padding(32)
            }
        }
        .scrollPosition($albumScrollPosition)
        .focusable()
        .focused($albumGridFocused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            guard !selectedAlbums.isEmpty else { return .ignored }
            selectedAlbums.removeAll()
            return .handled
        }
        .onKeyPress(.return) {
            guard selectedAlbums.count == 1, let id = selectedAlbums.first else { return .ignored }
            openAlbum(id)
            return .handled
        }
        .safeAreaPadding(.bottom, 120)
    }

    private func albumGridItems(_ albums: [Album]) -> some View {
        ForEach(albums) { album in
            Button {
                if (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command) {
                    if !selectedAlbums.insert(album.id).inserted { selectedAlbums.remove(album.id) }
                    albumGridFocused = true
                } else {
                    openAlbum(album.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Artwork(url: artworkURL(album.coverArt))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title).font(.system(size: 14)).lineLimit(2)
                        Text(album.artist).font(.system(size: 12)).foregroundStyle(Studio.fog).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                }
                .background(selectedAlbums.contains(album.id) ? Studio.control : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selectedAlbums.contains(album.id) ? Studio.signal : Color.clear, lineWidth: 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(album.id)
            .help("\(album.title)\n\(album.artist)")
            .accessibilityLabel("\(album.title)、\(album.artist)")
            .accessibilityAddTraits(selectedAlbums.contains(album.id) ? .isSelected : [])
            .accessibilityAction(named: Text("アルバムを開く")) { openAlbum(album.id) }
            .contextMenu {
                let targets: Set<String> = selectedAlbums.contains(album.id) ? selectedAlbums : [album.id]
                let saving = targets.contains(where: library.isSavingAlbumVisibility)
                let action = library.destination == .hiddenAlbums ? "非表示を解除する" : "非表示にする"
                Button(saving ? "保存しています…" : targets.count > 1 ? "選択した\(targets.count)枚を\(action)" : action) {
                    changeAlbumVisibility(targets)
                }.disabled(saving)
                Button("アルバムを開く") { openAlbum(album.id) }
            }
        }
    }

    private var showingAlbumGrid: Bool {
        !library.showingNowPlaying && (library.destination == .recentlyAdded || library.destination == .albums || library.destination == .hiddenAlbums)
            && (library.selectedAlbum == nil || !library.search.isEmpty)
    }

    private var albumVisibilityLabel: String {
        selectedAlbums.contains(where: library.isSavingAlbumVisibility) ? "保存しています…"
            : library.destination == .hiddenAlbums ? "非表示を解除する" : "非表示にする"
    }

    private func changeAlbumVisibility(_ ids: Set<String>) {
        library.setAlbumsHidden(ids, hidden: library.destination != .hiddenAlbums)
    }

    private func openAlbum(_ id: String) {
        library.search = ""
        library.selectedAlbum = id
        selectedAlbums.removeAll()
    }

    private var albumSortMenu: some View {
        Menu {
            Picker("並び替えの基準", selection: $library.albumSortField) {
                Text("タイトル").tag(AlbumSortField.title)
                Text("アーティスト").tag(AlbumSortField.artist)
            }
            .pickerStyle(.inline)
            Divider()
            Picker("表示順", selection: $library.albumSortDescending) {
                Text("昇順").tag(false)
                Text("降順").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image("album-sort").resizable().renderingMode(.template)
                .frame(width: 24, height: 24)
        }
        .menuIndicator(.hidden)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("並び替え")
        .accessibilityLabel("並び替え")
    }

    private func albumDetail(_ album: Album) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let wide = geometry.size.width >= 640
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                                      : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                    layout {
                        Artwork(url: artworkURL(album.coverArt)).frame(width: wide ? 272 : 200, height: wide ? 272 : 200)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(album.title).font(.system(size: 28, weight: .semibold))
                                .textSelection(.enabled)
                                .padding(.top, wide ? 48 : 0)
                                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                            if album.detailArtist == "V.A." {
                                Text("V.A.").font(.system(size: 20)).foregroundStyle(Studio.fog)
                            } else {
                                Button { showArtist(album.artist) } label: {
                                    Text(album.detailArtist ?? album.artist).font(.system(size: 20)).foregroundStyle(Studio.signal)
                                }.buttonStyle(.plain)
                            }
                            Text("\(album.tracks.count)曲").font(.system(size: 12)).foregroundStyle(Studio.fog)
                            Spacer(minLength: 20)
                            HStack(alignment: .center, spacing: 16) {
                                Button { library.startAlbum(album.tracks, shuffled: true) } label: {
                                    Image(systemName: "shuffle").frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain).foregroundStyle(Studio.signal)
                                .accessibilityLabel("アルバムをシャッフル再生")
                                playButton(album.tracks)
                                OfflineSaveControls(library: library, tracks: album.tracks,
                                                    scope: "album:" + album.id, iconOnly: true)
                            }
                        }.frame(minHeight: wide ? 272 : nil, alignment: .topLeading)
                        if wide { Spacer(minLength: 0) }
                    }
                    trackRows(album.tracks, showArtist: wide)
                }.padding(32)
            }.safeAreaPadding(.bottom, 120)
        }
    }

    private var artists: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(library.artists, id: \.self) { artist in
                            Button { library.selectedArtist = artist } label: {
                                HStack(spacing: 8) {
                                    MacIcon("users").foregroundStyle(Studio.fog)
                                        .frame(width: 32, height: 32).background(Studio.control, in: Circle())
                                    Text(artist).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 48)
                                .background(library.selectedArtist == artist ? Studio.button : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                                .foregroundStyle(library.selectedArtist == artist ? Color.white : AppearanceColors.primary)
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(library.selectedArtist == artist ? .isSelected : [])
                                .help(artist)
                        }
                    }.padding(8)
                }
                .frame(width: geometry.size.width >= 800 ? 300 : 180)
                .safeAreaPadding(.bottom, 120)
                Rectangle().fill(Studio.iron).frame(width: 1)
                if let artist = library.selectedArtist {
                    artistDetail(artist)
                } else {
                    Text("アーティストを選択").font(.system(size: 20, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func artistDetail(_ artist: String) -> some View {
        let albums = library.albums(for: artist)
        let tracks = albums.flatMap { $0.tracks.filter { ($0.artist ?? "アーティスト不明") == artist } }
        return GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artist).font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text("\(albums.count)枚のアルバム、\(tracks.count)曲")
                            .font(.system(size: 12)).foregroundStyle(Studio.fog)
                    }
                    ForEach(albums) { album in
                        let wide = geometry.size.width >= 800
                        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                        layout {
                            Artwork(url: artworkURL(album.coverArt))
                                .frame(width: min(wide ? 360 : 200, max(120, geometry.size.width - 64)))
                            VStack(alignment: .leading, spacing: 20) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) {
                                        artistAlbumTitle(album)
                                        Spacer(minLength: 0)
                                        playButton(album.tracks.filter { ($0.artist ?? "アーティスト不明") == artist })
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        artistAlbumTitle(album)
                                        playButton(album.tracks.filter { ($0.artist ?? "アーティスト不明") == artist })
                                    }
                                }
                                // Virtualize albums, keeping each visible album's height stable.
                                VStack(spacing: 0) {
                                    trackRowContents(album.tracks.filter { ($0.artist ?? "アーティスト不明") == artist }, showArtist: false)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(32)
            }.safeAreaPadding(.bottom, 120)
        }
    }

    private func artistAlbumTitle(_ album: Album) -> some View {
        Button { library.selectedAlbum = album.id; library.search = "" } label: {
            Text(album.title).font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }.buttonStyle(.plain)
    }

    private var songs: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 640
            let tracks = library.visibleTracks
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, index: index, tracks: tracks, showArtist: wide,
                                     showAlbum: wide, dense: true, striped: index.isMultiple(of: 2))
                        }
                    } header: {
                        HStack(spacing: 16) {
                            Text("タイトル").frame(maxWidth: .infinity, alignment: .leading)
                            if wide {
                                Text("アーティスト").frame(maxWidth: .infinity, alignment: .leading)
                                Text("アルバム").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("時間").frame(width: 40, alignment: .trailing)
                            Color.clear.frame(width: 32)
                        }.font(.system(size: 12)).foregroundStyle(Studio.fog)
                            .padding(.horizontal, 8).frame(height: 32).background(Studio.graphite)
                    }
                }.padding(.horizontal, 32).padding(.top, 20)
                if tracks.isEmpty { Text("一致する曲がありません。").foregroundStyle(Studio.fog).padding(32) }
            }.safeAreaPadding(.bottom, 120)
        }
    }

    private func trackRows(_ tracks: [Track], showArtist: Bool = true, preservingQueue: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            trackRowContents(tracks, showArtist: showArtist, preservingQueue: preservingQueue)
        }
    }

    private func trackRowContents(_ tracks: [Track], showArtist: Bool, preservingQueue: Bool = false) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            trackRow(track, index: index, tracks: preservingQueue ? nil : tracks, showArtist: showArtist)
                .contextMenu {
                    Button(library.albumVisibilityLabel(track.albumKey)) {
                        library.setAlbumHidden(track.albumKey, hidden: !library.isAlbumHidden(track.albumKey))
                    }.disabled(library.isSavingAlbumVisibility(track.albumKey))
                }
                .overlay(alignment: .bottom) { rule }
        }
    }

    private func trackRow(_ track: Track, index: Int, tracks: [Track]?, showArtist: Bool,
                          showAlbum: Bool = false, dense: Bool = false, striped: Bool = false) -> some View {
        let selected = library.current?.id == track.id
        let accentSelection = selected && !dense
        let secondary = accentSelection ? Color.white : Studio.fog
        return HStack(spacing: 16) {
            Button { library.play(track, in: tracks) } label: {
                HStack(spacing: 16) {
                    if !dense {
                        Group {
                            if selected || hoveredTrack == track.id {
                                MacIcon("filled-play").foregroundStyle(accentSelection ? Color.white : Studio.signal)
                            }
                            else { Text("\(index + 1)").foregroundStyle(Studio.fog) }
                        }.frame(width: 24).accessibilityHidden(true)
                    }
                    Text(track.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if showArtist {
                        Text(track.artist ?? "アーティスト不明").foregroundStyle(secondary)
                            .font(.system(size: showAlbum ? 14 : 12)).lineLimit(1)
                            .frame(width: showAlbum ? nil : 280, alignment: .leading)
                            .frame(maxWidth: showAlbum ? .infinity : nil, alignment: .leading)
                    }
                    if showAlbum {
                        Text(track.albumDisplayTitle).foregroundStyle(secondary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(time(track.duration ?? 0)).monospacedDigit().foregroundStyle(secondary)
                        .font(.system(size: 12))
                        .frame(width: 40, alignment: .trailing)
                }.frame(maxWidth: .infinity, minHeight: dense ? 32 : 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(track.title)、\(track.artist ?? "アーティスト不明")、\(time(track.duration ?? 0))")
                .accessibilityAddTraits(library.current?.id == track.id ? .isSelected : [])
            if let request = library.saveRequest(for: [track], scope: "track:" + track.id),
               request.state != .complete && !library.hasManagedCopy(track) {
                Text(request.state == .wifi ? "Wi-Fi待ち" : request.state == .saving ? "保存中" : request.state == .failed ? "保存失敗" : request.state == .cancelled ? "保存中止" : "接続待ち")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(request.error ?? "保存操作から中止または再試行できます")
            } else if library.localFiles[track.id] != nil {
                Text("保存済み").font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                Button("再生") { library.play(track, in: tracks) }
                if let request = library.saveRequest(for: [track], scope: "track:" + track.id),
                   [.waiting, .wifi, .saving].contains(request.state) {
                    Button(request.entries.count > 1 ? "アルバム保存を中止" : "保存を中止") { library.transfer.cancelSave(request) }
                } else if library.localFiles[track.id] == nil {
                    Button("この端末に保存") { Task { await library.transfer.requestSave([track], scope: "track:" + track.id) } }
                }
                if library.canRemoveLocalCopy(track) {
                    Button("この端末の保存を解除", role: .destructive) { library.localCopiesToRemove = [track] }.disabled(library.transfer.busy)
                }
                Button("アルバムを表示") { library.selectedAlbum = track.albumKey; library.search = ""; library.showingNowPlaying = false }
                Button("アーティストを表示") { self.showArtist(track.artist ?? "アーティスト不明") }
            } label: { Text("\(track.title)のその他の操作").hidden().frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32, height: 32)
            .overlay { MacIcon("dots").foregroundStyle(secondary).allowsHitTesting(false) }
            .accessibilityLabel("\(track.title)のその他の操作")
        }
        .font(.system(size: 14))
        .foregroundStyle(accentSelection ? Color.white : selected && dense ? Studio.signal : AppearanceColors.primary)
        .padding(.horizontal, 8)
        .background(selected ? (dense ? Studio.control : Studio.button)
                    : hoveredTrack == track.id ? Studio.control
                    : striped ? Studio.carbon : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .onHover { hoveredTrack = $0 ? track.id : nil }
        .help("\(track.title)\n\(track.artist ?? "アーティスト不明")")
    }

    private func showArtist(_ artist: String) {
        library.navigate(.artists)
        library.selectedArtist = artist
        library.search = ""
    }

    private func playButton(_ tracks: [Track]) -> some View {
        return Button { library.startAlbum(tracks) } label: {
            HStack(spacing: 8) {
                MacIcon("filled-play", size: 16)
                Text("再生")
            }
                .frame(width: 128, height: 36)
                .background(Studio.button, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(tracks.isEmpty)
    }

    private func backButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { MacIcon("chevron-left"); Text(title) }.frame(minHeight: 32)
        }.buttonStyle(.plain).foregroundStyle(Studio.signal)
    }

    private var nowPlaying: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backButton("ライブラリへ戻る") { library.showingNowPlaying = false }
                if let current = library.current {
                    HStack(spacing: 20) {
                        Artwork(url: artworkURL(current.coverArt)).frame(width: 120, height: 120)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(current.title).font(.system(size: 28)).accessibilityAddTraits(.isHeader)
                            Text(current.artist ?? "アーティスト不明").foregroundStyle(Studio.fog)
                        }
                    }
                    seeking
                    HStack(spacing: 20) {
                        Toggle("シャッフル", isOn: Binding(
                            get: { library.shuffled }, set: { library.setShuffle($0) }
                        ))
                        Picker("リピート", selection: $library.repeatMode) {
                            ForEach(PlaybackRepeat.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }.pickerStyle(.menu)
                        Slider(value: Binding(
                            get: { library.volume }, set: { library.setVolume($0) }
                        ), in: 0...1) { Text("音量") }
                            .frame(maxWidth: 180)
                    }
                    trackRows(library.queue, showArtist: false, preservingQueue: true)
                    if let failure = library.playbackFailure {
                        Text(failure).foregroundStyle(Studio.fog)
                        Button("再試行", action: library.resumePlayback)
                        if let id = library.failedDiagnosticID {
                            PlaybackDiagnosticCopyButton(attemptID: id, recorder: library.diagnostics).id(id)
                        }
                    }
                }
            }.padding(32)
        }.safeAreaPadding(.bottom, 120)
    }

    private func artworkURL(_ id: String?) -> URL? {
        id.flatMap { library.artworkURLs[$0] }
    }

    private var playbackBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                playbackTitle.frame(width: 232)
                transport
                miniSeeking.frame(minWidth: 160)
            }.padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: 704).frame(height: 72)
            HStack(spacing: 16) {
                playbackTitle
                transport
            }.padding(.horizontal, 16).padding(.vertical, 8).frame(height: 72)
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: Capsule())
    }

    private var miniSeeking: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(time(library.position))
                Spacer(minLength: 0)
                Text("−" + time(max(0, library.duration - library.position)))
            }.font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            playbackSlider.controlSize(.small).tint(.primary)
        }
    }

    private var playbackTitle: some View {
        Button { library.showingNowPlaying = true } label: {
            HStack(spacing: 8) {
                Artwork(url: artworkURL(library.current?.coverArt)).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.current?.title ?? "曲を選んでください").font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(library.loading ? library.playbackLoadingLabel : library.playbackFailure != nil ? "再生できません。詳細を確認" : library.current?.artist ?? "")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if library.loading { ProgressView().controlSize(.small) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(library.current == nil)
            .accessibilityLabel(library.current.map { "\($0.title)の再生中画面を開く" } ?? "曲を選んでください")
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button(action: library.previous) { MacIcon("filled-skip-back").frame(width: 32, height: 32).contentShape(Rectangle()) }
                .disabled(!library.canGoPrevious).accessibilityLabel("前の曲").help("前の曲")
            Button(action: library.togglePlayback) {
                MacIcon(!library.loading && library.playing ? "filled-pause" : "filled-play", size: 24)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }.disabled(library.current == nil || library.loading)
                .accessibilityLabel(library.loading ? "再生" : library.playbackAction)
            Button(action: library.next) { MacIcon("filled-skip-forward").frame(width: 32, height: 32).contentShape(Rectangle()) }
                .disabled(!library.canGoNext).accessibilityLabel("次の曲").help("次の曲")
        }.buttonStyle(.plain).fixedSize()
    }

    private var seeking: some View {
        VStack(spacing: 4) {
            playbackSlider
            HStack(spacing: 8) {
                Text(time(library.position))
                Spacer(minLength: 0)
                Text(time(library.duration))
            }.font(.system(size: 12)).monospacedDigit().foregroundStyle(Studio.fog)
        }
    }

    private var playbackSlider: some View {
        Slider(value: Binding(get: { min(library.position, max(library.duration, 1)) },
                              set: { library.seek(to: $0) }), in: 0...max(library.duration, 1))
            .disabled(!library.canSeek)
            .accessibilityLabel("再生位置")
            .accessibilityValue("\(time(library.position)) / \(time(library.duration))")
            .help("\(time(library.position)) / \(time(library.duration))")
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = ClickFocusedSearchField()
        if #available(macOS 26.0, *) {
            field.controlSize = .extraLarge
        } else {
            field.controlSize = .large
        }
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        (field as? ClickFocusedSearchField)?.removeClickMonitor()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func search(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
    }
}

private final class ClickFocusedSearchField: NSSearchField {
    private var handlingClick = false
    private var clickMonitor: Any?

    override var acceptsFirstResponder: Bool { handlingClick }

    override func mouseDown(with event: NSEvent) {
        handlingClick = true
        defer { handlingClick = false }
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeClickMonitor()
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.currentEditor() != nil,
                  !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            window.makeFirstResponder(nil)
            return event
        }
    }

    func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

private struct MacIcon: View {
    let name: String
    let size: CGFloat

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("regen-" + name).resizable().renderingMode(.template)
            .scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct Artwork: View {
    let url: URL?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            MusicImage(url: url) { image in
                image.resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } placeholder: {
                ZStack {
                    Studio.carbon
                    MacIcon("music", size: 28).foregroundStyle(Studio.fog)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(AppearanceColors.separator, lineWidth: 1 / displayScale)
        }
        .accessibilityHidden(true)
    }
}

@main
struct SyncstrApp: App {
    @StateObject private var library: Library
    @StateObject private var playback: PhonePlayback

    init() {
#if DEBUG
        let library: Library
        do { library = try SharedAudioUIFixture.library() ?? Library() }
        catch { fatalError("Cannot open isolated v5 fixture: \(error)") }
#else
        let library = Library()
#endif
        _library = StateObject(wrappedValue: library)
        _playback = StateObject(wrappedValue: PhonePlayback(library: library))
    }
    var body: some Scene {
        WindowGroup("Syncstr") {
            LibraryView(library: library).onAppear { _ = playback }
                .modifier(AppAppearance())
        }
            .defaultSize(width: 1080, height: 740)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unifiedCompact)
            .commands { PlaybackCommands() }
        Settings { SettingsView(library: library).modifier(AppAppearance()) }
    }
}

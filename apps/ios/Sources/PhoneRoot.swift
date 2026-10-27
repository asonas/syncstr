import SwiftUI

enum PhoneStyle {
    static let carbon = AppearanceColors.sidebar
    static let graphite = AppearanceColors.content
    static let signal = AppearanceColors.accent
    static let button = AppearanceColors.action
    static let secondary = AppearanceColors.secondary
}

enum PhoneTab: Hashable { case library, search, settings }

private struct PhonePlayerAccessory<Content: View>: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(placement == .inline) }
}

private struct PhoneArtistButton: View {
    let name: String
    let destination: () -> AnyView
    @State private var showing = false

    var body: some View {
        Button(name) { showing = true }
            .font(.body).foregroundStyle(PhoneStyle.signal).buttonStyle(.plain)
            .navigationDestination(isPresented: $showing, destination: destination)
    }
}

private enum TabletSection: String, CaseIterable, Identifiable {
    case recent = "最近追加した項目", albums = "アルバム", artists = "アーティスト", songs = "曲"
    case hidden = "非表示にしたアルバム", search = "検索", settings = "設定"
    case playlists = "すべてのプレイリスト"
    var id: Self { self }
    var icon: String {
        switch self {
        case .recent, .albums, .hidden: "layers"
        case .artists: "users"
        case .songs, .playlists: "music"
        case .search: "search"
        case .settings: "settings"
        }
    }
}

struct PhoneRoot: View {
    @ObservedObject var library: Library
    @State private var tab = PhoneTab.library
    @State private var tabletSection: TabletSection? = .recent
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if library.restoringSession {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("ライブラリに接続中…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        tabletNavigation
                            .safeAreaInset(edge: .bottom) {
                                if library.current != nil {
                                    miniPlayer().padding(8).frame(maxWidth: 704)
                                        .glassEffect(.regular, in: Capsule()).padding(20)
                                }
                            }
                    } else {
                        tabs.tabBarMinimizeBehavior(.onScrollDown)
                            .tabViewBottomAccessory(isEnabled: library.current != nil) {
                                PhonePlayerAccessory { compact in miniPlayer(compact: compact) }
                            }
                    }
                }
            }
        }
        .background(PhoneStyle.graphite)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, library.transfer.peerConnected { library.transfer.cancel() }
        }
        .modifier(OfflineSaveRemoval(library: library, enabled: !library.showingNowPlaying))
        .sheet(isPresented: $library.showingNowPlaying) {
            PhoneNowPlaying(library: library)
                .presentationDragIndicator(.visible)
                .presentationBackground(PhoneStyle.graphite)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = library.message {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        RegenIcon(name: "circle-alert", size: 20)
                        Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Button("閉じる") { library.message = nil }
                        }
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        Button("閉じる") { library.message = nil }
                    }
                }
                .padding()
                .background(PhoneStyle.carbon)
            }
        }
        .onChange(of: library.connected) { _, connected in
            if connected { tab = .library; tabletSection = .recent }
        }
    }

    private var tabletNavigation: some View {
        NavigationSplitView {
            List(selection: $tabletSection) {
                Section("ライブラリ") {
                    ForEach(TabletSection.allCases.filter { $0 != .playlists }) { section in
                        Label { Text(section.rawValue) } icon: { RegenIcon(name: section.icon) }.tag(section)
                    }
                }
                Section("プレイリスト") {
                    Label { Text(TabletSection.playlists.rawValue) } icon: { RegenIcon(name: "music") }.tag(TabletSection.playlists)
                }
            }
            .navigationTitle("ライブラリ")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            .toolbar { AddMusicButton(library: library) }
        } detail: {
            NavigationStack {
                Group {
                    switch tabletSection ?? .recent {
                    case .recent: recentAlbums
                    case .albums:
                        if library.connected { PhoneAlbumBrowser(library: library, detail: albumDetail) }
                        else { catalog }
                    case .hidden: PhoneAlbumBrowser(library: library, hidden: true, detail: albumDetail)
                    case .artists: artistList
                    case .songs: songList(library.catalogTracks).navigationTitle("曲")
                    case .search: search
                    case .settings: settings
                    case .playlists: PlaylistBrowser(library: library)
                    }
                }.id(tabletSection)
            }
        }
    }

    private var artistList: some View {
        List(library.artistNames, id: \.self) { artist in
            NavigationLink(artist) {
                artistDetail(artist)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
        .navigationTitle("アーティスト")
    }

    private func artistDetail(_ artist: String, origin: String? = nil) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 32) {
                        ForEach(library.albums(for: artist)) { album in
                            NavigationLink { AnyView(albumDetail(album)) } label: {
                                HStack(spacing: 20) {
                                    PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 80 : 128)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(album.title).font(.headline).foregroundStyle(AppearanceColors.primary)
                                        Text("\(album.tracks.count)曲").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("album-\(album.id)")
                            .id(album.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, origin == nil ? 20 : geometry.size.height / 2)
                }
                .task(id: origin) {
                    if let origin { proxy.scrollTo(origin, anchor: .center) }
                }
            }
        }
        .background(PhoneStyle.graphite)
        .navigationTitle(artist)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("ライブラリ", image: "regen-layers", value: PhoneTab.library) { NavigationStack { catalog } }
            Tab("設定", image: "regen-settings", value: PhoneTab.settings) { NavigationStack { settings } }
            Tab(value: PhoneTab.search, role: .search) { NavigationStack { search } } label: {
                Label("検索", image: "regen-search")
            }
        }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ライブラリ").font(.headline)
                VStack(spacing: 0) {
                    NavigationLink { recentAlbums } label: { categoryLabel("最近追加した項目", icon: "layers") }
                    NavigationLink {
                        artistList
                    } label: { categoryLabel("アーティスト", icon: "users") }
                    NavigationLink {
                        PhoneAlbumBrowser(library: library, detail: albumDetail)
                    } label: { categoryLabel("アルバム", icon: "layers") }
                    NavigationLink {
                        songList(library.catalogTracks).navigationTitle("曲")
                    } label: { categoryLabel("曲", icon: "music") }
                    NavigationLink {
                        PhoneAlbumBrowser(library: library, hidden: true, detail: albumDetail)
                    } label: { categoryLabel("非表示にしたアルバム", icon: "layers") }
                }
                .buttonStyle(.plain)
                Text("プレイリスト").font(.headline)
                NavigationLink { PlaylistBrowser(library: library) } label: { categoryLabel("すべてのプレイリスト", icon: "music") }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近追加した項目").font(.title3.bold())
                    if !library.connected {
                        Text("ライブラリに参加するか、この端末に音楽を追加して聴き始められます。")
                        NavigationLink("既存のライブラリに参加") {
                            ScrollView { PeerSetupView(transfer: library.transfer).padding(20) }
                                .navigationTitle("ライブラリに参加")
                        }
                        AddMusicButton(library: library)
                        if library.hasSavedLocalLibrary {
                            Button("保存した音楽を開く") { Task { await library.openSavedLocalLibrary() } }
                        }
                    } else if library.tracks.isEmpty {
                        Text("音楽はまだありません。音楽ファイルを追加できます。")
                        AddMusicButton(library: library)
                    }
                    recentAlbumGrid
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(PhoneStyle.graphite)
        .navigationTitle("ライブラリ")
        .toolbar {
            AddMusicButton(library: library)
        }
        .toolbarTitleDisplayMode(.inlineLarge)
        .refreshable { library.reload() }
    }

    private func categoryLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            RegenIcon(name: icon).foregroundStyle(PhoneStyle.signal)
            Text(title).font(.title3).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RegenIcon(name: "chevron-right").foregroundStyle(.secondary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var albumGrid: some View { albumGrid(library.albums) }

    private var recentAlbums: some View {
        ScrollView {
            recentAlbumGrid.padding(20)
        }
        .background(PhoneStyle.graphite)
        .navigationTitle("最近追加した項目")
    }

    private var recentAlbumGrid: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160), spacing: 20)], alignment: .leading, spacing: 32) {
            ForEach(library.recentlyAddedSections) { section in
                Section {
                    albumGridItems(section.albums)
                } header: {
                    Group {
                        if let month = section.month {
                            Text(month, format: .dateTime.year().month(.wide))
                        } else { Text("追加日不明") }
                    }.font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    private func albumGrid(_ albums: [Album], sorted: Bool = true) -> some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 32) {
            albumGridItems(sorted ? library.sortedAlbums(albums) : albums)
        }
    }

    private func albumGridItems(_ albums: [Album]) -> some View {
        ForEach(albums) { album in
            NavigationLink { albumDetail(album) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                    Text(album.title).font(.subheadline.bold()).foregroundStyle(AppearanceColors.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text(album.artist).font(.subheadline).foregroundStyle(PhoneStyle.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("album-\(album.id)")
            .contextMenu {
                Button(library.albumVisibilityLabel(album.id)) {
                    library.setAlbumHidden(album.id, hidden: !library.isAlbumHidden(album.id))
                }.disabled(library.isSavingAlbumVisibility(album.id))
            }
        }
    }

    private func albumDetail(_ album: Album) -> some View {
        return GeometryReader { geometry in
            List {
                let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(spacing: 20))
                let artworkSize = max(0, min(geometry.size.width - 80, dynamicTypeSize.isAccessibilitySize ? 120 : 320))
                layout {
                    PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                        .frame(width: artworkSize)
                    VStack(alignment: wide ? .leading : .center, spacing: 20) {
                        VStack(alignment: wide ? .leading : .center, spacing: 4) {
                            Text(album.title).font(.title3.bold())
                            if let artist = album.detailArtist, artist != "V.A.", !library.albums(for: artist).isEmpty {
                                PhoneArtistButton(name: artist) { AnyView(artistDetail(artist, origin: album.id)) }
                            } else {
                                Text(album.detailArtist ?? album.artist).font(.body).foregroundStyle(PhoneStyle.secondary)
                            }
                            Text("\(album.tracks.count)曲").font(.caption).foregroundStyle(PhoneStyle.secondary)
                        }
                        .multilineTextAlignment(wide ? .leading : .center)
                        if wide { Spacer(minLength: 20) }
                        HStack(spacing: 20) {
                            Button { library.startAlbum(album.tracks, shuffled: true) } label: {
                                Image(systemName: "shuffle").font(.system(size: 24)).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain).foregroundStyle(PhoneStyle.signal)
                            .accessibilityLabel("アルバムをシャッフル再生")
                            .accessibilityIdentifier("album-shuffle")
                            Button {
                                library.startAlbum(album.tracks)
                            } label: {
                                HStack(spacing: 8) {
                                    RegenIcon(name: "filled-play")
                                    Text("再生")
                                }
                                .frame(width: 176).frame(minHeight: 44)
                                .background(PhoneStyle.button, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .disabled(album.tracks.isEmpty)
                            .accessibilityLabel("再生")
                            .accessibilityIdentifier("album-play")
                            OfflineSaveControls(library: library, tracks: album.tracks, scope: "album:" + album.id, iconOnly: true)
                                .foregroundStyle(PhoneStyle.signal)
                                .accessibilityIdentifier("album-save")
                        }
                        .overlay(alignment: .bottom) {
                            if let request = library.saveRequest(for: album.tracks, scope: "album:" + album.id),
                               [.waiting, .wifi, .saving].contains(request.state) {
                                Text("\(album.tracks.filter { library.localFiles[$0.id] != nil }.count)/\(album.tracks.count)曲を保存済み")
                                    .font(.caption).foregroundStyle(.secondary).offset(y: 20)
                            }
                        }
                    }
                    .frame(minHeight: wide ? artworkSize : nil, alignment: .top)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, in: album.tracks, index: index + 1)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(library.current?.id == track.id ? PhoneStyle.button : Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PhoneStyle.graphite)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var search: some View {
        Group {
            if library.search.isEmpty {
                ContentUnavailableView {
                    Label { Text("音楽を検索") } icon: { RegenIcon(name: "search", size: 48) }
                } description: {
                    Text("曲、アルバム、アーティストを検索できます。")
                }
            } else if library.visibleTracks.isEmpty {
                ContentUnavailableView.search(text: library.search)
            } else {
                songList(library.visibleTracks)
            }
        }
        .navigationTitle("検索")
        .searchable(text: $library.search, prompt: "曲、アルバム、アーティスト")
        .searchFocused($searchFocused)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        .onDisappear { searchFocused = false }
        .background(PhoneStyle.graphite)
    }

    private func songList(_ tracks: [Track]) -> some View {
        List(tracks) { track in
            trackRow(track, in: tracks)
        }
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
    }

    private func trackRow(_ track: Track, in tracks: [Track], index: Int? = nil) -> some View {
        let current = library.current?.id == track.id
        let accented = current && index != nil
        return PhoneTrackRowSurface(selected: accented) { hovered in
            HStack(spacing: 8) {
                Button {
                    start(track, in: tracks)
                } label: {
                    HStack(spacing: 8) {
                        if let index {
                            Group {
                                if current && library.loading {
                                    ProgressView().tint(.white).accessibilityLabel(library.playbackLoadingLabel)
                                } else if current || hovered {
                                    RegenIcon(name: "filled-play").foregroundStyle(accented ? .white : PhoneStyle.signal)
                                } else { Text("\(index)").font(.subheadline).foregroundStyle(PhoneStyle.secondary) }
                            }
                            .frame(width: 24)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.callout)
                                .foregroundStyle(accented ? .white : current ? PhoneStyle.signal : AppearanceColors.primary)
                            Text(track.artist ?? "アーティスト不明")
                                .font(.subheadline).foregroundStyle(accented ? Color.white : PhoneStyle.secondary)
                        }
                        Spacer(minLength: 8)
                        if index == nil && library.current?.id == track.id {
                            if library.loading {
                                ProgressView().accessibilityLabel(library.playbackLoadingLabel)
                            } else {
                                RegenIcon(name: library.playing ? "activity" : "filled-pause")
                                    .accessibilityLabel(library.playing ? "再生中" : "選択中")
                            }
                        }
                        if index == nil, let duration = track.duration {
                            Text(time(duration)).font(.caption).monospacedDigit().foregroundStyle(PhoneStyle.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("track-\(track.id)")
                .accessibilityValue(library.current?.id == track.id ? (library.loading ? library.playbackLoadingLabel : library.playing ? "再生中" : "選択中") : "")
                OfflineSaveControls(library: library, tracks: [track], scope: "track:" + track.id, compact: true)
                    .buttonStyle(.borderless)
                    .foregroundStyle(accented ? Color.white : PhoneStyle.signal)
                    .tint(accented ? .white : PhoneStyle.signal)
            }
        }
        .contextMenu {
            if library.canRemoveLocalCopy(track) {
                Button("この端末の保存を解除", role: .destructive) { library.localCopiesToRemove = [track] }.disabled(library.transfer.busy)
            }
        }
    }

    private func miniPlayer(compact: Bool = false) -> some View {
        HStack(spacing: 8) {
            Button { library.showingNowPlaying = true } label: {
                HStack(spacing: 8) {
                    artwork(library.current?.coverArt, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(library.current?.title ?? "").fontWeight(.semibold).lineLimit(1)
                        if !compact && dynamicTypeSize <= .xLarge {
                            Text(library.loading ? library.playbackLoadingLabel : library.playbackFailure != nil ? "再生できません。詳細を確認" : library.current?.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.subheadline)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(library.current?.title ?? "")の再生中画面を開く")
            .accessibilityIdentifier("mini-player-open")
            .accessibilityValue(library.current?.artist ?? "")
            Button { library.togglePlayback() } label: {
                RegenIcon(name: !library.loading && library.playing ? "filled-pause" : "filled-play", size: 28)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(library.current == nil || library.loading)
            .accessibilityLabel(library.loading ? "再生" : library.playbackAction)
        }
        .padding(.horizontal, compact ? 8 : 16)
    }

    private var settings: some View {
        Form {
            Section { AppearanceSettings() }
            Section { PlaybackDiagnosticSettings(recorder: library.diagnostics) }
            Section { PlaybackStorageSettings(library: library) }
            Section("ライブラリと接続") { PeerSetupView(transfer: library.transfer) }
            Section { AddMusicButton(library: library) }
            if library.transfer.clusterRegistration == nil {
                Section("従来の接続") {
                    NavigationLink("従来の端末間転送") {
                        ScrollView { PhonePairingView(transfer: library.transfer).padding(20) }
                            .navigationTitle("従来の端末間転送")
                    }
                }
            }
            Section {
                LabeledContent("曲数", value: "\(library.tracks.count)")
                if library.connected && library.transfer.clusterRegistration == nil {
                    Button("ライブラリを閉じる") { library.closeLibrary() }
                } else if library.hasSavedLocalLibrary {
                    Button("保存した音楽を開く") { Task { await library.openSavedLocalLibrary() } }
                }
            } header: { Text("ライブラリ") } footer: { Text("保存した音楽は接続がなくても聴けます。") }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
        .navigationTitle("設定")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("ライブラリへ戻る") { tab = .library; tabletSection = .albums }
            }
        }
    }

    private func artwork(_ id: String?, size: CGFloat) -> some View {
        PhoneArtwork(url: id.flatMap { library.artworkURLs[$0] })
            .frame(width: size, height: size)
    }

    private func start(_ track: Track, in tracks: [Track]) {
        searchFocused = false
        library.play(track, in: tracks)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}

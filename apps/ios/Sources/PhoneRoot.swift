import SwiftUI

enum PhoneStyle {
    static let carbon = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
    static let graphite = Color(red: 35 / 255, green: 36 / 255, blue: 38 / 255)
    static let signal = Color(red: 82 / 255, green: 143 / 255, blue: 1)
    static let button = Color(red: 18 / 255, green: 83 / 255, blue: 1)
}

enum PhoneTab: Hashable { case library, search, settings }

private enum TabletSection: String, CaseIterable, Identifiable {
    case albums = "アルバム", artists = "アーティスト", songs = "曲"
    case hidden = "非表示にしたアルバム", search = "検索", settings = "設定"
    var id: Self { self }
    var icon: String {
        switch self {
        case .albums, .hidden: "layers"
        case .artists: "users"
        case .songs: "music"
        case .search: "search"
        case .settings: "settings"
        }
    }
}

struct PhoneRoot: View {
    @ObservedObject var library: Library
    @State private var tab = PhoneTab.library
    @State private var tabletSection: TabletSection? = .albums
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
                                    miniPlayer.padding(8).frame(maxWidth: 704)
                                        .glassEffect(.regular, in: Capsule()).padding(20)
                                }
                            }
                    } else {
                        tabs.tabViewBottomAccessory(isEnabled: library.current != nil) { miniPlayer }
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
            if connected { tab = .library; tabletSection = .albums }
        }
    }

    private var tabletNavigation: some View {
        NavigationSplitView {
            List(TabletSection.allCases, selection: $tabletSection) { section in
                Label { Text(section.rawValue) } icon: { RegenIcon(name: section.icon) }
                    .tag(section)
            }
            .navigationTitle("ライブラリ")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            .toolbar { AddMusicButton(library: library) }
        } detail: {
            NavigationStack {
                Group {
                    switch tabletSection ?? .albums {
                    case .albums:
                        if library.connected { PhoneAlbumBrowser(library: library, detail: albumDetail) }
                        else { catalog }
                    case .hidden: PhoneAlbumBrowser(library: library, hidden: true, detail: albumDetail)
                    case .artists: artistList
                    case .songs: songList(library.catalogTracks).navigationTitle("曲")
                    case .search: search
                    case .settings: settings
                    }
                }.id(tabletSection)
            }
        }
    }

    private var artistList: some View {
        List(library.artistNames, id: \.self) { artist in
            NavigationLink(artist) {
                songList(library.tracks(for: artist)).navigationTitle(artist)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
        .navigationTitle("アーティスト")
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack { catalog }
                .tabItem { Label("ライブラリ", image: "regen-layers") }
                .tag(PhoneTab.library)
            NavigationStack { search }
                .tabItem { Label("検索", image: "regen-search") }
                .tag(PhoneTab.search)
            NavigationStack { settings }
                .tabItem { Label("設定", image: "regen-settings") }
                .tag(PhoneTab.settings)
        }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("アルバム").font(.title3.bold())
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
                    albumGrid
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

    private func albumGrid(_ albums: [Album]) -> some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 32) {
            ForEach(library.sortedAlbums(albums)) { album in
                NavigationLink { albumDetail(album) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                        Text(album.title).font(.subheadline.bold()).foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(library.albumVisibilityLabel(album.id)) {
                        library.setAlbumHidden(album.id, hidden: !library.isAlbumHidden(album.id))
                    }.disabled(library.isSavingAlbumVisibility(album.id))
                }
            }
        }
    }

    private func albumDetail(_ album: Album) -> some View {
        return GeometryReader { geometry in
            List {
                let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
                let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 32)) : AnyLayout(VStackLayout(spacing: 20))
                layout {
                    PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                        .frame(width: max(0, min(geometry.size.width - 80, dynamicTypeSize.isAccessibilitySize ? 120 : 320)))
                    VStack(alignment: wide ? .leading : .center, spacing: 20) {
                        VStack(alignment: wide ? .leading : .center, spacing: 4) {
                            Text(album.title).font(.title3.bold())
                            Text(album.detailArtist ?? album.artist).font(.body)
                                .foregroundStyle(album.detailArtist == "V.A." ? .secondary : PhoneStyle.signal)
                            Text("\(album.tracks.count)曲").font(.caption).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(wide ? .leading : .center)
                        HStack(spacing: 20) {
                            Button {
                                library.togglePlayback(in: album.tracks)
                            } label: {
                                HStack(spacing: 8) {
                                    RegenIcon(name: "filled-play")
                                    Text("再生")
                                }
                                .frame(minWidth: 160, minHeight: 44)
                                .background(PhoneStyle.button, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .disabled(album.tracks.isEmpty)
                            .accessibilityLabel("再生")
                            OfflineSaveControls(library: library, tracks: album.tracks, scope: "album:" + album.id, iconOnly: true)
                        }
                    }
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
                                } else { Text("\(index)").font(.subheadline).foregroundStyle(.secondary) }
                            }
                            .frame(width: 24)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.callout)
                                .foregroundStyle(accented ? .white : current ? PhoneStyle.signal : .primary)
                            Text(track.artist ?? "アーティスト不明")
                                .font(.subheadline).foregroundStyle(accented ? Color.white : .secondary)
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
                            Text(time(duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
                    .tint(accented ? .white : PhoneStyle.signal)
            }
        }
        .contextMenu {
            if library.canRemoveLocalCopy(track) {
                Button("この端末の保存を解除", role: .destructive) { library.localCopiesToRemove = [track] }.disabled(library.transfer.busy)
            }
        }
    }

    private var miniPlayer: some View {
        HStack(spacing: 8) {
            Button { library.showingNowPlaying = true } label: {
                HStack(spacing: 8) {
                    artwork(library.current?.coverArt, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(library.current?.title ?? "").fontWeight(.semibold).lineLimit(1)
                        if dynamicTypeSize <= .xLarge {
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
            .accessibilityValue(library.current?.artist ?? "")
            Button { library.togglePlayback() } label: {
                RegenIcon(name: !library.loading && library.playing ? "filled-pause" : "filled-play", size: 28)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(library.current == nil || library.loading)
            .accessibilityLabel(library.loading ? "再生" : library.playbackAction)
        }
        .padding(.horizontal, 16)
    }

    private var settings: some View {
        Form {
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

import SwiftUI

enum PhoneStyle {
    static let carbon = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
    static let graphite = Color(red: 35 / 255, green: 36 / 255, blue: 38 / 255)
    static let signal = Color(red: 82 / 255, green: 143 / 255, blue: 1)
    static let button = Color(red: 18 / 255, green: 83 / 255, blue: 1)
}

enum PhoneTab: Hashable { case library, search, playing, settings }

struct PhoneRoot: View {
    @ObservedObject var library: Library
    @State private var tab = PhoneTab.library
    @State private var showingPlayer = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            if library.connected {
                tabs.tabViewBottomAccessory(isEnabled: library.current != nil && tab != .playing) { miniPlayer }
            } else if library.restoringSession {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("ライブラリに接続中…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                login
            }
        }
        .background(PhoneStyle.graphite)
        .sheet(isPresented: $showingPlayer) {
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
            if !connected { tab = .library }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack { catalog }
                .tabItem { Label("ライブラリ", image: "regen-layers") }
                .tag(PhoneTab.library)
            NavigationStack { search }
                .tabItem { Label("検索", image: "regen-search") }
                .tag(PhoneTab.search)
            NavigationStack { PhoneNowPlaying(library: library) }
                .tabItem { Label("再生中", image: "regen-circle-play") }
                .tag(PhoneTab.playing)
            NavigationStack { settings }
                .tabItem { Label("設定", image: "regen-settings") }
                .tag(PhoneTab.settings)
        }
    }

    private var login: some View {
        NavigationStack {
            Form {
                Section {
                    Text("NAS の音楽を、この iPhone で。")
                        .font(.title2).fontWeight(.regular)
                    Text("Navidrome のアカウントで接続します。")
                        .foregroundStyle(.secondary)
                }
                Section("接続先") {
                    TextField("サーバーURL", text: $library.server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("server")
                    TextField("ユーザー名", text: $library.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("username")
                    SecureField("パスワード", text: $library.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("password")
                }
                Section {
                    Button {
                        library.connect(server: library.server, username: library.username, password: library.password)
                    } label: {
                        HStack {
                            Spacer()
                            if library.refreshing { ProgressView() }
                            Text(library.refreshing ? "接続中…" : "ログイン")
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PhoneStyle.button)
                    .disabled(library.refreshing || library.username.isEmpty || library.password.isEmpty)
                    .accessibilityIdentifier("login")
                } footer: {
                    Text("ログイン情報はこの iPhone の Keychain に保存し、次回から自動で接続します。")
                }
            }
            .disabled(library.refreshing)
            .scrollContentBackground(.hidden)
            .background(PhoneStyle.graphite)
            .navigationTitle("syncstr")
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    NavigationLink {
                        List(library.artists, id: \.self) { artist in
                            NavigationLink(artist) {
                                songList(library.tracks.filter { ($0.artist ?? "アーティスト不明") == artist })
                                    .navigationTitle(artist)
                            }
                        }
                        .navigationTitle("アーティスト")
                    } label: { categoryLabel("アーティスト", icon: "users") }
                    NavigationLink {
                        ScrollView { albumGrid.padding(20) }
                            .background(PhoneStyle.graphite).navigationTitle("アルバム")
                    } label: { categoryLabel("アルバム", icon: "layers") }
                    NavigationLink {
                        songList(library.tracks).navigationTitle("曲")
                    } label: { categoryLabel("曲", icon: "music") }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 8) {
                    Text("アルバム").font(.title3.bold())
                    if library.albums.isEmpty { Text("音楽はまだありません。NAS へ音源を追加してください。") }
                    albumGrid
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(PhoneStyle.graphite)
        .navigationTitle("ライブラリ")
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

    private var albumGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
            ForEach(library.albums) { album in
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
            }
        }
    }

    private func albumDetail(_ album: Album) -> some View {
        GeometryReader { geometry in
            List {
                VStack(spacing: 0) {
                    PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                        .frame(width: max(0, min(geometry.size.width - 128, dynamicTypeSize.isAccessibilitySize ? 120 : 320)))
                        .padding(.bottom, 20)
                    VStack(spacing: 4) {
                        Text(album.title).font(.title3.bold())
                        Text(album.artist).font(.body).foregroundStyle(PhoneStyle.signal)
                        Text("\(album.tracks.count)曲").font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
                    Button {
                        if let first = album.tracks.first { start(first, in: album.tracks) }
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
                    .accessibilityLabel("アルバムを先頭から再生")
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
                        .listRowBackground(Color.clear)
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
        HStack(spacing: 8) {
            Button {
                start(track, in: tracks)
            } label: {
                HStack(spacing: 8) {
                    if let index {
                        Group {
                            if library.current?.id == track.id {
                                RegenIcon(name: library.playing ? "activity" : "filled-pause")
                                    .foregroundStyle(PhoneStyle.signal)
                            } else { Text("\(index)").font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .frame(width: 24)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.callout)
                            .foregroundStyle(library.current?.id == track.id ? PhoneStyle.signal : .primary)
                        Text(track.artist ?? "アーティスト不明")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if index == nil && library.current?.id == track.id {
                        if library.loading {
                            ProgressView().accessibilityLabel("再生を準備中")
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
            .accessibilityValue(library.current?.id == track.id ? (library.loading ? "再生を準備中" : library.playing ? "再生中" : "選択中") : "")
            if library.downloading.contains(track.id) {
                ProgressView().frame(width: 44, height: 44)
                    .accessibilityLabel("ダウンロード中")
            } else if library.downloaded.contains(track.id) {
                Image("regen-circle-check").renderingMode(.template)
                    .resizable().frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("ダウンロード済み")
            } else {
                Button { library.download(track) } label: {
                    Image("regen-cloud-download").renderingMode(.template)
                        .resizable().frame(width: 24, height: 24)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(track.title)、未ダウンロード。端末に保存")
            }
        }
    }

    private var miniPlayer: some View {
        HStack(spacing: 8) {
            Button { showingPlayer = true } label: {
                HStack(spacing: 8) {
                    artwork(library.current?.coverArt, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(library.current?.title ?? "").fontWeight(.semibold).lineLimit(1)
                        if dynamicTypeSize <= .xLarge {
                            Text(library.current?.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
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
                RegenIcon(name: library.playing || library.loading ? "filled-pause" : "filled-play", size: 28)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(library.playing || library.loading ? "一時停止" : "再生")
        }
        .padding(.horizontal, 16)
    }

    private var settings: some View {
        Form {
            Section("接続") {
                LabeledContent("サーバー", value: library.server)
                LabeledContent("ユーザー", value: library.username)
                LabeledContent("曲数", value: "\(library.tracks.count)")
                Button("ライブラリを再読み込み") { library.reload() }.disabled(library.refreshing)
            }
            Section {
                Button("ログアウト", role: .destructive) { library.disconnect() }
            } footer: { Text("この iPhone に保存したログイン情報を削除します。") }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
        .navigationTitle("設定")
    }

    private func artwork(_ id: String?, size: CGFloat) -> some View {
        PhoneArtwork(url: id.flatMap { library.artworkURLs[$0] })
            .frame(width: size, height: size)
    }

    private func start(_ track: Track, in tracks: [Track]) {
        library.play(track, in: tracks)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}

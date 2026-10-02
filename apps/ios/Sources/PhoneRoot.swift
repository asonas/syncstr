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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            if library.connected {
                if #available(iOS 26.1, *) {
                    tabs.tabViewBottomAccessory(isEnabled: library.current != nil && tab != .playing) { miniPlayer }
                } else if library.current != nil && tab != .playing {
                    tabs.tabViewBottomAccessory { miniPlayer }
                } else {
                    tabs
                }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = library.message {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 20))
                            .accessibilityHidden(true)
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
                .tabItem { Label("ライブラリ", systemImage: "square.stack") }
                .tag(PhoneTab.library)
            NavigationStack { search }
                .tabItem { Label("検索", systemImage: "magnifyingglass") }
                .tag(PhoneTab.search)
            NavigationStack { nowPlaying }
                .tabItem { Label("再生中", systemImage: "play.circle") }
                .tag(PhoneTab.playing)
            NavigationStack { settings }
                .tabItem { Label("設定", systemImage: "gearshape") }
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
        List {
            Section {
                NavigationLink {
                    songList(library.tracks).navigationTitle("曲")
                } label: { Label("曲", systemImage: "music.note.list") }
                NavigationLink {
                    List(library.artists, id: \.self) { artist in
                        NavigationLink(artist) {
                            songList(library.tracks.filter { ($0.artist ?? "アーティスト不明") == artist })
                                .navigationTitle(artist)
                        }
                    }
                    .navigationTitle("アーティスト")
                } label: { Label("アーティスト", systemImage: "person.2") }
            }
            Section("アルバム") {
                if library.albums.isEmpty { Text("音楽はまだありません。NAS へ音源を追加してください。") }
                ForEach(library.albums) { album in
                    NavigationLink {
                        songList(album.tracks)
                            .navigationTitle(album.title)
                    } label: {
                        HStack(spacing: 16) {
                            artwork(album.coverArt, size: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(album.title).font(.headline).fontWeight(.regular)
                                Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                                Text("\(album.tracks.count)曲").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
        .navigationTitle("ライブラリ")
        .refreshable { library.reload() }
        .toolbar {
            Button { library.reload() } label: {
                if library.refreshing { ProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(library.refreshing)
            .accessibilityLabel("ライブラリを再読み込み")
        }
    }

    private var search: some View {
        Group {
            if library.search.isEmpty {
                ContentUnavailableView("音楽を検索", systemImage: "magnifyingglass", description: Text("曲、アルバム、アーティストを検索できます。"))
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
            HStack(spacing: 8) {
                Button {
                    start(track, in: tracks)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.title).foregroundStyle(.primary)
                            Text(track.artist ?? "アーティスト不明")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if library.current?.id == track.id {
                            if library.loading {
                                ProgressView().accessibilityLabel("再生を準備中")
                            } else {
                                Image(systemName: library.playing ? "speaker.wave.2" : "pause.circle")
                                    .accessibilityLabel(library.playing ? "再生中" : "選択中")
                            }
                        }
                        if let duration = track.duration {
                            Text(time(duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("track-\(track.id)")
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
        .scrollContentBackground(.hidden)
        .background(PhoneStyle.graphite)
    }

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            Button { tab = .playing } label: {
                HStack(spacing: 12) {
                    artwork(library.current?.coverArt, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.current?.title ?? "").lineLimit(1)
                        Text(library.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(library.current?.title ?? "")の再生中画面を開く")
            playbackButton
        }
        .padding(12)
        .background(PhoneStyle.carbon)
    }

    private var nowPlaying: some View {
        GeometryReader { geometry in
            ScrollView {
                if let track = library.current {
                    VStack(alignment: .leading, spacing: 24) {
                        artwork(track.coverArt, size: min(dynamicTypeSize.isAccessibilitySize ? 120 : 240, max(0, geometry.size.width - 48)))
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(track.title).font(.title).fontWeight(.regular)
                            Text(track.artist ?? "アーティスト不明").foregroundStyle(.secondary)
                            if let album = track.album { Text(album).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        VStack(spacing: 8) {
                            Slider(value: Binding(get: { library.position }, set: { library.seek(to: $0) }), in: 0...max(library.duration, 1))
                                .disabled(library.duration <= 0)
                                .accessibilityLabel("再生位置")
                                .accessibilityValue("\(time(library.position)) / \(time(library.duration))")
                            HStack {
                                Text(time(library.position))
                                Spacer()
                                Text(time(library.duration))
                            }
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if library.loading { ProgressView("読み込み中…") }
                    }
                    .frame(width: max(0, geometry.size.width - 48), alignment: .leading)
                    .padding(24)
                } else {
                    ContentUnavailableView("曲を選んでください", systemImage: "music.note", description: Text("ライブラリまたは検索から音楽を選べます。"))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if library.current != nil {
                HStack(spacing: 16) {
                    Spacer(minLength: 0)
                    Button { library.previous() } label: {
                        Image(systemName: "backward.end.fill").frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(!library.canGoPrevious).accessibilityLabel("前の曲")
                    playbackButton
                    Button { library.next() } label: {
                        Image(systemName: "forward.end.fill").frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(!library.canGoNext).accessibilityLabel("次の曲")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 24))
                .buttonStyle(.bordered)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(PhoneStyle.graphite)
            }
        }
        .background(PhoneStyle.graphite)
        .navigationTitle("再生中")
    }

    private var playbackButton: some View {
        Button {
            library.togglePlayback()
        } label: {
            Image(systemName: library.playing || library.loading ? "pause.fill" : "play.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(library.playing || library.loading ? "一時停止" : "再生")
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
        AsyncImage(url: id.flatMap { library.artworkURLs[$0] }) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PhoneStyle.carbon)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
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

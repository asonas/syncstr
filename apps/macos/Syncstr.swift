import SwiftUI
import UniformTypeIdentifiers

enum Studio {
    static let carbon = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
    static let graphite = Color(red: 35 / 255, green: 36 / 255, blue: 38 / 255)
    static let iron = Color(red: 69 / 255, green: 70 / 255, blue: 77 / 255)
    static let fog = Color(red: 166 / 255, green: 168 / 255, blue: 173 / 255)
    static let signal = Color(red: 82 / 255, green: 143 / 255, blue: 1)
    static let button = Color(red: 18 / 255, green: 83 / 255, blue: 1)
}

struct StudioButton: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .foregroundStyle(enabled ? Color.white : Studio.fog)
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
    @State private var showingPairing = false
    @State private var importingAudio = false
    @State private var showingPeerSetup = false
    @State private var showingUploadStatus = false
    @State private var hoveredTrack: String?

    var body: some View {
        VStack(spacing: 0) {
            if library.connected {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Studio.iron).frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            playbackBar.padding(.horizontal, 20).padding(.bottom, 20)
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
                    Text("音楽フォルダを選ぶと、このMacで聴いたり、iPhoneへ持ち出したりできます。")
                    LocalFolderButton(library: library).buttonStyle(.borderedProminent)
                    if library.hasSavedLocalLibrary {
                        Button("前の音楽フォルダを開く") { Task { await library.openSavedLocalLibrary() } }
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = library.message ?? (showingUploadStatus ? library.transfer.status : nil) {
                HStack(alignment: .top, spacing: 8) {
                    MacIcon("circle-alert").accessibilityHidden(true)
                    Text(message).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(Studio.graphite)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 14))
        .tracking(-0.21)
        .foregroundStyle(.white)
        .background(Studio.graphite)
        .tint(Studio.signal)
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 560)
        .navigationTitle("")
        .focusedSceneObject(library)
        .toolbar {
            if library.connected {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySearchField(text: $library.search, placeholder: "\(library.destination.rawValue)を検索")
                        .frame(width: 280)
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { await library.restoreLibrary() }
        .sheet(isPresented: $showingPairing) {
            MacPairingView(transfer: library.transfer) { Task { await library.startPairing() } }
        }
        .sheet(isPresented: $showingPeerSetup) {
            ScrollView { PeerSetupView(transfer: library.transfer).padding(24) }
                .frame(width: 500, height: 600)
                .toolbar { Button("閉じる") { showingPeerSetup = false } }
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files):
                showingUploadStatus = true
                library.transfer.uploadPeer(files: files)
            case .failure(let error): library.message = error.localizedDescription
            }
        }
    }

    private var rule: some View { Rectangle().fill(Studio.iron).frame(height: 1) }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LibraryDestination.allCases, id: \.self) { destination in
                Button { library.navigate(destination); library.search = "" } label: {
                    HStack(spacing: 8) {
                        MacIcon(destination == .albums ? "layers" : destination == .artists ? "users" : "music")
                        Text(destination.rawValue)
                    }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(library.destination == destination && !library.showingNowPlaying ? Studio.graphite : Color.clear)
                        .foregroundStyle(library.destination == destination && !library.showingNowPlaying ? Studio.signal : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityAddTraits(library.destination == destination && !library.showingNowPlaying ? .isSelected : [])
            }
            rule.padding(.vertical, 16)
            Button {
                if library.transfer.peerConnected { importingAudio = true }
                else { showingPeerSetup = true }
            } label: {
                HStack(spacing: 8) { MacIcon("cloud-upload"); Text("音源ファイルを追加") }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(library.transfer.busy)
            .help("P2Pの接続先に音源ファイルを追加します")
            if showingUploadStatus && library.transfer.busy {
                ProgressView(value: library.transfer.progress).padding(.horizontal, 8)
                Button("中断する") { library.transfer.cancel() }.buttonStyle(.plain).padding(.horizontal, 8)
            }
            Button { showingPairing = true } label: {
                HStack(spacing: 8) { MacIcon("cloud-upload"); Text("iPhoneに転送") }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("iPhoneに音楽を転送")
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
        if library.showingNowPlaying && library.search.isEmpty {
            nowPlaying
        } else if library.search.isEmpty, let albumID = library.selectedAlbum,
                  let album = library.albums.first(where: { $0.id == albumID }) {
            albumDetail(album)
        } else {
            switch library.destination {
            case .albums: albums
            case .artists: artists
            case .songs: songs
            }
        }
    }

    private var albums: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20, alignment: .top)],
                      alignment: .leading, spacing: 32) {
                ForEach(library.visibleAlbums) { album in
                    Button { library.selectedAlbum = album.id; library.search = "" } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Artwork(url: artworkURL(album.coverArt))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(album.title).font(.system(size: 14)).lineLimit(2)
                                Text(album.artist).font(.system(size: 12)).foregroundStyle(Studio.fog).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(album.title)\n\(album.artist)")
                    .accessibilityLabel("\(album.title)、\(album.artist)")
                }
            }.padding(32)
            if library.visibleAlbums.isEmpty {
                Text(library.search.isEmpty ? "アルバムがありません。" : "一致するアルバムがありません。")
                    .foregroundStyle(Studio.fog).padding(32)
            }
        }.safeAreaPadding(.bottom, 120)
    }

    private func albumDetail(_ album: Album) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    backButton("アルバムへ戻る") { library.selectedAlbum = nil }
                    let wide = geometry.size.width >= 640
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                                      : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                    layout {
                        Artwork(url: artworkURL(album.coverArt)).frame(width: wide ? 272 : 200, height: wide ? 272 : 200)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(album.title).font(.system(size: 28, weight: .semibold))
                                .padding(.top, wide ? 48 : 0)
                                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                            Button { showArtist(album.artist) } label: {
                                Text(album.artist).font(.system(size: 20)).foregroundStyle(Studio.signal)
                            }.buttonStyle(.plain)
                            Text("\(album.tracks.count)曲").font(.system(size: 12)).foregroundStyle(Studio.fog)
                            Spacer(minLength: 20)
                            playButton(album.tracks)
                            if library.transfer.peerConnected {
                                Button("アルバムを保存") { library.transfer.copy(album.tracks) }
                                    .buttonStyle(.bordered).disabled(library.transfer.busy)
                                if library.transfer.busy { ProgressView(value: library.transfer.progress) }
                                if let status = library.transfer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
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
                                        .frame(width: 32, height: 32).background(Studio.iron, in: Circle())
                                    Text(artist).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 48)
                                .background(library.selectedArtist == artist ? Studio.button : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
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
        let albums = library.albums.filter { $0.tracks.contains { ($0.artist ?? "アーティスト不明") == artist } }
        let tracks = albums.flatMap { $0.tracks.filter { ($0.artist ?? "アーティスト不明") == artist } }
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
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
                                trackRows(album.tracks.filter { ($0.artist ?? "アーティスト不明") == artist }, showArtist: false)
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
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(library.visibleTracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, index: index, tracks: library.visibleTracks, showArtist: wide,
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
                if library.visibleTracks.isEmpty { Text("一致する曲がありません。").foregroundStyle(Studio.fog).padding(32) }
            }.safeAreaPadding(.bottom, 120)
        }
    }

    private func trackRows(_ tracks: [Track], showArtist: Bool = true, preservingQueue: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track, index: index, tracks: preservingQueue ? nil : tracks, showArtist: showArtist)
                    .overlay(alignment: .bottom) { rule }
            }
        }
    }

    private func trackRow(_ track: Track, index: Int, tracks: [Track]?, showArtist: Bool,
                          showAlbum: Bool = false, dense: Bool = false, striped: Bool = false) -> some View {
        HStack(spacing: 16) {
            Button { library.play(track, in: tracks) } label: {
                HStack(spacing: 16) {
                    if !dense {
                        Group {
                            if library.current?.id == track.id { MacIcon("activity") }
                            else { Text("\(index + 1)").foregroundStyle(Studio.fog) }
                        }.frame(width: 24).accessibilityHidden(true)
                    }
                    Text(track.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if showArtist {
                        Text(track.artist ?? "アーティスト不明").foregroundStyle(Studio.fog)
                            .font(.system(size: showAlbum ? 14 : 12)).lineLimit(1)
                            .frame(width: showAlbum ? nil : 280, alignment: .leading)
                            .frame(maxWidth: showAlbum ? .infinity : nil, alignment: .leading)
                    }
                    if showAlbum {
                        Text(track.album ?? "アルバム名不明").foregroundStyle(Studio.fog)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(time(track.duration ?? 0)).monospacedDigit().foregroundStyle(Studio.fog)
                        .font(.system(size: 12))
                        .frame(width: 40, alignment: .trailing)
                }.frame(maxWidth: .infinity, minHeight: dense ? 32 : 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(track.title)、\(track.artist ?? "アーティスト不明")、\(time(track.duration ?? 0))")
                .accessibilityAddTraits(library.current?.id == track.id ? .isSelected : [])
            Menu {
                Button("再生") { library.play(track, in: tracks) }
                if library.transfer.peerConnected {
                    Button("曲を保存") { library.transfer.copy([track]) }.disabled(library.transfer.busy)
                }
                Button("アルバムを表示") { library.selectedAlbum = track.albumKey; library.search = ""; library.showingNowPlaying = false }
                Button("アーティストを表示") { self.showArtist(track.artist ?? "アーティスト不明") }
            } label: { Text("\(track.title)のその他の操作").hidden().frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32, height: 32)
            .overlay { MacIcon("dots").foregroundStyle(Studio.fog).allowsHitTesting(false) }
            .accessibilityLabel("\(track.title)のその他の操作")
        }
        .font(.system(size: 14))
        .foregroundStyle(library.current?.id == track.id ? Studio.signal : Color.white)
        .padding(.horizontal, 8)
        .background(library.current?.id == track.id ? Studio.iron : striped || hoveredTrack == track.id ? Studio.carbon : Color.clear,
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
        let active = (library.playing || library.loading) && tracks.contains { $0.id == library.current?.id }
        return Button { library.togglePlayback(in: tracks) } label: {
            HStack(spacing: 8) {
                MacIcon(active ? "filled-pause" : "filled-play", size: 16)
                Text(active ? "一時停止" : "再生")
            }
                .frame(width: 128, height: 36)
                .background(Studio.button, in: RoundedRectangle(cornerRadius: 8))
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
        Button { library.showingNowPlaying = true; library.search = "" } label: {
            HStack(spacing: 8) {
                Artwork(url: artworkURL(library.current?.coverArt)).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.current?.title ?? "曲を選んでください").font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let artist = library.current?.artist {
                        Text(artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
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
                MacIcon(library.playing ? "filled-pause" : "filled-play", size: 24).frame(width: 32, height: 32).contentShape(Rectangle())
            }.disabled(library.current == nil).accessibilityLabel(library.playing ? "一時停止" : "再生")
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
            .disabled(library.current == nil || library.duration <= 0)
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
        let field = NSSearchField()
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func search(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
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
        .accessibilityHidden(true)
    }
}

@main
struct SyncstrApp: App {
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup("syncstr") { LibraryView(library: library) }
            .defaultSize(width: 1080, height: 740)
            .windowToolbarStyle(.unifiedCompact)
            .commands { PlaybackCommands() }
        Settings { SettingsView(library: library) }
    }
}

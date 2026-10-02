import SwiftUI

private enum Studio {
    static let carbon = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
    static let graphite = Color(red: 35 / 255, green: 36 / 255, blue: 38 / 255)
    static let iron = Color(red: 69 / 255, green: 70 / 255, blue: 77 / 255)
    static let fog = Color(red: 166 / 255, green: 168 / 255, blue: 173 / 255)
    static let signal = Color(red: 82 / 255, green: 143 / 255, blue: 1)
    static let button = Color(red: 18 / 255, green: 83 / 255, blue: 1)
}

private struct StudioButton: ButtonStyle {
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

private struct StudioInput: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Studio.carbon)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focused ? Studio.signal : Studio.iron, lineWidth: focused ? 2 : 1)
            }
    }
}

struct LibraryView: View {
    @StateObject private var library = Library()
    @State private var showingUpload = false

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            if library.connected {
                HStack(spacing: 0) {
                    if library.sidebarVisible {
                        sidebar
                        Rectangle().fill(Studio.iron).frame(width: 1)
                    }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if library.restoringSession {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("ライブラリに接続中…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { login }
            if let message = library.message {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(message).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(Studio.graphite)
                .accessibilityElement(children: .combine)
            }
            rule
            playbackBar
        }
        .font(.system(size: 14))
        .tracking(-0.21)
        .foregroundStyle(.white)
        .background(Studio.graphite)
        .tint(Studio.signal)
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 560)
        .navigationTitle("syncstr")
        .task { await library.restoreCredentials() }
        .sheet(isPresented: $showingUpload) { UploadView() }
    }

    private var rule: some View { Rectangle().fill(Studio.iron).frame(height: 1) }

    private var header: some View {
        HStack(spacing: 16) {
            Text("syncstr").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
            if library.connected {
                Button { library.sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.left").frame(width: 32, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("サイドバーを開閉")
                .help("サイドバーを開閉")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Studio.fog)
                    TextField("曲、アルバム、アーティストを検索", text: $library.search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("ライブラリを検索")
                    if !library.search.isEmpty {
                        Button { library.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("検索をクリア")
                    }
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Studio.carbon)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Studio.iron, lineWidth: 1) }
                .frame(maxWidth: 400)
                Spacer(minLength: 0)
                Button(action: library.reload) { Image(systemName: "arrow.clockwise") }
                    .disabled(library.refreshing)
                    .buttonStyle(StudioButton(primary: false))
                    .accessibilityLabel("再読み込み").help("再読み込み")
                Button(action: library.disconnect) { Image(systemName: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(StudioButton(primary: false))
                    .accessibilityLabel("ログアウト").help("ログアウトして保存情報を削除")
            } else {
                Spacer()
                Text("音楽ライブラリ").foregroundStyle(Studio.fog)
            }
            Button { showingUpload = true } label: { Image(systemName: "arrow.up.doc") }
                .buttonStyle(StudioButton(primary: false))
                .accessibilityLabel("音楽をアップロード").help("音楽をアップロード")
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color.black)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ライブラリ")
                .font(.system(size: 12)).foregroundStyle(Studio.fog)
                .padding(.horizontal, 12).padding(.bottom, 8)
            ForEach(LibraryDestination.allCases, id: \.self) { destination in
                Button { library.navigate(destination); library.search = "" } label: {
                    Label(destination.rawValue, systemImage: destination.symbol)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(library.destination == destination && !library.showingNowPlaying ? Studio.graphite : Color.clear)
                        .foregroundStyle(library.destination == destination && !library.showingNowPlaying ? Studio.signal : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityAddTraits(library.destination == destination && !library.showingNowPlaying ? .isSelected : [])
            }
            rule.padding(.vertical, 16)
            Button { library.showingNowPlaying = true; library.search = "" } label: {
                Label("再生中", systemImage: "waveform")
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 12)
                    .foregroundStyle(library.showingNowPlaying ? Studio.signal : Studio.fog)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(library.current == nil)
            Spacer()
            Text("\(library.tracks.count)曲")
                .font(.system(size: 12)).foregroundStyle(Studio.fog).padding(12)
        }
        .padding(.horizontal, 12).padding(.top, 28)
        .frame(width: 176)
        .background(Studio.carbon)
    }

    @ViewBuilder
    private var content: some View {
        if !library.search.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                pageTitle("検索結果", detail: "\(library.visibleTracks.count)曲")
                trackRows(library.visibleTracks)
            }
        } else if library.showingNowPlaying {
            nowPlaying
        } else if let albumID = library.selectedAlbum,
                  let album = library.albums.first(where: { $0.id == albumID }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { library.selectedAlbum = nil } label: { Label("アルバムへ戻る", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Studio.signal).padding([.top, .horizontal], 24)
                HStack(spacing: 20) {
                    Artwork(url: artworkURL(album.coverArt)).frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(album.title).font(.system(size: 28, weight: .regular)).tracking(-0.42)
                            .accessibilityAddTraits(.isHeader)
                        Text(album.artist).foregroundStyle(Studio.fog)
                        Text("\(album.tracks.count)曲").font(.system(size: 12)).foregroundStyle(Studio.fog)
                    }
                    Spacer(minLength: 0)
                }.padding(24)
                trackRows(album.tracks)
            }
        } else if let artist = library.selectedArtist {
            VStack(alignment: .leading, spacing: 0) {
                Button { library.selectedArtist = nil } label: { Label("アーティストへ戻る", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Studio.signal).padding([.top, .horizontal], 24)
                pageTitle(artist, detail: "\(library.visibleTracks.count)曲")
                trackRows(library.visibleTracks)
            }
        } else {
            switch library.destination {
            case .albums:
                VStack(alignment: .leading, spacing: 0) {
                    pageTitle("アルバム", detail: "\(library.albums.count)枚")
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 20)], alignment: .leading, spacing: 24) {
                            ForEach(library.albums) { album in
                                Button { library.selectedAlbum = album.id } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Artwork(url: artworkURL(album.coverArt))
                                        Text(album.title).font(.system(size: 16)).lineLimit(2)
                                        Text(album.artist).font(.system(size: 12)).foregroundStyle(Studio.fog).lineLimit(1)
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Studio.carbon)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Studio.iron, lineWidth: 1) }
                                }.buttonStyle(.plain)
                            }
                        }.padding([.horizontal, .bottom], 24)
                        if library.albums.isEmpty { emptyLibrary }
                    }
                }
            case .artists:
                VStack(alignment: .leading, spacing: 0) {
                    pageTitle("アーティスト", detail: "\(library.artists.count)組")
                    List(library.artists, id: \.self) { artist in
                        Button { library.selectedArtist = artist } label: {
                            HStack {
                                Image(systemName: "person.crop.circle").foregroundStyle(Studio.fog)
                                Text(artist)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Studio.fog)
                            }.padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain).listRowBackground(Color.clear)
                    }.listStyle(.plain).scrollContentBackground(.hidden).padding(.horizontal, 16)
                }
            case .songs:
                VStack(alignment: .leading, spacing: 0) {
                    pageTitle("曲", detail: "\(library.tracks.count)曲")
                    trackRows(library.tracks)
                }
            }
        }
    }

    private func pageTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 32, weight: .regular)).tracking(-0.48)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if library.refreshing { ProgressView().controlSize(.small) }
            Text(detail).foregroundStyle(Studio.fog)
        }.padding(24)
    }

    private func trackRows(_ tracks: [Track], preservingQueue: Bool = false) -> some View {
        List(tracks) { track in
            Button { library.play(track, in: preservingQueue ? nil : tracks) } label: {
                HStack(spacing: 12) {
                    Image(systemName: library.current?.id == track.id && library.playing ? "speaker.wave.2" : "music.note")
                        .foregroundStyle(library.current?.id == track.id ? Studio.signal : Studio.fog)
                        .frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title).font(.system(size: 15)).lineLimit(2)
                        Text(track.artist ?? "アーティスト不明").font(.system(size: 12)).foregroundStyle(Studio.fog)
                    }
                    Spacer(minLength: 8)
                    if library.current?.id == track.id {
                        Text(library.playing ? "再生中" : "選択中").font(.system(size: 12)).foregroundStyle(Studio.signal)
                    }
                    Text(time(track.duration ?? 0))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Studio.fog)
                }
                .padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .listRowBackground(library.current?.id == track.id ? Studio.carbon : Color.clear)
            .listRowSeparatorTint(Studio.iron)
        }
        .listStyle(.plain).scrollContentBackground(.hidden).padding(.horizontal, 24)
        .overlay {
            if tracks.isEmpty && !library.refreshing {
                Text(library.search.isEmpty ? "曲がありません。" : "一致する曲がありません。")
                    .foregroundStyle(Studio.fog).padding(24)
            }
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { library.showingNowPlaying = false } label: { Label("ライブラリへ戻る", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Studio.signal).padding([.top, .horizontal], 24)
            if let current = library.current {
                HStack(alignment: .center, spacing: 24) {
                    Artwork(url: artworkURL(current.coverArt)).frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("再生中").font(.system(size: 12)).foregroundStyle(Studio.fog)
                        Text(current.title).font(.system(size: 28, weight: .regular)).lineLimit(3)
                            .accessibilityAddTraits(.isHeader)
                        Text(current.artist ?? "アーティスト不明").foregroundStyle(Studio.fog)
                        if let album = current.album { Text(album).foregroundStyle(Studio.fog).font(.system(size: 12)) }
                    }
                    Spacer(minLength: 0)
                }.padding(24)
                Text("再生キュー").font(.system(size: 16)).padding(.horizontal, 24).padding(.bottom, 12)
                trackRows(library.queue, preservingQueue: true)
            }
        }
    }

    private var emptyLibrary: some View {
        Text("アルバムがありません。Navidrome のライブラリを確認してください。")
            .foregroundStyle(Studio.fog).padding(24)
    }

    private func artworkURL(_ id: String?) -> URL? {
        id.flatMap { library.artworkURLs[$0] }
    }

    private var login: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 48) {
                    loginHeading.frame(width: 220)
                    loginForm.frame(width: 320)
                }
                VStack(alignment: .leading, spacing: 32) {
                    loginHeading
                    loginForm
                }.frame(maxWidth: 400)
            }
            .padding(.horizontal, 48).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }.frame(maxHeight: .infinity)
    }

    private var loginHeading: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ライブラリに接続").font(.system(size: 36, weight: .regular)).tracking(-0.54)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text("Navidrome のアカウントでログインして、NAS の音楽を再生します。")
                .font(.system(size: 16)).foregroundStyle(Studio.fog)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("サーバーURL").font(.system(size: 12)).foregroundStyle(Studio.fog)
                TextField("サーバーURL", text: $library.server).modifier(StudioInput()).accessibilityLabel("サーバーURL")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ユーザー名").font(.system(size: 12)).foregroundStyle(Studio.fog)
                TextField("ユーザー名", text: $library.username).modifier(StudioInput()).accessibilityLabel("ユーザー名")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("パスワード").font(.system(size: 12)).foregroundStyle(Studio.fog)
                SecureField("パスワード", text: $library.password).modifier(StudioInput()).accessibilityLabel("パスワード")
            }
            Button {
                library.connect(server: library.server, username: library.username, password: library.password)
            } label: {
                HStack(spacing: 8) {
                    if library.refreshing { ProgressView().controlSize(.small) }
                    Text(library.refreshing ? "接続を準備中…" : "ログイン")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioButton(primary: true)).keyboardShortcut(.defaultAction)
            .disabled(library.refreshing || library.username.isEmpty || library.password.isEmpty)
            Text("ログイン情報はこの Mac の Keychain に保存します。")
                .font(.system(size: 12)).foregroundStyle(Studio.fog)
        }.disabled(library.refreshing)
    }

    private var playbackBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Button { library.showingNowPlaying = true; library.search = "" } label: {
                    HStack(spacing: 12) {
                        if let current = library.current {
                            Artwork(url: artworkURL(current.coverArt)).frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(library.current?.title ?? (library.connected ? "曲を選んでください" : "未接続"))
                                .font(.system(size: 15)).lineLimit(1)
                            if let artist = library.current?.artist {
                                Text(artist).font(.system(size: 12)).foregroundStyle(Studio.fog).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(library.current == nil)
                .accessibilityLabel(library.current.map { "\($0.title)の再生中画面を開く" } ?? "曲を選んでください")
                if library.loading { ProgressView().controlSize(.small) }
                if library.connected {
                    HStack(spacing: 8) {
                        Button(action: library.previous) { Image(systemName: "backward.end.fill") }
                            .buttonStyle(StudioButton(primary: false)).disabled(!library.canGoPrevious)
                            .accessibilityLabel("前の曲").help("前の曲")
                        Button(action: library.togglePlayback) {
                            Image(systemName: library.playing ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(StudioButton(primary: true)).disabled(library.current == nil)
                        .accessibilityLabel(library.playing ? "一時停止" : "再生")
                        .help(library.playing ? "一時停止" : "再生")
                        Button(action: library.next) { Image(systemName: "forward.end.fill") }
                            .buttonStyle(StudioButton(primary: false)).disabled(!library.canGoNext)
                            .accessibilityLabel("次の曲").help("次の曲")
                    }
                }
            }
            if library.connected {
                HStack(spacing: 12) {
                    Text(time(library.position)).frame(width: 46, alignment: .trailing)
                    Slider(value: Binding(get: { min(library.position, max(library.duration, 1)) },
                                          set: { library.seek(to: $0) }),
                           in: 0...max(library.duration, 1))
                        .disabled(library.current == nil || library.duration <= 0)
                        .accessibilityLabel("再生位置")
                        .accessibilityValue("\(time(library.position)) / \(time(library.duration))")
                    Text(time(library.duration)).frame(width: 46, alignment: .leading)
                }
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Studio.fog)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Studio.carbon)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct Artwork: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Studio.carbon
                Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(Studio.fog)
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
    var body: some Scene {
        WindowGroup("syncstr") { LibraryView() }.defaultSize(width: 1080, height: 740)
    }
}

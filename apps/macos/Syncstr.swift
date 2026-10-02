import SwiftUI

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

struct StudioInput: ViewModifier {
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
    @ObservedObject var library: Library
    @State private var showingUpload = false

    var body: some View {
        VStack(spacing: 0) {
            if library.connected {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Studio.iron).frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
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
        .navigationTitle("")
        .toolbar {
            if library.connected {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySearchField(text: $library.search, placeholder: "\(library.destination.rawValue)を検索")
                        .frame(width: 280, height: 38)
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { await library.restoreCredentials() }
        .sheet(isPresented: $showingUpload) { UploadView() }
    }

    private var rule: some View { Rectangle().fill(Studio.iron).frame(height: 1) }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LibraryDestination.allCases, id: \.self) { destination in
                Button { library.navigate(destination); library.search = "" } label: {
                    Label(destination.rawValue, systemImage: destination.symbol)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(library.destination == destination && !library.showingNowPlaying ? Studio.graphite : Color.clear)
                        .foregroundStyle(library.destination == destination && !library.showingNowPlaying ? Studio.signal : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityAddTraits(library.destination == destination && !library.showingNowPlaying ? .isSelected : [])
            }
            rule.padding(.vertical, 12)
            Button { showingUpload = true } label: {
                Label("音楽を追加", systemImage: "arrow.up.doc")
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("音楽をアップロード")
            Button(action: library.reload) {
                Label(library.refreshing ? "更新中…" : "ライブラリを更新", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(library.refreshing)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 20)
        .frame(width: 200)
        .background(Studio.carbon)
    }

    @ViewBuilder
    private var content: some View {
        if library.showingNowPlaying && library.search.isEmpty {
            nowPlaying
        } else if library.search.isEmpty, let albumID = library.selectedAlbum,
                  let album = library.albums.first(where: { $0.id == albumID }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { library.selectedAlbum = nil } label: { Label("アルバムへ戻る", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Studio.signal).padding([.top, .horizontal], 24)
                HStack(spacing: 20) {
                    Artwork(url: artworkURL(album.coverArt)).frame(width: 200, height: 200)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.title).font(.system(size: 28, weight: .semibold)).tracking(-0.42)
                            .accessibilityAddTraits(.isHeader)
                        Text(album.artist).foregroundStyle(Studio.fog)
                        Text("\(album.tracks.count)曲").font(.system(size: 12)).foregroundStyle(Studio.fog)
                        Spacer(minLength: 16)
                        Button {
                            if let first = album.tracks.first { library.play(first, in: album.tracks) }
                        } label: {
                            Label("再生", systemImage: "play.fill")
                                .frame(width: 106, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(Studio.signal)
                        .disabled(album.tracks.isEmpty)
                    }
                    .frame(height: 200, alignment: .center)
                    Spacer(minLength: 0)
                }.padding(24)
                trackRows(album.tracks)
            }
        } else if library.search.isEmpty, let artist = library.selectedArtist {
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
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                            ForEach(library.visibleAlbums) { album in
                                Button { library.selectedAlbum = album.id; library.search = "" } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Artwork(url: artworkURL(album.coverArt))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(album.title).font(.system(size: 14))
                                                .lineLimit(2)
                                                .truncationMode(.tail)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(album.artist).font(.system(size: 12)).foregroundStyle(Studio.fog)
                                                .lineLimit(1).truncationMode(.tail)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(height: 56, alignment: .topLeading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                    .help("\(album.title)\n\(album.artist)")
                                    .accessibilityLabel("\(album.title)、\(album.artist)")
                            }
                        }.padding(24)
                        if library.visibleAlbums.isEmpty { emptyLibrary }
                    }
                }
            case .artists:
                VStack(alignment: .leading, spacing: 0) {
                    pageTitle("アーティスト", detail: "\(library.artists.count)組")
                    List(library.artists, id: \.self) { artist in
                        Button { library.selectedArtist = artist; library.search = "" } label: {
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
                    pageTitle("曲", detail: "\(library.visibleTracks.count)曲")
                    trackRows(library.visibleTracks)
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
                    Text(time(track.duration ?? 0))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Studio.fog)
                }
                .padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(library.current?.id == track.id ? .isSelected : [])
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
                        Text(current.title).font(.system(size: 28, weight: .regular)).lineLimit(3)
                            .accessibilityAddTraits(.isHeader)
                        Text(current.artist ?? "アーティスト不明").foregroundStyle(Studio.fog)
                        if let album = current.album { Text(album).foregroundStyle(Studio.fog).font(.system(size: 12)) }
                    }
                    Spacer(minLength: 0)
                }.padding(24)
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

private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
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

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func search(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
    }
}

private struct Artwork: View {
    let url: URL?

    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } placeholder: {
                ZStack {
                    Studio.carbon
                    Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(Studio.fog)
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
        Settings { SettingsView(library: library) }
    }
}

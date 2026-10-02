import AVFoundation
import SwiftUI

@MainActor
final class Library: ObservableObject {
    @Published var server = "https://navidrome.jkte.ch"
    @Published var username = ""
    @Published var password = ""
    @Published var tracks: [Track] = []
    @Published var connected = false
    @Published var current: Track?
    @Published var playing = false
    @Published var loading = false
    @Published var refreshing = false
    @Published var message: String?
    private var client: Navidrome?
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var finishObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    func connect(server: String, username: String, password: String) {
        message = nil
        do { load(try Navidrome(server: server, username: username, password: password)) }
        catch { message = error.localizedDescription }
    }

    func reload() { if let client { load(client) } }

    private func load(_ client: Navidrome) {
        task?.cancel()
        refreshing = true
        message = nil
        task = Task {
            do {
                let tracks = try await client.tracks(session: session)
                guard !Task.isCancelled else { return }
                self.client = client
                self.tracks = tracks
                connected = true
                password = ""
            } catch {
                guard !Task.isCancelled else { return }
                message = (error as? ClientError)?.localizedDescription ?? "接続に失敗しました。ネットワークを確認して、もう一度お試しください。"
            }
            refreshing = false
        }
    }

    func play(_ track: Track) {
        guard let client else { return }
        stop()
        current = track
        message = nil
        let item = AVPlayerItem(url: client.url("stream", parameters: [
            URLQueryItem(name: "id", value: track.id),
            URLQueryItem(name: "format", value: "raw")
        ]))
        let player = AVPlayer(playerItem: item)
        self.player = player
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                playing = player.timeControlStatus == .playing
                loading = player.currentItem?.status != .failed && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item, item.status == .failed else { return }
                self.player?.pause()
                playing = false
                loading = false
                message = "曲を再生できませんでした。接続を確認して曲を選び直してください。"
            }
        }
        finishObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                playing = false
                loading = false
            }
        }
        player.play()
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate != 0 { player.pause() }
        else {
            if let item = player.currentItem, player.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    private func stop() {
        observation = nil
        itemObservation = nil
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
        finishObserver = nil
        player?.pause()
        player = nil
        playing = false
        loading = false
    }

    func disconnect() {
        task?.cancel()
        stop()
        refreshing = false
        client = nil
        current = nil
        tracks = []
        connected = false
        message = nil
    }
}

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Studio.iron).frame(height: 1)
            if library.connected { trackList }
            else { login }
            if let message = library.message {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                    Text(message).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(Studio.graphite)
                .accessibilityElement(children: .combine)
            }
            Rectangle().fill(Studio.iron).frame(height: 1)
            playbackBar
        }
        .font(.system(size: 14))
        .tracking(-0.21)
        .foregroundStyle(.white)
        .background(Studio.graphite)
        .tint(Studio.signal)
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 520)
        .navigationTitle("syncstr")
    }

    private var header: some View {
        HStack(spacing: 20) {
            Text("syncstr").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
            Spacer()
            if library.connected {
                Button("再読み込み", action: library.reload)
                    .disabled(library.refreshing)
                    .buttonStyle(StudioButton(primary: false))
                Button("ログアウト", action: library.disconnect)
                    .buttonStyle(StudioButton(primary: false))
            } else {
                Text("音楽ライブラリ").foregroundStyle(Studio.fog)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(Color.black)
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
                }
                .frame(maxWidth: 400)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxHeight: .infinity)
    }

    private var loginHeading: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ライブラリに接続")
                .font(.system(size: 36, weight: .regular))
                .tracking(-0.54)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Navidrome のアカウントでログインして、NAS の音楽を再生します。")
                .font(.system(size: 16))
                .tracking(-0.24)
                .foregroundStyle(Studio.fog)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("サーバーURL").font(.system(size: 12)).foregroundStyle(Studio.fog)
                TextField("サーバーURL", text: $library.server)
                    .modifier(StudioInput())
                    .accessibilityLabel("サーバーURL")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ユーザー名").font(.system(size: 12)).foregroundStyle(Studio.fog)
                TextField("ユーザー名", text: $library.username)
                    .modifier(StudioInput())
                    .accessibilityLabel("ユーザー名")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("パスワード").font(.system(size: 12)).foregroundStyle(Studio.fog)
                SecureField("パスワード", text: $library.password)
                    .modifier(StudioInput())
                    .accessibilityLabel("パスワード")
            }
            Button {
                library.connect(server: library.server, username: library.username, password: library.password)
            } label: {
                HStack(spacing: 8) {
                    if library.refreshing { ProgressView().controlSize(.small) }
                    Text(library.refreshing ? "接続中…" : "ログイン")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioButton(primary: true))
            .keyboardShortcut(.defaultAction)
            .disabled(library.refreshing || library.username.isEmpty || library.password.isEmpty)
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("ライブラリ").font(.system(size: 36, weight: .regular)).tracking(-0.54)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if library.refreshing { ProgressView().controlSize(.small) }
                Text("\(library.tracks.count)曲").foregroundStyle(Studio.fog)
            }.padding(32)
            List(library.tracks) { track in
                Button { library.play(track) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: library.current == track && library.playing ? "speaker.wave.2" : "music.note")
                            .font(.system(size: 16))
                            .foregroundStyle(library.current == track ? Studio.signal : Studio.fog)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(track.title).font(.system(size: 16)).tracking(-0.24)
                            if let artist = track.artist {
                                Text(artist).font(.system(size: 12)).foregroundStyle(Studio.fog)
                            }
                        }
                        Spacer(minLength: 16)
                        if library.current == track {
                            Text(library.playing ? "再生中" : "選択中")
                                .font(.system(size: 12)).foregroundStyle(Studio.signal)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(library.current == track ? Studio.carbon : Color.clear)
                .listRowSeparatorTint(Studio.iron)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 32)
            .overlay {
                if library.tracks.isEmpty && !library.refreshing {
                    Text("曲がありません。Navidrome のライブラリを確認してください。")
                        .foregroundStyle(Studio.fog)
                        .padding(32)
                }
            }
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(library.current?.title ?? (library.connected ? "曲を選んでください" : "未接続"))
                    .font(.system(size: 16)).tracking(-0.24)
                    .lineLimit(2)
                if let artist = library.current?.artist {
                    Text(artist).font(.system(size: 12)).foregroundStyle(Studio.fog)
                }
            }
            Spacer(minLength: 16)
            if library.loading { ProgressView().controlSize(.small) }
            if library.connected {
                Button(action: library.togglePlayback) {
                    Label(library.playing ? "一時停止" : "再生",
                          systemImage: library.playing ? "pause.fill" : "play.fill")
                }
                .disabled(library.current == nil)
                .buttonStyle(StudioButton(primary: true))
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .background(Studio.carbon)
    }
}

@main
struct SyncstrApp: App {
    var body: some Scene {
        WindowGroup("syncstr") { LibraryView() }.defaultSize(width: 920, height: 640)
    }
}

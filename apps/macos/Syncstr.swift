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

struct LibraryView: View {
    @StateObject private var library = Library()

    var body: some View {
        VStack(spacing: 0) {
            if !library.connected {
                VStack(alignment: .leading, spacing: 16) {
                    Text("音楽ライブラリに接続").font(.title2)
                    TextField("サーバーURL", text: $library.server)
                    TextField("ユーザー名", text: $library.username)
                    SecureField("パスワード", text: $library.password)
                    Button("ログイン") {
                        library.connect(server: library.server, username: library.username, password: library.password)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(library.refreshing || library.username.isEmpty || library.password.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(library.tracks) { track in
                    Button { library.play(track) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                if let artist = track.artist {
                                    Text(artist).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if library.current == track {
                                Text(library.playing ? "再生中" : "選択中")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 5)
                }
                .overlay {
                    if library.tracks.isEmpty && !library.refreshing {
                        Text("曲がありません。Navidrome のライブラリを確認してください。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = library.message { Text(message).foregroundStyle(.red) }
                HStack {
                    if library.loading || library.refreshing { ProgressView().controlSize(.small) }
                    Text(library.current?.title ?? (library.connected ? "曲を選んでください" : "Navidrome のアカウントでログインしてください"))
                        .lineLimit(2)
                    Spacer()
                    if library.connected {
                        Button(library.playing ? "一時停止" : "再生", action: library.togglePlayback)
                            .disabled(library.current == nil)
                    }
                }
            }.padding()
        }
        .frame(minWidth: 580, minHeight: 380)
        .toolbar {
            if library.connected {
                Button("再読み込み", action: library.reload).disabled(library.refreshing)
                Button("ログアウト", action: library.disconnect)
            }
        }
        .navigationTitle("syncstr")
    }
}

@main
struct SyncstrApp: App {
    var body: some Scene {
        WindowGroup("syncstr") { LibraryView() }.defaultSize(width: 760, height: 520)
    }
}

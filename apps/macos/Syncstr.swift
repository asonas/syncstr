import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class Library: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [URL] = []
    @Published var folder: URL?
    @Published var current: URL?
    @Published var playing = false
    @Published var loading = false
    @Published var message: String?
    private var player: AVAudioPlayer?
    private var request = UUID()

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "音楽フォルダを開く"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        let id = UUID()
        request = id
        player?.stop()
        player = nil
        playing = false
        current = nil
        tracks = []
        folder = url
        message = nil
        loading = true
        Task {
            do {
                let files = try await Task.detached { try MusicFiles.list(in: url) }.value
                guard request == id else { return }
                tracks = files
            } catch {
                guard request == id else { return }
                message = "フォルダを開けませんでした。共有への接続を確認してください。\n\(error.localizedDescription)"
            }
            loading = false
        }
    }

    func play(_ url: URL) {
        let id = UUID()
        request = id
        player?.stop()
        player = nil
        playing = false
        current = url
        message = nil
        loading = true
        Task {
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                guard request == id else { return }
                let audio = try AVAudioPlayer(data: data)
                audio.delegate = self
                player = audio
                playing = audio.play()
                if !playing { message = "再生を開始できませんでした。音声出力を確認して、もう一度お試しください。" }
            } catch {
                guard request == id else { return }
                message = "曲を読み込めませんでした。共有への接続を確認して、もう一度お試しください。\n\(error.localizedDescription)"
            }
            loading = false
        }
    }

    func togglePlayback() {
        guard let player else {
            if let current { play(current) }
            return
        }
        if playing {
            player.pause()
            playing = false
        } else {
            playing = player.play()
            if !playing { message = "再生を開始できませんでした。" }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            playing = false
            if !flag { message = "曲の再生を完了できませんでした。" }
        }
    }
}

struct LibraryView: View {
    @StateObject private var library = Library()

    var body: some View {
        VStack(spacing: 0) {
            if library.folder == nil {
                VStack(spacing: 16) {
                    Text("音楽フォルダを開く").font(.title2)
                    Text("NASの共有フォルダを接続して、MP3の入ったフォルダを選んでください。")
                        .foregroundStyle(.secondary)
                    Button("フォルダを選択…", action: library.chooseFolder)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(library.tracks, id: \.self) { track in
                    Button { library.play(track) } label: {
                        HStack {
                            Text(track.deletingPathExtension().lastPathComponent)
                            Spacer()
                            if library.current == track {
                                Text(library.playing ? "再生中" : "選択中")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 5)
                }
                .overlay {
                    if library.tracks.isEmpty && !library.loading && library.message == nil {
                        Text("このフォルダにはMP3がありません。別のフォルダを選んでください。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = library.message {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if library.loading { ProgressView().controlSize(.small) }
                    Text(library.current?.deletingPathExtension().lastPathComponent ?? "曲を選んでください")
                        .lineLimit(2)
                    Spacer()
                    Button(library.playing ? "一時停止" : "再生", action: library.togglePlayback)
                        .disabled(library.current == nil || library.loading)
                }
            }.padding()
        }
        .frame(minWidth: 580, minHeight: 380)
        .toolbar {
            ToolbarItem {
                Button("フォルダを選択…", action: library.chooseFolder)
                    .keyboardShortcut("o", modifiers: .command)
            }
            ToolbarItem {
                Button("再読み込み") { if let folder = library.folder { library.open(folder) } }
                    .disabled(library.folder == nil || library.loading)
            }
        }
        .navigationTitle(library.folder?.lastPathComponent ?? "syncstr")
    }
}

@main
struct SyncstrApp: App {
    var body: some Scene {
        WindowGroup("syncstr") { LibraryView() }
            .defaultSize(width: 760, height: 520)
    }
}

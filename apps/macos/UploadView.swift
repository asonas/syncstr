import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://syncstr-uploader.jkte.ch"
    @State private var token = ""
    @State private var files: [URL] = []
    @State private var picker = false
    @State private var sending = false
    @State private var message: String?
    @State private var completed = 0
    @State private var currentName = ""
    @State private var showingSettings = false
    private let store = CredentialStore(service: "as.ason.syncstr.upload", label: "syncstr Upload")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音楽をアップロード").font(.title2)
            Text("音楽ファイルをサーバーへ追加します。追加した曲はNavidromeのスキャン後に表示されます。")
                .foregroundStyle(.secondary)
            Text(token.isEmpty ? "設定でアップロード先とトークンを保存してください。" : "アップロード先: \(server)")
                .foregroundStyle(.secondary)
            Button("アップロード設定…") { showingSettings = true }.disabled(sending)
            HStack {
                Button("ファイルを選択…") { picker = true }.disabled(sending)
                Text("\(files.count)件を選択").foregroundStyle(.secondary)
            }
            if sending {
                ProgressView("\(completed) / \(files.count)件 完了 — \(currentName)")
            } else if !files.isEmpty {
                Text(files.map(\.lastPathComponent).joined(separator: "、"))
                    .lineLimit(3).foregroundStyle(.secondary)
            }
            if let message { Text(message).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.disabled(sending)
                Button("アップロード") { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || files.isEmpty || server.isEmpty || token.isEmpty)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(sending)
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await loadSettings() } }) {
            VStack {
                UploadSettingsView()
                Button("閉じる") { showingSettings = false }.padding(.bottom, 16)
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            do { files = try result.get(); completed = 0; message = nil }
            catch { message = "ファイルを選択できませんでした。" }
        }
        .task { await loadSettings() }
    }

    @MainActor private func loadSettings() async {
        do {
            let saved = try await store.load()
            server = saved?.server ?? "https://syncstr-uploader.jkte.ch"
            token = saved?.password ?? ""
            message = nil
        } catch { token = ""; message = "保存した接続情報を読み込めませんでした。" }
    }

    @MainActor private func send() async {
        sending = true
        completed = 0
        message = nil
        defer { sending = false }
        do {
            let client = try UploadClient(server: server, token: token)
            for file in files {
                currentName = file.lastPathComponent
                _ = try await client.upload(file)
                completed += 1
            }
            message = "\(completed)件をアップロードしました。ライブラリはスキャン後に再読み込みしてください。"
            files = []
        } catch {
            files = Array(files.dropFirst(completed))
            message = "\(currentName): \(error.localizedDescription)\n完了した\(completed)件を除き、残りは再試行できます。"
        }
    }
}

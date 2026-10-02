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
    private let store = CredentialStore(service: "as.ason.syncstr.upload", label: "syncstr Upload")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音楽をアップロード").font(.title2)
            Text("音楽ファイルをサーバーへ追加します。追加した曲はNavidromeのスキャン後に表示されます。")
                .foregroundStyle(.secondary)
            Form {
                TextField("アップロード先（HTTPS）", text: $server)
                SecureField("アップロード用トークン", text: $token)
            }.disabled(sending)
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
                Button("保存した接続情報を削除") {
                    Task {
                        do { try await store.remove(); server = ""; token = ""; message = "接続情報を削除しました。" }
                        catch { message = "接続情報を削除できませんでした。" }
                    }
                }.disabled(sending)
                Spacer()
                Button("閉じる") { dismiss() }.disabled(sending)
                Button("アップロード") { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || files.isEmpty || server.isEmpty || token.isEmpty)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(sending)
        .fileImporter(isPresented: $picker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            do { files = try result.get(); completed = 0; message = nil }
            catch { message = "ファイルを選択できませんでした。" }
        }
        .task {
            do {
                if let saved = try await store.load() { server = saved.server; token = saved.password }
            } catch { message = "保存した接続情報を読み込めませんでした。" }
        }
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
                if completed == 1 {
                    try await store.save(LoginCredentials(server: server, username: "upload", password: token))
                }
            }
            message = "\(completed)件をアップロードしました。ライブラリはスキャン後に再読み込みしてください。"
            files = []
        } catch {
            files = Array(files.dropFirst(completed))
            message = "\(currentName): \(error.localizedDescription)\n完了した\(completed)件を除き、残りは再試行できます。"
        }
    }
}

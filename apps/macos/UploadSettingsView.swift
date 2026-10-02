import SwiftUI

struct UploadSettingsView: View {
    @State private var server = "https://syncstr-uploader.jkte.ch"
    @State private var token = ""
    @State private var message: String?
    @State private var working = false
    private let store = CredentialStore(service: "as.ason.syncstr.upload", label: "syncstr Upload")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("アップロード設定").font(.title2)
            Form {
                TextField("アップロード先（HTTPS）", text: $server)
                SecureField("アップロード用トークン", text: $token)
            }
            Text("トークンはこのMacのKeychainに保存します。Navidromeのログイン情報とは別に管理します。")
                .foregroundStyle(.secondary)
            if let message { Text(message).textSelection(.enabled) }
            HStack {
                Button("保存した接続情報を削除") {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            try await store.remove()
                            token = ""
                            message = "接続情報を削除しました。"
                        } catch { message = "接続情報を削除できませんでした。" }
                    }
                }
                Spacer()
                Button("保存") {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            let client = try UploadClient(server: server, token: token)
                            try await store.save(LoginCredentials(server: client.server.absoluteString,
                                                                 username: "upload", password: token))
                            message = "アップロード設定を保存しました。"
                        } catch { message = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.isEmpty || token.isEmpty)
            }
        }
        .disabled(working)
        .padding(24).frame(width: 560)
        .task {
            do {
                if let saved = try await store.load() { server = saved.server; token = saved.password }
            } catch { message = "保存した接続情報を読み込めませんでした。" }
        }
    }
}

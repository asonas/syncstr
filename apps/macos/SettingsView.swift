import SwiftUI

struct SettingsView: View {
    var library: Library? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "upload"
    @State private var server = ""
    @State private var token = ""
    @State private var message: String?
    @State private var working = false
    @State private var loaded = false
    @State private var deleting = false
    @State private var hasSavedCredentials = false
    private let store = CredentialStore(service: "as.ason.syncstr.upload", label: "syncstr Upload")

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                if let library {
                    ConnectionSettingsView(library: library)
                        .tabItem { Label("接続", systemImage: "network") }.tag("connection")
                }
                UploadSettingsView(server: $server, token: $token, deleting: $deleting,
                                   message: message, working: working, check: checkConnection)
                    .tabItem { Label("アップロード", systemImage: "arrow.up.document") }.tag("upload")
            }.padding(24).disabled(working || !loaded)
            Rectangle().fill(Studio.iron).frame(height: 1)
            HStack(spacing: 12) {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(StudioButton(primary: false))
                    .disabled(working)
                Button("OK") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(StudioButton(primary: true))
                    .disabled(working || !loaded)
            }.padding(20)
        }
        .frame(width: 600, height: 460)
        .font(.system(size: 14)).foregroundStyle(.white)
        .background(Studio.graphite).tint(Studio.signal).preferredColorScheme(.dark)
        .interactiveDismissDisabled(working).navigationTitle("設定")
        .task {
            loaded = false
            message = nil
            deleting = false
            tab = library == nil ? "upload" : "connection"
            do {
                let saved = try await store.load()
                server = saved?.server ?? ""
                token = saved?.password ?? ""
                hasSavedCredentials = saved != nil
                loaded = true
            } catch { message = "保存した接続情報を読み込めませんでした。"; tab = "upload" }
        }
        .onChange(of: server) { message = nil }
        .onChange(of: token) { message = nil; deleting = false }
    }

    @MainActor private func checkConnection() async {
        working = true
        message = nil
        defer { working = false }
        do {
            try await UploadClient(server: server, token: token).checkConnection()
            message = "接続できました。トークンは有効です。"
        } catch { message = error.localizedDescription }
    }

    @MainActor private func save() async {
        working = true
        defer { working = false }
        do {
            if deleting { try await store.remove() }
            else if token.isEmpty && hasSavedCredentials { throw UploadError.invalidToken }
            else if !token.isEmpty {
                let client = try UploadClient(server: server, token: token)
                try await store.save(LoginCredentials(server: client.server.absoluteString,
                                                       username: "upload", password: token))
            }
            dismiss()
        } catch { message = error.localizedDescription; tab = "upload" }
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var library: Library
    @State private var confirmingLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Navidromeの接続").font(.headline)
            if library.connected {
                Text(library.server).textSelection(.enabled)
                Text("ユーザー: \(library.username)").foregroundStyle(Studio.fog)
                Button("ログアウト…", role: .destructive) { confirmingLogout = true }
                    .buttonStyle(StudioButton(primary: false))
            } else {
                Text("未接続です。ライブラリ画面からログインしてください。")
                    .foregroundStyle(Studio.fog)
            }
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Studio.graphite)
        .confirmationDialog("Navidromeからログアウトしますか？", isPresented: $confirmingLogout,
                            titleVisibility: .visible) {
            Button("ログアウト", role: .destructive) { library.disconnect() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("再生を停止し、このMacに保存したNavidromeのログイン情報を削除します。アップロード設定は残ります。")
        }
    }
}

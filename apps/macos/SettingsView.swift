import SwiftUI

struct SettingsView: View {
    @ObservedObject var library: Library
    @State private var confirmingLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Navidromeの接続").font(.title2)
                if library.connected {
                    Text(library.server).textSelection(.enabled)
                    Text("ユーザー: \(library.username)").foregroundStyle(.secondary)
                    Button("ログアウト…", role: .destructive) { confirmingLogout = true }
                } else {
                    Text("未接続です。ライブラリ画面からログインしてください。")
                        .foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            UploadSettingsView()
        }
        .frame(width: 560)
        .confirmationDialog("Navidromeからログアウトしますか？", isPresented: $confirmingLogout,
                            titleVisibility: .visible) {
            Button("ログアウト", role: .destructive) { library.disconnect() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("再生を停止し、このMacに保存したNavidromeのログイン情報を削除します。アップロード設定は残ります。")
        }
    }
}

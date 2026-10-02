import SwiftUI

struct UploadSettingsView: View {
    @Binding var server: String
    @Binding var token: String
    @Binding var deleting: Bool
    let message: String?
    let working: Bool
    let check: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("アップロード先（HTTPS）").font(.headline)
            TextField("https://…", text: $server).modifier(StudioInput())
                .accessibilityLabel("アップロード先（HTTPS）")
            Text("アップロード用トークン").font(.headline)
            SecureField("トークン", text: $token).modifier(StudioInput())
                .accessibilityLabel("アップロード用トークン")
            Text("トークンはこのMacのKeychainに保存します。Navidromeのログイン情報とは別に管理します。")
                .font(.caption).foregroundStyle(Studio.fog).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("接続を確認") { Task { await check() } }
                    .buttonStyle(StudioButton(primary: false))
                    .disabled(server.isEmpty || token.isEmpty || deleting)
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("保存した接続情報を削除", isOn: $deleting).toggleStyle(.checkbox)
            }
            if deleting {
                Text("OKで接続情報を削除します。").font(.caption).foregroundStyle(Studio.fog)
            } else if let message {
                Text(message).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(20).background(Studio.graphite)
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var library: Library
    @State private var showingLegacy = false

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text("音楽の追加").font(.headline)
            AddMusicButton(library: library)
            if library.transfer.clusterRegistration == nil {
                LocalFolderButton(library: library)
                Text("登録せずにこの端末で再生できます。ライブラリホストには設定されません。")
                    .foregroundStyle(.secondary)
            }
            if let message = library.message { Text(message).textSelection(.enabled) }
            Divider()
            PlaybackStorageSettings(library: library)
            Divider()
            PeerSetupView(transfer: library.transfer)
            Divider()
            DisclosureGroup("従来の接続") {
                Button("従来の端末間転送") { showingLegacy = true }
                    .disabled(library.transfer.clusterRegistration != nil)
                Text("音楽フォルダを使う旧方式です。共有ライブラリへの参加と日常の保存操作は上の設定から行えます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24) }
        .frame(width: 520, height: 680)
        .background(Studio.graphite).preferredColorScheme(.dark)
        .navigationTitle("設定")
        .sheet(isPresented: $showingLegacy) {
            VStack {
                if library.hasLocalFolder {
                    MacPairingView(transfer: library.transfer) { Task { await library.startPairing() } }
                        .task { await library.startPairing(newPairing: false) }
                } else {
                    Text("従来の転送に使う音楽フォルダを選んでください。")
                    LocalFolderButton(library: library)
                    Button("閉じる") { showingLegacy = false }
                }
            }.padding()
        }
    }
}

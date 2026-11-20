import SwiftUI

struct SettingsView: View {
    @ObservedObject var library: Library
    @State private var hostSetup: HostSetupRequest?

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            AppearanceSettings()
            if library.transfer.showsLibraryEditControls {
                Divider()
                Text("音楽の追加").font(.headline)
                AddMusicButton(library: library)
            }
            LocalFolderButton(library: library)
            Text("登録せずにこの端末で再生できます。ライブラリホストには設定されません。")
                .foregroundStyle(Studio.fog)

            if let message = library.message { Text(message).textSelection(.enabled) }
            Divider()
            PlaybackStorageSettings(library: library)
            Divider()
            PlaybackDiagnosticSettings(recorder: library.diagnostics)
            Divider()
            HostConnectionSettings(transfer: library.transfer) { hostSetup = $0 }
        }.padding(24) }
        .frame(width: 520, height: 680)
        .background(Studio.graphite)
        .navigationTitle("設定")
        .sheet(item: $hostSetup) { HostConnectionView(transfer: library.transfer, request: $0) }
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音楽フォルダ").font(.headline)
            LocalFolderButton(library: library)
            Text("選んだフォルダの音楽を再生し、iPhoneに転送できます。")
                .foregroundStyle(.secondary)
            if let message = library.message { Text(message).textSelection(.enabled) }
            Spacer()
        }
        .padding(24).frame(width: 480, height: 240)
        .background(Studio.graphite).preferredColorScheme(.dark)
        .navigationTitle("設定")
    }
}

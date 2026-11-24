import SwiftUI

struct SettingsView: View {
    @ObservedObject var library: Library
    @State private var hostSetup: HostSetupRequest?

    var body: some View {
        TabView {
            Tab("一般", systemImage: "gearshape") {
                settingsForm {
                    Section { AppearanceSettings() }
                    Section { AppVersionRow() }
                }
            }
            Tab("ライブラリ", systemImage: "music.note.house") {
                settingsForm { LibrarySettingsSection(library: library) { hostSetup = $0 } }
            }
            Tab("保存と容量", systemImage: "internaldrive") {
                settingsForm {
                    SavedMusicSettingsSection(library: library)
                    PlaybackCacheSettingsSection(library: library)
                }
            }
            Tab("詳細", systemImage: "stethoscope") {
                PlaybackDiagnosticList(recorder: library.diagnostics)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 360)
        .navigationTitle("設定")
        .sheet(item: $hostSetup) { HostConnectionView(transfer: library.transfer, request: $0) }
    }

    private func settingsForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form {
            content()
            if let message = library.message { Section { Text(message).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
    }
}

import SwiftUI

struct LibrarySettingsSection: View {
    @ObservedObject var library: Library
    let open: (HostSetupRequest) -> Void

    var body: some View {
        Section("ライブラリ") { HostConnectionSettings(library: library, open: open) }
    }
}

struct SavedMusicSettingsSection: View {
    @ObservedObject var library: Library
    @State private var confirming = false

    private var saved: SavedAudioSummary { library.transfer.savedAudio }
    private var hasAnythingToDelete: Bool {
        !saved.pins.isEmpty || saved.unpinnedFiles > 0 || !library.transfer.saveRequests.isEmpty
    }

    var body: some View {
        Section("保存した音楽") {
#if os(iOS)
            Toggle("モバイル通信でも自動転送する", isOn: Binding(get: { library.transfer.automaticCellular },
                                                       set: library.transfer.setAutomaticCellular))
#endif
            LabeledContent("使用量", value: ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .decimal))
            Button("保存した音楽をすべて削除", role: .destructive) { confirming = true }
                .disabled(!hasAnythingToDelete)
                .alert("保存した音楽をすべて削除しますか？", isPresented: $confirming) {
                    Button("キャンセル", role: .cancel) {}
                    Button("すべて削除", role: .destructive) { Task { await library.removeAllSavedMusic() } }
                } message: {
                    Text(saved.pins.isEmpty ? "保存待ちと、この端末に残っている音声を削除します。再生中の曲は停止します。ホストのライブラリには残ります。"
                         : "\(saved.pins.count)曲をこの端末から削除します。再生中の曲は停止します。ホストのライブラリには残ります。")
                }
        }
        .task { await library.transfer.refreshSavedAudio() }
    }
}

struct PlaybackCacheSettingsSection: View {
    @ObservedObject var library: Library

    private var cache: PlaybackCache { library.transfer.playbackCache }

    var body: some View {
        Section("再生キャッシュ") {
            LabeledContent("上限") {
                HStack {
                    Text("\(cache.limitGB) GB")
                    Stepper("上限", value: Binding(
                        get: { cache.limitGB },
                        set: { value in
                            do {
                                try cache.setLimit(value) { error in
                                    library.message = "キャッシュを整理できませんでした。\(error.localizedDescription)"
                                }
                                library.objectWillChange.send()
                                Task { await cache.maintenance?.value; library.objectWillChange.send() }
                            } catch { library.message = "キャッシュ容量を変更できませんでした。\(error.localizedDescription)" }
                        }
                    ), in: 1...1000).labelsHidden()
                }
            }
            LabeledContent("使用量", value: ByteCountFormatter.string(fromByteCount: cache.usedBytes, countStyle: .decimal))
            Button("キャッシュを消去") {
                Task {
                    do { try await cache.clear() }
                    catch { library.message = "キャッシュを消去できませんでした。\(error.localizedDescription)" }
                    library.objectWillChange.send()
                }
            }
            // While a track is being prepared its file is verified before it becomes the protected one.
            .disabled(cache.usedBytes == 0 || library.loading)
        }
    }
}

struct AppVersionRow: View {
    var body: some View { LabeledContent("バージョン", value: Self.version) }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "-"
        guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
}

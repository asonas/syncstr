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
    @State private var removal: Removal?

    private struct Removal {
        let library: String?
        let tracks: [Track]
    }

    private var removable: [Track] { library.tracks.filter(library.canRemoveLocalCopy) }

    var body: some View {
        Section("保存した音楽") {
#if os(iOS)
            Toggle("モバイル通信でも自動転送する", isOn: Binding(get: { library.transfer.automaticCellular },
                                                       set: library.transfer.setAutomaticCellular))
#endif
            LabeledContent("使用量", value: ByteCountFormatter.string(fromByteCount: library.savedAudioBytes, countStyle: .decimal))
            Button("保存した音楽をすべて削除", role: .destructive) {
                removal = Removal(library: library.localCatalog?.id, tracks: removable)
            }
                .disabled(removable.isEmpty)
                .alert("保存した音楽をすべて削除しますか？", isPresented: Binding(
                    get: { removal != nil }, set: { if !$0 { removal = nil } }
                ), presenting: removal) { target in
                    Button("キャンセル", role: .cancel) {}
                    Button("すべて削除", role: .destructive) {
                        // The library can change while the alert is open, and track IDs alone could match the new one.
                        guard library.localCatalog?.id == target.library else { return }
                        library.removeLocalCopies(target.tracks)
                    }
                } message: { target in
                    Text("\(target.tracks.count)曲をこの端末から削除します。ホストのライブラリには残ります。")
                }
        }
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
                            do { try cache.setLimit(value); library.objectWillChange.send() }
                            catch { library.message = "キャッシュ容量を変更できませんでした。\(error.localizedDescription)" }
                        }
                    ), in: 1...1000).labelsHidden()
                }
            }
            LabeledContent("使用量", value: ByteCountFormatter.string(fromByteCount: cache.usedBytes, countStyle: .decimal))
            Button("キャッシュを消去") {
                do { try cache.clear(); library.objectWillChange.send() }
                catch { library.message = "キャッシュを消去できませんでした。\(error.localizedDescription)" }
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

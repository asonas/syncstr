import Foundation
import SwiftUI

@MainActor
final class PlaybackCache {
    let store: LocalMusicStore
    var protectedURL: URL?
    private let settings: URL
    private(set) var limitGB: Int

    var usedBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { ClusterIdentity.isLowercaseHex256($0.deletingPathExtension().lastPathComponent) }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    init(root: URL) {
        store = LocalMusicStore(root: root)
        settings = root.appendingPathComponent("limit.json")
        limitGB = (try? JSONDecoder().decode(Int.self, from: Data(contentsOf: settings))) ?? 10
        limitGB = min(1000, max(1, limitGB))
    }

    func setLimit(_ value: Int) throws {
        try store.prepare()
        limitGB = min(1000, max(1, value))
        try JSONEncoder().encode(limitGB).write(to: settings, options: .atomic)
        try trim()
    }

    func file(_ entry: LocalEntry) throws -> URL? {
        guard store.hasFile(entry) else { return nil }
        let url = store.fileURL(entry)
        guard try LocalMusicStore.digest(file: url) == entry.sha256 else {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func markPlayed(_ url: URL) throws {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == store.root.resolvingSymlinksInPath().path else { return }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func makeRoom(for entry: LocalEntry) throws {
        try store.prepare()
        try trim(incoming: entry.track.size ?? 0)
    }

    func trim(incoming: UInt64 = 0) throws {
        let directory = store.root
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        let entries = try files.compactMap { url -> (URL, UInt64, Date)? in
            guard ClusterIdentity.isLowercaseHex256(url.deletingPathExtension().lastPathComponent),
                  ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac"].contains(url.pathExtension) else { return nil }
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard info.isRegularFile == true else { return nil }
            return (url, UInt64(info.fileSize ?? 0), info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(UInt64(0)) { $0 + $1.1 }
        let budget = UInt64(limitGB) * 1_000_000_000
        for (url, size, _) in entries where total + incoming > budget {
            guard url.resolvingSymlinksInPath().path != protectedURL?.resolvingSymlinksInPath().path else { continue }
            try FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

struct PlaybackStorageSettings: View {
    @ObservedObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("再生キャッシュの上限: \(library.transfer.playbackCache.limitGB) GB", value: Binding(
                get: { library.transfer.playbackCache.limitGB },
                set: { value in
                    do { try library.transfer.playbackCache.setLimit(value); library.objectWillChange.send() }
                    catch { library.message = "キャッシュ容量を変更できませんでした。\(error.localizedDescription)" }
                }
            ), in: 1...1000)
            Text("明示的に保存した音楽は、この上限と自動削除の対象外です。")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("再生キャッシュ", value: ByteCountFormatter.string(fromByteCount: library.transfer.playbackCache.usedBytes, countStyle: .decimal))
            LabeledContent("保存済み音源", value: ByteCountFormatter.string(fromByteCount: library.savedAudioBytes, countStyle: .decimal))
        }
    }
}

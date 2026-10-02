import SwiftUI
import UniformTypeIdentifiers

private struct UploadItem: Identifiable {
    let id = UUID()
    let file: URL
    let bytes: Int64?
    var state: State = .waiting

    enum State: Equatable {
        case waiting, uploading, completed, failed(String)
    }
}

struct UploadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://syncstr-uploader.jkte.ch"
    @State private var token = ""
    @State private var items: [UploadItem] = []
    @State private var picker = false
    @State private var sending = false
    @State private var dropTargeted = false
    @State private var message: String?
    @State private var showingSettings = false
    private let store = CredentialStore(service: "as.ason.syncstr.upload", label: "syncstr Upload")
    private let supportedExtensions = Set(["mp3", "aac", "m4a", "alac", "wav", "aiff", "aif", "flac", "ogg", "opus"])

    private var pendingCount: Int { items.filter { $0.state != .completed }.count }
    private var completedCount: Int { items.filter { $0.state == .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("音楽をアップロード").font(.title2.weight(.semibold))
                    Text("ファイルを追加して、1件ずつアップロードします。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("アップロード設定").help("アップロード設定")
                    .disabled(sending)
            }
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.document").font(.system(size: 28, weight: .light))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(dropTargeted ? "ここにドロップして追加" : "音楽ファイルをここにドラッグ＆ドロップ")
                    .font(.headline)
                Button("ファイルを選択…") { picker = true }.disabled(sending)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 5]))
            }
            VStack(spacing: 0) {
                HStack {
                    Text("アップロードするファイル").font(.subheadline.weight(.semibold))
                    Text("\(items.count)件").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if !items.isEmpty {
                        Button("一覧をクリア") { items = []; message = nil }.disabled(sending)
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.padding(14)
                Divider()
                ScrollView {
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Text("まだファイルが追加されていません")
                            Text("MP3、FLAC、WAVなどの音楽ファイルに対応しています。")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                fileRow(item)
                                if item.id != items.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                    }
                }.frame(height: 220)
            }
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)) }
            VStack(alignment: .leading, spacing: 8) {
                if sending {
                    ProgressView(value: Double(completedCount), total: Double(max(items.count, 1)))
                    Text("\(completedCount) / \(items.count)件 完了").monospacedDigit()
                }
                if let message { Text(message).textSelection(.enabled) }
                Text(token.isEmpty ? "アップロード設定でURLとトークンを保存してください。" : "保存先: \(server)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("追加した曲はNavidromeのスキャン後に表示されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(pendingCount)件 未完了 · \(completedCount)件 完了")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("閉じる") { dismiss() }.disabled(sending)
                Button(sending ? "アップロード中…" : "アップロード") { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || pendingCount == 0 || token.isEmpty)
            }
        }
        .padding(24).frame(width: 680)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(sending)
        .dropDestination(for: URL.self) { urls, _ in
            guard !sending else { return false }
            addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 && !sending }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await loadSettings() } }) {
            SettingsView()
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): addFiles(urls)
            case .failure: message = "ファイルを選択できませんでした。"
            }
        }
        .task { await loadSettings() }
    }

    private func fileRow(_ item: UploadItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
                .frame(width: 24, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.file.lastPathComponent).font(.subheadline.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(item.file.lastPathComponent)
                if let bytes = item.bytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let error) = item.state {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Group {
                switch item.state {
                case .waiting: Text("待機中").foregroundStyle(.secondary)
                case .uploading:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("送信中") }
                case .completed: Label("完了", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .failed: Label("失敗", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }.font(.caption).padding(.top, 4)
            Button {
                items.removeAll { $0.id == item.id }
            } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(sending)
                .accessibilityLabel("\(item.file.lastPathComponent)を一覧から外す")
        }.padding(14)
    }

    private func addFiles(_ urls: [URL]) {
        var rejected = 0
        for url in urls {
            guard !items.contains(where: { $0.file.standardizedFileURL == url.standardizedFileURL }) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL, supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { rejected += 1; continue }
            items.append(UploadItem(file: url, bytes: values.fileSize.map(Int64.init)))
        }
        message = rejected == 0 ? nil : "\(rejected)件は追加できませんでした。対応する音楽ファイルを選んでください。フォルダは追加できません。"
    }

    @MainActor private func loadSettings() async {
        do {
            let saved = try await store.load()
            server = saved?.server ?? "https://syncstr-uploader.jkte.ch"
            token = saved?.password ?? ""
        } catch { token = ""; message = "保存した接続情報を読み込めませんでした。" }
    }

    @MainActor private func send() async {
        guard !sending else { return }
        sending = true
        message = nil
        defer { sending = false }
        do {
            let client = try UploadClient(server: server, token: token)
            let pendingIDs = items.filter { $0.state != .completed }.map(\.id)
            for id in pendingIDs {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].state = .uploading
                do {
                    _ = try await client.upload(items[index].file)
                    items[index].state = .completed
                } catch { items[index].state = .failed(error.localizedDescription) }
            }
            message = pendingCount == 0 ? "すべてのアップロードが完了しました。" : "失敗したファイルは、アップロードボタンから再試行できます。"
        } catch { message = error.localizedDescription }
    }
}

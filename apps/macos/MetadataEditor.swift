import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let filename: String
    let original: MusicMetadata
    let save: (MusicMetadata) -> Void
    @State var metadata: MusicMetadata
    @State private var imagePicker = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("曲情報を編集").font(.title2)
            Text(filename).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 12) {
                    Group {
                        if let data = metadata.artwork, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Rectangle().fill(.quaternary).overlay { Text("ジャケットなし").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(width: 144, height: 144).clipped().accessibilityLabel("ジャケット")
                    Button("画像を選択…") { imagePicker = true }
                    if metadata.artwork != nil {
                        Button("ジャケットを外す") { metadata.artwork = nil; metadata.artworkMIME = nil }
                    }
                }
                Form {
                    TextField("曲名", text: $metadata.title)
                    TextField("アーティスト", text: $metadata.artist)
                    TextField("アルバム", text: $metadata.album)
                    TextField("曲番号", text: $metadata.track, prompt: Text("例: 1 または 1/12"))
                }.formStyle(.grouped)
            }
            Text("曲情報はアップロードするコピーに保存します。元ファイルは変更しません。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("適用") {
                    guard metadata.track == original.track || metadata.track.isEmpty ||
                            metadata.track.range(of: #"^[1-9][0-9]*(/[1-9][0-9]*)?$"#, options: .regularExpression) != nil else {
                        error = MetadataError.invalidTrack.localizedDescription; return
                    }
                    save(metadata); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580).preferredColorScheme(.dark)
            .fileImporter(isPresented: $imagePicker, allowedContentTypes: [.jpeg, .png]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard (1...10_000_000).contains(size) else { throw MetadataError.invalidArtwork }
                    let data = try Data(contentsOf: url)
                    guard let representation = NSBitmapImageRep(data: data), representation.pixelsWide > 0,
                          representation.pixelsHigh > 0,
                          let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                          type.conforms(to: .jpeg) || type.conforms(to: .png) else { throw MetadataError.invalidArtwork }
                    metadata.artwork = data
                    metadata.artworkMIME = type.conforms(to: .png) ? "image/png" : "image/jpeg"
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct PeerSetupView: View {
    @ObservedObject var transfer: LocalTransfer
    @State private var expected = ""
    @State private var address = ""
    @State private var name = "NAS"
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("P2Pで音楽を共有").font(.headline)
            Text("この端末のIDを接続先で許可し、接続先のIDとアドレス情報を入力してください。接続先が中継を有効にしている場合は、直接接続できないときに中継を利用します。")
                .foregroundStyle(.secondary)
            Text("この端末のID")
            Text(transfer.peerID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("端末IDをコピー") {
#if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transfer.peerID, forType: .string)
#else
                UIPasteboard.general.string = transfer.peerID
#endif
            }.disabled(transfer.peerID.isEmpty)
            TextField("接続先の名前", text: $name).textFieldStyle(.roundedBorder)
            TextField("確認済みの接続先ID", text: $expected).textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text("接続先が出力したアドレス情報（JSON）")
            TextEditor(text: $address).font(.system(.caption, design: .monospaced)).frame(height: 100)
                .accessibilityLabel("接続先のアドレス情報")
            Button("P2Pで接続") {
                transfer.connectPeer(addressText: address.trimmingCharacters(in: .whitespacesAndNewlines),
                    expected: expected.trimmingCharacters(in: .whitespacesAndNewlines), name: name)
            }.buttonStyle(.borderedProminent).disabled(transfer.busy || address.isEmpty || expected.isEmpty)
            if let name = transfer.peerName {
                Text("登録済み: \(name)")
                Button("登録した接続先に再接続") { Task { await transfer.reconnectPeer() } }.disabled(transfer.busy)
                Button("P2Pの接続先を削除", role: .destructive) { Task { await transfer.forgetPeer() } }
            }
            if transfer.peerConnected {
                Button("音源ファイルを接続先に追加") { importing = true }.disabled(transfer.busy)
            }
            if transfer.busy {
                ProgressView(value: transfer.progress)
                Button("中断する") { transfer.cancel() }
            }
            if let status = transfer.status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
        .task { await transfer.restorePeer() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): transfer.uploadPeer(files: files)
            case .failure(let error): transfer.status = error.localizedDescription
            }
        }
    }
}

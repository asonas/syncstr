import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
import VisionKit
#endif

struct PeerSetupView: View {
    @ObservedObject var transfer: LocalTransfer
    @State private var address = ""
    @State private var name = "NAS"
    @State private var importing = false
    @State private var confirming = false
    @State private var confirmedAddress = ""
    @State private var confirmedID = ""
#if os(iOS)
    @State private var scanning = false
#endif

    private var parsedAddress: PeerAddress? { try? PeerAddress.parse(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("P2Pで音楽を共有").font(.headline)
            Text("この端末のIDを接続先で許可し、接続情報を貼り付けてください。登録前に接続先のIDを確認できます。")
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
            Text("接続情報（JSON）")
            TextEditor(text: $address).font(.system(.caption, design: .monospaced)).frame(height: 100)
                .accessibilityLabel("接続先のアドレス情報")
#if os(iOS)
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                Button("接続先のQRコードを読み取る") {
                    Task {
                        if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                        else { transfer.status = "設定でカメラへのアクセスを許可するか、接続情報を貼り付けてください。" }
                    }
                }
            }
#endif
            if let peer = parsedAddress {
                Text("接続先のID")
                Text(peer.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("接続情報を読み取れません。接続先が出力したJSONを貼り付けてください。")
                    .foregroundStyle(.secondary)
            }
            Button("接続先を確認して登録") {
                guard let peer = parsedAddress else { return }
                confirmedAddress = address
                confirmedID = peer.id
                confirming = true
            }.buttonStyle(.borderedProminent).disabled(transfer.busy || parsedAddress == nil)
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
        .alert("この接続先を登録しますか？", isPresented: $confirming) {
            Button("キャンセル", role: .cancel) {}
            Button("登録して接続") {
                transfer.connectPeer(addressText: confirmedAddress, expected: confirmedID, name: name)
            }
        } message: {
            Text("接続先のIDを、信頼できる接続先の画面や管理者の案内と照合してください。\n\n\(confirmedID)")
        }
#if os(iOS)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                PairingScanner { value in
                    scanning = false
                    if (try? PeerAddress.parse(value)) != nil { address = value; transfer.status = nil }
                    else { transfer.status = "Syncstrの接続情報を含むQRコードを読み取ってください。" }
                }
                .navigationTitle("接続先のQRコードを読み取る")
                .toolbar { Button("キャンセル") { scanning = false } }
            }
        }
#endif
        .task { await transfer.restorePeer() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): transfer.uploadPeer(files: files)
            case .failure(let error): transfer.status = error.localizedDescription
            }
        }
    }
}

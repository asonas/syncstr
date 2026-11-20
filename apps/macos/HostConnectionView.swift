import SwiftUI
#if os(iOS)
import AVFoundation
import VisionKit
#endif

struct HostSetupRequest: Identifiable {
    let id = UUID()
    var input: HostInput?
    var showsSettings = false
}

struct HostConnectionView: View {
    @ObservedObject var transfer: LocalTransfer
    let request: HostSetupRequest
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow = HostConnectionFlow()
    @State private var address = ""
    @State private var reading: Task<Void, Never>?
    @State private var submitting = false
#if os(iOS)
    @State private var scanning = false
    @State private var cameraDenied = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                switch flow.phase {
                case .entry: entry
                case .failure(let message):
                    Text(message)
                    entry
                case .reading: ProgressView("ライブラリの情報を読み込み中…")
                case .confirmation(let address, let info):
                    Text("\(address.displayName) のライブラリ「\(info.name)」に接続しますか？")
                    Button("接続") { confirm() }
                case .replacement(let address, let info):
                    Text("この端末に表示するライブラリを、\(address.displayName) の「\(info.name)」に置き換えますか？")
                    Button("置き換える", role: .destructive) { confirm(replacing: true) }
                case .connecting, .connected: ProgressView("ライブラリに接続中…")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("ホストに接続")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { reading?.cancel(); dismiss() }.disabled(submitting)
                }
            }
        }
        .interactiveDismissDisabled(submitting)
#if os(macOS)
        .frame(minWidth: 440, minHeight: 300)
#else
        .sheet(isPresented: $scanning) {
            NavigationStack {
                PairingScanner { value in
                    scanning = false
                    read(.text(value))
                }
                .navigationTitle("QRコードを読み取る")
                .toolbar { Button("キャンセル") { scanning = false } }
            }
        }
#endif
        .onAppear { if let input = request.input { read(input) } }
        .onDisappear { reading?.cancel() }
    }

    @ViewBuilder private var entry: some View {
        Section("ホストのアドレス") {
            TextField("ホストのアドレス", text: $address, prompt: Text("music.example.ts.net"))
                .labelsHidden()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .onSubmit { read(.text(address)) }
            Button("ライブラリを確認") { read(.text(address)) }.disabled(address.isEmpty)
        }
#if os(iOS)
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            Button("QRコードを読み取る") {
                Task {
                    if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                    else { cameraDenied = true }
                }
            }
            if cameraDenied { Text("アドレスを入力するか、設定でカメラへのアクセスを許可してください。") }
        }
#endif
    }

    private func read(_ input: HostInput) {
        reading?.cancel()
        reading = Task { await flow.read(input, using: transfer) }
    }

    private func confirm(replacing: Bool = false) {
        guard !submitting else { return }
        submitting = true
        Task {
            await flow.confirm(using: transfer, replacing: replacing)
            submitting = false
            if case .connected = flow.phase { dismiss() }
        }
    }
}

struct HostConnectionSettings: View {
    @ObservedObject var transfer: LocalTransfer
    let open: (HostSetupRequest) -> Void
    @State private var disconnecting = false
    @State private var message: String?

    var body: some View {
        if let host = transfer.hostConnection {
            LabeledContent("ライブラリ", value: host.name)
            LabeledContent("ホスト", value: host.address.displayName)
            Button("ライブラリを更新") {
                message = nil
                Task {
                    do {
                        let result = try await transfer.refreshHost()
                        if case .differentLibrary = result { return }
                        message = "ライブラリを更新しました。"
                    } catch { message = HostConnectionFlow.message(for: error) }
                }
            }.disabled(transfer.busy)
            if transfer.changedHostLibrary != nil {
                Button("ホストの新しいライブラリを確認") {
                    open(HostSetupRequest(input: .text(host.address.origin.absoluteString)))
                }
            }
            Button("接続先を変える") { open(HostSetupRequest()) }
            Button("接続を解除", role: .destructive) { disconnecting = true }
                .alert("接続を解除しますか？", isPresented: $disconnecting) {
                    Button("キャンセル", role: .cancel) {}
                    Button("接続を解除", role: .destructive) {
                        Task {
                            do { try await transfer.disconnectHost(); message = nil }
                            catch { message = "接続を解除できませんでした。" }
                        }
                    }
                } message: { Text("この端末に保存した音楽は、接続を解除した後も再生できます。") }
            if let message { Text(message).font(.callout) }
        } else {
            Button("ホストに接続") { open(HostSetupRequest()) }
            if transfer.clusterRegistration != nil || transfer.peerName != nil || transfer.pairedName != nil {
                DisclosureGroup("従来のライブラリ接続") { PeerSetupView(transfer: transfer) }
            }
        }
    }
}

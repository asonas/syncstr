import SwiftUI
#if os(macOS)
import CoreImage.CIFilterBuiltins
#else
import AVFoundation
import VisionKit
#endif

struct MusicImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if let url, url.isFileURL {
#if os(macOS)
            if let image = NSImage(contentsOf: url) { content(Image(nsImage: image)) }
            else { placeholder() }
#else
            if let image = UIImage(contentsOfFile: url.path) { content(Image(uiImage: image)) }
            else { placeholder() }
#endif
        } else { AsyncImage(url: url, content: content, placeholder: placeholder) }
    }
}

#if os(macOS)
struct LocalFolderButton: View {
    @ObservedObject var library: Library
    var body: some View {
        Button(library.refreshing ? "音楽を読み込み中…" : "音楽フォルダを選ぶ") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "選択"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { await library.chooseFolder(url) }
            }
        }.disabled(library.refreshing)
    }
}

struct MacPairingView: View {
    @ObservedObject var transfer: LocalTransfer
    var newPairing: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("iPhoneに音楽を持ち出す").font(.title2)
                Text("同じWi-FiでiPhoneのSyncstrを開き、このMacを選んでください。転送中は両方のアプリを開いてください。")
                if let name = transfer.pairedName {
                    LabeledContent("ペアリング済み", value: name)
                    Button("ペアリングを解除", role: .destructive) { Task { await transfer.forget() } }
                } else if !transfer.code.isEmpty {
                    if let qr = qrImage {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                            .padding(16).background(.white)
                            .accessibilityLabel("iPhoneで読み取るペアリング用QRコード")
                    }
                    Text("QRコードを読み取るか、次のコードをiPhoneに入力してください。")
                    Text(transfer.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("コードをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transfer.code, forType: .string)
                    }
                    Button("ペアリングをキャンセル") { Task { await transfer.forget() } }
                } else { Button("新しい端末をペアリング", action: newPairing) }
                if let name = transfer.pendingName {
                    Text("「\(name)」に音楽へのアクセスを許可しますか？")
                    HStack {
                        Button("許可する") { transfer.approve(true) }.buttonStyle(.borderedProminent)
                        Button("拒否する", role: .cancel) { transfer.approve(false) }
                    }
                }
                if let status = transfer.status { Text(status).foregroundStyle(.secondary) }
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
        }.frame(width: 480, height: 600)
    }

    private var qrImage: NSImage? {
        guard let payload = transfer.pairingPayload else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
    }
}
#else
struct PhonePairingView: View {
    @ObservedObject var transfer: LocalTransfer
    @State private var selected: String?
    @State private var code = ""
    @State private var scanning = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Macから音楽を持ち出す").font(.title2.bold())
            Text("Macで音楽フォルダを選び、同じWi-Fiで「iPhoneに転送」を開いてください。")
            if transfer.nearby.isEmpty {
                Text("Macを探しています。見つからない場合は、両方のアプリとローカルネットワークの許可を確認してください。")
                    .foregroundStyle(.secondary)
                Button("もう一度探す") { transfer.stopBrowsing(); transfer.browse() }
            }
            ForEach(transfer.nearby) { device in
                Button { selected = device.id; code = "" } label: {
                    HStack {
                        Text(device.name).lineLimit(2)
                        Spacer()
                        if selected == device.id { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityAddTraits(selected == device.id ? .isSelected : [])
            }
            if let selected, let device = transfer.nearby.first(where: { $0.id == selected }) {
                TextField("初回はMacのコードを入力", text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                if DataScannerViewController.isSupported {
                    Button("MacのQRコードを読み取る") {
                        Task {
                            if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                            else { transfer.status = "カメラが許可されていません。コードを入力するか、設定からカメラを許可してください。" }
                        }
                    }
                }
                Button("接続する") { transfer.connect(device, code: code, name: UIDevice.current.name) }
                    .buttonStyle(.borderedProminent).disabled(transfer.busy)
                Text("ペアリング済みの場合は、コードを入力せずに接続できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = transfer.status { Text(status).font(.callout).accessibilityIdentifier("transfer-status") }
            if transfer.busy {
                ProgressView(value: transfer.progress)
                Button("中断する") { transfer.cancel() }
            }
            if transfer.pairedName != nil || transfer.connected {
                Button("ペアリングを解除", role: .destructive) { Task { await transfer.forget() } }
            }
        }
        .task { await transfer.restorePairing(); if !Task.isCancelled { transfer.browse() } }
        .onDisappear { transfer.stopBrowsing() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { transfer.cancel(); transfer.stopBrowsing() }
            else if phase == .active { transfer.browse() }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                PairingScanner { value in
                    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count == 3, parts[0] == "syncstr-pair", "Syncstr-" + parts[1] == selected else {
                        transfer.status = "選択したMacのQRコードを読み取ってください。"
                        scanning = false
                        return
                    }
                    code = String(parts[2])
                    scanning = false
                }
                .navigationTitle("MacのQRコードを読み取る")
                .toolbar { Button("キャンセル") { scanning = false } }
            }
        }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { context.coordinator.onCode("") }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case let .barcode(barcode) in addedItems {
                if let code = barcode.payloadStringValue { delivered = true; onCode(code); return }
            }
        }
    }
}

struct AlbumTransferButton: View {
    @ObservedObject var transfer: LocalTransfer
    let tracks: [Track]
    var body: some View {
        VStack(spacing: 8) {
            Button("アルバムを保存") { transfer.copy(tracks) }
                .buttonStyle(.bordered).disabled(!transfer.connected || transfer.busy)
            if !transfer.connected {
                NavigationLink("Macに接続") { ScrollView { PhonePairingView(transfer: transfer).padding(24) } }
            }
            if transfer.busy { ProgressView(value: transfer.progress) }
            if let status = transfer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
#endif

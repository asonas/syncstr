import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
import VisionKit
#endif

struct AddMusicButton: View {
    @ObservedObject var library: Library
    @State private var importing = false

    var body: some View {
        if library.transfer.showsLibraryEditControls {
            VStack(alignment: .leading, spacing: 4) {
                Button("音楽ファイルを追加") { importing = true }
                    .disabled(library.refreshing || library.transfer.busy)
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                        switch result {
                        case .success(let files): Task { await library.addMusic(files) }
                        case .failure(let error): library.message = error.localizedDescription
                        }
                    }
            }
        }
    }
}

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
        }.disabled(library.refreshing || !library.transfer.canChooseFolder)
    }
}

#else
struct PairingScanner: UIViewControllerRepresentable {
    var onFailure: () -> Void
    var onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { Task { @MainActor in onFailure() } }
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

#endif

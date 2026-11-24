import SwiftUI
#if os(iOS)
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

#if os(iOS)
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

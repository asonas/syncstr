import SwiftUI

@main
struct SyncstrApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: Library
    @StateObject private var playback: PhonePlayback
    private let appearanceDefaults: UserDefaults

    init() {
        let library: Library
#if DEBUG
        if SharedAudioUIFixture.requested {
            do { library = try SharedAudioUIFixture.library()! }
            catch { fatalError("Cannot open isolated v5 fixture: \(error)") }
            appearanceDefaults = UserDefaults(suiteName: "syncstr-v5-ui")!
        } else if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            let defaults = UserDefaults(suiteName: "as.ason.syncstr.ui-fixture")!
            if ProcessInfo.processInfo.arguments.contains("--reset-appearance") { defaults.removeObject(forKey: "appearance") }
            appearanceDefaults = defaults
            do { library = try MobileUITestFixture.makeLibrary() }
            catch { fatalError("Cannot create UI test fixture: \(error)") }
        } else { library = Library(); appearanceDefaults = .standard }
#else
        library = Library()
        appearanceDefaults = .standard
#endif
        _library = StateObject(wrappedValue: library)
        _playback = StateObject(wrappedValue: PhonePlayback(library: library))
    }

    var body: some Scene {
        WindowGroup {
            PhoneWindow(library: library)
                .focusedSceneObject(library)
                .modifier(AppAppearance())
                .defaultAppStorage(appearanceDefaults)
                .tint(PhoneStyle.signal)
                .task {
                    _ = playback
                    await library.restoreLibrary()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        library.setBackgrounded(true)
                        library.transfer.cancel()
                        library.transfer.stopBrowsing()
                    } else if phase == .active {
                        library.setBackgrounded(false)
                        if library.transfer.hasHostActivity || (library.transfer.hasLibrarySource && !library.transfer.busy) {
                            library.transfer.refreshConnection()
                        }
                    }
                }
        }
        .commands { PlaybackCommands() }
    }
}

private struct PhonePresentationAnchor: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct PhoneWindow: View {
    @ObservedObject var library: Library
    @State private var hostSetup: HostSetupRequest?

    @State private var pendingLink: HostSetupRequest?
    @State private var presentationAnchor = UIView()

    var body: some View {
        PhoneRoot(library: library, hostSetup: $hostSetup)
            .onOpenURL { url in
                if let hostSetup { hostSetup.input = .link(url) }
                else { pendingLink = HostSetupRequest(input: .link(url)) }
            }
            .background { PhonePresentationAnchor(view: presentationAnchor).allowsHitTesting(false) }
            .task(id: pendingLink?.id) {
                guard let request = pendingLink else { return }
                while !Task.isCancelled {
                    if let root = presentationAnchor.window?.rootViewController {
                        if root.presentedViewController == nil, library.trackMetadataPresentation == nil,
                           !library.showingNowPlaying {
                            hostSetup = request
                            pendingLink = nil
                            return
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
    }
}

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
        if ProcessInfo.processInfo.arguments.contains("--v5-fixture") {
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
            PhoneRoot(library: library)
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
                        if library.transfer.clusterRegistration != nil && !library.transfer.busy { library.transfer.connectCluster() }
                    }
                }
        }
        .commands { PlaybackCommands() }
    }
}

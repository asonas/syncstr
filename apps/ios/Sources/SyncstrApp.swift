import SwiftUI

@main
struct SyncstrApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: Library
    @StateObject private var playback: PhonePlayback

    init() {
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _playback = StateObject(wrappedValue: PhonePlayback(library: library))
    }

    var body: some Scene {
        WindowGroup {
            PhoneRoot(library: library)
                .preferredColorScheme(.dark)
                .tint(PhoneStyle.signal)
                .task {
                    _ = playback
                    await library.restoreCredentials()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        library.transfer.cancel()
                        library.transfer.stopBrowsing()
                    }
                }
        }
    }
}

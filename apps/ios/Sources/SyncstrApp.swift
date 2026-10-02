import SwiftUI

@main
struct SyncstrApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            PhoneRoot(library: library)
                .preferredColorScheme(.dark)
                .tint(PhoneStyle.signal)
                .task { await library.restoreCredentials() }
        }
    }
}

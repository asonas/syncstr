#if DEBUG
    import Foundation

    @MainActor
    enum MobileUITestFixture {
        static func makeLibrary() throws -> Library {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-fixture-" + UUID().uuidString)
            let service = "as.ason.syncstr.ui-test." + UUID().uuidString
            let library = Library(
                localStore: LocalMusicStore(root: root),
                pairingSecrets: CredentialStore(service: service + ".pairing"),
                peerSecrets: CredentialStore(service: service + ".identity"),
                peerPairing: CredentialStore(service: service + ".peer"))
            let entries = (0..<281).map { index in
                LocalEntry(
                    track: Track(
                        id: "fixture-\(index)", title: "曲 \(index + 1) 夜の輪郭",
                        artist: index == 1 ? "Guest Artist" : "Fixture Ensemble", album: "Album \(index / 11 + 1)",
                        albumId: "album-\(index / 11)", duration: 10, track: index % 11 + 1, suffix: "wav", size: 44),
                    sha256: String(repeating: "a", count: 64), artwork: nil)
            }
            try library.openLocal(LocalCatalog(id: "ui-fixture", name: "UI Fixture", entries: entries))
            return library
        }
    }
#endif

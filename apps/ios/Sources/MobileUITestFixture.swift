#if DEBUG
    import Foundation

    @MainActor
    enum MobileUITestFixture {
        static func makeLibrary() throws -> Library {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-fixture-" + UUID().uuidString)
            let library = Library(localStore: LocalMusicStore(root: root))
            let entries = (0..<281).map { index in
                LocalEntry(
                    track: Track(
                        id: "fixture-\(index)", title: "曲 \(index + 1) 夜の輪郭",
                        artist: index == 1 ? "Guest Artist" : "Fixture Ensemble", album: "Album \(index / 11 + 1)",
                        albumId: "album-\(index / 11)", duration: 10, track: index % 11 + 1, suffix: "wav", size: 44,
                        addedAt: 1_700_000_000_000 - Int64(index)),
                    sha256: String(repeating: "a", count: 64), artwork: nil)
            }
            var catalog = LocalCatalog(id: "ui-fixture", name: "UI Fixture", entries: entries)
            if ProcessInfo.processInfo.arguments.contains("--retained-host") {
                catalog.source = .host
                catalog.organize()
                let database = try library.localStore.database()
                let host = try HostConnection(address: HostAddress("https://music.example.test"), library: catalog.id,
                                              name: catalog.name, hosts: [])
                try database.saveHostCatalog(CatalogUpdate(catalog: catalog, etag: "fixture"), connection: host, replacing: nil)
                _ = try database.forgetHost()
            } else {
                try library.openLocal(catalog)
            }
            return library
        }
    }
#endif

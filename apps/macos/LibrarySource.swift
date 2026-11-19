@MainActor
protocol LibrarySource: Sendable {
    func refreshCatalog() async throws -> LocalCatalog
    func download(_ entry: LocalEntry, cache: LocalMusicStore?, diagnostic: PlaybackDiagnosticContext?,
                  progress: @escaping @MainActor (Double) -> Void) async throws
    func recoverDownloadedFile(_ entry: LocalEntry) async throws
    func stop()
}

extension LibrarySource {
    func recoverDownloadedFile(_ entry: LocalEntry) async throws {}
}

struct ClusterLibrarySource: LibrarySource {
    let network: ClusterNetwork

    func refreshCatalog() async throws -> LocalCatalog {
        try await network.refresh()
    }

    func download(_ entry: LocalEntry, cache: LocalMusicStore?, diagnostic: PlaybackDiagnosticContext?,
                  progress: @escaping @MainActor (Double) -> Void) async throws {
        try await network.download(object: entry.sha256, track: entry.track.id, cache: cache,
                                   diagnostic: diagnostic, progress: progress)
    }

    func recoverDownloadedFile(_ entry: LocalEntry) async throws {
        try await network.recoverDownloadedFile(entry)
    }

    func stop() { network.stop() }
}

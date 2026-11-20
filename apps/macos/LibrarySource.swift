import Foundation

struct CatalogUpdate {
    var catalog: LocalCatalog
    var playlists: [PlaylistDocument] = []
    var conflicts: Set<String> = []
    var marker: String?
    var etag: String?
    var hostSwitch: String?
}

enum CatalogRefresh {
    case unchanged
    case updated(CatalogUpdate)
}

@MainActor
protocol LibrarySource: Sendable {
    func refreshCatalog() async throws -> CatalogRefresh
    func download(_ entry: LocalEntry, cache: LocalMusicStore?, diagnostic: PlaybackDiagnosticContext?,
                  progress: @escaping @MainActor (Double) -> Void) async throws
    func stop()
}

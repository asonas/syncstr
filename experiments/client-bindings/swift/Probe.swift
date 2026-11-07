import Foundation

@main struct Probe {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.lockfile").path
        let client = try Client.open(profilePath: path)
        do { _ = try Client.open(profilePath: path); fatalError("duplicate profile accepted") }
        catch ProbeError.ProfileUnavailable { }
        let pin = PinnedTrack(trackId: "logical-track-a", audioHash: "shared-audio")
        let catalog = try client.catalog()
        precondition(catalog == CatalogView(revision: 7, tracks: [pin, PinnedTrack(trackId: "logical-track-b", audioHash: "shared-audio")]))
        do { _ = try client.prepare(pin: PinnedTrack(trackId: "", audioHash: "hash")); fatalError("invalid pin accepted") }
        catch ProbeError.InvalidPin { }
        let result = try await client.prepare(pin: pin).complete()
        precondition(result == pin)
        MainActor.assertIsolated()
        let operation = try client.prepare(pin: pin)
        let pending = Task { try await operation.complete() }
        let deadline = Date().addingTimeInterval(5)
        while !operation.hasStarted() {
            precondition(Date() < deadline)
            await Task.yield()
        }
        operation.cancel()
        do { _ = try await pending.value; fatalError("late result accepted") }
        catch ProbeError.Cancelled { }
        client.shutdown()
        let reopened = try Client.open(profilePath: path)
        reopened.shutdown()
        do { _ = try client.prepare(pin: pin); fatalError("closed client accepted") }
        catch ProbeError.Closed { }
        reopened.shutdown()
        var disposable: Client? = try Client.open(profilePath: path)
        let disposableCatalog = try disposable?.catalog()
        precondition(disposableCatalog?.tracks.count == 2)
        disposable = nil
        let afterDisposal = try Client.open(profilePath: path)
        afterDisposal.shutdown()
        print("PASS Swift: typed pin/error, async MainActor return, explicit cancellation, shutdown/reopen")
    }
}

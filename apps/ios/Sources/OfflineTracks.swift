import CryptoKit
import Foundation

struct OfflineTracks {
    var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OfflineTracks", isDirectory: true)

    func url(account: String, id: String, suffix: String? = nil) -> URL {
        let suffix = suffix?.lowercased() ?? "mp3"
        let fileExtension = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "ogg", "opus", "alac"].contains(suffix) ? suffix : "mp3"
        return root.appendingPathComponent(hash(account), isDirectory: true)
            .appendingPathComponent(hash(id) + "." + fileExtension)
    }

    func contains(account: String, id: String, suffix: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: url(account: account, id: id, suffix: suffix).path)
    }

    func save(_ temporary: URL, account: String, id: String, suffix: String? = nil) throws {
        let destination = url(account: account, id: id, suffix: suffix)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = destination.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

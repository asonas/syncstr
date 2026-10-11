import Foundation

struct ClusterIdentity: Codable, Equatable {
    let id: String
    let memberID: String
    enum CodingKeys: String, CodingKey { case id, memberID = "member_id" }
    static func isLowercaseHex256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct ClusterKnownPeer: Codable, Equatable {
    let id: String
    let name: String
    let address: String?
}

struct ClusterLocation: Codable, Equatable {
    let libraryID: String
    let trackID: String
    let memberID: String?
    enum CodingKeys: String, CodingKey { case libraryID = "library_id", trackID = "track_id", memberID = "member_id" }
}

struct ClusterObject: Codable, Equatable {
    let sha256: String
    let bytes: Int64
    var locations: [ClusterLocation]
}

struct ClusterInventory: Codable, Equatable {
    let cluster: ClusterIdentity?
    let peers: [ClusterKnownPeer]
    let objects: [ClusterObject]
}

struct ClusterPendingChange: Codable, Equatable {
    let id: String
    let author: String
    let parents: [String]
    let operation: String

    func validate() throws {
        guard UUID(uuidString: id) != nil, ClusterIdentity.isLowercaseHex256(author),
              parents.count <= 64, Set(parents).count == parents.count,
              !parents.contains(id), parents.allSatisfy({ UUID(uuidString: $0) != nil }),
              operation.utf8.count <= 1024 * 1024,
              try JSONSerialization.jsonObject(with: Data(operation.utf8)) is [String: Any] else {
            throw LocalMusicError.invalidData
        }
    }
}

struct ClusterTransferJob: Codable, Equatable {
    enum State: String, Codable { case queued, running, complete }
    let id: String
    let sha256: String
    let source: String
    let destination: String
    var state: State
}

struct ClusterCapabilities: Codable, Equatable {
    var version = 0
    var membership = false
    var deletions = false
    var conflicts = false

    var allowsAutomaticWriter: Bool { version == 1 && membership && deletions && conflicts }

    init(version: Int = 0, membership: Bool = false, deletions: Bool = false, conflicts: Bool = false) {
        self.version = version
        self.membership = membership
        self.deletions = deletions
        self.conflicts = conflicts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        membership = try values.decodeIfPresent(Bool.self, forKey: .membership) ?? false
        deletions = try values.decodeIfPresent(Bool.self, forKey: .deletions) ?? false
        conflicts = try values.decodeIfPresent(Bool.self, forKey: .conflicts) ?? false
    }
}

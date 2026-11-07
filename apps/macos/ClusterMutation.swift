import Foundation

enum ClusterOperation: String, Codable, Sendable {
    case editTrack = "edit-track"
    case resolveTrack = "resolve-track"
    case updatePlaylists = "update-playlists"
}

enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(UInt64.self) { self = .unsignedInteger(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .integer(let decoded): try value.encode(decoded)
        case .unsignedInteger(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }

    fileprivate static func encoding<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

struct ClusterMutationRequest: Codable, Sendable, Equatable {
    let request: String
    let cluster: String
    let baseline: String
    let operation: ClusterOperation
    let expected: [String: [String]]
    let payload: JSONValue
    let confirmed: [JSONValue]
}

extension ClusterMutationRequest {
    init<Payload: Encodable, Confirmed: Encodable>(
        request: String = UUID().uuidString.lowercased(),
        cluster: String,
        baseline: String,
        operation: ClusterOperation,
        expected: [String: [String]],
        payload: Payload,
        confirmed: [Confirmed]
    ) throws {
        self.request = request
        self.cluster = cluster
        self.baseline = baseline
        self.operation = operation
        self.expected = expected
        self.payload = try JSONValue.encoding(payload)
        self.confirmed = try confirmed.map { try JSONValue.encoding($0) }
    }
}

struct ClusterMutationEnvelope: Encodable {
    let operation = "mutation"
    let mutation: ClusterMutationRequest
}

enum ClusterMutationRejection: String, Codable, Sendable {
    case invalid, unauthorized, revoked
    case clusterMismatch = "cluster-mismatch"
    case baselineMismatch = "baseline-mismatch"
}

enum ClusterMutationReply: Codable, Sendable, Equatable {
    case accepted(request: String, record: String, host: String, heads: [String: [String]])
    case needsReview(request: String, current: [String: [String]])
    case rejected(request: String, reason: ClusterMutationRejection)
    case deferred(request: String, reason: String)
    case unsupported(request: String, operation: String)

    private enum Status: String, Codable {
        case accepted, rejected, deferred, unsupported
        case needsReview = "needs-review"
    }
    private enum CodingKeys: String, CodingKey {
        case status, request, record, host, heads, current, reason, operation
    }

    var request: String {
        switch self {
        case .accepted(let request, _, _, _), .needsReview(let request, _),
             .rejected(let request, _), .deferred(let request, _), .unsupported(let request, _): request
        }
    }

    func validated(for request: String) throws -> Self {
        guard self.request == request else { throw LocalMusicError.invalidData }
        return self
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let request = try values.decode(String.self, forKey: .request)
        switch try values.decode(Status.self, forKey: .status) {
        case .accepted:
            self = .accepted(request: request, record: try values.decode(String.self, forKey: .record),
                host: try values.decode(String.self, forKey: .host), heads: try values.decode([String: [String]].self, forKey: .heads))
        case .needsReview:
            self = .needsReview(request: request, current: try values.decode([String: [String]].self, forKey: .current))
        case .rejected:
            self = .rejected(request: request, reason: try values.decode(ClusterMutationRejection.self, forKey: .reason))
        case .deferred:
            self = .deferred(request: request, reason: try values.decode(String.self, forKey: .reason))
        case .unsupported:
            self = .unsupported(request: request, operation: try values.decode(String.self, forKey: .operation))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request, forKey: .request)
        switch self {
        case .accepted(_, let record, let host, let heads):
            try values.encode(Status.accepted, forKey: .status)
            try values.encode(record, forKey: .record)
            try values.encode(host, forKey: .host)
            try values.encode(heads, forKey: .heads)
        case .needsReview(_, let current):
            try values.encode(Status.needsReview, forKey: .status)
            try values.encode(current, forKey: .current)
        case .rejected(_, let reason):
            try values.encode(Status.rejected, forKey: .status)
            try values.encode(reason, forKey: .reason)
        case .deferred(_, let reason):
            try values.encode(Status.deferred, forKey: .status)
            try values.encode(reason, forKey: .reason)
        case .unsupported(_, let operation):
            try values.encode(Status.unsupported, forKey: .status)
            try values.encode(operation, forKey: .operation)
        }
    }
}

struct ClusterHelloRefusalV5: Codable {
    let version: Int
    let status: String
    let reason: String
    let member: String
    let evidence: ClusterMembership

    func verifiedMembership(registration: ClusterRegistration, peer: String) throws -> ClusterMembership {
        let own = try registration.membership.chain(registration.localGrant)[0]
        guard version == 5, status == "rejected", reason == "revoked", member == own.member else {
            throw LocalMusicError.invalidData
        }
        let merged = try registration.membership.merging(evidence, presenter: peer)
        let host = try merged.authorize(peer, host: true)
        guard host.cluster == own.cluster, try merged.isEffectivelyRevoked(registration.localGrant) else {
            throw LocalMusicError.unauthorized
        }
        return merged
    }
}

struct ClusterHelloV5: Codable {
    let version: Int
    let proof: ClusterMembership
    let supportedOperations: Set<ClusterOperation>

    init(version: Int, proof: ClusterMembership, supportedOperations: Set<ClusterOperation> = []) {
        self.version = version
        self.proof = proof
        self.supportedOperations = supportedOperations
    }

    private enum CodingKeys: String, CodingKey {
        case version, proof
        case supportedOperations = "supported_operations"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        proof = try values.decode(ClusterMembership.self, forKey: .proof)
        let names = (try? values.decode([JSONValue].self, forKey: .supportedOperations)) ?? []
        supportedOperations = Set(names.compactMap {
            guard case .string(let name) = $0 else { return nil }
            return ClusterOperation(rawValue: name)
        })
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(proof, forKey: .proof)
        try values.encode(supportedOperations.map(\.rawValue).sorted(), forKey: .supportedOperations)
    }
}

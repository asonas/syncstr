import Foundation
import CryptoKit

enum ClusterCrypto {
    static func bytes(_ hex: String, count: Int) throws -> Data {
        guard hex.utf8.count == count * 2, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LocalMusicError.invalidData
        }
        let characters = Array(hex.utf8)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(decoding: characters[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    static func verify(id: String, author: String, signature: String, payload: Data) throws {
        guard SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == id,
              try Curve25519.Signing.PublicKey(rawRepresentation: bytes(author, count: 32))
                .isValidSignature(bytes(signature, count: 64), for: payload) else {
            throw LocalMusicError.unauthorized
        }
    }

    static func payload(_ domain: String, _ fields: [Any]) throws -> Data {
        var data = Data((domain + "\n").utf8)
        data.append(try JSONSerialization.data(withJSONObject: fields, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
        return data
    }
}

struct ClusterInvitation: Codable {
    let version: Int
    let cluster: String
    let host: String
    let secret: String
    let expires: UInt64
    var relay: String? = nil

    static func validatedRelay(_ value: String) throws -> String {
        guard value.utf8.count <= 2048, var url = URLComponents(string: value),
              let host = url.host, !host.isEmpty,
              (url.user ?? "").isEmpty, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port.map({ (1...65535).contains($0) }) ?? true else { throw LocalMusicError.invalidData }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        let loopback = host == "::1" || host == "[::1]" || (octets.count == 4 && octets[0] == 127 && octets.allSatisfy { (0...255).contains($0) })
        guard url.scheme == "https" || (url.scheme == "http" && loopback) else { throw LocalMusicError.invalidData }
        url.path = "/"
        guard let normalized = url.url?.absoluteString else { throw LocalMusicError.invalidData }
        return normalized
    }

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 16384 else { throw LocalMusicError.invalidData }
        var invitation = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard invitation.version == 1, UUID(uuidString: invitation.cluster) != nil,
              ClusterIdentity.isLowercaseHex256(invitation.host),
              ClusterIdentity.isLowercaseHex256(invitation.secret) else { throw LocalMusicError.invalidData }
        invitation.relay = try invitation.relay.map(validatedRelay)
        return invitation
    }
}

struct ClusterGrant: Codable, Equatable {
    let version: Int
    let id: String
    let cluster: String
    let issuer: String
    let member: String
    let host: Bool
    let authority: String?
    let signature: String

    func validate() throws {
        guard version == 1, UUID(uuidString: cluster) != nil,
              ClusterIdentity.isLowercaseHex256(member) else { throw LocalMusicError.invalidData }
        try ClusterCrypto.verify(id: id, author: issuer, signature: signature,
            payload: ClusterCrypto.payload("syncstr-enrollment-grant-v1", [version, cluster, issuer, member, host, authority as Any? ?? NSNull()]))
    }
}

struct ClusterRevocation: Codable, Equatable {
    let version: Int
    let id: String
    let cluster: String
    let issuer: String
    let member: String
    let authority: String
    let observed: [String]
    let changeHeads: [String]
    let signature: String
    enum CodingKeys: String, CodingKey {
        case version, id, cluster, issuer, member, authority, observed, signature
        case changeHeads = "change_heads"
    }

    func validate() throws {
        let references = observed + changeHeads
        guard version == 1, UUID(uuidString: cluster) != nil,
              ClusterIdentity.isLowercaseHex256(member), observed.count <= 4352, changeHeads.count <= 64,
              Set(references).count == references.count,
              references.allSatisfy(ClusterIdentity.isLowercaseHex256) else { throw LocalMusicError.invalidData }
        try ClusterCrypto.verify(id: id, author: issuer, signature: signature,
            payload: ClusterCrypto.payload("syncstr-membership-revocation-v1", [version, cluster, issuer, member, authority, observed, changeHeads]))
    }
}

struct ClusterMembership: Codable, Equatable {
    let root: String
    var grants: [ClusterGrant]
    var revocations: [ClusterRevocation]

    func chain(_ id: String) throws -> [ClusterGrant] {
        guard grants.count <= 4096, Set(grants.map(\.id)).count == grants.count,
              let leaf = grants.first(where: { $0.id == id }) else { throw LocalMusicError.unauthorized }
        let records = Dictionary(uniqueKeysWithValues: grants.map { ($0.id, $0) })
        var grant = leaf
        var seen = Set<String>()
        var chain: [ClusterGrant] = []
        while true {
            guard seen.count < 32, seen.insert(grant.id).inserted, grant.cluster == leaf.cluster else { throw LocalMusicError.unauthorized }
            try grant.validate()
            chain.append(grant)
            guard let authority = grant.authority else {
                guard grant.issuer == root, grant.member == root, grant.host else { throw LocalMusicError.unauthorized }
                return chain
            }
            guard let parent = records[authority], parent.member == grant.issuer, parent.host else { throw LocalMusicError.unauthorized }
            grant = parent
        }
    }

    func revocationState() throws -> (active: [Int], disputed: Set<String>) {
        guard revocations.count <= 256 else { throw LocalMusicError.invalidData }
        var unique = Set(grants.map(\.id))
        var chains: [[ClusterGrant]] = []
        for record in revocations {
            try record.validate()
            guard unique.insert(record.id).inserted else { throw LocalMusicError.invalidData }
            let authority = try chain(record.authority)
            guard authority[0].member == record.issuer, authority[0].host,
                  authority[0].cluster == record.cluster else { throw LocalMusicError.unauthorized }
            chains.append(authority)
        }
        var blockers = Array(repeating: [Int](), count: revocations.count)
        for (index, record) in revocations.enumerated() {
            for (other, revoked) in revocations.enumerated() where index != other {
                if (record.issuer == revoked.member && !revoked.observed.contains(record.id))
                    || chains[index].contains(where: { $0.issuer == revoked.member && !revoked.observed.contains($0.id) }) {
                    blockers[index].append(other)
                }
            }
        }
        var state = Array<Bool?>(repeating: nil, count: revocations.count)
        while true {
            var changed = false
            for (index, blockedBy) in blockers.enumerated() where state[index] == nil {
                if blockedBy.contains(where: { state[$0] == true }) {
                    state[index] = false; changed = true
                } else if blockedBy.allSatisfy({ state[$0] == false }) {
                    state[index] = true; changed = true
                }
            }
            if !changed { break }
        }
        var active: [Int] = []
        var disputed = Set<String>()
        for (index, value) in state.enumerated() {
            if value == true { active.append(index) }
            else if value == nil { disputed.insert(revocations[index].issuer); disputed.insert(revocations[index].member) }
        }
        return (active, disputed)
    }

    func verify(_ id: String) throws -> ClusterGrant {
        let chain = try chain(id)
        let state = try revocationState()
        let member = chain[0]
        guard !state.disputed.contains(member.member),
              chain.allSatisfy({ !state.disputed.contains($0.issuer) }) else { throw LocalMusicError.unauthorized }
        for index in state.active {
            let revoked = revocations[index]
            guard revoked.member != member.member,
                  chain.allSatisfy({ $0.issuer != revoked.member || revoked.observed.contains($0.id) }) else {
                throw LocalMusicError.unauthorized
            }
        }
        return member
    }

    func authorize(_ member: String, host: Bool = false) throws -> ClusterGrant {
        for grant in grants where grant.member == member && (!host || grant.host) {
            if let valid = try? verify(grant.id) { return valid }
        }
        throw LocalMusicError.unauthorized
    }

    func merging(_ incoming: Self, presenter: String) throws -> Self {
        guard root == incoming.root, let cluster = grants.first?.cluster else { throw LocalMusicError.unauthorized }
        var merged = self
        for grant in incoming.grants {
            guard grant.cluster == cluster else { throw LocalMusicError.unauthorized }
            if let existing = merged.grants.first(where: { $0.id == grant.id }) {
                guard existing == grant else { throw LocalMusicError.invalidData }
            } else { merged.grants.append(grant) }
        }
        _ = try merged.authorize(presenter, host: true)
        for revocation in incoming.revocations {
            guard revocation.cluster == cluster else { throw LocalMusicError.unauthorized }
            if let existing = merged.revocations.first(where: { $0.id == revocation.id }) {
                guard existing == revocation else { throw LocalMusicError.invalidData }
            } else { merged.revocations.append(revocation) }
        }
        for grant in merged.grants { _ = try merged.chain(grant.id) }
        _ = try merged.revocationState()
        return merged
    }
}

struct ClusterRegistration: Codable {
    let name: String
    let localGrant: String
    var membership: ClusterMembership
    var relay: String? = nil
}

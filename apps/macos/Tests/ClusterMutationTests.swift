import Foundation
import Testing
#if os(iOS)
@testable import Syncstr
#endif

private final class ClusterMutationTestBundle: NSObject {}

@MainActor
struct ClusterMutationTests {
    private let requestID = "b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f"

    private func json(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func requestMatchesTheHostMutationEnvelope() throws {
        struct Payload: Encodable { let track: String; let metadata: [String: String] }
        struct Approval: Encodable { let source: String; let track: String }
        let request = try ClusterMutationRequest(request: requestID, cluster: "cluster-example", baseline: "baseline",
            operation: .editTrack, expected: ["track:track-a": ["revision-1"]],
            payload: Payload(track: "track-a", metadata: ["title": "Edited title"]),
            confirmed: [Approval(source: "source-a", track: "track-a")])
        let expected = Data(#"""
        {"operation":"mutation","mutation":{
          "request":"b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f","cluster":"cluster-example","baseline":"baseline",
          "operation":"edit-track","expected":{"track:track-a":["revision-1"]},
          "payload":{"track":"track-a","metadata":{"title":"Edited title"}},
          "confirmed":[{"source":"source-a","track":"track-a"}]
        }}
        """#.utf8)
        let encoded = try JSONEncoder().encode(ClusterMutationEnvelope(mutation: request))
        #expect(try json(encoded) == json(expected))
        let restored = try JSONDecoder().decode(ClusterMutationRequest.self, from: JSONEncoder().encode(request))
        #expect(restored == request)
        let retry = try ClusterMutationRequest(request: restored.request, cluster: restored.cluster,
            baseline: restored.baseline, operation: .editTrack, expected: restored.expected,
            payload: Payload(track: "track-a", metadata: ["title": "Edited title"]),
            confirmed: [Approval(source: "source-a", track: "track-a")])
        #expect(retry == request)
    }

    @Test func defaultRequestIDIsALowercaseUUID() throws {
        let request = try ClusterMutationRequest(cluster: "cluster", baseline: "baseline", operation: .resolveTrack,
            expected: [:], payload: ["track": "track-a", "select": "revision-1"], confirmed: [String]())
        #expect(UUID(uuidString: request.request) != nil)
        #expect(request.request == request.request.lowercased())
        #expect(request.confirmed.isEmpty)
    }

    @Test func genericPayloadPreservesJSONTypesAndIntegerPrecision() throws {
        struct Payload: Encodable {
            let negative = Int64.min
            let positive = UInt64.max
            let decimal = 1.25
            let flag = true
            let empty: String? = nil
            enum CodingKeys: String, CodingKey { case negative, positive, decimal, flag, empty }
            func encode(to encoder: any Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(negative, forKey: .negative)
                try values.encode(positive, forKey: .positive)
                try values.encode(decimal, forKey: .decimal)
                try values.encode(flag, forKey: .flag)
                try values.encodeNil(forKey: .empty)
            }
        }
        let request = try ClusterMutationRequest(cluster: "cluster", baseline: "baseline", operation: .editTrack,
            expected: [:], payload: Payload(), confirmed: [String]())
        #expect(request.payload == .object(["negative": .integer(Int64.min), "positive": .unsignedInteger(UInt64.max),
            "decimal": .number(1.25), "flag": .bool(true), "empty": .null]))
        #expect(try JSONDecoder().decode(ClusterMutationRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func payloadAndConfirmationEncodingErrorsPropagate() throws {
        enum Failure: Error { case expected }
        struct Broken: Encodable {
            func encode(to encoder: any Encoder) throws { throw Failure.expected }
        }
        #expect(throws: Failure.self) {
            try ClusterMutationRequest(cluster: "cluster", baseline: "baseline", operation: .editTrack,
                expected: [:], payload: Broken(), confirmed: [String]())
        }
        #expect(throws: Failure.self) {
            try ClusterMutationRequest(cluster: "cluster", baseline: "baseline", operation: .updatePlaylists,
                expected: [:], payload: ["documents": [String]()], confirmed: [Broken()])
        }
    }

    @Test func everyHostReplyUsesTheExactTaggedWireShapeAndValidatesTheRequest() throws {
        // Tags and fields are defined by shared_audio_net::MutationReply's serde representation.
        let fixtures: [(String, ClusterMutationReply)] = [
            (#"{"status":"accepted","request":"b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f","record":"record-1","host":"host-a","heads":{"track:track-a":["record-1"]}}"#,
                .accepted(request: requestID, record: "record-1", host: "host-a", heads: ["track:track-a": ["record-1"]])),
            (#"{"status":"needs-review","request":"b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f","current":{"track:track-a":["revision-2","revision-3"]}}"#,
                .needsReview(request: requestID, current: ["track:track-a": ["revision-2", "revision-3"]])),
            (#"{"status":"rejected","request":"b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f","reason":"revoked"}"#,
                .rejected(request: requestID, reason: .revoked)),
            (#"{"status":"deferred","request":"b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f","reason":"store-unavailable"}"#,
                .deferred(request: requestID, reason: "store-unavailable")),
            (#"{"status":"unsupported","request":"b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f","operation":"future-operation"}"#,
                .unsupported(request: requestID, operation: "future-operation"))
        ]
        for (wire, expected) in fixtures {
            let data = Data(wire.utf8)
            let reply = try JSONDecoder().decode(ClusterMutationReply.self, from: data)
            #expect(reply == expected)
            #expect(try reply.validated(for: requestID) == expected)
            #expect(try json(JSONEncoder().encode(reply)) == json(data))
            do {
                _ = try reply.validated(for: "different-request")
                Issue.record("A reply for another request must be rejected")
            } catch LocalMusicError.invalidData {}
        }
    }

    @Test(arguments: ["invalid", "unauthorized", "revoked", "cluster-mismatch", "baseline-mismatch"])
    func rejectionReasonsMatchTheHost(_ reason: String) throws {
        let data = Data("""
        {"status":"rejected","request":"\(requestID)","reason":"\(reason)"}
        """.utf8)
        let reply = try JSONDecoder().decode(ClusterMutationReply.self, from: data)
        let expected = try #require(ClusterMutationRejection(rawValue: reason))
        #expect(reply == .rejected(request: requestID, reason: expected))
        #expect(try json(JSONEncoder().encode(reply)) == json(data))
    }

    @Test func malformedRepliesAreNotAccepted() {
        for wire in [#"{"status":"accepted","request":"request"}"#,
                     #"{"status":"rejected","request":"request","reason":"unknown"}"#,
                     #"{"status":"future-status","request":"request"}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ClusterMutationReply.self, from: Data(wire.utf8)) }
        }
    }

    @Test func helloDefaultsToNoOperationsAndIgnoresUnknownOrMalformedNames() throws {
        let url = try #require(Bundle(for: ClusterMutationTestBundle.self).url(forResource: "cluster-signed", withExtension: "json"))
        struct Fixture: Decodable { let membership: ClusterMembership }
        let proof = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).membership
        let data = try JSONEncoder().encode(ClusterHelloV5(version: 5, proof: proof))
        var wire = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        wire.removeValue(forKey: "supported_operations")
        let oldHello = try JSONDecoder().decode(ClusterHelloV5.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(oldHello.supportedOperations.isEmpty)
        let names: [Any] = ["edit-track", "resolve-track", "update-playlists", "future-operation", "edit-track", 42, NSNull()]
        wire["supported_operations"] = names
        let hello = try JSONDecoder().decode(ClusterHelloV5.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(hello.supportedOperations == [.editTrack, .resolveTrack, .updatePlaylists])
        wire["supported_operations"] = "edit-track"
        let malformed = try JSONDecoder().decode(ClusterHelloV5.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(malformed.supportedOperations.isEmpty)
    }
}

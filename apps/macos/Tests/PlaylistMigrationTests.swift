import Foundation
import Testing
#if os(iOS)
@testable import Syncstr
#endif

struct PlaylistMigrationTests {
    private func source() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Library Persistent ID": "source",
            "Tracks": ["1": ["Persistent ID": "song", "Name": "Song", "Artist": "Artist",
                             "Album": "Album", "Total Time": 120000, "Track Number": 1]],
            "Playlists": [
                ["Playlist Persistent ID": "system", "Name": "Music", "Master": true],
                ["Playlist Persistent ID": "folder", "Name": "Folder", "Folder": true],
                ["Playlist Persistent ID": "mix", "Parent Persistent ID": "folder", "Name": "Mix",
                 "Smart Info": Data([1, 2, 3]),
                 "Playlist Items": [["Track ID": 1], ["Track ID": 99], ["Track ID": 1]]],
                ["Playlist Persistent ID": "other", "Name": "Other"]
            ]
        ], format: .xml, options: 0)
    }

    @Test func selectionPreservesFoldersMissingTracksAndRepeatedOccurrences() throws {
        let entry = LocalEntry(track: Track(id: "destination", title: "Song", artist: "Artist", album: "Album",
                                           duration: 120, track: 1), sha256: String(repeating: "a", count: 64), artwork: nil)
        let draft = try PlaylistDraft.parse(source(), catalog: PlaylistMatchingCatalog(cluster: "shared", entries: [entry]))
        #expect(draft.playlists.count == 3)
        #expect(draft.songs["1"]?.candidates.count == 1)
        #expect(throws: (any Error).self) { try draft.documents(selected: [], accepted: [:]) }
        let unresolved = try draft.documents(selected: ["mix"], accepted: [:])
        #expect(unresolved.map(\.id) == ["source:folder", "source:mix"])
        #expect(unresolved[1].items.allSatisfy { $0.trackId == nil })
        let selected = try draft.documents(selected: ["mix"], accepted: ["1": "destination:" + entry.sha256])
        let mix = selected[1]
        #expect(mix.kind == "snapshot")
        #expect(mix.definition["Smart Info"] == "AQID")
        #expect(mix.items.map(\.sourceTrack) == ["song", "99", "song"])
        #expect(mix.items.map(\.trackId) == ["destination", nil, "destination"])
        #expect(Set(mix.items.map(\.id)).count == 3)
        #expect(throws: (any Error).self) { try draft.documents(selected: ["mix"], accepted: ["1": "unreviewed"]) }
    }

    @Test func ambiguousCandidatesRequireAnExplicitChoice() throws {
        let track = Track(id: "first", title: "Song", artist: "Artist", album: "Album", duration: 120, track: 1)
        var second = track
        second.id = "second"
        let entries = [LocalEntry(track: track, sha256: String(repeating: "a", count: 64), artwork: nil),
                       LocalEntry(track: second, sha256: String(repeating: "b", count: 64), artwork: nil)]
        let draft = try PlaylistDraft.parse(source(), catalog: PlaylistMatchingCatalog(cluster: "shared", entries: entries))
        #expect(draft.songs["1"]?.candidates.count == 2)
        #expect(try draft.documents(selected: ["mix"], accepted: [:])[1].items[0].trackId == nil)
        let resolved = try draft.documents(selected: ["mix"], accepted: ["1": "second:" + entries[1].sha256])
        #expect(resolved[1].items[0].trackId == "second")
    }

    @Test(arguments: ["missing", "empty", "whitespace"])
    func unsetAlbumsMatchOnlyCompatibleTracksAfterReview(_ representation: String) throws {
        var root = try #require(PropertyListSerialization.propertyList(from: source(), format: nil) as? [String: Any])
        var tracks = try #require(root["Tracks"] as? [String: [String: Any]])
        tracks["1"]?["Album"] = representation == "missing" ? nil : representation == "empty" ? "" : " \n"
        tracks["1"]?["Disc Number"] = 2
        root["Tracks"] = tracks
        let xml = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        let valid = Track(id: "compatible", title: "Song", artist: "Artist", album: "", duration: 120, track: 1, discNumber: 2)
        let alternatives = ["title", "artist", "album", "duration", "track", "disc"].map { field in
            Track(id: field, title: field == "title" ? "Other song" : "Song",
                  artist: field == "artist" ? "Other artist" : "Artist",
                  album: field == "album" ? "Named album" : "",
                  duration: field == "duration" ? 123 : 120,
                  track: field == "track" ? 2 : 1, discNumber: field == "disc" ? 1 : 2)
        }
        let entries = ([valid] + alternatives).map { LocalEntry(track: $0, sha256: String(repeating: "a", count: 64), artwork: nil) }
        let draft = try PlaylistDraft.parse(xml, catalog: PlaylistMatchingCatalog(cluster: "shared", entries: entries))
        #expect(draft.songs["1"]?.candidates.map(\.track.id) == ["compatible"])
        #expect(try draft.documents(selected: ["mix"], accepted: [:])[1].items[0].trackId == nil)
        let accepted = ["1": "compatible:" + entries[0].sha256]
        #expect(try draft.documents(selected: ["mix"], accepted: accepted)[1].items[0].trackId == "compatible")
    }

    @Test(arguments: ["Name", "Artist"])
    func missingRequiredMetadataDoesNotProduceCandidates(_ field: String) throws {
        var root = try #require(PropertyListSerialization.propertyList(from: source(), format: nil) as? [String: Any])
        var tracks = try #require(root["Tracks"] as? [String: [String: Any]])
        tracks["1"]?[field] = ""
        root["Tracks"] = tracks
        let xml = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        let track = Track(id: "destination", title: field == "Name" ? "" : "Song", artist: field == "Artist" ? "" : "Artist", album: "Album", duration: 120, track: 1)
        let entry = LocalEntry(track: track, sha256: String(repeating: "a", count: 64), artwork: nil)
        let draft = try PlaylistDraft.parse(xml, catalog: PlaylistMatchingCatalog(cluster: "shared", entries: [entry]))
        #expect(draft.songs["1"]?.candidates.isEmpty == true)
    }
}

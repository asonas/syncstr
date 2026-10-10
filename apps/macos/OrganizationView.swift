import SwiftUI

struct OrganizationView: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AlbumOrganization()
    @State private var error: String?
    @State private var newTitle = ""
    @State private var selectedTracks = Set<String>()
    @State private var reassociating: String?
    @State private var replacement = ""

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                Section("アルバムを作成") {
                    TextField("アルバム名", text: $newTitle)
                    Text("下の曲を選んで、ひとつのアルバムとしてまとめます。")
                        .foregroundStyle(.secondary)
                    Button("選択した曲をまとめる") {
                        let album = OrganizationAlbum(id: UUID().uuidString, title: newTitle)
                        draft.albums.append(album)
                        for id in selectedTracks { draft.set(subject: id, kind: "membership", value: album.id) }
                        selectedTracks = []
                        newTitle = ""
                    }.disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedTracks.isEmpty)
                }
                ForEach(Array(draft.proposals.enumerated()), id: \.offset) { _, proposal in
                    Section("「\(proposal[0].title)」の所属候補") {
                        Text("同じアルバム名を持つ別のグループです。発売版と収録曲を確認してください。")
                        ForEach(proposal) { album in
                            Text("\(album.title): \(members(album.id))")
                        }
                        Button("ひとつのアルバムにまとめる") {
                            do { try draft.join(proposal.map(\.id), confirmed: true) }
                            catch { self.error = error.localizedDescription }
                        }
                        Button("別のアルバムとして残す") {
                            draft.set(subject: proposal.map(\.id).joined(separator: ","), kind: "proposal", value: "dismissed")
                        }
                    }
                    .id("proposal:" + proposal.map(\.id).joined(separator: ","))
                }
                ForEach(draft.albums.filter { draft.canonical($0.id) == $0.id }) { album in
                    Section(album.title.isEmpty ? "アルバム名不明" : album.title) {
                        Text(draft.classificationEvidence(album.id)).foregroundStyle(.secondary)
                        Picker("分類", selection: Binding(get: {
                            draft.choice(subject: album.id, kind: "classification")?.value ?? "imported"
                        }, set: { draft.set(subject: album.id, kind: "classification", value: $0 == "imported" ? nil : $0) })) {
                            Text("元タグを使う").tag("imported")
                            Text("コンピレーション").tag("true")
                            Text("通常アルバム").tag("false")
                        }
                        conflicts(subject: album.id, kind: "classification")
                        ForEach(draft.tracks.filter { draft.canonicalTrack($0.id) == $0.id && draft.albumID(for: $0.id) == album.id }, id: \.id) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { selectedTracks.contains(record.id) }, set: {
                                    if $0 { selectedTracks.insert(record.id) } else { selectedTracks.remove(record.id) }
                                })) {
                                    Text(trackName(record.id))
                                }
                                if !available(record.id) { Text("音源が見つかりません").foregroundStyle(.secondary) }
                                Picker("所属", selection: Binding(get: {
                                    draft.choice(subject: record.id, kind: "membership")?.value ?? "imported"
                                }, set: { draft.set(subject: record.id, kind: "membership", value: $0 == "imported" ? nil : $0) })) {
                                    Text("元タグを使う").tag("imported")
                                    ForEach(draft.albums.filter { draft.canonical($0.id) == $0.id }) { target in
                                        Text(target.title.isEmpty ? "アルバム名不明" : target.title).tag(target.id)
                                    }
                                }
                                conflicts(subject: record.id, kind: "membership")
                                if !available(record.id) {
                                    Button("音源を関連付ける") { reassociating = record.id; replacement = "" }
                                }
                            }
                        }
                    }
                    .id("album:" + album.id)
                }
            }
            .navigationTitle("アルバムの整理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try library.saveOrganization(draft); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { reassociating != nil }, set: { if !$0 { reassociating = nil } })) {
                NavigationStack {
                    Form {
                        Text("「\(trackName(reassociating ?? ""))」の音源を選んでください。所属と選択を引き継ぎます。")
                        Picker("音源", selection: $replacement) {
                            Text("選択してください").tag("")
                            ForEach(library.tracks) { track in Text(track.title).tag(track.id) }
                        }
                    }
                    .navigationTitle("音源の関連付け")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { reassociating = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("関連付ける") {
                                guard let old = reassociating else { return }
                                do { try library.reassociate(old: old, replacement: replacement, organization: draft); dismiss() }
                                catch { self.error = error.localizedDescription }
                                reassociating = nil
                            }.disabled(replacement.isEmpty)
                        }
                    }
                }
            }
        }
        .onAppear { draft = library.localCatalog?.organization ?? AlbumOrganization() }
#if os(macOS)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 440, idealHeight: 640)
#endif
    }

    private func available(_ id: String) -> Bool { library.tracks.contains { draft.canonicalTrack($0.id) == id } }
    private func trackName(_ id: String) -> String {
        if let track = library.tracks.first(where: { draft.canonicalTrack($0.id) == id }) { return "\(track.title) — \(track.artist ?? "アーティスト不明")" }
        guard let record = draft.tracks.first(where: { $0.id == id }) else { return "不明な曲" }
        return "\(record.title ?? "不明な曲") — \(record.imported.artist ?? "アーティスト不明")"
    }
    private func members(_ id: String) -> String {
        draft.tracks.filter { draft.albumID(for: $0.id) == id }.map { trackName($0.id) }.joined(separator: "、")
    }
    @ViewBuilder private func conflicts(subject: String, kind: String) -> some View {
        if draft.hasConflict(subject: subject, kind: kind) {
            Text("端末間で選択が競合しています。採用する設定を選んでください。")
            ForEach(draft.heads(subject: subject, kind: kind)) { revision in
                Button(choiceLabel(revision)) { draft.set(subject: subject, kind: kind, value: revision.value) }
            }
        }
    }
    private func choiceLabel(_ revision: OrganizationChoice) -> String {
        let value = revision.value.map { value in
            if revision.kind == "membership" { return draft.albums.first { $0.id == draft.canonical(value) }?.title ?? value }
            return value == "true" ? "コンピレーション" : "通常アルバム"
        } ?? "元タグを使う"
        let local = draft.choice(subject: revision.subject, kind: revision.kind)?.id == revision.id
        return "\(local ? "現在の選択" : "受け取った選択"): \(value)"
    }
}

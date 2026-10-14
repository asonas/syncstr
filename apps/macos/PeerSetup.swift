import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
import VisionKit
#endif

struct ClusterImportResults: View {
    @ObservedObject var transfer: LocalTransfer
    @Environment(\.dismiss) private var dismiss
    @State private var restoration: (batch: String, item: String)?
    @State private var confirmingRestore = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(transfer.clusterBatches) { batch in
                    Section {
                        Text("優先する保存先: \(batch.host)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("他の保存先への複製は、それぞれの接続後に進みます。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(batch.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                if item.state == .stored {
                                    Text("保存先への追加を確認しました").foregroundStyle(.secondary)
                                    Text(item.storedHost ?? batch.host).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                } else {
                                    Text(item.error ?? "追加を待っています").foregroundStyle(.secondary)
                                }
                                if item.state == .awaitingRestore {
                                    Button("削除された音源を再追加…") {
                                        restoration = (batch.id, item.id); confirmingRestore = true
                                    }.disabled(transfer.busy)
                                }
                            }
                        }
                        if batch.items.contains(where: { ($0.state == .queued || $0.state == .failed) && $0.entry != nil }) {
                            Button("追加できなかった音源を再試行") { transfer.retryClusterBatch(batch.id) }.disabled(transfer.busy)
                        }
                        if !batch.awaitingDecision.isEmpty {
                            Text("保存先への追加を確認した\(batch.awaitingDecision.count)曲を、この端末にも残しますか？ 元のファイルと、追加できなかった音源は保持します。")
                            Button("この端末にも残す") { transfer.decideClusterCopies(batchID: batch.id, keep: true) }.disabled(transfer.busy)
                            Button("この端末のコピーを削除", role: .destructive) { transfer.decideClusterCopies(batchID: batch.id, keep: false) }.disabled(transfer.busy)
                        }
                    }
                }
                if transfer.busy { ProgressView(value: transfer.progress) }
                if let status = transfer.status { Text(status).foregroundStyle(.secondary) }
            }
            .navigationTitle("音源の追加結果")
            .toolbar { Button("閉じる") { dismiss() } }
            .alert("削除された音源を再追加しますか？", isPresented: $confirmingRestore) {
                Button("キャンセル", role: .cancel) {}
                Button("ライブラリに再追加") {
                    if let restoration { transfer.confirmClusterRestore(batchID: restoration.batch, itemID: restoration.item) }
                }
            } message: {
                Text("ライブラリで共有する音源として復元します。別の変更と競合した場合は、改めて内容を選べます。")
            }
        }
#if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 500)
#endif
    }
}

struct ClusterConflictsView: View {
    @ObservedObject var transfer: LocalTransfer
    @State private var conflict: ClusterObjectState?
    @State private var selected: String?
    @State private var confirming = false
    @State private var albumConflict: ClusterAlbumConflict?
    @State private var albumTitle: String?
    @State private var confirmingAlbum = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !transfer.clusterConflicts.isEmpty || !transfer.clusterAlbumConflicts.isEmpty {
                Text("変更が競合しています").font(.headline)
                Text("自動では内容を選びません。確認して優先する内容を選んでください。")
                    .foregroundStyle(.secondary)
            }
            ForEach(transfer.clusterAlbumConflicts) { album in
                Text("アルバム名の競合（\(album.objects.count)曲）").font(.headline)
                ForEach(album.titles, id: \.self) { title in
                    Button("「\(title)」を優先") {
                        albumConflict = album; albumTitle = title; confirmingAlbum = true
                    }.disabled(transfer.busy)
                }
                Divider()
            }
            ForEach(transfer.clusterConflicts, id: \.object) { state in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.heads, id: \.id) { head in
                        let entry = try? ClusterObjectState(object: state.object, heads: [head]).selected(in: transfer.clusterChanges)?.action.entry
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry?.track.title ?? "ライブラリから削除する変更")
                            if let artist = entry?.track.artist { Text(artist).foregroundStyle(.secondary) }
                            if let album = entry?.track.album { Text(album).foregroundStyle(.secondary) }
                            Text("変更した端末: \(head.author)").font(.system(.caption, design: .monospaced))
                            Button("この内容を優先") { conflict = state; selected = head.id; confirming = true }
                                .disabled(transfer.busy || (entry == nil && !canDelete))
                            if entry == nil && !canDelete {
                                Text("削除を優先する場合は、保存先の端末で解消してください。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider()
            }
        }
        .alert("選んだ内容で競合を解消しますか？", isPresented: $confirming) {
            Button("キャンセル", role: .cancel) {}
            Button("選んだ内容を優先") {
                if let conflict, let selected { transfer.resolveCluster(conflict, selected: selected) }
            }
        } message: {
            Text("保存先に解消結果を送信します。他の変更履歴は保持します。")
        }
        .alert("選んだアルバム名を優先しますか？", isPresented: $confirmingAlbum) {
            Button("キャンセル", role: .cancel) {}
            Button("このアルバム名を優先") {
                if let albumConflict, let albumTitle { transfer.resolveClusterAlbum(albumConflict, title: albumTitle) }
            }
        } message: {
            Text("競合している曲に同じアルバム名を適用します。確認後に別の変更が届いた場合は、再度確認できます。")
        }
    }

    private var canDelete: Bool {
        guard let registration = transfer.clusterRegistration else { return false }
        return (try? registration.membership.verify(registration.localGrant).host) ?? false
    }
}

struct PeerSetupView: View {
    @ObservedObject var transfer: LocalTransfer
    @State private var address = ""
    @State private var name = "ライブラリ"
    @State private var importing = false
    @State private var showingResults = false
    @State private var confirming = false
    @State private var confirmedAddress = ""
    @State private var confirmedID = ""
    @State private var updatingRegistration = false
#if os(iOS)
    @State private var scanning = false
    private enum Field: Hashable { case name, address }
    @FocusState private var editing: Field?
#endif

    private var parsedAddress: PeerAddress? { try? PeerAddress.parse(address) }
    private var invitation: ClusterInvitation? { try? ClusterInvitation.parse(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let registration = transfer.clusterRegistration, !updatingRegistration {
                Text(registration.name).font(.headline)
                Text("参加済みのライブラリです。再生と保存では、利用できる音源を自動で探します。")
                    .foregroundStyle(.secondary)
                DisclosureGroup("保存先と接続診断") {
                if let relay = registration.relay {
                    Text(relay).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityLabel("外部接続の中継先 \(relay)")
                }
                if let path = transfer.clusterLastPath {
                    Text(path == "direct" ? "直近の通信: 直接接続" : "直近の通信: 中継経由")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let hosts = Set(registration.membership.grants.filter {
                    $0.host && (try? registration.membership.verify($0.id)) != nil
                }.map(\.member)).sorted()
                ForEach(hosts, id: \.self) { host in
                    Text(host).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .accessibilityLabel("保存先の端末ID \(host)")
                }
                Text("この端末のID: \(transfer.peerID)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("ライブラリを更新") { transfer.connectCluster() }.disabled(transfer.busy)
                Button("接続設定を更新") {
                    name = registration.name
                    address = ""
                    updatingRegistration = true
                }.disabled(transfer.busy)
                Button("音源ファイルを追加") { importing = true }.disabled(transfer.busy)
                if !transfer.clusterBatches.isEmpty {
                    Button("音源の追加結果") { showingResults = true }
                }
                DisclosureGroup("変更の競合と端末の権限") {
                ClusterConflictsView(transfer: transfer)
                if !transfer.disputedMembers.isEmpty {
                    Text("端末の権限が競合しています").font(.headline)
                    Text("次の端末は、相互に矛盾する失効情報があるため接続を許可していません。保存先の管理者に確認してください。")
                        .foregroundStyle(.secondary)
                    ForEach(transfer.disputedMembers, id: \.self) { member in
                        Text(member).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if transfer.disputedMembers.isEmpty && transfer.clusterConflicts.isEmpty && transfer.clusterAlbumConflicts.isEmpty {
                    Text("確認が必要な競合はありません。表にない端末の追加や権限の変更は、ライブラリの管理者に依頼してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                Toggle("モバイル通信でも自動転送する", isOn: Binding(get: { transfer.automaticCellular }, set: { transfer.setAutomaticCellular($0) }))
                Text("オフの場合も、再生と保存を選ぶ操作はモバイル通信で利用できます。保存待ちの自動再開はWi-Fiを待ちます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
            Text(updatingRegistration ? "ライブラリの接続設定" : "既存のライブラリに参加").font(.headline)
            Text(updatingRegistration
                ? "同じライブラリの保存先から新しい招待を受け取り、貼り付けてください。登録済みのライブラリと保存した音源は保持されます。"
                : "ライブラリの管理者から受け取った招待を貼り付けてください。音源の保存先は自動で選ばれます。")
                .foregroundStyle(.secondary)
            DisclosureGroup("従来のP2P接続と端末ID") {
            Text("従来の接続情報を使う場合は、この端末のIDを接続先で許可してください。")
            Text("この端末のID")
            Text(transfer.peerID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("端末IDをコピー") {
#if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transfer.peerID, forType: .string)
#else
                UIPasteboard.general.string = transfer.peerID
#endif
            }.disabled(transfer.peerID.isEmpty)
            }
            TextField("接続先の名前", text: $name).textFieldStyle(.roundedBorder)
#if os(iOS)
                .focused($editing, equals: .name)
                .submitLabel(.done)
                .onSubmit { editing = nil }
#endif
            Text("招待または接続情報（JSON）")
            TextEditor(text: $address).font(.system(.caption, design: .monospaced)).frame(height: 100)
                .accessibilityLabel("接続先のアドレス情報")
#if os(iOS)
                .focused($editing, equals: .address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
#if os(iOS)
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                Button("接続先のQRコードを読み取る") {
                    editing = nil
                    Task {
                        if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                        else { transfer.status = "設定でカメラへのアクセスを許可するか、接続情報を貼り付けてください。" }
                    }
                }
            }
#endif
            if let target = invitation?.host ?? parsedAddress?.id {
                Text("接続先のID")
                Text(target).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("接続情報を読み取れません。接続先が出力したJSONを貼り付けてください。")
                    .foregroundStyle(.secondary)
            }
            Button("接続先を確認して登録") {
#if os(iOS)
                editing = nil
#endif
                guard let target = invitation?.host ?? parsedAddress?.id else { return }
                confirmedAddress = address
                confirmedID = target
                confirming = true
            }.buttonStyle(.borderedProminent)
                .disabled(transfer.busy || (updatingRegistration ? invitation == nil : (parsedAddress == nil && invitation == nil)))
            if updatingRegistration {
                Button("キャンセル") { updatingRegistration = false; address = "" }.disabled(transfer.busy)
            }
            if let savedName = transfer.peerName, !updatingRegistration {
                Text("登録済み: \(savedName)")
                Button("登録した接続先に再接続") { Task { await transfer.reconnectPeer() } }.disabled(transfer.busy)
                Button("P2Pの接続先を削除", role: .destructive) {
                    Task {
                        await transfer.forgetPeer()
                        if transfer.peerName == nil { address = ""; name = "ライブラリ" }
                    }
                }
            }
            if transfer.peerConnected && !updatingRegistration {
                Button("音源ファイルを接続先に追加") { importing = true }.disabled(transfer.busy)
            }
            }
            if transfer.busy {
                ProgressView(value: transfer.progress)
                Button("中断する") { transfer.cancel() }
            }
            if let status = transfer.status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
        .alert("この接続先を登録しますか？", isPresented: $confirming) {
            Button("キャンセル", role: .cancel) {}
            Button("登録して接続") {
                if (try? ClusterInvitation.parse(confirmedAddress)) != nil {
                    transfer.connectCluster(invitation: confirmedAddress, name: name)
                    updatingRegistration = false
                } else {
                    transfer.connectPeer(addressText: confirmedAddress, expected: confirmedID, name: name)
                }
            }
        } message: {
            Text("接続先のIDを、信頼できる接続先の画面や管理者の案内と照合してください。\n\n\(confirmedID)")
        }
#if os(iOS)
        .onDisappear { editing = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if editing != nil {
                    Spacer()
                    Button("完了") { editing = nil }
                }
            }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                PairingScanner { value in
                    scanning = false
                    if (try? PeerAddress.parse(value)) != nil || (try? ClusterInvitation.parse(value)) != nil { address = value; transfer.status = nil }
                    else { transfer.status = "Syncstrの接続情報を含むQRコードを読み取ってください。" }
                }
                .navigationTitle("接続先のQRコードを読み取る")
                .toolbar { Button("キャンセル") { scanning = false } }
            }
        }
#endif
        .task {
            await transfer.restorePeer()
            if address.isEmpty {
                address = transfer.peerAddressText
                name = transfer.peerName ?? "ライブラリ"
            }
        }
        .onChange(of: transfer.clusterRegistration?.localGrant) { _, grant in
            if grant != nil { address = ""; confirmedAddress = "" }
        }
        .onChange(of: transfer.busy) { _, busy in
            if !busy && transfer.clusterResultsPending {
                transfer.clusterResultsPending = false
                showingResults = true
            }
        }
        .sheet(isPresented: $showingResults) { ClusterImportResults(transfer: transfer) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): transfer.uploadPeer(files: files)
            case .failure(let error): transfer.status = error.localizedDescription
            }
        }
    }
}

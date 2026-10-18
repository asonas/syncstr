import SwiftUI
import UIKit

struct PhoneAlbumBrowser<Detail: View>: View {
    @ObservedObject var library: Library
    var hidden = false
    @ViewBuilder var detail: (Album) -> Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var searching = false
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var openedID: String?
    @State private var returnQuery: String?
    @State private var showingDetail = false
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @FocusState private var searchFocused: Bool

    private var albums: [Album] {
        library.sortedAlbums(
            (hidden ? library.hiddenAlbums : library.albums).filter {
                query.isEmpty || $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query)
            })
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160), spacing: 20)],
                spacing: 32
            ) {
                ForEach(albums) { album in
                    albumCard(album).id(album.id)
                }
            }
            .scrollTargetLayout()
            .padding(20)
        }
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? (hidden ? "非表示にしたアルバムはありません" : "アルバムはありません") : "一致するアルバムはありません",
                    systemImage: "square.stack")
            }
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        .background(PhoneStyle.graphite)
        .navigationTitle(hidden ? "非表示にしたアルバム" : "アルバム")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "アルバムを検索")
        .searchFocused($searchFocused)
        .toolbar { browserToolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .navigationDestination(isPresented: $showingDetail) {
            if let openedID, let album = library.album(id: openedID) { detail(album) }
        }
        .onChange(of: showingDetail) { _, visible in
            searchFocused = false
            if !visible {
                if let returnQuery { query = returnQuery }
                returnQuery = nil
                if let openedID { scrollPosition.scrollTo(id: openedID, anchor: .center) }
            }
        }
        .onChange(of: albums.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onKeyPress(.escape) {
            selecting = false
            selected.removeAll()
            searchFocused = false
            return .handled
        }
    }

    private func albumCard(_ album: Album) -> some View {
        Button {
            searchFocused = false
            if selecting { toggle(album.id) } else { open(album) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                PhoneArtwork(url: album.coverArt.flatMap { library.artworkURLs[$0] })
                    .overlay(alignment: .topTrailing) {
                        if selecting {
                            Image(systemName: selected.contains(album.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(.white, PhoneStyle.button)
                                .padding(8)
                        }
                    }
                Text(album.title).font(.subheadline.bold()).foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            .padding(4)
            .background(
                selected.contains(album.id) ? PhoneStyle.carbon : Color.clear, in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected.contains(album.id) ? PhoneStyle.signal : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(
            CommandAlbumClick {
                selecting = true
                toggle(album.id)
            }
        )
        .accessibilityLabel("\(album.title)、\(album.artist)")
        .accessibilityIdentifier("album-\(album.id)")
        .accessibilityAddTraits(selected.contains(album.id) ? .isSelected : [])
        .contextMenu {
            let targets = selected.contains(album.id) ? selected : [album.id]
            Button(hidden ? "非表示を解除する" : "非表示にする") {
                changeVisibility(targets)
            }.disabled(targets.contains(where: library.isSavingAlbumVisibility))
        }
    }

    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("並び替え", selection: $library.albumSortField) {
                    Text("タイトル").tag(AlbumSortField.title)
                    Text("アーティスト").tag(AlbumSortField.artist)
                }
                Picker("順序", selection: $library.albumSortDescending) {
                    Text("昇順").tag(false)
                    Text("降順").tag(true)
                }
            } label: {
                Image("album-sort").resizable().renderingMode(.template).frame(width: 24, height: 24)
            }
            .accessibilityLabel("並び替え")
            Button(selecting ? "完了" : "選択") {
                searchFocused = false
                selecting.toggle()
                selected.removeAll()
            }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if selecting {
            HStack {
                Text("\(selected.count)枚を選択")
                Spacer()
                Button(hidden ? "非表示を解除" : "非表示にする") { changeVisibility(selected) }
                    .disabled(selected.isEmpty || selected.contains(where: library.isSavingAlbumVisibility))
            }.padding(20).background(.regularMaterial)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func open(_ album: Album) {
        // Ending native search clears its text; restore the filter on return.
        returnQuery = query
        searching = false
        selected.removeAll()
        openedID = album.id
        showingDetail = true
    }

    private func changeVisibility(_ ids: Set<String>) {
        Task {
            await library.setAlbumsHidden(ids, hidden: !hidden).value
        }
    }
}

// SwiftUI's modifier-key gesture filter is macOS-only.
private struct CommandAlbumClick: UIGestureRecognizerRepresentable {
    var action: () -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.delaysTouchesBegan = true
        recognizer.delegate = context.coordinator
        return recognizer
    }
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            event.modifierFlags.contains(.command)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.modifierFlags.contains(.command)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

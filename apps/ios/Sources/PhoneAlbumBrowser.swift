import SwiftUI

struct PhoneAlbumBrowser<Detail: View>: View {
    @ObservedObject var library: Library
    var hidden = false
    @ViewBuilder var detail: (Album) -> Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var searching = false
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
        .onKeyPress(.escape) {
            searchFocused = false
            return .handled
        }
    }

    private func albumCard(_ album: Album) -> some View {
        Button {
            searchFocused = false
            open(album)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                PhoneArtwork(url: album.coverArt.flatMap { library.artworkURL(for: $0) })
                Text(album.title).font(.subheadline.bold()).foregroundStyle(AppearanceColors.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(album.artist).font(.subheadline).foregroundStyle(PhoneStyle.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(album.title)、\(album.artist)")
        .accessibilityIdentifier("album-\(album.id)")
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
        }
    }

    private func open(_ album: Album) {
        // Ending native search clears its text; restore the filter on return.
        returnQuery = query
        searching = false
        openedID = album.id
        showingDetail = true
    }
}

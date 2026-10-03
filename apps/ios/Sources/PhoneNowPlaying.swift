import SwiftUI

struct RegenIcon: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Image("regen-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PhoneArtwork: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            PhoneStyle.carbon.overlay {
                GeometryReader { geometry in
                    RegenIcon(name: "music", size: min(48, geometry.size.width * 0.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

struct PhoneNowPlaying: View {
    @ObservedObject var library: Library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var metadataSize = 18.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let track = library.current {
                    VStack(spacing: 0) {
                        PhoneArtwork(url: track.coverArt.flatMap { library.artworkURLs[$0] })
                            .frame(width: artworkSize(in: geometry.size))
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).fontWeight(.bold)
                                Text(track.artist ?? "アーティスト不明")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: metadataSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            Menu {
                                Button { library.download(track) } label: {
                                    Label("端末に保存", image: "regen-cloud-download")
                                }
                                .disabled(library.downloaded.contains(track.id) || library.downloading.contains(track.id))
                            } label: {
                                // The original SVG has a 3 pt transparent inset on its right.
                                RegenIcon(name: "dots")
                                    .offset(x: 3)
                                    .frame(width: 44, height: 44, alignment: .trailing)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("曲の操作")
                        }
                        .frame(minHeight: 52)
                        .padding(.leading, 32)
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)

                        VStack(spacing: 8) {
                            Slider(value: Binding(get: { library.position }, set: { library.seek(to: $0) }),
                                   in: 0...max(library.duration, 1))
                                .sliderThumbVisibility(.hidden)
                                .tint(.secondary)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                                .frame(height: 6)
                                .disabled(library.duration <= 0)
                                .accessibilityLabel("再生位置")
                                .accessibilityValue("\(time(library.position)) / \(time(library.duration))")
                            HStack {
                                Text(time(library.position))
                                Spacer()
                                Text("−\(time(max(0, library.duration - library.position)))")
                            }
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.leading, 32)
                        .padding(.trailing, 20)
                        .padding(.bottom, 32)

                        HStack(spacing: 32) {
                            Button { library.previous() } label: {
                                RegenIcon(name: "filled-skip-back", size: 36).frame(width: 64, height: 64)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!library.canGoPrevious).accessibilityLabel("前の曲")
                            Button { library.togglePlayback() } label: {
                                RegenIcon(name: library.playing || library.loading ? "filled-pause" : "filled-play", size: 48)
                                    .frame(width: 64, height: 64)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(library.playing || library.loading ? "一時停止" : "再生")
                            .accessibilityIdentifier("player-toggle")
                            Button { library.next() } label: {
                                RegenIcon(name: "filled-skip-forward", size: 36).frame(width: 64, height: 64)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!library.canGoNext).accessibilityLabel("次の曲")
                        }
                        .buttonStyle(.plain)
                        if library.loading {
                            ProgressView("読み込み中…").padding(.top, 16)
                        }
                    }
                    .padding(.top, 64)
                    .padding(.bottom, 32)
                } else {
                    ContentUnavailableView {
                        Label { Text("曲を選んでください") } icon: { RegenIcon(name: "music", size: 48) }
                    } description: {
                        Text("ライブラリまたは検索から音楽を選べます。")
                    }
                }
            }
        }
        .background(PhoneStyle.graphite)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func artworkSize(in size: CGSize) -> CGFloat {
        min(max(0, size.width - 40), dynamicTypeSize.isAccessibilitySize ? 120 : max(120, size.height - 280))
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}

import SwiftUI

/// “我喜欢的音乐”：所有平台上红心过的歌曲，独立于本地歌单。
struct LikedSongsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @StateObject private var selection = SongSelectionState()

    private var songs: [Song] {
        favorites.likedSongs
    }

    /// 搜索只影响可见列表；播放队列仍然是完整的喜欢列表。
    private var displayedSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return songs }
        return songs.filter { song in
            song.name.lowercased().contains(keyword)
                || song.artists.lowercased().contains(keyword)
        }
    }

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if songs.isEmpty {
                    EmptyStateView(icon: "heart", text: "还没有喜欢的歌曲\n在播放页点红心，或长按歌曲选“喜欢”")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            header
                            ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                                SelectableSongRow(selection: selection, song: song) {
                                    SongCell(
                                        song: song,
                                        showCover: true,
                                        suppressNativeCleanRowGlass: true,
                                        coverSize: 46,
                                        fixedRowHeight: 64,
                                        playbackContext: songs,
                                        playbackIndex: playbackIndex(for: song)
                                    ) {
                                        if selection.isActive {
                                            BeansHaptics.select()
                                            selection.toggle(song.identityKey)
                                        } else {
                                            player.play(songs: songs, startAt: playbackIndex(for: song))
                                        }
                                    }
                                }
                                .padding(.horizontal, 22)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 118)
                    }
                    .beansScrollIndicatorsHidden()
                    .beansSongSelectionBar(selection, songs: songs) { selected in
                        player.playNextInOrder(selected)
                    }
                }
            }
            .navigationTitle("我喜欢的音乐")
            .navigationBarTitleDisplayMode(.inline)
            .beansDetailProfileToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SongSelectionToggle(selection: selection)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                    player.play(songs: songs, startAt: 0)
                }
                GlassButton(title: "随机播放", systemName: "shuffle", forceLiquid: true) {
                    player.play(songs: songs, startAt: Int.random(in: 0..<songs.count))
                }
            }
            Text(beansSongCountText(songs.count))
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.beansComment)
                TextField("搜索喜欢的歌曲", text: $searchText)
                    .font(BeansFont.appFont(14))
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.beansComment)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private func playbackIndex(for song: Song) -> Int {
        songs.firstIndex { $0.identityKey == song.identityKey } ?? 0
    }
}

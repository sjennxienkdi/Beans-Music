import SwiftUI

/// “已下载”：app 下载过的歌曲。播放时直接用本地文件，离线可用。
struct DownloadedSongsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var downloads = DownloadLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @StateObject private var selection = SongSelectionState()
    @State private var shareFile: ShareFileItem?

    private var songs: [Song] {
        downloads.songs
    }

    /// 搜索只影响可见列表；播放队列仍然是完整的已下载列表。
    private var displayedSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return songs }
        return songs.filter { song in
            song.name.lowercased().contains(keyword)
                || song.artists.lowercased().contains(keyword)
        }
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)
        return "\(beansLocalSongCountText(songs.count)) · \(size)"
    }

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if songs.isEmpty {
                    EmptyStateView(
                        icon: "arrow.down.circle",
                        text: "还没有下载的歌曲\n长按歌曲选“下载歌曲”，下载后会出现在这里"
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            header
                            ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { _, song in
                                SelectableSongRow(selection: selection, song: song) {
                                    SongCell(
                                        song: song,
                                        showCover: true,
                                        suppressNativeCleanRowGlass: true,
                                        coverSize: 46,
                                        fixedRowHeight: 64,
                                        playbackContext: songs,
                                        playbackIndex: playbackIndex(for: song),
                                        extraMenuItems: AnyView(fileMenu(song))
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
                    .beansSongSelectionBar(
                        selection,
                        songs: songs,
                        onDelete: self.deleteDownloads,
                        onPlayNext: { selected in player.playNextInOrder(selected) }
                    )
                }
            }
            .navigationTitle("已下载")
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
            .sheet(item: $shareFile) { item in
                ShareSheet(items: [item.url])
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
            Text(subtitle)
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.beansComment)
                TextField("搜索已下载的歌曲", text: $searchText)
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

    /// 长按菜单里的文件操作：分享本地文件、删除这条下载。
    private func fileMenu(_ song: Song) -> some View {
        Group {
            if let entry = downloads.entry(for: song) {
                Button {
                    shareFile = ShareFileItem(
                        url: DownloadLibrary.directory.appendingPathComponent(entry.fileName)
                    )
                } label: {
                    Label("分享文件", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    deleteDownloads([song])
                } label: {
                    Label("删除下载", systemImage: "trash")
                }
            }
        }
    }

    private func deleteDownloads(_ selected: [Song]) {
        let count = selected.count
        downloads.removeDownloads(for: selected)
        selection.end()
        BeansHaptics.success()
        ToastCenter.shared.show(count == 1 ? "已删除下载" : "已删除 \(count) 首下载")
    }

    private func playbackIndex(for song: Song) -> Int {
        songs.firstIndex { $0.identityKey == song.identityKey } ?? 0
    }
}

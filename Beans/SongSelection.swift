import SwiftUI

/// 多选后点“加入歌单”时发给页面的请求，用来弹出加入面板。
struct SongSelectionAddRequest: Identifiable {
    let id = UUID()
    let songs: [Song]
}

/// 歌曲多选状态：歌单页、搜索结果、每日推荐、我喜欢共用。
final class SongSelectionState: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var selectedKeys: Set<String> = []
    /// 非空时页面弹出“加入歌单”面板（见 beansSongSelectionBar）。
    @Published var addRequest: SongSelectionAddRequest?

    var count: Int { selectedKeys.count }

    func begin() {
        selectedKeys = []
        isActive = true
    }

    func end() {
        isActive = false
        selectedKeys = []
    }

    func toggle(_ key: String) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }

    func selectAll(_ songs: [Song]) {
        selectedKeys = Set(songs.map(\.identityKey))
    }

    func clear() {
        selectedKeys = []
    }

    /// 按传入顺序返回被选中的歌曲。
    func selectedSongs(in songs: [Song]) -> [Song] {
        let keys = selectedKeys
        return songs.filter { keys.contains($0.identityKey) }
    }
}

extension PlayerManager {
    /// 把一批歌曲按顺序插到当前歌曲之后。
    /// playNext 每次都插在当前位置后面，所以倒着插入才能保持原顺序。
    func playNextInOrder(_ songs: [Song]) {
        for song in songs.reversed() {
            playNext(song)
        }
    }
}

/// 多选模式下包在歌曲行外面：行首显示勾选圈，未选中的行变淡。
/// 点击行是播放还是勾选，由页面在 onTap 里根据 selection.isActive 决定。
struct SelectableSongRow<Content: View>: View {
    @ObservedObject var selection: SongSelectionState
    let song: Song
    @ViewBuilder var content: () -> Content

    private var isSelected: Bool {
        selection.selectedKeys.contains(song.identityKey)
    }

    var body: some View {
        content()
            .opacity(selection.isActive && !isSelected ? 0.55 : 1)
            .overlay(alignment: .leading) {
                if selection.isActive {
                    ZStack {
                        Circle().fill(.regularMaterial)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.beansAmber : Color.beansComment)
                    }
                    .frame(width: 46, height: 46)
                    .allowsHitTesting(false)
                }
            }
    }
}

/// 导航栏上的“多选 / 完成”按钮。
struct SongSelectionToggle: View {
    @ObservedObject var selection: SongSelectionState

    var body: some View {
        Button(selection.isActive ? "完成" : "多选") {
            BeansHaptics.tap()
            if selection.isActive {
                selection.end()
            } else {
                selection.begin()
            }
        }
    }
}

/// 多选时的操作条：全选、加入歌单、下一首播放、取消。
struct SongSelectionBar: View {
    @ObservedObject var selection: SongSelectionState
    let songs: [Song]
    var onPlayNext: ([Song]) -> Void

    private var allSelected: Bool {
        let keys = Set(songs.map(\.identityKey))
        return !keys.isEmpty && keys.isSubset(of: selection.selectedKeys)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                BeansHaptics.select()
                if allSelected { selection.clear() } else { selection.selectAll(songs) }
            } label: {
                Text(allSelected ? "取消全选" : "全选")
                    .font(BeansFont.appFont(14, .medium))
                    .foregroundStyle(Color.beansAmber)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text("已选 \(selection.count) 首")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .monospacedDigit()
            actionButton("加入歌单", systemImage: "text.badge.plus", enabled: selection.count > 0) {
                selection.addRequest = SongSelectionAddRequest(songs: selection.selectedSongs(in: songs))
            }
            actionButton("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward", enabled: selection.count > 0) {
                onPlayNext(selection.selectedSongs(in: songs))
            }
            actionButton("取消", systemImage: "xmark", enabled: true) {
                selection.end()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(BeansFont.appFont(13, .semibold))
                .foregroundStyle(Color.beansAmber)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 观察多选状态的宿主：未激活时不占位，激活后由页面固定显示在顶部。
private struct SongSelectionBarHost: View {
    @ObservedObject var selection: SongSelectionState
    let songs: [Song]
    let onPlayNext: ([Song]) -> Void

    var body: some View {
        if selection.isActive {
            SongSelectionBar(selection: selection, songs: songs, onPlayNext: onPlayNext)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}

/// 承载“加入歌单”面板。单独做成一个观察 selection 的视图，
/// 保证 addRequest 变化时面板一定弹出来。
private struct SongSelectionAddSheetHost: View {
    @ObservedObject var selection: SongSelectionState

    var body: some View {
        EmptyView()
            .sheet(item: $selection.addRequest) { request in
                AddToLocalPlaylistSheet(songs: request.songs)
            }
    }
}

extension View {
    /// 给歌曲列表加上多选：激活时在顶部固定一条操作条，并负责弹出“加入歌单”面板。
    /// 操作条放在顶部而不是底部，避免和悬浮底栏、迷你播放器重叠。
    func beansSongSelectionBar(
        _ selection: SongSelectionState,
        songs: [Song],
        onPlayNext: @escaping ([Song]) -> Void
    ) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            SongSelectionBarHost(selection: selection, songs: songs, onPlayNext: onPlayNext)
        }
        .background {
            SongSelectionAddSheetHost(selection: selection)
        }
    }
}

import Foundation
import SwiftUI

/// 给歌单卡片加“保存到本地歌单”的长按菜单。还没有歌曲列表，所以会先取完整歌单。
extension View {
    func beansPlaylistSaveMenu(_ playlist: Playlist) -> some View {
        contextMenu {
            Button {
                PlaylistSaver.fetchAndSave(playlist)
            } label: {
                Label("保存到本地歌单", systemImage: "folder.badge.plus")
            }
        }
    }
}

/// “保存到本地歌单”的共用实现：把平台歌单存进本地音乐库，不依赖平台登录状态。
@MainActor
enum PlaylistSaver {
    /// 正在取歌曲的歌单，避免同一张歌单被重复点击时发起多次请求。
    private static var inFlight: Set<String> = []

    /// 歌单的来源标识：同一来源的同一歌单再次保存时据此合并。
    static func originKey(for playlist: Playlist) -> String {
        switch playlist.source {
        case .qishui:
            return "qishui:\(playlist.qishuiID ?? String(playlist.id))"
        case .bilibili:
            return "bilibili:\(playlist.bilibiliID ?? String(playlist.id))"
        case .netease, .qq, .kugou, .kuwo, .migu, .webdav:
            return "\(playlist.source.rawValue):\(playlist.id)"
        }
    }

    static func platformName(_ source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        case .kuwo: return "酷我音乐"
        case .migu: return "咪咕音乐"
        case .qishui: return "汽水音乐"
        case .bilibili: return "哔哩哔哩"
        case .webdav: return "WebDAV"
        }
    }

    /// 歌曲列表已经加载好时直接保存（歌单页里的按钮）。
    static func save(_ playlist: Playlist, songs: [Song]) {
        guard !songs.isEmpty else {
            ToastCenter.shared.show("歌单还没有加载出歌曲，请稍后再试", duration: 2.5)
            return
        }
        let result = LocalLibraryStore.shared.savePlatformPlaylist(
            name: playlist.name,
            songs: songs,
            coverURL: playlist.coverURL,
            sourceName: platformName(playlist.source),
            originKey: originKey(for: playlist)
        )
        BeansHaptics.success()
        ToastCenter.shared.show(
            result.merged
                ? "已更新「\(result.name)」，新增 \(result.added) 首"
                : "已保存「\(result.name)」（\(result.added) 首）到本地音乐库",
            duration: 2.6
        )
    }

    /// 还没有歌曲列表时（长按歌单卡片）：先取完整歌单再保存。
    static func fetchAndSave(_ playlist: Playlist) {
        let key = originKey(for: playlist)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        ToastCenter.shared.show("正在获取「\(playlist.name)」…", duration: 2)
        Task { @MainActor in
            defer { PlaylistSaver.inFlight.remove(key) }
            do {
                let songs = try await loadSongs(for: playlist)
                save(playlist, songs: songs)
            } catch {
                ToastCenter.shared.show("保存失败：\(error.localizedDescription)", duration: 3)
            }
        }
    }

    /// 与歌单页相同的取数路径，不走歌单页的界面状态。
    private static func loadSongs(for playlist: Playlist) async throws -> [Song] {
        switch playlist.source {
        case .kugou:
            return try await KugouMusicAPI.shared.playlistSongs(playlist: playlist)
        case .qq:
            let songs = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
            // 云端“我的喜欢”偶发返回空，此时用已同步到本机的 QQ 收藏。
            if songs.isEmpty, playlist.id == QQMusicAPI.qqLikedPlaylistID {
                return FavoritesStore.shared.qqFavoriteSongs
            }
            return songs
        case .qishui:
            let identifier = playlist.qishuiID ?? String(playlist.id)
            return try await QishuiAPI.shared.playlistSongs(id: identifier, forceRefresh: true) { _ in }
        case .bilibili:
            let identifier = playlist.bilibiliID ?? String(playlist.id)
            return try await BilibiliAPI.shared.collection(identifier, force: false).songs
        case .kuwo, .migu:
            return try await AdditionalCatalogSearchAPI.playlistSongs(source: playlist.source, id: playlist.id)
        case .netease, .webdav:
            return try await NetEaseAPI.shared.playlistTracks(id: playlist.id)
        }
    }
}

import Foundation

/// 收藏管理（红心 = 我喜欢）。
///
/// `likedSongs` 是统一的本地喜欢列表，所有平台的歌都记在这里，也是 `isLiked` 的唯一依据。
/// 各平台原来的收藏数组继续保留，供“一键同步歌单”、封面预取和云端同步使用。
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    /// QQ 红心收藏（本地持久化，供音乐库展示）
    @Published private(set) var qqFavoriteSongs: [Song] = []
    /// 网易云红心收藏（本地缓存 + 云端同步）
    @Published private(set) var neteaseFavoriteSongs: [Song] = []
    /// 酷狗红心收藏（本地持久化，酷狗暂无稳定云端红心写入接口）
    @Published private(set) var kugouFavoriteSongs: [Song] = []
    /// 酷狗官方歌单收藏的本地镜像，用于显示收藏状态，不替代设备本地歌单。
    @Published private(set) var kugouOfficialFavoriteSongs: [Song] = []
    /// 统一的“我喜欢”列表：所有平台的红心都在这里，最新喜欢的排在最前。
    @Published private(set) var likedSongs: [Song] = [] {
        didSet {
            likedKeys = Set(likedSongs.map(\.identityKey))
            saveSongs(likedSongs, key: likedKey)
        }
    }
    private var likedKeys: Set<String> = []

    private let defaults = UserDefaults.standard
    private let neteaseKey = "beans.fav.netease.v1"
    private let qqKey = "beans.fav.qq.v1"
    private let kugouKey = "beans.fav.kugou.v1"
    private let kugouOfficialKey = "beans.fav.kugou.official.v1"
    private let likedKey = "beans.fav.liked.v2"
    private static let likedMigrationKey = "beans.fav.liked.migrated.v1"

    private init() {
        qqFavoriteSongs = Self.loadSongs(qqKey)
        neteaseFavoriteSongs = Self.loadSongs(neteaseKey)
        kugouFavoriteSongs = Self.loadSongs(kugouKey)
        kugouOfficialFavoriteSongs = Self.loadSongs(kugouOfficialKey)
        likedSongs = Self.loadSongs(likedKey)
        migrateLegacyFavoritesIfNeeded()
    }

    /// 旧版本的红心含义是“在某个本地歌单里”，另有一部分分散在各平台的收藏数组里。
    /// 首次进入新版本时把它们一次性并入“我喜欢”，之后只认统一的喜欢列表。
    private func migrateLegacyFavoritesIfNeeded() {
        let migrationDefaults = UserDefaults.standard
        guard !migrationDefaults.bool(forKey: Self.likedMigrationKey) else { return }
        var keys = likedKeys
        var merged = likedSongs
        let legacyGroups: [[Song]] = [
            neteaseFavoriteSongs,
            qqFavoriteSongs,
            kugouFavoriteSongs,
            kugouOfficialFavoriteSongs,
            // 默认红心歌单：旧版播放在只有一个本地歌单时，红心就是把歌放进这里。
            LocalLibraryStore.shared.playlists
                .filter { $0.name == "我的收藏歌单" }
                .flatMap(\.songs),
        ]
        for group in legacyGroups {
            for song in group.reversed() where keys.insert(song.identityKey).inserted {
                merged.insert(song, at: 0)
            }
        }
        if merged.count != likedSongs.count {
            likedSongs = merged
        }
        migrationDefaults.set(true, forKey: Self.likedMigrationKey)
    }

    /// 该歌曲是否已喜欢（红心）
    func isLiked(_ song: Song?) -> Bool {
        guard let song else { return false }
        return likedKeys.contains(song.identityKey)
    }

    /// 设置红心。本地立即生效；已登录网易云 / QQ 时尽力同步到云端，失败不影响本地状态。
    func setLiked(_ song: Song, _ liked: Bool) {
        applyLocalLike(song, liked)
        switch song.source {
        case .netease:
            guard NetEaseAPI.shared.isLoggedIn else { return }
            Task { _ = try? await NetEaseAPI.shared.like(id: song.id, liked: liked) }
        case .qq:
            guard QQMusicAuth.shared.isLoggedIn, let mid = song.qqMid, !mid.isEmpty else { return }
            Task { _ = (try? await QQMusicAPI.shared.like(songmid: mid, liked: liked)) ?? false }
        case .kugou, .kuwo, .migu, .qishui, .bilibili, .webdav:
            return
        }
    }

    /// 切换红心。保留给旧调用方；现在云端失败不再回滚本地状态。
    @discardableResult
    func toggle(_ song: Song) async -> Bool {
        setLiked(song, !isLiked(song))
        return true
    }

    /// 把一批歌曲并入“我喜欢”（只增不删），例如云端同步回来的红心。
    func mergeLiked(_ songs: [Song]) {
        var merged = likedSongs
        var keys = likedKeys
        var changed = false
        for song in songs.reversed() where keys.insert(song.identityKey).inserted {
            merged.insert(song, at: 0)
            changed = true
        }
        if changed { likedSongs = merged }
    }

    /// 把网易云“我喜欢的音乐”合并进本地喜欢列表（只增不删）。
    @MainActor
    func syncNeteaseFromCloud(playlistID: Int) async {
        guard let songs = try? await NetEaseAPI.shared.playlistTracks(id: playlistID), !songs.isEmpty else { return }
        mergeLiked(songs)
    }

    private func setUnifiedLiked(_ song: Song, _ liked: Bool) {
        var songs = likedSongs
        songs.removeAll { $0.identityKey == song.identityKey }
        if liked { songs.insert(song, at: 0) }
        likedSongs = songs
    }

    private func applyLocalLike(_ song: Song, _ liked: Bool) {
        setUnifiedLiked(song, liked)
        // 各平台原来的收藏数组继续同步维护，旧代码仍会读取它们。
        switch song.source {
        case .netease:
            updateNetease(song, liked: liked)
        case .qq:
            updateQQ(song, liked: liked)
        case .kugou:
            updateKugou(song, liked: liked)
        case .kuwo, .migu, .qishui, .bilibili, .webdav:
            break
        }
    }

    func isOfficiallyLiked(_ song: Song?) -> Bool {
        guard let song else { return false }
        switch song.source {
        case .netease:
            return neteaseFavoriteSongs.contains { $0.id == song.id }
        case .kugou:
            return kugouOfficialFavoriteSongs.contains { $0.identityKey == song.identityKey }
        case .qq:
            return false
        case .kuwo, .migu, .qishui, .bilibili, .webdav:
            return false
        }
    }

    /// 移除 QQ 收藏（音乐库侧滑删除）
    func removeQQFavorite(_ song: Song) {
        updateQQ(song, liked: false)
        setUnifiedLiked(song, false)
    }

    /// 登录 QQ / 微信后从 QQ 音乐云端同步“我的喜欢”。
    /// 只有云端明确返回歌曲时才覆盖本地，避免接口空响应误清空收藏。
    @MainActor
    func syncQQFromCloud() async {
        guard QQMusicAuth.shared.isLoggedIn else { return }
        guard let songs = try? await QQMusicAPI.shared.favoriteSongs(), !songs.isEmpty else { return }
        qqFavoriteSongs = songs
        saveSongs(qqFavoriteSongs, key: qqKey)
        mergeLiked(songs)
    }

    /// 网易云“我喜欢的音乐”使用明确状态写入，避免普通官方歌单的本地缓存影响切换判断。
    @discardableResult
    func setNeteaseOfficial(_ song: Song, liked: Bool) async -> Bool {
        let previous = neteaseFavoriteSongs.contains { $0.id == song.id }
        updateNetease(song, liked: liked)
        do {
            let ok = try await NetEaseAPI.shared.like(id: song.id, liked: liked)
            if ok {
                setUnifiedLiked(song, liked)
            } else {
                updateNetease(song, liked: previous)
            }
            return ok
        } catch {
            updateNetease(song, liked: previous)
            return false
        }
    }

    private func updateNetease(_ song: Song, liked: Bool) {
        if liked {
            neteaseFavoriteSongs.removeAll { $0.id == song.id }
            neteaseFavoriteSongs.insert(song, at: 0)
        } else {
            neteaseFavoriteSongs.removeAll { $0.id == song.id }
        }
        saveSongs(neteaseFavoriteSongs, key: neteaseKey)
    }

    private func updateQQ(_ song: Song, liked: Bool) {
        qqFavoriteSongs.removeAll { existing in
            existing.identityKey == song.identityKey
                || (existing.qqMid != nil && song.qqMid != nil && existing.qqMid == song.qqMid)
        }
        if liked {
            qqFavoriteSongs.insert(song, at: 0)
        }
        saveSongs(qqFavoriteSongs, key: qqKey)
    }

    private func updateKugou(_ song: Song, liked: Bool) {
        if liked {
            kugouFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            kugouFavoriteSongs.insert(song, at: 0)
        } else {
            kugouFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(kugouFavoriteSongs, key: kugouKey)
    }

    private static func loadSongs(_ key: String) -> [Song] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Song].self, from: data) else { return [] }
        return saved
    }

    private func saveSongs(_ songs: [Song], key: String) {
        if let data = try? JSONEncoder().encode(songs) {
            defaults.set(data, forKey: key)
        }
    }

    /// 退出网易云登录时清空本地网易云收藏缓存（保留 QQ 收藏和“我喜欢”）
    func resetNetease() {
        neteaseFavoriteSongs = []
        defaults.removeObject(forKey: neteaseKey)
    }

    func markKugouOfficial(_ song: Song, liked: Bool) {
        if liked {
            kugouOfficialFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            kugouOfficialFavoriteSongs.insert(song, at: 0)
        } else {
            kugouOfficialFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(kugouOfficialFavoriteSongs, key: kugouOfficialKey)
        setUnifiedLiked(song, liked)
    }

    func markNeteaseOfficial(_ song: Song, liked: Bool) {
        updateNetease(song, liked: liked)
        setUnifiedLiked(song, liked)
    }
}

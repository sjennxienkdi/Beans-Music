import Foundation

/// 本地歌单（保存在设备本机，不依赖任何平台账号）
struct LocalPlaylist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var songs: [Song] = []
    var createdAt = Date()
    /// Optional metadata for playlists imported from another music app.
    var coverURL: URL?
    var sourceName: String?
    /// 由平台歌单保存而来时的来源标识（如 "netease:12345"），再次保存同一歌单时据此合并。
    var originKey: String?

    enum CodingKeys: String, CodingKey { case id, name, songs, createdAt, coverURL, sourceName, originKey }

    init(
        id: UUID = UUID(),
        name: String,
        songs: [Song] = [],
        createdAt: Date = Date(),
        coverURL: URL? = nil,
        sourceName: String? = nil,
        originKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.songs = songs
        self.createdAt = createdAt
        self.coverURL = coverURL
        self.sourceName = sourceName
        self.originKey = originKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名歌单"
        songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        originKey = try c.decodeIfPresent(String.self, forKey: .originKey)
    }
}

/// 本地音乐库：本地歌单的创建 / 删除 / 收藏歌曲，UserDefaults JSON 持久化（覆盖安装不丢失）
final class LocalLibraryStore: ObservableObject {
    static let shared = LocalLibraryStore()

    @Published var playlists: [LocalPlaylist] {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let key = "beans.localLibrary.playlists"

    private init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([LocalPlaylist].self, from: data) {
            playlists = list
        } else {
            playlists = []
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name)
        playlists.append(playlist)
        return playlist
    }

    /// Creates a local playlist with imported metadata while keeping the old
    /// createPlaylist(name:) behavior unchanged for existing callers.
    @discardableResult
    func createPlaylist(
        name: String,
        songs: [Song],
        coverURL: URL? = nil,
        sourceName: String? = nil
    ) -> LocalPlaylist {
        let playlist = LocalPlaylist(
            name: name,
            songs: songs,
            coverURL: coverURL,
            sourceName: sourceName
        )
        playlists.insert(playlist, at: 0)
        return playlist
    }

    /// Imports a playlist from the same link / JSON formats used by Moumusic.
    @discardableResult
    func importPlaylist(from input: String) async throws -> LocalPlaylist {
        let imported = try await BeansPlaylistImportService.importPlaylist(from: input)
        return createPlaylist(
            name: imported.name,
            songs: imported.songs,
            coverURL: imported.coverURL,
            sourceName: imported.sourceName
        )
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    func renamePlaylist(id: UUID, name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
    }

    /// 调整本地歌单顺序，顺序会随歌单一起持久化。
    func movePlaylist(id: UUID, offset: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard playlists.indices.contains(destination) else { return }
        var reordered = playlists
        reordered.swapAt(index, destination)
        playlists = reordered
    }

    /// 使用 List 的拖动结果更新顺序，显式重新赋值确保 @Published 与持久化都能触发。
    func movePlaylists(from offsets: IndexSet, to destination: Int) {
        var reordered = playlists
        reordered.move(fromOffsets: offsets, toOffset: destination)
        playlists = reordered
    }

    /// 添加歌曲到本地歌单（按 identityKey 去重）
    func addSong(_ song: Song, to id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[idx].songs.contains(where: { $0.identityKey == song.identityKey }) else { return }
        // 新收藏排在歌单最上方，符合“最近收藏优先”的显示顺序。
        playlists[idx].songs.insert(song, at: 0)
    }

    /// 批量添加歌曲到本地歌单（按 identityKey 去重），返回实际新增的数量。
    /// 只写回一次：逐首调用 addSong 会让每一首都把全部歌单重新编码并落盘。
    @discardableResult
    func addSongs(_ songs: [Song], to id: UUID) -> Int {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var identities = Set(playlists[idx].songs.map(\.identityKey))
        var inserted: [Song] = []
        for song in songs where identities.insert(song.identityKey).inserted {
            inserted.append(song)
        }
        guard !inserted.isEmpty else { return 0 }
        var updated = playlists
        // 新收藏排在歌单最上方，并保持传入顺序（最近加入的在最前）。
        updated[idx].songs.insert(contentsOf: inserted.reversed(), at: 0)
        playlists = updated
        return inserted.count
    }

    /// 把一张平台歌单保存为本地歌单。同一来源的同一歌单再次保存时合并新增歌曲，
    /// 不会重复建歌单。返回 (歌单名称, 新增数量, 是否合并到已有歌单)。
    func savePlatformPlaylist(
        name: String,
        songs: [Song],
        coverURL: URL?,
        sourceName: String?,
        originKey: String
    ) -> (name: String, added: Int, merged: Bool) {
        if let index = playlists.firstIndex(where: { $0.originKey == originKey }) {
            let existing = playlists[index]
            let added = addSongs(songs, to: existing.id)
            return (existing.name, added, true)
        }
        var seen = Set<String>()
        let uniqueSongs = songs.filter { seen.insert($0.identityKey).inserted }
        let playlist = LocalPlaylist(
            name: name,
            songs: uniqueSongs,
            coverURL: coverURL,
            sourceName: sourceName,
            originKey: originKey
        )
        playlists.insert(playlist, at: 0)
        return (name, uniqueSongs.count, false)
    }

    func containsSong(_ song: Song?) -> Bool {
        guard let song else { return false }
        return playlists.contains { $0.songs.contains { $0.identityKey == song.identityKey } }
    }

    @discardableResult
    func addToDefaultFavorites(_ song: Song, name: String = "我的收藏歌单") -> String {
        let playlist = playlists.first(where: { $0.name == name }) ?? createPlaylist(name: name)
        let before = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? 0
        addSong(song, to: playlist.id)
        let after = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? before
        return after > before ? "已加入「\(playlist.name)」" : "已在「\(playlist.name)」中"
    }

    @discardableResult
    func syncSongs(_ songs: [Song], intoPlaylistNamed name: String = "三平台喜欢") -> Int {
        var updated = playlists
        let targetIndex: Int
        if let index = updated.firstIndex(where: { $0.name == name }) {
            targetIndex = index
        } else {
            updated.append(LocalPlaylist(name: name))
            targetIndex = updated.index(before: updated.endIndex)
        }

        var merged = updated[targetIndex].songs
        var identities = Set(merged.map(\.identityKey))
        var added = 0
        for song in songs where identities.insert(song.identityKey).inserted {
            merged.append(song)
            added += 1
        }

        // 批量合并后只重新赋值一次，避免大歌单同步时逐首触发持久化。
        updated[targetIndex].songs = merged
        playlists = updated
        return added
    }

    func removeSong(playlistID: UUID, songIdentity: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songs.removeAll { $0.identityKey == songIdentity }
    }

    @discardableResult
    func removeSongFromAllPlaylists(_ song: Song) -> Int {
        var removed = 0
        for index in playlists.indices {
            let before = playlists[index].songs.count
            playlists[index].songs.removeAll { $0.identityKey == song.identityKey }
            removed += before - playlists[index].songs.count
        }
        return removed
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: key)
        }
    }
}

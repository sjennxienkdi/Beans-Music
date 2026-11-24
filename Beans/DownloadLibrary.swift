import Foundation

/// 一首已下载的歌曲：歌曲本身的平台信息 + 本地文件。
struct DownloadedSong: Codable, Identifiable, Equatable {
    /// 等于 song.identityKey，同时作为列表 id。
    let key: String
    let song: Song
    /// 相对下载目录的文件名。
    let fileName: String
    let quality: String
    let addedAt: Date
    let fileSize: Int64

    var id: String { key }
}

/// “已下载”索引：记录 app 下载过的歌曲和对应的本地文件。
/// 播放这些歌时优先用本地文件；索引放在 Application Support，不会出现在“文件”app 里。
final class DownloadLibrary: ObservableObject {
    static let shared = DownloadLibrary()

    @Published private(set) var items: [DownloadedSong] = [] {
        didSet { save() }
    }

    static let directoryName = "BeansDownloads"

    /// 下载目录：Documents/BeansDownloads，在“文件”app 的 Beans Music 文件夹下可见。
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private let indexURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansDownloadLibrary.json", isDirectory: false)
    }()

    private init() {
        load()
    }

    var songs: [Song] {
        items.map(\.song)
    }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    func entry(for song: Song) -> DownloadedSong? {
        items.first { $0.key == song.identityKey }
    }

    func contains(_ song: Song) -> Bool {
        entry(for: song) != nil
    }

    /// 本地文件仍然存在时返回它的地址；文件被用户从“文件”app 里删掉时顺带清掉记录。
    func existingFileURL(for song: Song) -> URL? {
        guard let entry = entry(for: song) else { return nil }
        let url = Self.directory.appendingPathComponent(entry.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let staleKey = entry.key
        items.removeAll { $0.key == staleKey }
        return nil
    }

    /// 登记一次成功的下载。同一首歌重复下载时替换旧文件。
    func record(song: Song, fileURL: URL, quality: String) {
        let key = song.identityKey
        if let old = entry(for: song) {
            let oldURL = Self.directory.appendingPathComponent(old.fileName)
            if oldURL != fileURL {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let entry = DownloadedSong(
            key: key,
            song: song,
            fileName: fileURL.lastPathComponent,
            quality: quality,
            addedAt: Date(),
            fileSize: size
        )
        var updated = items.filter { $0.key != key }
        updated.insert(entry, at: 0)
        items = updated
    }

    /// 删除下载记录，同时删除本地文件。
    func removeDownloads(for songs: [Song]) {
        let keys = Set(songs.map(\.identityKey))
        guard items.contains(where: { keys.contains($0.key) }) else { return }
        for entry in items where keys.contains(entry.key) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(entry.fileName))
        }
        items.removeAll { keys.contains($0.key) }
    }

    /// 启动时清理：本地文件已经不在的记录去掉。
    func pruneMissing() {
        let missing = items.filter {
            !FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent($0.fileName).path)
        }
        guard !missing.isEmpty else { return }
        let missingKeys = Set(missing.map(\.key))
        items.removeAll { missingKeys.contains($0.key) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([DownloadedSong].self, from: data) else { return }
        items = saved
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

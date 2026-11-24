import Foundation

final class AuthStore: ObservableObject {
    @Published var user: NetEaseUser?
    @Published var isLoggedIn = false
    @Published var playlists: [Playlist] = []
    /// 最近一次拉取歌单失败（通常是登录过期），音乐库据此显示重新登录入口。
    @Published var libraryLoadFailed = false

    private let defaults = UserDefaults.standard
    private let userKey = "beans.user"

    init() {
        if let data = defaults.data(forKey: userKey),
           let saved = try? JSONDecoder().decode(NetEaseUser.self, from: data) {
            user = saved
            isLoggedIn = true
            playlists = SyncedPlaylistCache.shared
                .cachedPlaylists(source: .netease, accountID: "\(saved.uid)")?
                .playlists ?? []
        }
    }

    @MainActor
    func finishLogin() async throws {
        var account: NetEaseUser?
        for attempt in 0..<3 {
            do {
                account = try await NetEaseAPI.shared.account()
                break
            } catch {
                if attempt == 2 { throw error }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        guard let account else { throw NetEaseError.unknown("获取账号信息失败") }
        let playlists = (try? await NetEaseAPI.shared.userPlaylists(uid: account.uid)) ?? []
        user = account
        self.playlists = playlists
        libraryLoadFailed = false
        if !self.playlists.isEmpty {
            SyncedPlaylistCache.shared.savePlaylists(
                self.playlists,
                source: .netease,
                accountID: "\(account.uid)"
            )
        }
        isLoggedIn = true
        if let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: userKey)
        }
        DiscoverCache.shared.invalidate(.netease)
        NotificationCenter.default.post(name: .beansNeteaseLoginDidUpdate, object: nil)
    }

    /// 刷新账号资料（VIP 状态等），登录后保持最新会员标识
    @MainActor
    func refreshAccount() async {
        guard let current = user else { return }
        if let fresh = try? await NetEaseAPI.shared.account() {
            user = fresh
            if let data = try? JSONEncoder().encode(fresh) {
                defaults.set(data, forKey: userKey)
            }
            if fresh.uid != current.uid {
                isLoggedIn = true
            }
        }
    }

    @MainActor
    func loadLibrary(force: Bool = false) async {
        guard let user else { return }
        let accountID = "\(user.uid)"
        if let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .netease, accountID: accountID) {
            playlists = cached.playlists
            if !force, SyncedPlaylistCache.shared.isFresh(cached), !BeansNetworkStatus.shared.isReachable {
                return
            }
        }
        if let fresh = try? await NetEaseAPI.shared.userPlaylists(uid: user.uid), !fresh.isEmpty {
            libraryLoadFailed = false
            playlists = fresh
            SyncedPlaylistCache.shared.savePlaylists(fresh, source: .netease, accountID: accountID)
            // 把网易云“我喜欢的音乐”并进本地“我喜欢”，在官方 App 里点过的红心也会出现。
            if let likedPlaylist = fresh.first(where: { $0.isNetEaseLikedPlaylist }) {
                await FavoritesStore.shared.syncNeteaseFromCloud(playlistID: likedPlaylist.id)
            }
        } else {
            // 每个网易云账号至少有“我喜欢的音乐”，所以拉取失败或为空、且网络可用时，视为登录失效。
            libraryLoadFailed = BeansNetworkStatus.shared.isReachable
        }
    }

    func logout() {
        NetEaseAPI.shared.clearCookies()
        user = nil
        playlists = []
        libraryLoadFailed = false
        isLoggedIn = false
        defaults.removeObject(forKey: userKey)
        DiscoverCache.shared.invalidate(.netease)
    }
}

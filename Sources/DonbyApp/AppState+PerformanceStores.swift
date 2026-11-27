import SwiftUI
import DonbyCore
import DonbyNetwork

@MainActor
public final class DonbyToastStore: ObservableObject {
    @Published public var message: ToastMessage? = nil

    public init() {}
}

struct AsyncAppStateHydrationPayload: Sendable {
    let urlMediaItems: [LocalOrURLMediaItem]?
    let iptvChannels: [IPTVChannelItem]?
    let cachedSeriesNames: [String: String]?
    let watchHistory: [WatchRecordItem]?
}

extension AppState {
    func computeHomeShelves() -> [HomeShelfSection] {
        var result: [HomeShelfSection] = []
        if showMyMedia && !libraryViews.isEmpty {
            var counts: [String: Int] = [:]
            for lib in libraryViews {
                if let count = lib.childCount ?? latestByLibrary[lib.id]?.count {
                    counts[lib.id] = count
                }
            }
            result.append(HomeShelfSection(
                id: "my_media",
                title: "我的媒体",
                kind: .library,
                items: libraryViews,
                countsByLibrary: counts
            ))
        }
        if showContinueWatching {
            var continueItems = resumeItems
            if !nextUpItems.isEmpty {
                var seenIds = Set(continueItems.map(\.id))
                var seenSeriesIds = Set(continueItems.compactMap { item -> String? in
                    if let sid = item.seriesId, !sid.isEmpty { return sid }
                    return item.isSeries ? item.id : nil
                })
                for candidate in nextUpItems {
                    guard seenIds.insert(candidate.id).inserted else { continue }
                    if let sid = candidate.seriesId, !sid.isEmpty {
                        guard seenSeriesIds.insert(sid).inserted else { continue }
                    }
                    continueItems.append(candidate)
                }
            }
            if !continueItems.isEmpty {
                result.append(HomeShelfSection(
                    id: "continue_watching",
                    title: "继续观看",
                    kind: .landscape,
                    items: continueItems
                ))
            }
        }
        if showFavorites && !favoriteItems.isEmpty {
            result.append(HomeShelfSection(
                id: "my_favorites",
                title: "我的收藏",
                kind: .poster,
                items: favoriteItems
            ))
        }
        if let extShelves = DonbyAppExtensionCenter.shared.plugin?.homeShelves(for: activeServer) {
            result.append(contentsOf: extShelves)
        }
        let allowAnimeOnHome = HomeHeroCurator.isAnimeFocusedServer(
            serverName: activeServer?.name,
            libraryViews: libraryViews,
            explicitAnimeMode: activeServer.flatMap { DonbyAppExtensionCenter.shared.plugin?.isAnimeModeActive(for: $0) }
        )
        for lib in libraryViews {
            if !allowAnimeOnHome && HomeHeroCurator.isAnimeLibraryName(lib.name) {
                continue
            }
            if let items = latestByLibrary[lib.id], !items.isEmpty {
                let displayItems = allowAnimeOnHome
                    ? items
                    : items.filter { !HomeHeroCurator.isAnimeOrAnimation($0, libraryName: lib.name) }
                guard !displayItems.isEmpty else { continue }
                result.append(HomeShelfSection(
                    id: "lib_\(lib.id)",
                    title: lib.name,
                    kind: .poster,
                    items: displayItems,
                    library: lib
                ))
            }
        }
        return result
    }

    func refreshCachedHomeShelvesIfNeeded() {
        let next = computeHomeShelves()
        if cachedHomeShelves != next {
            cachedHomeShelves = next
            homeRevision &+= 1
        }
    }

    func scheduleAsyncDiskHydration() {
        let urlKey = urlMediaStorageKey
        let iptvKey = iptvChannelsStorageKey
        let seriesKey = cachedSeriesNamesStorageKey
        let watchKey = watchHistoryStorageKey
        let activeId = activeServer?.id

        if let activeId {
            ServerHomeCacheStore.shared.preload(serverId: activeId)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let payload = Self.decodeInitialHydrationPayload(
                urlMediaStorageKey: urlKey,
                iptvChannelsStorageKey: iptvKey,
                cachedSeriesNamesStorageKey: seriesKey,
                watchHistoryStorageKey: watchKey
            )
            await MainActor.run {
                self?.applyInitialHydrationPayload(payload)
            }
        }
    }

    private nonisolated static func decodeInitialHydrationPayload(
        urlMediaStorageKey: String,
        iptvChannelsStorageKey: String,
        cachedSeriesNamesStorageKey: String,
        watchHistoryStorageKey: String
    ) -> AsyncAppStateHydrationPayload {
        let decoder = JSONDecoder()
        let defaults = UserDefaults.standard

        let urlMedia: [LocalOrURLMediaItem]? = defaults.data(forKey: urlMediaStorageKey).flatMap {
            try? decoder.decode([LocalOrURLMediaItem].self, from: $0)
        }
        let iptv: [IPTVChannelItem]? = defaults.data(forKey: iptvChannelsStorageKey).flatMap {
            try? decoder.decode([IPTVChannelItem].self, from: $0)
        }
        let seriesNames = defaults.dictionary(forKey: cachedSeriesNamesStorageKey) as? [String: String]
        let watchHistory: [WatchRecordItem]? = defaults.data(forKey: watchHistoryStorageKey).flatMap { data in
            guard let decoded = try? decoder.decode([WatchRecordItem].self, from: data) else { return nil }
            return sanitizeWatchHistory(decoded, cachedSeriesNames: seriesNames ?? [:])
        }

        return AsyncAppStateHydrationPayload(
            urlMediaItems: urlMedia,
            iptvChannels: iptv,
            cachedSeriesNames: seriesNames,
            watchHistory: watchHistory
        )
    }

    private nonisolated static func sanitizeWatchHistory(
        _ decoded: [WatchRecordItem],
        cachedSeriesNames: [String: String]
    ) -> [WatchRecordItem] {
        var sanitizedMap: [String: WatchRecordItem] = [:]
        var order: [String] = []

        for var item in decoded {
            let isLocal = item.sourceType == "本地文件" ||
                          item.sourceType == "Local" ||
                          (item.streamURLString?.hasPrefix("/") == true) ||
                          (item.streamURLString?.hasPrefix("file://") == true) ||
                          (item.sourceType == "原画直链" && item.embyItemId == nil && (item.title.contains(".mkv") || item.title.contains(".mp4")))

            if isLocal {
                item.sourceType = "本地文件"
                item.embyItemId = nil
                if let s = item.streamURLString, s.hasPrefix("file://") {
                    item.streamURLString = URL(string: s)?.path ?? s
                }
                let parsed = MediaTitleParser.parse(rawName: item.title)
                if parsed.mainTitle != item.title {
                    item.title = parsed.mainTitle
                    item.subtitle = parsed.subTitle
                }
            } else if item.sourceType == "原画直链" || item.embyItemId != nil {
                item.sourceType = "Emby"
                if item.title.hasPrefix("第") && (item.title.hasSuffix("集") || item.title.contains("集")),
                   let itemId = item.embyItemId, let sName = cachedSeriesNames[itemId], !sName.isEmpty {
                    let epSub = (item.subtitle != nil && !item.subtitle!.isEmpty) ? "\(item.subtitle!) · \(item.title)" : item.title
                    item.title = sName
                    item.subtitle = epSub
                }
            }

            let dedupKey: String
            if item.sourceType == "本地文件" {
                let normPath = item.streamURLString ?? item.title
                dedupKey = "local:\(normPath)"
            } else if let embyId = item.embyItemId, !embyId.isEmpty {
                dedupKey = "emby:\(embyId)"
            } else {
                dedupKey = "url:\(item.streamURLString ?? item.title)"
            }
            item.id = dedupKey

            if let existing = sanitizedMap[dedupKey] {
                var merged = existing
                if item.positionSeconds > existing.positionSeconds {
                    merged.positionSeconds = item.positionSeconds
                }
                if item.lastWatchedAt > existing.lastWatchedAt {
                    merged.lastWatchedAt = item.lastWatchedAt
                }
                if merged.subtitle == nil || merged.subtitle?.isEmpty == true {
                    merged.subtitle = item.subtitle
                }
                merged.mediaType = merged.mediaType ?? item.mediaType
                merged.seriesId = merged.seriesId ?? item.seriesId
                sanitizedMap[dedupKey] = merged
            } else {
                sanitizedMap[dedupKey] = item
                order.append(dedupKey)
            }
        }
        return Array(order.compactMap { sanitizedMap[$0] }.prefix(Self.maxWatchHistoryCount))
    }

    private func applyInitialHydrationPayload(_ payload: AsyncAppStateHydrationPayload) {
        let wasLoading = isLoadingFromDisk
        isLoadingFromDisk = true
        defer { isLoadingFromDisk = wasLoading }

        if !didMutateURLMediaBeforeHydration, let urlMedia = payload.urlMediaItems, self.urlMediaItems.isEmpty {
            self.urlMediaItems = urlMedia
        }
        if !didMutateIPTVChannelsBeforeHydration, let iptv = payload.iptvChannels, self.iptvChannels.isEmpty {
            self.iptvChannels = iptv
        }
        if !didMutateCachedSeriesNamesBeforeHydration, let names = payload.cachedSeriesNames, self.cachedSeriesNames.isEmpty {
            self.cachedSeriesNames = names
        }
        if !didMutateWatchHistoryBeforeHydration, let history = payload.watchHistory, self.watchHistory.isEmpty {
            self.watchHistory = history
        }
    }
}

extension ServerHomeCacheStore {
    public func cachedSnapshotInMemory(for serverId: UUID) -> ServerHomeSnapshot? {
        inMemorySnapshots[serverId]
    }

    public func loadSnapshotFromDiskAsync(for serverId: UUID) async -> ServerHomeSnapshot? {
        if let mem = inMemorySnapshots[serverId] {
            return mem
        }
        let dir = cacheDirectoryURL
        let decoded = await Task.detached(priority: .userInitiated) { () -> ServerHomeSnapshot? in
            let file = dir.appendingPathComponent("home_\(serverId.uuidString).json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(ServerHomeSnapshot.self, from: data)
        }.value
        if let decoded {
            inMemorySnapshots[serverId] = decoded
        }
        return decoded
    }

    public func preload(serverId: UUID) {
        guard inMemorySnapshots[serverId] == nil else { return }
        let dir = cacheDirectoryURL
        Task.detached(priority: .utility) { [weak self] in
            let file = dir.appendingPathComponent("home_\(serverId.uuidString).json")
            guard let data = try? Data(contentsOf: file),
                  let snap = try? JSONDecoder().decode(ServerHomeSnapshot.self, from: data) else {
                return
            }
            await MainActor.run {
                if self?.inMemorySnapshots[serverId] == nil {
                    self?.inMemorySnapshots[serverId] = snap
                }
            }
        }
    }
}

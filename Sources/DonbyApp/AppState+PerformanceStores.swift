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

struct HomeShelvesComputationInput: Sendable {
    let showMyMedia: Bool
    let showContinueWatching: Bool
    let showFavorites: Bool
    let libraryViews: [EmbyItem]
    let resumeItems: [EmbyItem]
    let nextUpItems: [EmbyItem]
    let favoriteItems: [EmbyItem]
    let latestByLibrary: [String: [EmbyItem]]
    let serverName: String?
    let explicitAnimeMode: Bool?
}

struct HomeShelfDraft: Sendable {
    let id: String
    let title: String
    let kind: HomeShelfSection.Kind
    let items: [EmbyItem]
    let library: EmbyItem?
    let countsByLibrary: [String: Int]
    let isLibraryShelf: Bool
}

extension AppState {
    private nonisolated static func computeHomeShelfDrafts(input: HomeShelvesComputationInput) -> [HomeShelfDraft] {
        var result: [HomeShelfDraft] = []
        if input.showMyMedia && !input.libraryViews.isEmpty {
            var counts: [String: Int] = [:]
            for lib in input.libraryViews {
                if let count = lib.childCount ?? input.latestByLibrary[lib.id]?.count {
                    counts[lib.id] = count
                }
            }
            result.append(HomeShelfDraft(
                id: "my_media",
                title: "我的媒体",
                kind: .library,
                items: input.libraryViews,
                library: nil,
                countsByLibrary: counts,
                isLibraryShelf: false
            ))
        }
        if input.showContinueWatching {
            var continueItems = input.resumeItems
            if !input.nextUpItems.isEmpty {
                var seenIds = Set(continueItems.map(\.id))
                var seenSeriesIds = Set(continueItems.compactMap { item -> String? in
                    if let sid = item.seriesId, !sid.isEmpty { return sid }
                    return item.isSeries ? item.id : nil
                })
                for candidate in input.nextUpItems {
                    guard seenIds.insert(candidate.id).inserted else { continue }
                    if let sid = candidate.seriesId, !sid.isEmpty {
                        guard seenSeriesIds.insert(sid).inserted else { continue }
                    }
                    continueItems.append(candidate)
                }
            }
            if !continueItems.isEmpty {
                result.append(HomeShelfDraft(
                    id: "continue_watching",
                    title: "继续观看",
                    kind: .landscape,
                    items: continueItems,
                    library: nil,
                    countsByLibrary: [:],
                    isLibraryShelf: false
                ))
            }
        }
        if input.showFavorites && !input.favoriteItems.isEmpty {
            result.append(HomeShelfDraft(
                id: "my_favorites",
                title: "我的收藏",
                kind: .poster,
                items: input.favoriteItems,
                library: nil,
                countsByLibrary: [:],
                isLibraryShelf: false
            ))
        }
        let allowAnimeOnHome = HomeHeroCurator.isAnimeFocusedServer(
            serverName: input.serverName,
            libraryViews: input.libraryViews,
            explicitAnimeMode: input.explicitAnimeMode
        )
        for lib in input.libraryViews {
            if !allowAnimeOnHome && HomeHeroCurator.isAnimeLibraryName(lib.name) {
                continue
            }
            if let items = input.latestByLibrary[lib.id], !items.isEmpty {
                let displayItems = allowAnimeOnHome
                    ? items
                    : items.filter { !HomeHeroCurator.isAnimeOrAnimation($0, libraryName: lib.name) }
                guard !displayItems.isEmpty else { continue }
                result.append(HomeShelfDraft(
                    id: "lib_\(lib.id)",
                    title: lib.name,
                    kind: .poster,
                    items: displayItems,
                    library: lib,
                    countsByLibrary: [:],
                    isLibraryShelf: true
                ))
            }
        }
        return result
    }

    private nonisolated static func materializeHomeShelves(
        drafts: [HomeShelfDraft],
        extShelves: [HomeShelfSection]
    ) -> [HomeShelfSection] {
        var result: [HomeShelfSection] = []
        result.reserveCapacity(drafts.count + extShelves.count)
        var insertedExt = false
        for draft in drafts {
            if draft.isLibraryShelf && !insertedExt {
                result.append(contentsOf: extShelves)
                insertedExt = true
            }
            result.append(HomeShelfSection(
                id: draft.id,
                title: draft.title,
                kind: draft.kind,
                items: draft.items,
                library: draft.library,
                countsByLibrary: draft.countsByLibrary
            ))
        }
        if !insertedExt {
            result.append(contentsOf: extShelves)
        }
        return result
    }

    private func makeHomeShelvesComputationInput() -> (input: HomeShelvesComputationInput, extShelves: [HomeShelfSection]) {
        let srv = activeServer
        let extShelves = DonbyAppExtensionCenter.shared.plugin?.homeShelves(for: srv) ?? []
        let explicitAnimeMode = srv.flatMap { DonbyAppExtensionCenter.shared.plugin?.isAnimeModeActive(for: $0) }
        let input = HomeShelvesComputationInput(
            showMyMedia: showMyMedia,
            showContinueWatching: showContinueWatching,
            showFavorites: showFavorites,
            libraryViews: libraryViews,
            resumeItems: resumeItems,
            nextUpItems: nextUpItems,
            favoriteItems: favoriteItems,
            latestByLibrary: latestByLibrary,
            serverName: srv?.name,
            explicitAnimeMode: explicitAnimeMode
        )
        return (input, extShelves)
    }

    func computeHomeShelves() -> [HomeShelfSection] {
        let (input, extShelves) = makeHomeShelvesComputationInput()
        let drafts = Self.computeHomeShelfDrafts(input: input)
        return Self.materializeHomeShelves(drafts: drafts, extShelves: extShelves)
    }

    func refreshCachedHomeShelvesIfNeeded() {
        guard !isLoadingFromDisk,
              !isBatchUpdatingHomeShelves,
              !isSuppressingHomeShelfRefresh,
              openedServerId != nil else { return }

        homeShelvesComputeTask?.cancel()
        homeShelvesComputeTask = nil
        homeShelvesGeneration &+= 1
        let (input, extShelves) = makeHomeShelvesComputationInput()

        if input.libraryViews.isEmpty
            && input.resumeItems.isEmpty
            && input.nextUpItems.isEmpty
            && input.favoriteItems.isEmpty
            && extShelves.isEmpty {
            if !cachedHomeShelves.isEmpty {
                cachedHomeShelves = []
                homeRevision &+= 1
            }
            return
        }

        // Compute synchronously on MainActor (< 0.5 ms in-memory array slicing) so
        // NativeEmbyHomeView mounts immediately with populated shelves in the same turn.
        let drafts = Self.computeHomeShelfDrafts(input: input)
        let next = Self.materializeHomeShelves(drafts: drafts, extShelves: extShelves)
        if cachedHomeShelves != next {
            cachedHomeShelves = next
            homeRevision &+= 1
        }
    }

    func resolvePluginImdbIds(for items: [EmbyItem], server: EmbyServerConfig) async -> [String: String] {
        guard let plugin = DonbyAppExtensionCenter.shared.plugin, plugin.isActive(for: server) else {
            return [:]
        }
        return await plugin.resolveImdbIds(for: items, server: server, maxCount: 16)
    }

    func scheduleHomeCurationAndRatingsEnrichment(
        for serverId: UUID,
        curationGeneration: UInt64,
        loadGeneration: UInt64,
        libraryViews: [EmbyItem],
        resumeItems: [EmbyItem],
        nextUpItems: [EmbyItem],
        favoriteItems: [EmbyItem],
        latestByLibrary: [String: [EmbyItem]],
        extraHeroCandidates: [EmbyItem],
        serverName: String?,
        explicitAnimeMode: Bool?,
        apiKey: String,
        targetServer: EmbyServerConfig?
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let nextCarousel = HomeHeroCurator.selectHeroItems(
                libraryViews: libraryViews,
                latestByLibrary: latestByLibrary,
                extraCandidates: extraHeroCandidates,
                fallbackResumes: resumeItems,
                serverName: serverName,
                explicitAnimeMode: explicitAnimeMode
            )
            let snapshot = ServerHomeCacheStore.ServerHomeSnapshot(
                libraryViews: libraryViews,
                resumeItems: resumeItems,
                nextUpItems: nextUpItems,
                favoriteItems: favoriteItems,
                latestByLibrary: latestByLibrary,
                carouselItems: nextCarousel,
                cachedAt: Date()
            )
            let cachedRatings = await MultiPlatformRatingService.shared.cachedRatingsByItemId(for: nextCarousel)

            let shouldEnrich: Bool = await MainActor.run {
                guard let self,
                      self.homeCurationGeneration == curationGeneration,
                      self.homeLoadGeneration == loadGeneration,
                      self.activeServer?.id == serverId else {
                    return false
                }
                if self.carouselItems != nextCarousel {
                    self.carouselItems = nextCarousel
                }
                self.isLoadingHome = false
                if !cachedRatings.isEmpty {
                    self.mergeRatingsBatch(cachedRatings)
                }
                ServerHomeCacheStore.shared.save(snapshot, for: serverId, explicitAnimeMode: explicitAnimeMode)
                if let srv = targetServer, !nextCarousel.isEmpty {
                    HomeArtworkPrewarmer.shared.prewarmShelfItems(
                        server: srv,
                        items: Array(nextCarousel.prefix(2)),
                        kind: .backdrop,
                        maxWidth: 2200,
                        priority: .veryHigh,
                        maxCount: 2
                    )
                }
                return true
            }
            guard shouldEnrich else { return }

            let poolForEnrichment: [EmbyItem] = {
                var seen = Set<String>()
                var pool: [EmbyItem] = []
                for item in nextCarousel where seen.insert(item.id).inserted {
                    pool.append(item)
                }
                for item in extraHeroCandidates where seen.insert(item.id).inserted {
                    pool.append(item)
                }
                for view in libraryViews {
                    for item in (latestByLibrary[view.id] ?? []).prefix(8) where seen.insert(item.id).inserted {
                        pool.append(item)
                    }
                }
                return Array(pool.prefix(48))
            }()
            guard !poolForEnrichment.isEmpty else { return }

            var bridgedImdbIds: [String: String] = [:]
            if let srv = targetServer, let self {
                bridgedImdbIds = await self.resolvePluginImdbIds(for: poolForEnrichment, server: srv)
            }
            let enriched = await MultiPlatformRatingService.shared.enrichRatings(
                for: poolForEnrichment,
                mdblistAPIKey: apiKey,
                resolvedImdbIds: bridgedImdbIds
            )
            guard !enriched.isEmpty else { return }
            let curated = HomeHeroCurator.selectHeroItems(
                libraryViews: libraryViews,
                latestByLibrary: latestByLibrary,
                extraCandidates: extraHeroCandidates,
                ratingsByItemId: enriched,
                fallbackResumes: resumeItems,
                serverName: serverName,
                explicitAnimeMode: explicitAnimeMode
            )
            await MainActor.run {
                guard let self,
                      self.homeCurationGeneration == curationGeneration,
                      self.homeLoadGeneration == loadGeneration,
                      self.activeServer?.id == serverId else { return }
                self.mergeRatingsBatch(enriched)
                if self.carouselItems != curated {
                    self.carouselItems = curated
                    let updatedSnapshot = ServerHomeCacheStore.ServerHomeSnapshot(
                        libraryViews: libraryViews,
                        resumeItems: resumeItems,
                        nextUpItems: nextUpItems,
                        favoriteItems: favoriteItems,
                        latestByLibrary: latestByLibrary,
                        carouselItems: curated,
                        cachedAt: Date()
                    )
                    ServerHomeCacheStore.shared.save(updatedSnapshot, for: serverId, explicitAnimeMode: explicitAnimeMode)
                }
            }
        }
    }

    func scheduleAsyncDiskHydration() {
        let urlKey = urlMediaStorageKey
        let iptvKey = iptvChannelsStorageKey
        let seriesKey = cachedSeriesNamesStorageKey
        let watchKey = watchHistoryStorageKey
        let allServers = servers
        let activeSrv = activeServer

        for server in allServers {
            ServerHomeCacheStore.shared.preload(serverId: server.id)
        }
        if let activeSrv {
            Task {
                if let snap = await ServerHomeCacheStore.shared.loadSnapshotFromDiskAsync(for: activeSrv.id) {
                    HomeArtworkPrewarmer.shared.prewarmHome(
                        server: activeSrv,
                        carouselItems: snap.carouselItems,
                        libraryViews: snap.libraryViews,
                        resumeItems: snap.resumeItems,
                        nextUpItems: snap.nextUpItems,
                        latestByLibrary: snap.latestByLibrary
                    )
                } else if let baseURL = URL(string: activeSrv.activeBaseURL) {
                    ArtworkDownloadManager.shared.prewarmOrigin(for: baseURL, server: activeSrv)
                }
            }
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

@MainActor
private final class ServerHomeModeCacheBox {
    static let shared = ServerHomeModeCacheBox()
    var snapshotsByCompositeKey: [String: ServerHomeCacheStore.ServerHomeSnapshot] = [:]
    var lastSyncedAtByCompositeKey: [String: Date] = [:]
    var inFlightLoadsByCompositeKey: [String: Task<ServerHomeCacheStore.ServerHomeSnapshot?, Never>] = [:]
}

extension ServerHomeCacheStore {
    public static let swrFreshnessTTL: TimeInterval = 120

    private static func modeKey(for explicitAnimeMode: Bool?) -> String {
        switch explicitAnimeMode {
        case .some(true): return "anime"
        case .some(false): return "normal"
        case .none: return "default"
        }
    }

    @MainActor
    private static func resolveModeKey(for serverId: UUID) -> String {
        guard let server = AppState.sharedInstance?.servers.first(where: { $0.id == serverId }),
              let isAnime = DonbyAppExtensionCenter.shared.plugin?.isAnimeModeActive(for: server) else {
            return "default"
        }
        return modeKey(for: isAnime)
    }

    private static func compositeKey(serverId: UUID, modeKey: String) -> String {
        "\(serverId.uuidString)|\(modeKey)"
    }

    private func diskFileURL(serverId: UUID, modeKey: String) -> URL {
        let filename = modeKey == "default"
            ? "home_\(serverId.uuidString).json"
            : "home_\(serverId.uuidString)_\(modeKey).json"
        return cacheDirectoryURL.appendingPathComponent(filename)
    }

    @MainActor
    public func markSyncedNow(for serverId: UUID, explicitAnimeMode: Bool?, at date: Date = Date()) {
        let key = explicitAnimeMode.map { Self.modeKey(for: $0) } ?? Self.resolveModeKey(for: serverId)
        let cKey = Self.compositeKey(serverId: serverId, modeKey: key)
        ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey[cKey] = date
    }

    @MainActor
    public func isSnapshotFresh(for serverId: UUID, ttl: TimeInterval = ServerHomeCacheStore.swrFreshnessTTL) -> Bool {
        let key = Self.resolveModeKey(for: serverId)
        let cKey = Self.compositeKey(serverId: serverId, modeKey: key)
        let syncedAt = ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey[cKey]
            ?? cachedSnapshotInMemory(for: serverId)?.cachedAt
        guard let syncedAt else { return false }
        return Date().timeIntervalSince(syncedAt) < ttl
    }

    @MainActor
    public func save(_ snapshot: ServerHomeSnapshot, for serverId: UUID, explicitAnimeMode: Bool?) {
        let key = Self.modeKey(for: explicitAnimeMode)
        let cKey = Self.compositeKey(serverId: serverId, modeKey: key)
        ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] = snapshot
        ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey[cKey] = snapshot.cachedAt
        if key == "default" {
            inMemorySnapshots[serverId] = snapshot
        }
        let file = diskFileURL(serverId: serverId, modeKey: key)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    @MainActor
    public func cachedSnapshotInMemory(for serverId: UUID) -> ServerHomeSnapshot? {
        let key = Self.resolveModeKey(for: serverId)
        let cKey = Self.compositeKey(serverId: serverId, modeKey: key)
        if let scoped = ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] {
            return scoped
        }
        return key == "default" ? inMemorySnapshots[serverId] : nil
    }

    @MainActor
    public func loadSnapshotFromDiskAsync(for serverId: UUID) async -> ServerHomeSnapshot? {
        let key = Self.resolveModeKey(for: serverId)
        let cKey = Self.compositeKey(serverId: serverId, modeKey: key)
        if let mem = ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] {
            return mem
        }
        if let inFlight = ServerHomeModeCacheBox.shared.inFlightLoadsByCompositeKey[cKey] {
            return await inFlight.value
        }
        let file = diskFileURL(serverId: serverId, modeKey: key)
        let task = Task<ServerHomeSnapshot?, Never> { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { () -> ServerHomeSnapshot? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(ServerHomeSnapshot.self, from: data)
            }.value
            ServerHomeModeCacheBox.shared.inFlightLoadsByCompositeKey.removeValue(forKey: cKey)
            if let decoded {
                if ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] == nil {
                    ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] = decoded
                }
                if ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey[cKey] == nil {
                    ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey[cKey] = decoded.cachedAt
                }
                if key == "default", self?.inMemorySnapshots[serverId] == nil {
                    self?.inMemorySnapshots[serverId] = decoded
                }
            }
            return ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] ?? decoded
        }
        ServerHomeModeCacheBox.shared.inFlightLoadsByCompositeKey[cKey] = task
        return await task.value
    }

    @MainActor
    public func preload(serverId: UUID) {
        let key = Self.resolveModeKey(for: serverId)
        let cKey = Self.compositeKey(serverId: serverId, modeKey: key)
        guard ServerHomeModeCacheBox.shared.snapshotsByCompositeKey[cKey] == nil,
              ServerHomeModeCacheBox.shared.inFlightLoadsByCompositeKey[cKey] == nil else { return }
        Task { @MainActor [weak self] in
            _ = await self?.loadSnapshotFromDiskAsync(for: serverId)
        }
    }

    @MainActor
    public func diskCacheSizeBytesAsync() async -> Int64 {
        let dir = cacheDirectoryURL
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for url in urls where url.lastPathComponent.hasPrefix("home_") && url.pathExtension == "json" {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
            return total
        }.value
    }

    @MainActor
    public func clearModeCache(for serverId: UUID) {
        let prefix = "\(serverId.uuidString)|"
        for key in ServerHomeModeCacheBox.shared.snapshotsByCompositeKey.keys where key.hasPrefix(prefix) {
            ServerHomeModeCacheBox.shared.snapshotsByCompositeKey.removeValue(forKey: key)
        }
        for key in ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey.keys where key.hasPrefix(prefix) {
            ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey.removeValue(forKey: key)
        }
    }

    @MainActor
    public func clearAllAsync() async {
        inMemorySnapshots.removeAll()
        ServerHomeModeCacheBox.shared.snapshotsByCompositeKey.removeAll()
        ServerHomeModeCacheBox.shared.lastSyncedAtByCompositeKey.removeAll()
        let dir = cacheDirectoryURL
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in urls where url.lastPathComponent.hasPrefix("home_") && url.pathExtension == "json" {
                try? fm.removeItem(at: url)
            }
        }.value
    }

    @MainActor
    public func pruneIfNeededAsync(maxBytes: Int64) async {
        guard maxBytes > 0 else { return }
        let dir = cacheDirectoryURL
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            var entries: [(url: URL, size: Int64, mtime: Date)] = []
            var total: Int64 = 0
            for url in urls where url.lastPathComponent.hasPrefix("home_") && url.pathExtension == "json" {
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let size = Int64(vals?.fileSize ?? 0)
                let mtime = vals?.contentModificationDate ?? .distantPast
                entries.append((url: url, size: size, mtime: mtime))
                total += size
            }
            guard total > maxBytes else { return }
            entries.sort { $0.mtime < $1.mtime }
            for entry in entries {
                guard total > maxBytes else { break }
                try? fm.removeItem(at: entry.url)
                total -= entry.size
            }
        }.value
    }
}

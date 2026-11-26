import Foundation
import DonbyCore
import DonbyNetwork
import DonbyMetalRenderer

extension AppState {
    public var allLoadedMediaItems: [EmbyItem] {
        var seen = Set<String>()
        var result: [EmbyItem] = []
        var sources = [carouselItems, resumeItems, nextUpItems, favoriteItems] + Array(latestByLibrary.values)
        if let extLists = DonbyAppExtensionCenter.shared.plugin?.extraHomeItemLists() {
            sources.append(contentsOf: extLists)
        }
        for list in sources {
            for item in list where !seen.contains(item.id) {
                seen.insert(item.id)
                result.append(item)
            }
        }
        return result
    }

    public func addRecentMedia(name: String, urlString: String, isLocal: Bool) {
        urlMediaItems.removeAll { $0.urlString == urlString }
        let newItem = LocalOrURLMediaItem(name: name, urlString: urlString, isLocalFile: isLocal, addedAt: Date())
        urlMediaItems.insert(newItem, at: 0)
        showToast("已加入播放列表: \(name)", icon: isLocal ? "film" : "link")
    }

    public func deleteRecentMedia(id: UUID) {
        urlMediaItems.removeAll { $0.id == id }
    }

    public func addIPTVChannel(name: String, group: String, urlString: String) {
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let newChannel = IPTVChannelItem(name: name, group: cleanGroup.isEmpty ? "自定义" : cleanGroup, urlString: urlString)
        iptvChannels.append(newChannel)
        showToast("已添加频道: \(name)", icon: "sparkles.tv")
    }

    public func deleteIPTVChannel(id: UUID) {
        iptvChannels.removeAll { $0.id == id }
    }

    public func importM3UContent(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        var existingURLs = Set(iptvChannels.map(\.urlString))
        var newChannels: [IPTVChannelItem] = []
        var currentName: String? = nil
        var currentGroup = "导入频道"

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                // Extract group-title
                if let groupRange = line.range(of: "group-title=\"") {
                    let sub = line[groupRange.upperBound...]
                    if let endQuote = sub.firstIndex(of: "\"") {
                        currentGroup = String(sub[..<endQuote])
                    }
                }
                // Extract channel name after comma
                if let commaIdx = line.lastIndex(of: ",") {
                    let nameSub = line[line.index(after: commaIdx)...].trimmingCharacters(in: .whitespaces)
                    if !nameSub.isEmpty { currentName = nameSub }
                }
            } else if !line.hasPrefix("#") {
                // This is stream URL
                let name = currentName ?? "未知频道 \(newChannels.count + 1)"
                if existingURLs.insert(line).inserted {
                    newChannels.append(IPTVChannelItem(name: name, group: currentGroup, urlString: line))
                }
                currentName = nil
            }
        }

        if !newChannels.isEmpty {
            iptvChannels.append(contentsOf: newChannels)
            showToast("成功导入 \(newChannels.count) 个 IPTV 频道", icon: "sparkles.tv")
        } else {
            showToast("未检测到有效 M3U 频道，请检查文件格式", icon: "exclamationmark.triangle", isError: true)
        }
    }

    public func recordSearchHistory(_ rawQuery: String) {
        let cleaned = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        searchHistory.removeAll { $0.compare(cleaned, options: .caseInsensitive) == .orderedSame }
        searchHistory.insert(cleaned, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: searchHistoryStorageKey)
    }

    public func removeSearchHistoryItem(_ term: String) {
        searchHistory.removeAll { $0 == term }
        UserDefaults.standard.set(searchHistory, forKey: searchHistoryStorageKey)
    }

    public func clearSearchHistory() {
        searchHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: searchHistoryStorageKey)
    }

    public func addLocalFolder(url: URL) {
        let path = url.path
        if localFolders.contains(where: { $0.path == path }) {
            showToast("该文件夹已在列表中", icon: "folder")
            return
        }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = url.lastPathComponent
        let isFirst = localFolders.isEmpty
        let folder = LocalMediaFolder(name: name, path: path, bookmarkData: bookmark, isPresetDefault: isFirst)
        localFolders.append(folder)
        if isFirst && defaultFilesFolderId.isEmpty {
            defaultFilesFolderId = folder.id.uuidString
        }
        showToast("已添加本地文件夹: \(name)", icon: "folder.badge.plus")
    }

    public func removeLocalFolder(id: UUID) {
        if browsingFolder?.id == id {
            browsingFolder = nil
        }
        if defaultFilesFolderId == id.uuidString {
            defaultFilesFolderId = ""
        }
        localFolders.removeAll { $0.id == id }
        showToast("已移除该文件夹", icon: "trash")
    }

    public func setPresetDefaultFolder(id: UUID) {
        if defaultFilesFolderId == id.uuidString {
            defaultFilesFolderId = ""
            for i in 0..<localFolders.count {
                localFolders[i].isPresetDefault = false
            }
            showToast("已取消默认打开文件夹", icon: "folder")
        } else {
            defaultFilesFolderId = id.uuidString
            for i in 0..<localFolders.count {
                localFolders[i].isPresetDefault = (localFolders[i].id == id)
            }
            showToast("已设为默认打开文件夹", icon: "star.fill")
        }
    }

    nonisolated private static let supportedVideoExtensions: Set<String> = ["mp4", "mkv", "mov", "webm", "avi", "m4v", "flv", "ts", "m2ts", "wmv", "iso", "rmvb"]

    nonisolated public static func countFolderVideos(path: String) -> Int {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var count = 0
        for case let fileURL as URL in enumerator where supportedVideoExtensions.contains(fileURL.pathExtension.lowercased()) {
            count += 1
        }
        return count
    }

    nonisolated public static func scanFolderHierarchy(path: String) -> (subfolders: [LocalMediaFolder], videos: [LocalVideoFileInfo]) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }
        var folders: [LocalMediaFolder] = []
        var videos: [LocalVideoFileInfo] = []
        for entryURL in items {
            let res = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if res?.isDirectory == true {
                folders.append(LocalMediaFolder(name: entryURL.lastPathComponent, path: entryURL.path))
                continue
            }
            let ext = entryURL.pathExtension.lowercased()
            if supportedVideoExtensions.contains(ext) {
                let size = Int64(res?.fileSize ?? 0)
                let date = res?.contentModificationDate ?? Date()
                videos.append(LocalVideoFileInfo(name: entryURL.lastPathComponent, path: entryURL.path, fileSizeBytes: size, fileExtension: ext.uppercased(), modifiedDate: date))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        videos.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (folders, videos)
    }

    nonisolated public static func scanFolderVideos(path: String) -> [LocalVideoFileInfo] {
        scanFolderHierarchy(path: path).videos
    }

    public func loadActiveServerHome(syncDomains: Bool = false) async {
        guard let server = activeServer else { return }
        homeLoadGeneration &+= 1
        let currentGen = homeLoadGeneration

        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.libraryViews = []
            self.carouselItems = []
            self.resumeItems = []
            self.nextUpItems = []
            self.latestByLibrary = [:]
            self.favoriteItems = []
            self.homeErrorMessage = nil
            self.isLoadingHome = false
            return
        }

        if self.libraryViews.isEmpty {
            isLoadingHome = true
        }
        homeErrorMessage = nil

        if syncDomains && autoSyncDomains {
            Task { await syncExtDomains(for: server.id, showFeedback: false) }
        }
        Task { await refreshServerCapabilities(for: server) }
        Task.detached(priority: .utility) { DKMetalLayerView.prewarmPipelines() }
        if let extProvider = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            Task { await extProvider.prewarmPlayback(server: server, item: nil) }
        } else {
            Task { await EmbyClient.shared.prewarmConnection(server: server) }
        }

        if isUsingUHDExtension(for: server), let ext = DonbyAppExtensionCenter.shared.plugin {
            await ext.loadHomeContent(
                for: server,
                appState: self,
                isCurrentGeneration: { [weak self] in self?.homeLoadGeneration == currentGen }
            )
            return
        }

        // Standard Emby mode (also seamless fallback when optional UHD extension is disabled):
        // If current token/userId is invalid for standard Emby API (e.g. switched from UHD JWT session),
        // transparently re-authenticate over standard Emby using saved credentials.
        var activeEmbyServer = server
        func authenticateEmbyFallback(_ target: EmbyServerConfig) async -> EmbyServerConfig? {
            guard !target.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !target.password.isEmpty else { return nil }
            var candidateURLs: [String] = [target.activeBaseURL, target.mainLineURL]
            for line in target.backupLines {
                candidateURLs.append(line.url)
            }
            if target.host.lowercased().contains("uhdnow.com") {
                candidateURLs.append("https://v1.uhdnow.com")
            }
            var seen = Set<String>()
            let uniqueCandidates = candidateURLs.filter { !$0.isEmpty && seen.insert($0).inserted }
            for baseURL in uniqueCandidates {
                if let auth = try? await EmbyClient.shared.authenticate(
                    baseURL: baseURL,
                    username: target.username,
                    password: target.password
                ), let token = auth.accessToken, !token.isEmpty {
                    var updated = target
                    updated.accessToken = token
                    if let uid = auth.user?.id, !uid.isEmpty { updated.userId = uid }
                    if let sId = auth.serverId ?? auth.user?.serverId, !sId.isEmpty { updated.serverId = sId }
                    if let matchedLine = updated.backupLines.first(where: { $0.url == baseURL }) {
                        updated.selectedLineId = matchedLine.id
                    } else if baseURL != updated.activeBaseURL, let parsed = URL(string: baseURL), let h = parsed.host {
                        updated.host = h
                        updated.isHttps = (parsed.scheme?.lowercased() != "http")
                        updated.port = parsed.port ?? (updated.isHttps ? 443 : 80)
                        updated.selectedLineId = nil
                    }
                    if let idx = self.servers.firstIndex(where: { $0.id == target.id }) {
                        self.servers[idx].accessToken = updated.accessToken
                        if !updated.userId.isEmpty { self.servers[idx].userId = updated.userId }
                        if !updated.serverId.isEmpty { self.servers[idx].serverId = updated.serverId }
                        self.servers[idx].selectedLineId = updated.selectedLineId
                        self.servers[idx].host = updated.host
                        self.servers[idx].port = updated.port
                        self.servers[idx].isHttps = updated.isHttps
                    }
                    return updated
                }
            }
            return nil
        }

        if activeEmbyServer.accessToken.isEmpty || activeEmbyServer.userId.isEmpty {
            if let authed = await authenticateEmbyFallback(activeEmbyServer) {
                activeEmbyServer = authed
            }
        }

        let embyServerForHome: EmbyServerConfig
        let initialViews: [EmbyItem]
        do {
            initialViews = try await EmbyClient.shared.fetchViews(server: activeEmbyServer)
            embyServerForHome = activeEmbyServer
        } catch {
            if let authed = await authenticateEmbyFallback(activeEmbyServer) {
                do {
                    initialViews = try await EmbyClient.shared.fetchViews(server: authed)
                    embyServerForHome = authed
                } catch {
                    guard currentGen == homeLoadGeneration else { return }
                    self.homeErrorMessage = error.localizedDescription
                    self.isLoadingHome = false
                    return
                }
            } else {
                guard currentGen == homeLoadGeneration else { return }
                self.homeErrorMessage = error.localizedDescription
                self.isLoadingHome = false
                return
            }
        }

        // Update library item counts in background so large servers (400k+ episodes) never block homepage UI
        Task {
            if let counts = try? await EmbyClient.shared.fetchCounts(server: embyServerForHome),
               let idx = self.servers.firstIndex(where: { $0.id == embyServerForHome.id }) {
                let newMovies = counts.movieCount ?? self.servers[idx].movieCount
                let newEpisodes = counts.episodeCount ?? counts.seriesCount ?? self.servers[idx].episodeCount
                if self.servers[idx].movieCount != newMovies || self.servers[idx].episodeCount != newEpisodes {
                    self.servers[idx].movieCount = newMovies
                    self.servers[idx].episodeCount = newEpisodes
                }
            }
        }

        do {
            async let resumeTask = EmbyClient.shared.fetchResumeItems(server: embyServerForHome, limit: 16)
            async let favTask = EmbyClient.shared.fetchItems(server: embyServerForHome, isFavorite: true, limit: 24)
            async let topMoviesTask = EmbyClient.shared.fetchItems(
                server: embyServerForHome,
                includeItemTypes: "Movie",
                sortBy: "CriticRating,CommunityRating",
                sortOrder: "Descending",
                limit: 36
            )
            async let topSeriesTask = EmbyClient.shared.fetchItems(
                server: embyServerForHome,
                includeItemTypes: "Series",
                sortBy: "CriticRating,CommunityRating",
                sortOrder: "Descending",
                limit: 36
            )

            let views = initialViews
            guard currentGen == homeLoadGeneration else { return }
            if self.libraryViews != views {
                self.libraryViews = views
            }

            let resumes = (try? await resumeTask) ?? []
            let nextUps: [EmbyItem] = []
            let favs = (try? await favTask)?.items ?? []

            guard currentGen == homeLoadGeneration else { return }
            if self.resumeItems != resumes { self.resumeItems = resumes }
            if !self.nextUpItems.isEmpty { self.nextUpItems = [] }
            if self.favoriteItems != favs { self.favoriteItems = favs }

            // Silently prewarm top continue-watching PlaybackInfo so clicking from Home resolves in 0ms
            let embyPrewarmTargets = Array(resumes.filter { !$0.isSeries }.prefix(3))
            if !embyPrewarmTargets.isEmpty {
                Task.detached(priority: .utility) {
                    for target in embyPrewarmTargets {
                        await EmbyClient.shared.prewarmPlaybackInfo(server: embyServerForHome, itemId: target.id)
                    }
                }
            }

            var latestMap: [String: [EmbyItem]] = [:]
            let hadCachedLatest = !self.latestByLibrary.isEmpty

            await withTaskGroup(of: (String, [EmbyItem]).self) { group in
                for view in views {
                    group.addTask { [hideWatchedInLatest] in
                        let items = (try? await EmbyClient.shared.fetchLatestItems(
                            server: embyServerForHome,
                            parentId: view.id,
                            limit: 16,
                            hidePlayed: hideWatchedInLatest
                        )) ?? []
                        return (view.id, items)
                    }
                }
                for await (viewId, items) in group {
                    guard currentGen == self.homeLoadGeneration else { return }
                    latestMap[viewId] = items
                    if !hadCachedLatest && self.latestByLibrary[viewId] != items {
                        self.latestByLibrary[viewId] = items
                    }
                }
            }

            let topMovies = (try? await topMoviesTask)?.items ?? []
            let topSeries = (try? await topSeriesTask)?.items ?? []

            guard currentGen == homeLoadGeneration else { return }
            finalizeHomeContent(
                for: server.id,
                libraryViews: views,
                resumeItems: resumes,
                nextUpItems: nextUps,
                favoriteItems: favs,
                latestByLibrary: latestMap,
                extraHeroCandidates: topMovies + topSeries,
                serverName: embyServerForHome.name,
                explicitAnimeMode: nil
            )
        } catch {
            guard currentGen == homeLoadGeneration else { return }
            self.homeErrorMessage = error.localizedDescription
            self.isLoadingHome = false
        }
    }

    /// Canonical home finalizer: curates `carouselItems` strictly from library shelves + top-rated pools
    /// via `HomeHeroCurator` (never from extension hot/promotional feeds), persists snapshot, and
    /// asynchronously enriches top candidates with multi-platform ratings (MDBList / Cinemeta IMDb).
    public func finalizeHomeContent(
        for serverId: UUID,
        libraryViews: [EmbyItem],
        resumeItems: [EmbyItem],
        nextUpItems: [EmbyItem],
        favoriteItems: [EmbyItem],
        latestByLibrary: [String: [EmbyItem]],
        extraHeroCandidates: [EmbyItem] = [],
        serverName: String? = nil,
        explicitAnimeMode: Bool? = nil
    ) {
        if self.latestByLibrary != latestByLibrary {
            self.latestByLibrary = latestByLibrary
        }
        let resolvedServerName = serverName ?? self.servers.first(where: { $0.id == serverId })?.name
        let nextCarousel = HomeHeroCurator.selectHeroItems(
            libraryViews: libraryViews,
            latestByLibrary: latestByLibrary,
            extraCandidates: extraHeroCandidates,
            fallbackResumes: resumeItems,
            serverName: resolvedServerName,
            explicitAnimeMode: explicitAnimeMode
        )
        if self.carouselItems != nextCarousel {
            self.carouselItems = nextCarousel
        }
        let snapshot = ServerHomeCacheStore.ServerHomeSnapshot(
            libraryViews: libraryViews,
            resumeItems: resumeItems,
            nextUpItems: nextUpItems,
            favoriteItems: favoriteItems,
            latestByLibrary: latestByLibrary,
            carouselItems: self.carouselItems,
            cachedAt: Date()
        )
        ServerHomeCacheStore.shared.save(snapshot, for: serverId)
        self.isLoadingHome = false

        // Seed any already-cached multi-platform ratings immediately so hero badges appear without delay.
        let initialCarousel = self.carouselItems
        Task { [weak self] in
            let cached = await MultiPlatformRatingService.shared.cachedRatingsByItemId(for: initialCarousel)
            guard !cached.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for (itemId, rating) in cached {
                    self.multiPlatformRatingsByItemId[itemId] = rating
                }
            }
        }

        // Background multi-platform rating enrichment (MDBList 8-platform batch if API key configured,
        // or zero-key IMDb Official + Cinemeta fallback) — re-curates hero carousel without blocking initial paint.
        let generation = self.homeLoadGeneration
        let apiKey = self.mdblistAPIKey
        let poolForEnrichment: [EmbyItem] = {
            var seen = Set<String>()
            var pool: [EmbyItem] = []
            for item in initialCarousel where seen.insert(item.id).inserted {
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
        let targetServer = self.servers.first(where: { $0.id == serverId })
        Task { [weak self] in
            var bridgedImdbIds: [String: String] = [:]
            if let srv = targetServer,
               let plugin = DonbyAppExtensionCenter.shared.plugin,
               plugin.isActive(for: srv) {
                bridgedImdbIds = await plugin.resolveImdbIds(for: poolForEnrichment, server: srv, maxCount: 16)
            }
            let enriched = await MultiPlatformRatingService.shared.enrichRatings(
                for: poolForEnrichment,
                mdblistAPIKey: apiKey,
                resolvedImdbIds: bridgedImdbIds
            )
            guard !enriched.isEmpty else { return }
            await MainActor.run {
                guard let self,
                      self.homeLoadGeneration == generation,
                      self.activeServer?.id == serverId else { return }
                for (itemId, rating) in enriched {
                    self.multiPlatformRatingsByItemId[itemId] = rating
                }
                let curated = HomeHeroCurator.selectHeroItems(
                    libraryViews: libraryViews,
                    latestByLibrary: latestByLibrary,
                    extraCandidates: extraHeroCandidates,
                    ratingsByItemId: enriched,
                    fallbackResumes: resumeItems,
                    serverName: resolvedServerName,
                    explicitAnimeMode: explicitAnimeMode
                )
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
                    ServerHomeCacheStore.shared.save(updatedSnapshot, for: serverId)
                }
            }
        }
    }

    /// Loads (from disk/memory cache or remote enrichment) multi-platform ratings for a single hero item
    /// and caches the result on `multiPlatformRatingsByItemId`.
    public func ensureMultiPlatformRating(
        for item: EmbyItem,
        server: EmbyServerConfig?
    ) async -> MultiPlatformRatings? {
        let apiKey = self.mdblistAPIKey
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(ProcessInfo.processInfo.environment["DONBY_MDBLIST_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if let existing = multiPlatformRatingsByItemId[item.id] {
            let needsUpgrade = hasKey
                && existing.mdblistFetched != true
                && existing.rottenTomatoesCritics == nil
                && existing.rottenTomatoesAudience == nil
                && existing.metacritic == nil
                && existing.trakt == nil
                && existing.letterboxd == nil
            if !needsUpgrade {
                return existing
            }
        }

        if let cached = await MultiPlatformRatingService.shared.cachedRating(for: item) {
            self.multiPlatformRatingsByItemId[item.id] = cached
            let needsUpgrade = hasKey
                && cached.mdblistFetched != true
                && cached.rottenTomatoesCritics == nil
                && cached.rottenTomatoesAudience == nil
                && cached.metacritic == nil
                && cached.trakt == nil
                && cached.letterboxd == nil
            if !needsUpgrade {
                return cached
            }
        }

        var bridgedImdb: String? = MultiPlatformRatingService.resolvedProviderId(in: item.providerIds, key: "imdb")
        if bridgedImdb == nil,
           let srv = server ?? activeServer,
           let plugin = DonbyAppExtensionCenter.shared.plugin,
           plugin.isActive(for: srv) {
            let resolvedMap = await plugin.resolveImdbIds(for: [item], server: srv, maxCount: 1)
            bridgedImdb = resolvedMap[item.id]
        }

        let enriched = await MultiPlatformRatingService.shared.enrichRating(
            for: item,
            mdblistAPIKey: apiKey,
            resolvedImdbId: bridgedImdb
        )
        if let enriched {
            self.multiPlatformRatingsByItemId[item.id] = enriched
        }
        return enriched ?? self.multiPlatformRatingsByItemId[item.id]
    }

    public static func detailSeriesKey(for item: EmbyItem) -> String {
        item.isSeries ? item.id : (item.seriesId ?? item.id)
    }

    public func rememberDetailFocusedEpisode(seriesKey: String, seasonNumber: Int?, episodeId: String) {
        guard !seriesKey.isEmpty, !episodeId.isEmpty else { return }
        detailFocusedEpisodeMemory[seriesKey] = (seasonNumber: seasonNumber, episodeId: episodeId)
    }

    public func detailFocusedEpisode(forSeriesKey seriesKey: String) -> (seasonNumber: Int?, episodeId: String)? {
        detailFocusedEpisodeMemory[seriesKey]
    }

    public func updateDetailFocusedEpisodeIfActive(forItem item: EmbyItem) {
        let key = Self.detailSeriesKey(for: item)
        let hasActiveSeriesDetail = detailStack.contains { Self.detailSeriesKey(for: $0) == key }
        guard hasActiveSeriesDetail, item.isEpisode else { return }
        detailFocusedEpisodeMemory[key] = (seasonNumber: item.parentIndexNumber, episodeId: item.id)
    }

    private func cachedSeriesItem(withId seriesId: String) -> EmbyItem? {
        carouselItems.first(where: { $0.id == seriesId && $0.isSeries })
            ?? favoriteItems.first(where: { $0.id == seriesId && $0.isSeries })
            ?? latestByLibrary.values.lazy.compactMap { $0.first(where: { $0.id == seriesId && $0.isSeries }) }.first
    }

    private func normalizedDetailEntry(for item: EmbyItem) -> EmbyItem {
        guard item.isEpisode,
              let sid = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sid.isEmpty else { return item }
        if let cached = cachedSeriesItem(withId: sid) { return cached }
        let title = (item.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? item.seriesName! : item.name
        return EmbyItem(
            id: sid, name: title, serverId: item.serverId, type: "Series",
            imageTags: item.seriesPrimaryImageTag.map { ["Primary": $0] },
            backdropImageTags: item.parentBackdropImageTags,
            uhdPosterURL: item.uhdPosterURL, uhdBackdropURL: item.uhdBackdropURL,
            uhdLogoURL: item.uhdLogoURL, uhdMediaType: item.uhdMediaType != nil ? "tv" : nil
        )
    }

    public func openDetail(for item: EmbyItem, preferOfflineFocus: Bool = false) {
        cancelPendingPlaybackStart()
        let entry = normalizedDetailEntry(for: item)
        if preferOfflineFocus { detailOfflineFocusIds.insert(entry.id) } else { detailOfflineFocusIds.remove(entry.id) }
        let key = Self.detailSeriesKey(for: entry)
        if item.isEpisode {
            detailFocusedEpisodeMemory[key] = (seasonNumber: item.parentIndexNumber, episodeId: item.id)
        } else {
            detailFocusedEpisodeMemory.removeValue(forKey: key)
        }
        if let last = detailStack.last, last.id == entry.id { return }
        detailStack.append(entry)
    }

    public func popDetail() {
        cancelPendingPlaybackStart()
        if let popped = detailStack.popLast() {
            detailOfflineFocusIds.remove(popped.id)
            detailFocusedEpisodeMemory.removeValue(forKey: Self.detailSeriesKey(for: popped))
        }
    }

    public func popToRootDetail() {
        cancelPendingPlaybackStart()
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()
    }

    public func toggleFavorite(for item: EmbyItem) async -> EmbyItem {
        guard let server = activeServer else { return item }
        var updated = item
        let newFav = !(item.userData?.isFavorite ?? false)
        var uData = updated.userData ?? EmbyUserData()
        uData.isFavorite = newFav
        updated.userData = uData

        if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            try? await ext.setFavorite(server: server, item: item, isFavorite: newFav)
        } else {
            try? await EmbyClient.shared.setFavorite(server: server, itemId: item.id, isFavorite: newFav)
        }
        if newFav {
            if !favoriteItems.contains(where: { $0.id == updated.id }) { favoriteItems.insert(updated, at: 0) }
            showToast("已添加到收藏夹", icon: "heart.fill")
        } else {
            favoriteItems.removeAll { $0.id == updated.id }
            showToast("已从收藏夹移除", icon: "heart.slash")
        }
        return updated
    }

    public func togglePlayed(for item: EmbyItem) async -> EmbyItem {
        var updated = item
        let newPlayed = !(item.userData?.played ?? false)
        var uData = updated.userData ?? EmbyUserData()
        uData.played = newPlayed
        if newPlayed { uData.playbackPositionTicks = 0 }
        updated.userData = uData

        DonbyDownloadManager.shared.updateOfflinePlaybackProgress(
            itemId: item.id,
            played: newPlayed,
            positionSeconds: newPlayed ? nil : 0,
            durationSeconds: nil,
            persistDiskNow: true
        )

        if let server = activeServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                try? await ext.setPlayed(server: server, item: item, isPlayed: newPlayed)
            } else {
                try? await EmbyClient.shared.setPlayed(server: server, itemId: item.id, played: newPlayed)
            }
        }
        showToast(newPlayed ? "已标记为已观看" : "已标记为未观看", icon: "checkmark.circle.fill")
        return updated
    }
}

// MARK: - Multi-Tier Server Home Cache Store
public final class ServerHomeCacheStore {
    public static let shared = ServerHomeCacheStore()
    private var inMemorySnapshots: [UUID: ServerHomeSnapshot] = [:]
    private let cacheDirectoryURL: URL

    public struct ServerHomeSnapshot: Codable {
        public var libraryViews: [EmbyItem]
        public var resumeItems: [EmbyItem]
        public var nextUpItems: [EmbyItem]
        public var favoriteItems: [EmbyItem]
        public var latestByLibrary: [String: [EmbyItem]]
        public var carouselItems: [EmbyItem]
        public var cachedAt: Date
    }

    private init() {
        let base = DonbyStoragePaths.cachesDirectoryURL
        let dir = base.appendingPathComponent("com.don.Donby/ServerHomeCache", isDirectory: true)
        self.cacheDirectoryURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }

    public func snapshot(for serverId: UUID) -> ServerHomeSnapshot? {
        if let mem = inMemorySnapshots[serverId] {
            return mem
        }
        let file = cacheDirectoryURL.appendingPathComponent("home_\(serverId.uuidString).json")
        if let data = try? Data(contentsOf: file),
           let snap = try? JSONDecoder().decode(ServerHomeSnapshot.self, from: data) {
            inMemorySnapshots[serverId] = snap
            return snap
        }
        return nil
    }

    public func save(_ snapshot: ServerHomeSnapshot, for serverId: UUID) {
        inMemorySnapshots[serverId] = snapshot
        DispatchQueue.global(qos: .utility).async { [cacheDirectoryURL] in
            let file = cacheDirectoryURL.appendingPathComponent("home_\(serverId.uuidString).json")
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    public func clear(for serverId: UUID) {
        inMemorySnapshots.removeValue(forKey: serverId)
        DispatchQueue.global(qos: .utility).async { [cacheDirectoryURL] in
            let file = cacheDirectoryURL.appendingPathComponent("home_\(serverId.uuidString).json")
            try? FileManager.default.removeItem(at: file)
        }
    }
}

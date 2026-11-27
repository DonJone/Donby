import SwiftUI
import DonbyCore
import DonbyNetwork

extension DetailView {
    func loadDetailMultiPlatformRatings() async {
        let target = item
        if let resolved = await appState.ensureMultiPlatformRating(for: target, server: effectiveDetailServer) {
            guard !Task.isCancelled else { return }
            self.multiPlatformRatings = resolved
        }
    }

    func effectiveStartSeconds(for candidate: EmbyItem) -> Double {
        if candidate.resumePositionSeconds > 0.5 {
            return candidate.resumePositionSeconds
        }
        if candidate.isEpisode, let serverId = effectiveDetailServer?.id ?? appState.activeServer?.id {
            let pref = appState.effectiveSkipPreference(serverId: serverId, item: candidate)
            if pref.introEnabled && pref.mode == .automatic && pref.introSeconds > 0 {
                return Double(pref.introSeconds)
            }
        }
        return 0.0
    }

    var effectivePlayButtonStartSeconds: Double {
        effectiveStartSeconds(for: heroResolvedPlayTarget)
    }

    func stageHoveredOrFocusedEpisode(_ ep: EmbyItem) {
        guard appState.activePlayback == nil,
              let server = effectiveDetailServer,
              !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if appState.detailPreloadEnabled && ep.id == heroResolvedPlayTarget.id {
            return
        }
        let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
        PlaybackIntentCoordinator.shared.stageCandidateEpisode(
            server: server,
            item: targetEp,
            startSeconds: effectiveStartSeconds(for: targetEp),
            preferredPreset: appState.preferredVersionPreset,
            enable302Cache: appState.enable302Cache,
            turboEnabled: appState.turboEnabled,
            debounceNanoseconds: 180_000_000,
            maxMemoryBytes: max(64, appState.turboMemoryCacheMB) * 1024 * 1024
        )
    }

    func runDetailPrewarmAndPreload() async {
        guard hasHydratedDetail, !isLoadingDetails else { return }
        guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if item.isSeries && heroTargetEpisode == nil { return }
        let target = heroResolvedPlayTarget
        // Stage 1 (50ms settle): resolve control-plane resource into 0ms fast table + prewarm 4 TLS/H2 edge lanes
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled else { return }
        let sourceHint = (target.id == item.id && !selectedSourceId.isEmpty) ? selectedSourceId : nil
        let preset = appState.preferredVersionPreset
        let enable302 = appState.enable302Cache && server.cache302Request

        async let prewarmSideTask: Void = {
            if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                await ext.prewarmPlayback(server: server, item: target)
            } else {
                await EmbyClient.shared.prewarmConnection(server: server)
            }
        }()
        let resolved = try? await PlaybackIntentCoordinator.shared.resolveAndCacheResource(
            server: server,
            item: target,
            preferredSourceId: sourceHint,
            preferredPreset: preset,
            enable302Cache: appState.enable302Cache,
            defer302ProbeWhenTurbo: true
        )
        _ = await prewarmSideTask

        guard !Task.isCancelled,
              appState.turboEnabled,
              appState.activePlayback == nil,
              DonbyDownloadManager.shared.completedEntry(for: target.id, serverId: server.id) == nil,
              let res = resolved else {
            return
        }
        // Stage 2 (220ms gentle debounce): warm data-plane chunks (full runway if detailPreloadEnabled, else 1.5 MiB micro-stage)
        try? await Task.sleep(nanoseconds: 220_000_000)
        guard !Task.isCancelled, appState.activePlayback == nil else { return }
        let urlStr = res.streamURL.absoluteString.lowercased()
        guard (urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://")),
              !urlStr.contains(".m3u8"), !urlStr.contains(".mpd") else {
            return
        }

        let assetKey = DonbyTurboCacheEngine.makeAssetKey(
            serverId: server.id,
            itemId: target.id,
            mediaSourceId: res.mediaSource.id
        )
        let redirectKey = EmbyClient.redirectCacheKey(
            serverId: server.id,
            itemId: target.id,
            mediaSourceId: res.mediaSource.id,
            baseURL: server.activeBaseURL
        )
        let originURL = res.originStreamURL ?? res.streamURL
        let cachedRedirectURL: URL? = (res.originStreamURL != nil && res.originStreamURL != res.streamURL)
            ? res.streamURL
            : NetworkRouteWarmStore.shared.cachedRedirect(for: redirectKey)
        let durationSec = Double(target.runTimeTicks ?? res.mediaSource.runTimeTicks ?? 0) / 10_000_000.0
        let playStartSec = effectivePlayButtonStartSeconds
        let redirectHandler: (@Sendable (URL) -> Void)? = enable302
            ? Self.makeRedirectStoreHandler(key: redirectKey)
            : nil
        let memoryCap = max(64, appState.turboMemoryCacheMB) * 1024 * 1024

        if appState.detailPreloadEnabled {
            DonbyTurboCacheEngine.shared.startDetailPreload(
                assetKey: assetKey,
                streamURL: originURL,
                cachedRedirectURL: cachedRedirectURL,
                headers: res.headers,
                knownTotalSize: res.mediaSource.size,
                durationSeconds: durationSec,
                resumePositionSeconds: playStartSec,
                preloadSeconds: appState.detailPreloadSeconds,
                maxMemoryBytes: memoryCap,
                connectionBudget: appState.effectiveConnectionBudget(for: server),
                onResolvedRedirectURL: redirectHandler
            )
        } else {
            DonbyTurboCacheEngine.shared.startMicroStagePreload(
                assetKey: assetKey,
                streamURL: originURL,
                cachedRedirectURL: cachedRedirectURL,
                headers: res.headers,
                knownTotalSize: res.mediaSource.size,
                durationSeconds: durationSec,
                startPositionSeconds: playStartSec,
                maxMemoryBytes: memoryCap,
                onResolvedRedirectURL: redirectHandler
            )
        }
    }

    private nonisolated static func makeRedirectStoreHandler(key: String) -> @Sendable (URL) -> Void {
        { finalURL in
            Task {
                await RedirectCacheStore.shared.storeRedirect(finalURL, for: key)
            }
        }
    }

    private nonisolated static func matchOfflineGroup(for target: EmbyItem, in groups: [OfflineLibraryGroup]) -> OfflineLibraryGroup? {
        let targetSeriesId = target.isSeries ? target.id : (target.seriesId ?? target.id)
        return groups.first { g in
            g.displayItem.id == target.id ||
            g.displayItem.id == targetSeriesId ||
            g.displayItem.name == (target.seriesName ?? target.name) ||
            g.episodesBySeason.values.contains(where: { eps in eps.contains(where: { $0.id == target.id }) })
        }
    }

    private func downloadedEpisodesIn(_ group: OfflineLibraryGroup?) -> [EmbyItem] {
        var result: [EmbyItem] = []
        var seenIds = Set<String>()
        if let group {
            for sNum in group.episodesBySeason.keys.sorted() {
                for ep in group.episodesBySeason[sNum] ?? [] {
                    if seenIds.insert(ep.id).inserted {
                        result.append(ep)
                    }
                }
            }
        }
        let targetSeriesId = initialItem.isSeries ? initialItem.id : (initialItem.seriesId ?? initialItem.id)
        for entry in DonbyDownloadManager.shared.entries where entry.status == .completed {
            let snap = entry.hydratedItemSnapshot
            let matchesSeries = (snap.seriesId == targetSeriesId) || (snap.seriesName == item.name)
            if matchesSeries && seenIds.insert(snap.id).inserted {
                result.append(snap)
            }
        }
        return result.sorted {
            let sA = $0.parentIndexNumber ?? 1
            let sB = $1.parentIndexNumber ?? 1
            if sA != sB { return sA < sB }
            return ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0)
        }
    }

    private func isEpisodeWatched(_ ep: EmbyItem) -> Bool {
        let localPath = DonbyDownloadManager.shared.activeOrCompletedEntry(for: ep.id)?.localVideoFilePath
        return appState.isItemWatchedOfflineOrLocal(ep, localVideoPath: localPath)
    }

    private func preferredFocusEpisodeId(in eps: [EmbyItem]) -> String? {
        if (item.isEpisode || initialItem.isEpisode),
           let exact = eps.first(where: { $0.id == initialItem.id || $0.id == item.id }) {
            return exact.id
        }
        if preferOfflineFocus {
            let downloadedInSeason = eps.filter { DonbyDownloadManager.shared.completedEntry(for: $0.id) != nil }
            if let unwatchedDownloaded = downloadedInSeason.first(where: { !isEpisodeWatched($0) }) {
                return unwatchedDownloaded.id
            }
            if let firstDownloaded = downloadedInSeason.first {
                return firstDownloaded.id
            }
        }
        return eps.first(where: { !isEpisodeWatched($0) })?.id ?? eps.first?.id
    }

    private func mergeEpisodes(remote: [EmbyItem], local: [EmbyItem]) -> [EmbyItem] {
        guard !local.isEmpty else { return remote }
        var merged = remote
        let existingIds = Set(remote.map(\.id))
        for localEp in local where !existingIds.contains(localEp.id) {
            merged.append(localEp)
        }
        return merged.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
    }

    private func fetchOfflineAndCacheSnapshots() async -> (OfflineLibraryGroup?, [CachedMediaSummary]) {
        let entries = DonbyDownloadManager.shared.entries
        let target = initialItem
        return await Task.detached(priority: .userInitiated) {
            let groups = DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: entries)
            let matched = Self.matchOfflineGroup(for: target, in: groups)
            let unpinned = DonbyTurboCacheEngine.shared.listUnpinnedCachedAssets()
            return (matched, unpinned)
        }.value
    }

    func refreshOfflineAndCacheSnapshots(signature: String? = nil) async {
        let (group, assets) = await fetchOfflineAndCacheSnapshots()
        guard !Task.isCancelled else { return }
        self.cachedOfflineGroup = group
        self.cachedUnpinnedAssets = assets
        if let signature {
            self.lastScannedDownloadSignature = signature
        }
    }

    private func applyOfflineGroupHydration(_ localGroup: OfflineLibraryGroup) {
        self.item = localGroup.displayItem
        let remembered = appState.detailFocusedEpisode(forSeriesKey: AppState.detailSeriesKey(for: localGroup.displayItem))
        if localGroup.isSeries && !localGroup.seasonItems.isEmpty {
            self.seasons = localGroup.seasonItems
            if let remembered,
               let rSeason = remembered.seasonNumber,
               let localEps = localGroup.episodesBySeason[rSeason],
               !localEps.isEmpty {
                self.selectedSeasonIndex = rSeason
                self.episodes = localEps
                if localEps.contains(where: { $0.id == remembered.episodeId }) {
                    self.focusedEpisodeId = remembered.episodeId
                } else if !userDidPickEpisodeLocally {
                    self.focusedEpisodeId = preferredFocusEpisodeId(in: localEps)
                }
            } else if preferOfflineFocus {
                let allDownloaded = downloadedEpisodesIn(localGroup)
                let targetEp = allDownloaded.first(where: { !isEpisodeWatched($0) }) ?? allDownloaded.first
                let preferredSeasonNum = targetEp?.parentIndexNumber ?? localGroup.seasonItems.first?.indexNumber ?? 1
                let localEps = localGroup.episodesBySeason[preferredSeasonNum] ?? []
                self.selectedSeasonIndex = preferredSeasonNum
                self.episodes = localEps
                if !userDidPickEpisodeLocally {
                    self.focusedEpisodeId = targetEp?.id ?? preferredFocusEpisodeId(in: localEps)
                }
            } else {
                let preferredSeasonNum = initialItem.isEpisode
                    ? (initialItem.parentIndexNumber ?? localGroup.seasonItems.first?.indexNumber ?? 1)
                    : (localGroup.seasonItems.first?.indexNumber ?? 1)
                let localEps = localGroup.episodesBySeason[preferredSeasonNum] ?? []
                self.selectedSeasonIndex = preferredSeasonNum
                self.episodes = localEps
                if let remembered, localEps.contains(where: { $0.id == remembered.episodeId }) {
                    self.focusedEpisodeId = remembered.episodeId
                } else if !userDidPickEpisodeLocally {
                    self.focusedEpisodeId = preferredFocusEpisodeId(in: localEps)
                }
            }
        }
        syncDefaultTracks()
    }

    func loadFullDetailData() async {
        detailLoadError = nil
        hasHydratedDetail = false
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        let initialSig = detailCompletedDownloadSignature
        async let snapshotTask = fetchOfflineAndCacheSnapshots()

        let precheckServer = effectiveDetailServer
        if precheckServer == nil || precheckServer?.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            let (localGroup, assets) = await snapshotTask
            guard !Task.isCancelled else { return }
            self.cachedOfflineGroup = localGroup
            self.cachedUnpinnedAssets = assets
            self.lastScannedDownloadSignature = initialSig
            if let localGroup {
                applyOfflineGroupHydration(localGroup)
            } else {
                self.detailLoadError = "未配置可用服务器且无本地离线缓存"
            }
            self.hasHydratedDetail = true
            return
        }

        let server = precheckServer!
        let targetSeriesId: String? = initialItem.isSeries ? initialItem.id : (initialItem.isEpisode ? initialItem.seriesId : nil)

        if let ext = DonbyAppExtensionCenter.shared.plugin, ext.isActive(for: server) {
            async let extPayloadTask = ext.loadDetailPayload(server: server, initialItem: initialItem, targetSeriesId: targetSeriesId)
            let (localGroup, assets) = await snapshotTask
            guard !Task.isCancelled else { return }
            self.cachedOfflineGroup = localGroup
            self.cachedUnpinnedAssets = assets
            self.lastScannedDownloadSignature = initialSig
            if let localGroup {
                applyOfflineGroupHydration(localGroup)
            }

            let payload = await extPayloadTask
            guard !Task.isCancelled else { return }
            if let enriched = payload.enrichedItem {
                self.item = enriched
            } else if localGroup == nil && payload.seasons?.isEmpty != false {
                self.detailLoadError = "无法获取详情信息，请检查网络或切换线路"
            }
            syncDefaultTracks()

            if let preloadedSeasons = payload.seasons, !preloadedSeasons.isEmpty {
                self.seasons = preloadedSeasons
                if !userDidPickEpisodeLocally,
                   !self.item.isEpisode,
                   appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey) == nil,
                   let prefEp = payload.preferredEpisode,
                   let matchedSeason = preloadedSeasons.first(where: { (!prefEp.seasonId.isEmpty && $0.id == prefEp.seasonId) || $0.indexNumber == prefEp.seasonNumber }) {
                    await loadEpisodesForSeason(
                        matchedSeason,
                        seasonNumber: matchedSeason.indexNumber ?? prefEp.seasonNumber,
                        preferredOverrideEpisodeId: prefEp.episodeId
                    )
                } else {
                    await applyInitialSeasonAndFocus(seasons: preloadedSeasons, localGroup: localGroup)
                }
            }
            self.similarItems = []
            self.hasHydratedDetail = true
            return
        }

        let detailFetchId: String = if initialItem.isEpisode, let sid = targetSeriesId, !sid.isEmpty {
            sid
        } else {
            initialItem.id
        }

        async let detailResultTask: Result<EmbyItem, Error> = {
            do {
                return .success(try await EmbyClient.shared.fetchItemDetail(server: server, itemId: detailFetchId))
            } catch {
                return .failure(error)
            }
        }()
        async let seasonsResultTask: Result<[EmbyItem], Error>? = {
            guard let sid = targetSeriesId, !sid.isEmpty else { return nil }
            do {
                return .success(try await EmbyClient.shared.fetchSeasons(server: server, seriesId: sid))
            } catch {
                return .failure(error)
            }
        }()

        // Launch similar items in an independent branch so it never blocks or causes 4-wave vertical jumps
        activeSimilarTask?.cancel()
        activeSimilarTask = Task { [weak appState] in
            _ = appState
            if let sims = try? await EmbyClient.shared.fetchSimilarItems(server: server, itemId: detailFetchId),
               !Task.isCancelled {
                self.similarItems = sims
            }
        }

        let (localGroup, assets) = await snapshotTask
        guard !Task.isCancelled else { return }
        self.cachedOfflineGroup = localGroup
        self.cachedUnpinnedAssets = assets
        self.lastScannedDownloadSignature = initialSig
        if let localGroup {
            applyOfflineGroupHydration(localGroup)
        }

        var detailError: Error? = nil
        switch await detailResultTask {
        case .success(let detailed):
            guard !Task.isCancelled else { return }
            if detailed.isEpisode, let sid = detailed.seriesId, !sid.isEmpty {
                appState.rememberDetailFocusedEpisode(
                    seriesKey: sid,
                    seasonNumber: detailed.parentIndexNumber,
                    episodeId: detailed.id
                )
                if sid != detailFetchId {
                    activeSimilarTask?.cancel()
                    activeSimilarTask = Task {
                        if let sims = try? await EmbyClient.shared.fetchSimilarItems(server: server, itemId: sid),
                           !Task.isCancelled {
                            self.similarItems = sims
                        }
                    }
                }
                if let parentSeries = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid) {
                    guard !Task.isCancelled else { return }
                    self.item = parentSeries
                } else {
                    self.item = detailed
                }
            } else {
                self.item = detailed
            }
        case .failure(let error):
            if !(error is CancellationError) {
                detailError = error
            }
        }
        guard !Task.isCancelled else { return }
        syncDefaultTracks()

        var preloadedSeasons: [EmbyItem]? = nil
        var seasonsError: Error? = nil
        if let sRes = await seasonsResultTask {
            switch sRes {
            case .success(let s):
                preloadedSeasons = s
            case .failure(let err):
                if !(err is CancellationError) { seasonsError = err }
            }
        }
        guard !Task.isCancelled else { return }
        if (preloadedSeasons == nil || preloadedSeasons?.isEmpty == true), item.isSeries, targetSeriesId == nil {
            do {
                preloadedSeasons = try await EmbyClient.shared.fetchSeasons(server: server, seriesId: item.id)
            } catch {
                if !(error is CancellationError) { seasonsError = error }
            }
            guard !Task.isCancelled else { return }
        }

        if item.isSeries {
            if let loadedSeasons = preloadedSeasons, !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                await applyInitialSeasonAndFocus(seasons: loadedSeasons, localGroup: localGroup)
            } else {
                do {
                    let allEps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id)
                    guard !Task.isCancelled else { return }
                    let sNums = Set(allEps.compactMap { $0.parentIndexNumber }).sorted()
                    if !sNums.isEmpty {
                        let builtSeasons = sNums.map { s in
                            EmbyItem(id: "\(item.id)_s\(s)", name: "第 \(s) 季", type: "Season", seriesId: item.id, indexNumber: s)
                        }
                        self.seasons = builtSeasons
                        await applyInitialSeasonAndFocus(seasons: builtSeasons, localGroup: localGroup, preloadedAllEpisodes: allEps)
                    } else {
                        self.episodes = allEps
                        let remembered = appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey)
                        if let remembered, allEps.contains(where: { $0.id == remembered.episodeId }) {
                            self.focusedEpisodeId = remembered.episodeId
                        } else if !userDidPickEpisodeLocally || !allEps.contains(where: { $0.id == focusedEpisodeId }) {
                            self.focusedEpisodeId = preferredFocusEpisodeId(in: allEps)
                        }
                    }
                } catch {
                    if !(error is CancellationError), self.episodes.isEmpty {
                        self.detailLoadError = (seasonsError ?? detailError ?? error).localizedDescription
                    }
                }
            }
        } else if item.isEpisode, let sId = item.seriesId {
            let loadedSeasons: [EmbyItem]?
            if let preloadedSeasons, !preloadedSeasons.isEmpty {
                loadedSeasons = preloadedSeasons
            } else {
                do {
                    loadedSeasons = try await EmbyClient.shared.fetchSeasons(server: server, seriesId: sId)
                } catch {
                    loadedSeasons = nil
                    if !(error is CancellationError) { seasonsError = error }
                }
            }
            guard !Task.isCancelled else { return }
            if let loadedSeasons, !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                let remembered = appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey)
                let sNum = remembered?.seasonNumber ?? item.parentIndexNumber ?? 1
                selectedSeasonIndex = sNum
                if let currentSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == sNum }) ?? loadedSeasons.first {
                    await loadEpisodesForSeason(currentSeason, seasonNumber: sNum, preferredOverrideEpisodeId: remembered?.episodeId)
                }
            } else if self.episodes.isEmpty, let err = seasonsError ?? detailError {
                self.detailLoadError = err.localizedDescription
            }
        } else if localGroup == nil, let err = detailError {
            self.detailLoadError = err.localizedDescription
        }

        guard !Task.isCancelled else { return }
        self.hasHydratedDetail = true
    }

    private func applyInitialSeasonAndFocus(
        seasons loadedSeasons: [EmbyItem],
        localGroup: OfflineLibraryGroup?,
        preloadedAllEpisodes: [EmbyItem]? = nil
    ) async {
        let remembered = appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey)
        if let remembered {
            let targetSeasonNum = remembered.seasonNumber ?? (item.isEpisode ? (item.parentIndexNumber ?? 1) : (loadedSeasons.first(where: { ($0.indexNumber ?? 1) > 0 })?.indexNumber ?? 1))
            if let matchedSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == targetSeasonNum }) ?? loadedSeasons.first {
                await loadEpisodesForSeason(
                    matchedSeason,
                    seasonNumber: targetSeasonNum,
                    preloadedAllEpisodes: preloadedAllEpisodes,
                    preferredOverrideEpisodeId: remembered.episodeId
                )
                return
            }
        }

        if item.isEpisode, let epSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == (item.parentIndexNumber ?? 1) }) ?? loadedSeasons.first {
            let sNum = item.parentIndexNumber ?? epSeason.indexNumber ?? 1
            await loadEpisodesForSeason(epSeason, seasonNumber: sNum, preloadedAllEpisodes: preloadedAllEpisodes)
            return
        }

        if preferOfflineFocus {
            let allDownloaded = downloadedEpisodesIn(localGroup)
            let downloadedIds = Set(allDownloaded.map(\.id))
            let downloadedSeasonNums = Array(Set(allDownloaded.map { $0.parentIndexNumber ?? 1 })).sorted()

            if !downloadedSeasonNums.isEmpty {
                var fallbackSeasonNum: Int? = nil
                var fallbackEps: [EmbyItem] = []
                var fallbackFocusId: String? = nil

                for sNum in downloadedSeasonNums {
                    guard let seasonObj = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == sNum }) else { continue }
                    let seasonEps = await fetchMergedEpisodesForSeason(seasonObj, seasonNumber: sNum, localGroup: localGroup, preloadedAllEpisodes: preloadedAllEpisodes).episodes
                    guard !Task.isCancelled else { return }

                    let downloadedInSeason = seasonEps.filter { downloadedIds.contains($0.id) }
                    if fallbackSeasonNum == nil && !downloadedInSeason.isEmpty {
                        fallbackSeasonNum = sNum
                        fallbackEps = seasonEps
                        fallbackFocusId = downloadedInSeason.first?.id
                    }
                    if let firstUnwatched = downloadedInSeason.first(where: { !isEpisodeWatched($0) }) {
                        self.selectedSeasonIndex = sNum
                        self.episodes = seasonEps
                        self.focusedEpisodeId = firstUnwatched.id
                        return
                    }
                }

                if let fallbackSeasonNum {
                    self.selectedSeasonIndex = fallbackSeasonNum
                    self.episodes = fallbackEps
                    self.focusedEpisodeId = fallbackFocusId ?? preferredFocusEpisodeId(in: fallbackEps)
                    return
                }
            }
        }

        if let defaultSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? loadedSeasons.first {
            let sNum = defaultSeason.indexNumber ?? 1
            await loadEpisodesForSeason(defaultSeason, seasonNumber: sNum, preloadedAllEpisodes: preloadedAllEpisodes)
        }
    }

    private func fetchMergedEpisodesForSeason(
        _ season: EmbyItem,
        seasonNumber: Int,
        localGroup: OfflineLibraryGroup?,
        preloadedAllEpisodes: [EmbyItem]? = nil
    ) async -> (episodes: [EmbyItem], error: Error?) {
        let localEps = localGroup?.episodesBySeason[seasonNumber] ?? []
        if let preloadedAllEpisodes {
            let filtered = preloadedAllEpisodes.filter { ($0.parentIndexNumber ?? 1) == seasonNumber }
            let remote = filtered.isEmpty ? preloadedAllEpisodes : filtered
            return (mergeEpisodes(remote: remote, local: localEps), nil)
        }
        guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (localEps, nil)
        }
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            let tvId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
            let sName = item.isEpisode ? item.seriesName : item.name
            do {
                let eps = try await ext.fetchSeasonEpisodes(
                    server: server,
                    tvId: tvId,
                    seasonId: season.id,
                    seasonNumber: seasonNumber,
                    seriesName: sName
                )
                let fallbackPoster = season.uhdPosterURL ?? item.uhdPosterURL
                let fallbackBackdrop = item.uhdBackdropURL
                let fallbackLogo = item.uhdLogoURL
                let enrichedRemote = eps.map { ep in
                    ep.withInheritedArtworkFallback(
                        posterURL: fallbackPoster,
                        backdropURL: fallbackBackdrop,
                        logoURL: fallbackLogo
                    )
                }
                return (mergeEpisodes(remote: enrichedRemote, local: localEps), nil)
            } catch {
                return (localEps, error)
            }
        }
        let seriesId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
        var lastError: Error? = nil
        do {
            let eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: seriesId, seasonId: season.id)
            if !eps.isEmpty {
                return (mergeEpisodes(remote: eps, local: localEps), nil)
            }
        } catch {
            lastError = error
        }
        do {
            let allEps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: seriesId)
            let filtered = allEps.filter { ($0.parentIndexNumber ?? 1) == seasonNumber }
            return (mergeEpisodes(remote: filtered.isEmpty ? allEps : filtered, local: localEps), nil)
        } catch {
            return (localEps, lastError ?? error)
        }
    }

    func triggerSeasonLoad(_ season: EmbyItem, seasonNumber: Int) {
        activeSeasonLoadTask?.cancel()
        selectedSeasonIndex = seasonNumber
        activeSeasonLoadTask = Task {
            await loadEpisodesForSeason(season, seasonNumber: seasonNumber)
        }
    }

    func loadEpisodesForSeason(
        _ season: EmbyItem,
        seasonNumber: Int? = nil,
        preloadedAllEpisodes: [EmbyItem]? = nil,
        preferredOverrideEpisodeId: String? = nil
    ) async {
        let sNum = seasonNumber ?? season.indexNumber ?? 1
        seasonLoadGeneration &+= 1
        let gen = seasonLoadGeneration
        selectedSeasonIndex = sNum
        isLoadingSeasonEpisodes = true
        defer {
            if gen == seasonLoadGeneration {
                isLoadingSeasonEpisodes = false
            }
        }
        let localGroup = cachedOfflineGroup
        let result = await fetchMergedEpisodesForSeason(season, seasonNumber: sNum, localGroup: localGroup, preloadedAllEpisodes: preloadedAllEpisodes)
        guard !Task.isCancelled, gen == seasonLoadGeneration else { return }
        self.episodes = result.episodes
        if result.episodes.isEmpty, let err = result.error, !(err is CancellationError) {
            self.detailLoadError = err.localizedDescription
        } else if !result.episodes.isEmpty {
            self.detailLoadError = nil
        }
        if let ovId = preferredOverrideEpisodeId, result.episodes.contains(where: { $0.id == ovId }) {
            self.focusedEpisodeId = ovId
        } else if userDidPickEpisodeLocally, let curId = focusedEpisodeId, result.episodes.contains(where: { $0.id == curId }) {
            self.focusedEpisodeId = curId
        } else {
            self.focusedEpisodeId = preferredFocusEpisodeId(in: result.episodes)
        }
    }

    private func syncDefaultTracks() {
        if let preferredSource = item.mediaSources?.preferredSource(for: appState.preferredVersionPreset) ?? item.mediaSources?.first {
            selectedSourceId = preferredSource.id
        }
        syncStreamsForSelectedSource()
    }

    func syncStreamsForSelectedSource() {
        if let selAudio = selectedAudioIndex, audioStreams.contains(where: { $0.index == selAudio }) {
            // keep valid audio selection
        } else {
            selectedAudioIndex = (audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first)?.index
        }

        if let selSub = selectedSubtitleIndex, subtitleStreams.contains(where: { $0.index == selSub }) {
            // keep valid subtitle selection
        } else if !didUserDisableSubtitle {
            let candidates = subtitleStreams.map { stream in
                SubtitleTrackCandidate(
                    id: "emb-\(stream.index ?? -1)",
                    language: stream.language,
                    title: stream.readableLabel,
                    codec: stream.codec,
                    isExternal: stream.isExternal == true,
                    embyIndex: stream.index,
                    avStreamIndex: stream.index,
                    isDefault: stream.isDefault == true
                )
            }
            if let srvId = effectiveDetailServer?.id ?? appState.activeServer?.id,
               let remembered = appState.resolvedPrimarySubtitleMemory(serverId: srvId, item: item) {
                if remembered.isDisabled {
                    didUserDisableSubtitle = true
                    selectedSubtitleIndex = nil
                    return
                }
                if let matchedIdx = SubtitleTrackMatcher.bestMatchIndex(in: candidates, for: remembered) {
                    selectedSubtitleIndex = subtitleStreams[matchedIdx].index
                    return
                }
            }
            if let smartDefaultIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: candidates) {
                selectedSubtitleIndex = subtitleStreams[smartDefaultIdx].index
            } else {
                selectedSubtitleIndex = (subtitleStreams.first(where: { $0.isDefault == true }) ?? subtitleStreams.first)?.index
            }
        }
    }
}

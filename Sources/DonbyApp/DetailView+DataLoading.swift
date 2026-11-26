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

    var effectivePlayButtonStartSeconds: Double {
        let target = heroResolvedPlayTarget
        if target.resumePositionSeconds > 0.5 {
            return target.resumePositionSeconds
        }
        if target.isEpisode, let serverId = effectiveDetailServer?.id ?? appState.activeServer?.id {
            let pref = appState.effectiveSkipPreference(serverId: serverId, item: target)
            if pref.introEnabled && pref.mode == .automatic && pref.introSeconds > 0 {
                return Double(pref.introSeconds)
            }
        }
        return 0.0
    }

    func runDetailPrewarmAndPreload() async {
        guard !isLoadingDetails else { return }
        guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if item.isSeries && heroTargetEpisode == nil { return }
        let target = heroResolvedPlayTarget
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let sourceHint = (target.id == item.id && !selectedSourceId.isEmpty) ? selectedSourceId : nil
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            await ext.prewarmPlayback(server: server, item: target)
        } else {
            await EmbyClient.shared.prewarmPlaybackInfo(server: server, itemId: target.id, mediaSourceId: sourceHint)
        }

        guard appState.detailPreloadEnabled,
              appState.turboEnabled,
              appState.activePlayback == nil,
              DonbyDownloadManager.shared.completedEntry(for: target.id, serverId: server.id) == nil else {
            return
        }
        // Gentle debounce so quick detail browsing never wastes traffic
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, appState.activePlayback == nil else { return }

        let preset = appState.preferredVersionPreset
        let enable302 = appState.enable302Cache && server.cache302Request
        let resolved: ResolvedPlaybackResource?
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            resolved = try? await ext.resolvePlaybackResource(
                server: server,
                item: target,
                preferredSourceId: sourceHint,
                preferredPreset: preset,
                enable302Cache: enable302
            )
        } else {
            resolved = try? await EmbyClient.shared.resolvePlaybackResource(
                server: server,
                item: target,
                preferredSourceId: sourceHint,
                preferredPreset: preset,
                enable302Cache: enable302,
                defer302ProbeWhenTurbo: true
            )
        }
        guard !Task.isCancelled, appState.activePlayback == nil, let res = resolved else { return }
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
        let cachedRedirectURL: URL? = (res.originStreamURL != nil && res.originStreamURL != res.streamURL) ? res.streamURL : nil
        let durationSec = Double(target.runTimeTicks ?? res.mediaSource.runTimeTicks ?? 0) / 10_000_000.0
        let playStartSec = effectivePlayButtonStartSeconds
        let redirectHandler: (@Sendable (URL) -> Void)? = enable302
            ? Self.makeRedirectStoreHandler(key: redirectKey)
            : nil

        DonbyTurboCacheEngine.shared.startDetailPreload(
            assetKey: assetKey,
            streamURL: originURL,
            cachedRedirectURL: cachedRedirectURL,
            headers: res.headers,
            knownTotalSize: res.mediaSource.size,
            durationSeconds: durationSec,
            resumePositionSeconds: playStartSec,
            preloadSeconds: appState.detailPreloadSeconds,
            maxMemoryBytes: max(64, appState.turboMemoryCacheMB) * 1024 * 1024,
            onResolvedRedirectURL: redirectHandler
        )
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
        for entry in downloadManager.entries where entry.status == .completed {
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
        let localPath = downloadManager.activeOrCompletedEntry(for: ep.id)?.localVideoFilePath
        return appState.isItemWatchedOfflineOrLocal(ep, localVideoPath: localPath)
    }

    private func preferredFocusEpisodeId(in eps: [EmbyItem]) -> String? {
        if (item.isEpisode || initialItem.isEpisode),
           let exact = eps.first(where: { $0.id == initialItem.id || $0.id == item.id }) {
            return exact.id
        }
        if preferOfflineFocus {
            let downloadedInSeason = eps.filter { downloadManager.completedEntry(for: $0.id) != nil }
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

    func refreshOfflineAndCacheSnapshots() async {
        let entries = downloadManager.entries
        let target = initialItem
        let (group, assets) = await Task.detached(priority: .userInitiated) {
            let groups = DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: entries)
            let matched = Self.matchOfflineGroup(for: target, in: groups)
            let unpinned = DonbyTurboCacheEngine.shared.listUnpinnedCachedAssets()
            return (matched, unpinned)
        }.value
        guard !Task.isCancelled else { return }
        self.cachedOfflineGroup = group
        self.cachedUnpinnedAssets = assets
    }

    func loadFullDetailData() async {
        await refreshOfflineAndCacheSnapshots()
        guard !Task.isCancelled else { return }
        let localGroup = cachedOfflineGroup
        // Hydrate from local offline library first so offline items / slow networks show immediately
        if let localGroup {
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

        guard let server = effectiveDetailServer else { return }
        guard !server.host.isEmpty else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        let targetSeriesId: String? = initialItem.isSeries ? initialItem.id : (initialItem.isEpisode ? initialItem.seriesId : nil)

        if let ext = DonbyAppExtensionCenter.shared.plugin, ext.isActive(for: server) {
            let payload = await ext.loadDetailPayload(server: server, initialItem: initialItem, targetSeriesId: targetSeriesId)
            guard !Task.isCancelled else { return }
            if let enriched = payload.enrichedItem {
                self.item = enriched
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
            return
        }

        let detailFetchId: String = if initialItem.isEpisode, let sid = targetSeriesId, !sid.isEmpty {
            sid
        } else {
            initialItem.id
        }

        async let detailTask = try? EmbyClient.shared.fetchItemDetail(server: server, itemId: detailFetchId)
        async let similarTask = try? EmbyClient.shared.fetchSimilarItems(server: server, itemId: detailFetchId)
        async let seasonsTask: [EmbyItem]? = {
            guard let sid = targetSeriesId, !sid.isEmpty else { return nil }
            return try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: sid)
        }()

        var upgradedSimilarItems: [EmbyItem]? = nil
        if let detailed = await detailTask {
            guard !Task.isCancelled else { return }
            if detailed.isEpisode, let sid = detailed.seriesId, !sid.isEmpty {
                appState.rememberDetailFocusedEpisode(
                    seriesKey: sid,
                    seasonNumber: detailed.parentIndexNumber,
                    episodeId: detailed.id
                )
                async let parentSeriesTask = try? EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                async let parentSimilarTask = try? EmbyClient.shared.fetchSimilarItems(server: server, itemId: sid)
                if let parentSeries = await parentSeriesTask {
                    guard !Task.isCancelled else { return }
                    self.item = parentSeries
                    upgradedSimilarItems = await parentSimilarTask
                } else {
                    self.item = detailed
                }
            } else {
                self.item = detailed
            }
        }
        guard !Task.isCancelled else { return }
        syncDefaultTracks()

        var preloadedSeasons = await seasonsTask
        guard !Task.isCancelled else { return }
        if (preloadedSeasons == nil || preloadedSeasons?.isEmpty == true), item.isSeries, targetSeriesId == nil {
            preloadedSeasons = try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: item.id)
            guard !Task.isCancelled else { return }
        }

        if item.isSeries {
            if let loadedSeasons = preloadedSeasons, !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                await applyInitialSeasonAndFocus(seasons: loadedSeasons, localGroup: localGroup)
            } else if let allEps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id) {
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
            }
        } else if item.isEpisode, let sId = item.seriesId {
            let loadedSeasons: [EmbyItem]?
            if let preloadedSeasons, !preloadedSeasons.isEmpty {
                loadedSeasons = preloadedSeasons
            } else {
                loadedSeasons = try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: sId)
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
            }
        }

        guard !Task.isCancelled else { return }
        if let sims = upgradedSimilarItems {
            self.similarItems = sims
        } else if let sims = await similarTask {
            self.similarItems = sims
        }
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
                    let seasonEps = await fetchMergedEpisodesForSeason(seasonObj, seasonNumber: sNum, localGroup: localGroup, preloadedAllEpisodes: preloadedAllEpisodes)
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
    ) async -> [EmbyItem] {
        let localEps = localGroup?.episodesBySeason[seasonNumber] ?? []
        if let preloadedAllEpisodes {
            let filtered = preloadedAllEpisodes.filter { ($0.parentIndexNumber ?? 1) == seasonNumber }
            let remote = filtered.isEmpty ? preloadedAllEpisodes : filtered
            return mergeEpisodes(remote: remote, local: localEps)
        }
        guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return localEps
        }
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            let tvId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
            let sName = item.isEpisode ? item.seriesName : item.name
            if let eps = try? await ext.fetchSeasonEpisodes(
                server: server,
                tvId: tvId,
                seasonId: season.id,
                seasonNumber: seasonNumber,
                seriesName: sName
            ) {
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
                return mergeEpisodes(remote: enrichedRemote, local: localEps)
            }
            return localEps
        }
        let seriesId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
        if let eps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: seriesId, seasonId: season.id), !eps.isEmpty {
            return mergeEpisodes(remote: eps, local: localEps)
        }
        if let allEps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: seriesId) {
            let filtered = allEps.filter { ($0.parentIndexNumber ?? 1) == seasonNumber }
            return mergeEpisodes(remote: filtered.isEmpty ? allEps : filtered, local: localEps)
        }
        return localEps
    }

    func loadEpisodesForSeason(
        _ season: EmbyItem,
        seasonNumber: Int? = nil,
        preloadedAllEpisodes: [EmbyItem]? = nil,
        preferredOverrideEpisodeId: String? = nil
    ) async {
        let sNum = seasonNumber ?? season.indexNumber ?? 1
        selectedSeasonIndex = sNum
        let localGroup = cachedOfflineGroup
        let merged = await fetchMergedEpisodesForSeason(season, seasonNumber: sNum, localGroup: localGroup, preloadedAllEpisodes: preloadedAllEpisodes)
        guard !Task.isCancelled else { return }
        self.episodes = merged
        if let ovId = preferredOverrideEpisodeId, merged.contains(where: { $0.id == ovId }) {
            self.focusedEpisodeId = ovId
        } else if userDidPickEpisodeLocally, let curId = focusedEpisodeId, merged.contains(where: { $0.id == curId }) {
            self.focusedEpisodeId = curId
        } else {
            self.focusedEpisodeId = preferredFocusEpisodeId(in: merged)
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

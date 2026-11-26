import Foundation
import DonbyCore
import DonbyNetwork

extension AppState {
    // MARK: - Turbo Constraints & Offline Download Coordination

    public func effectiveConnectionBudget(for server: EmbyServerConfig) -> Int {
        let configured = max(1, min(8, turboConnectionBudget))
        if let cap = serverCapabilities[server.id], cap.activeVideoDeliveryLimit > 0 {
            return max(1, min(configured, cap.activeVideoDeliveryLimit))
        }
        return configured
    }

    /// Offline downloads benefit from higher multi-TCP parallelism on high-RTT / per-stream-shaped CDNs:
    /// honors explicit low user limits (`1...3`) and positive `activeVideoDeliveryLimit` caps, while lifting
    /// the default `4` to `6` (and honoring `5...8` user settings) on unlimited servers.
    public func effectiveDownloadConnectionBudget(for server: EmbyServerConfig) -> Int {
        let configured = max(1, min(8, turboConnectionBudget))
        if let cap = serverCapabilities[server.id], cap.activeVideoDeliveryLimit > 0 {
            return max(1, min(configured, cap.activeVideoDeliveryLimit))
        }
        return configured >= 4 ? max(configured, 6) : configured
    }

    public func canDownload(from server: EmbyServerConfig) -> Bool {
        serverCapabilities[server.id]?.allowDownload ?? true
    }

    public func refreshServerCapabilities(for server: EmbyServerConfig) async {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isUsingUHDExtension(for: server), let ext = DonbyAppExtensionCenter.shared.plugin {
            await ext.refreshAccountSnapshot(for: server, appState: self)
        } else {
            let allowDl = await EmbyClient.shared.fetchUserDownloadPermission(server: server)
            serverCapabilities[server.id] = ServerDeliveryCapabilities(allowDownload: allowDl)
        }
    }

    public func enqueueDownload(
        server: EmbyServerConfig,
        item: EmbyItem,
        seriesItemHint: EmbyItem? = nil,
        preferredSourceId: String? = nil
    ) async {
        await refreshServerCapabilities(for: server)
        guard canDownload(from: server) else {
            showToast("当前账号或订阅套餐不允许下载", icon: "lock.fill", isError: true)
            return
        }
        do {
            var targetItem = item
            var resolvedSeries: EmbyItem? = seriesItemHint ?? (item.isSeries ? item : nil)
            if item.isSeries {
                let eps: [EmbyItem]
                if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                    let seasons = try await ext.fetchSeasons(server: server, tvId: item.id)
                    let preferredSeason = seasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? seasons.first
                    if let s = preferredSeason {
                        let rawEps = try await ext.fetchSeasonEpisodes(
                            server: server, tvId: item.id, seasonId: s.id, seasonNumber: s.indexNumber, seriesName: item.name
                        )
                        eps = rawEps.map {
                            $0.withInheritedArtworkFallback(
                                posterURL: s.uhdPosterURL ?? item.uhdPosterURL,
                                backdropURL: item.uhdBackdropURL,
                                logoURL: item.uhdLogoURL
                            )
                        }
                    } else { eps = [] }
                } else {
                    eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id)
                }
                if let first = eps.first(where: { $0.userData?.played != true }) ?? eps.first {
                    targetItem = first
                }
            }

            if targetItem.isEpisode && resolvedSeries == nil, let sid = targetItem.seriesId, !sid.isEmpty {
                resolvedSeries = allLoadedMediaItems.first(where: { $0.id == sid })
                if resolvedSeries == nil {
                    resolvedSeries = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                        try? await ext.fetchItemDetail(
                            server: server,
                            item: EmbyItem(id: sid, name: targetItem.seriesName ?? "", type: "Series", uhdMediaType: "tv")
                        )
                    } else {
                        try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                    }
                }
            }

            let resource: ResolvedPlaybackResource = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                try await ext.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache && server.cache302Request
                )
            } else {
                try await EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache
                )
            }

            let itemPoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 800)
            let itemBackdrop = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .backdrop, maxWidth: 1920)
            let itemThumb = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .thumb, maxWidth: 800)
            let itemLogo = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .logo, maxWidth: 800)
            let seasonPoster = targetItem.seasonId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 600) }

            let seriesPoster = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .primary, maxWidth: 800) }
                ?? targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 800) }
            let seriesBackdrop = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .backdrop, maxWidth: 1920) }
                ?? targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .backdrop, maxWidth: 1920) }
            let seriesLogo = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .logo, maxWidth: 800) }
                ?? targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .logo, maxWidth: 800) }

            let poster = (seriesPoster ?? itemPoster)?.absoluteString
            let meta = formattedWatchRecordMetadata(for: targetItem, resolvedSeriesName: resolvedSeries?.name ?? targetItem.seriesName)
            let budget = effectiveDownloadConnectionBudget(for: server)
            DonbyDownloadManager.shared.enqueueDownload(
                server: server,
                item: targetItem,
                seriesItem: resolvedSeries,
                resource: resource,
                title: meta.title,
                subtitle: meta.subtitle,
                posterURLString: poster,
                itemArtworkURLs: (poster: itemPoster, backdrop: itemBackdrop, thumb: itemThumb, logo: itemLogo, seasonPoster: seasonPoster),
                seriesArtworkURLs: (poster: seriesPoster, backdrop: seriesBackdrop, logo: seriesLogo),
                connectionBudgetPerTask: budget
            )
            showToast("已加入下载队列：\(meta.title)", icon: "arrow.down.circle.fill")
        } catch {
            showToast("添加下载失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func handleFullyCachedAssetNotification(_ meta: ChunkStoreMeta) {
        guard autoSaveFullCacheToOffline else { return }
        guard DonbyDownloadManager.shared.entry(for: meta.assetKey) == nil else { return }
        guard !meta.pinned, meta.isFullyCached else { return }
        if let serverId = meta.serverId,
           let srv = servers.first(where: { $0.id == serverId }),
           !canDownload(from: srv) {
            return
        }
        let summary = CachedMediaSummary(
            assetKey: meta.assetKey,
            serverId: meta.serverId,
            itemId: meta.itemId ?? meta.itemSnapshot?.id,
            mediaSourceId: meta.mediaSourceId ?? meta.mediaSourceSnapshot?.id,
            displayTitle: meta.displayTitle ?? meta.itemSnapshot?.name ?? "已缓存媒体",
            subtitle: meta.subtitle,
            posterURLString: meta.posterURLString,
            sourceURLString: meta.sourceURLString,
            cachedBytes: meta.cachedBytes,
            totalBytes: meta.totalSize,
            lastAccess: meta.lastAccess,
            isFullyCached: true,
            itemSnapshot: meta.itemSnapshot,
            mediaSourceSnapshot: meta.mediaSourceSnapshot
        )
        Task {
            await promoteCachedAssetToOffline(summary, isAutoSave: true)
        }
    }

    public func promoteCachedAssetToOffline(_ summary: CachedMediaSummary, isAutoSave: Bool = false) async {
        let store = DonbyTurboCacheEngine.shared.store(for: summary.assetKey, persistDisk: true)
        store.setPinned(true)

        let server = servers.first(where: { $0.id == summary.serverId })
            ?? activeServer
            ?? DemoServerData.makeDefaultUHDServer()
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await refreshServerCapabilities(for: server)
            guard canDownload(from: server) else {
                store.setPinned(false)
                if !isAutoSave {
                    showToast("当前账户订阅不允许转存下载", icon: "lock.fill", isError: true)
                }
                return
            }
        }

        let targetItem = summary.itemSnapshot ?? EmbyItem(
            id: summary.itemId ?? summary.assetKey,
            name: summary.displayTitle,
            serverId: server.id.uuidString,
            type: "Movie",
            uhdPosterURL: summary.posterURLString
        )

        var resolvedSeries: EmbyItem? = nil
        if targetItem.isEpisode, let sid = targetItem.seriesId, !sid.isEmpty {
            resolvedSeries = allLoadedMediaItems.first(where: { $0.id == sid })
            if resolvedSeries == nil && !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvedSeries = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                    try? await ext.fetchItemDetail(
                        server: server,
                        item: EmbyItem(id: sid, name: targetItem.seriesName ?? "", type: "Series", uhdMediaType: "tv")
                    )
                } else {
                    try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                }
            }
        }

        let resolvedResource: ResolvedPlaybackResource
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           summary.itemSnapshot != nil,
           let fresh = try? await (
                DonbyMediaServiceRegistry.shared.provider(for: server.type) != nil
                ? DonbyMediaServiceRegistry.shared.provider(for: server.type)!.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: summary.mediaSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache && server.cache302Request
                )
                : EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: summary.mediaSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache
                )
           ) {
            resolvedResource = fresh
        } else if let streamURL = URL(string: summary.sourceURLString) {
            let ms = summary.mediaSourceSnapshot ?? MediaSourceInfo(
                id: summary.mediaSourceId ?? summary.assetKey,
                name: streamURL.pathExtension.isEmpty ? "Cached" : streamURL.pathExtension.uppercased(),
                path: summary.sourceURLString,
                container: streamURL.pathExtension.isEmpty ? "mkv" : streamURL.pathExtension,
                size: summary.totalBytes > 0 ? summary.totalBytes : summary.cachedBytes
            )
            resolvedResource = ResolvedPlaybackResource(
                streamURL: streamURL,
                downloadURL: DownloadEntry.derivePreferredDownloadURL(from: streamURL),
                headers: [:],
                playSessionId: UUID().uuidString,
                mediaSource: ms,
                subtitleURLs: [],
                isDirectStream: true,
                routeNote: "从 Turbo 缓存转存"
            )
        } else {
            store.setPinned(false)
            if !isAutoSave {
                showToast("缓存元数据缺少媒体链接，无法转存", icon: "exclamationmark.triangle.fill", isError: true)
            }
            return
        }

        let isUHD = isUsingUHDExtension(for: server)
        let itemPoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 800)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .primary, maxWidth: 800))
            ?? summary.posterURLString.flatMap { URL(string: $0) }
        let itemBackdrop = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .backdrop, maxWidth: 1920)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .backdrop, maxWidth: 1920))
        let itemThumb = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .thumb, maxWidth: 800)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .thumb, maxWidth: 800))
        let itemLogo = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .logo, maxWidth: 800)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .logo, maxWidth: 800))
        let seasonPoster = isUHD ? nil : targetItem.seasonId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 600) }
        let seriesPoster = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .primary, maxWidth: 800) }
            ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 800) })
            ?? itemPoster
        let seriesBackdrop = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .backdrop, maxWidth: 1920) }
            ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .backdrop, maxWidth: 1920) })
        let seriesLogo = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .logo, maxWidth: 800) }
            ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .logo, maxWidth: 800) })

        let meta = formattedWatchRecordMetadata(for: targetItem, resolvedSeriesName: resolvedSeries?.name ?? targetItem.seriesName)
        let budget = effectiveDownloadConnectionBudget(for: server)
        DonbyDownloadManager.shared.enqueueDownload(
            server: server,
            item: targetItem,
            seriesItem: resolvedSeries,
            resource: resolvedResource,
            title: meta.title,
            subtitle: meta.subtitle,
            posterURLString: (seriesPoster ?? itemPoster)?.absoluteString,
            itemArtworkURLs: (poster: itemPoster, backdrop: itemBackdrop, thumb: itemThumb, logo: itemLogo, seasonPoster: seasonPoster),
            seriesArtworkURLs: (poster: seriesPoster, backdrop: seriesBackdrop, logo: seriesLogo),
            connectionBudgetPerTask: budget,
            origin: isAutoSave ? .autoArchivedFromCache : .manualDownload
        )
        showToast(
            isAutoSave
                ? "已将完整播放缓存自动归档：\(meta.title)"
                : (summary.isFullyCached ? "已将完整缓存保存至离线库：\(meta.title)" : "已从缓存继续下载 (\(Int(summary.progressFraction * 100))%)：\(meta.title)"),
            icon: "arrow.down.circle.fill"
        )
    }

    public func cleanupAutoArchivedEntryIfFinished(itemId: String, mediaSourceId: String?) {
        guard autoSaveFullCacheToOffline && autoDeleteAutoArchivedAfterPlayback else { return }
        if let removed = DonbyDownloadManager.shared.removeAutoArchivedAfterPlayback(itemId: itemId, mediaSourceId: mediaSourceId) {
            DonbyLogger.shared.log("播放完毕已自动删除缓存自动归档文件（手动下载保留）: \(removed.title)", level: .info, subsystem: "Cache")
            showToast("播放完毕，已清理自动归档：\(removed.title)", icon: "trash.circle.fill")
        }
    }
}

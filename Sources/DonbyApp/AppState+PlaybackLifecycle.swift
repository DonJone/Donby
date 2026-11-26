import Foundation
import AppKit
import DonbyCore
import DonbyNetwork

extension AppState {
    public func cancelPendingPlaybackStart() {
        guard isStartingPlayback else { return }
        playbackStartGeneration &+= 1
        pendingPlaybackKey = nil
        isStartingPlayback = false
    }

    public func startPlayback(
        item: EmbyItem,
        episodesQueue: [EmbyItem] = [],
        preferredSourceId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        subtitleExplicitlyOff: Bool = false,
        fromBeginning: Bool = false,
        preferOffline: Bool = false
    ) async {
        let directOfflineMatch = DonbyDownloadManager.shared.completedEntry(
            for: item.id,
            serverId: activeServer?.id,
            mediaSourceId: preferredSourceId
        ) ?? DonbyDownloadManager.shared.completedEntry(for: item.id, mediaSourceId: preferredSourceId)

        let resolvedServer: EmbyServerConfig
        if let active = activeServer, !active.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedServer = active
        } else if let dl = directOfflineMatch,
                  let dlSrv = servers.first(where: { $0.id == dl.serverId }) {
            resolvedServer = dlSrv
        } else if directOfflineMatch != nil {
            resolvedServer = DemoServerData.makeDefaultUHDServer()
        } else {
            showToast("请先配置服务器信息", icon: "exclamationmark.triangle.fill", isError: true)
            return
        }
        var server = resolvedServer
        let startKey = "\(server.id.uuidString)|\(item.id)|\(preferredSourceId ?? "")|\(fromBeginning)"
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if isStartingPlayback,
           pendingPlaybackKey == startKey,
           nowUptime - pendingPlaybackTimestamp < 2.5 {
            return
        }
        if activePlayback != nil,
           lastCompletedPlaybackKey == startKey,
           nowUptime - lastCompletedPlaybackTimestamp < 1.5 {
            return
        }

        playbackStartGeneration &+= 1
        let currentStartGen = playbackStartGeneration
        pendingPlaybackKey = startKey
        pendingPlaybackTimestamp = nowUptime
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            server.lastWatchedDate = Date()
            updateServerInList(server)
        }

        isStartingPlayback = true
        defer {
            if currentStartGen == playbackStartGeneration {
                isStartingPlayback = false
                pendingPlaybackKey = nil
            }
        }

        DonbyLogger.shared.log("准备播放媒体: \(item.name) (ID: \(item.id))", level: .info, subsystem: "Playback")

        do {
            var targetItem = item
            var resolvedQueue = episodesQueue
            if item.isSeries {
                let offlineLibraryGroup = DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: DonbyDownloadManager.shared.entries)
                    .first(where: { $0.displayItem.id == item.id || $0.displayItem.name == item.name })

                let eps: [EmbyItem]
                if (preferOffline || server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                   let offlineGroup = offlineLibraryGroup {
                    let allOfflineEps = offlineGroup.episodesBySeason.keys.sorted().flatMap { seasonKey in
                        (offlineGroup.episodesBySeason[seasonKey] ?? []).sorted {
                            ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0)
                        }
                    }
                    eps = allOfflineEps
                    if !allOfflineEps.isEmpty {
                        resolvedQueue = allOfflineEps
                        targetItem = allOfflineEps.first(where: { !isItemWatchedOfflineOrLocal($0) }) ?? allOfflineEps[0]
                    }
                } else if isUsingUHDExtension(for: server), let ext = DonbyAppExtensionCenter.shared.plugin {
                    let extRes = try await ext.resolveSeriesStartEpisode(server: server, seriesItem: item)
                    eps = extRes.episodes
                    if let exact = extRes.preferredTarget {
                        targetItem = exact
                    }
                } else {
                    eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id)
                }
                guard currentStartGen == playbackStartGeneration else { return }
                if resolvedQueue.isEmpty && !eps.isEmpty {
                    resolvedQueue = eps
                }
                if targetItem.id == item.id {
                    if let firstUnwatched = eps.first(where: { !isItemWatchedOfflineOrLocal($0) }) ?? eps.first {
                        targetItem = firstUnwatched
                    }
                }
            }

            DonbyLogger.shared.log("解析播放资源地址 (目标: \(targetItem.name))", level: .info, subsystem: "Playback")
            let resource: ResolvedPlaybackResource
            if let offlineEntry = DonbyDownloadManager.shared.completedEntry(
                for: targetItem.id,
                serverId: server.id,
                mediaSourceId: preferredSourceId
            ) ?? DonbyDownloadManager.shared.completedEntry(for: targetItem.id, mediaSourceId: preferredSourceId),
               let offlineRes = DonbyDownloadManager.shared.offlinePlayableResource(for: offlineEntry) {
                resource = offlineRes
            } else if let fastCached = PlaybackIntentCoordinator.shared.cachedResolvedResource(
                server: server,
                itemId: targetItem.id,
                preferredSourceId: preferredSourceId,
                preferredPreset: preferredVersionPreset,
                enable302Cache: enable302Cache && server.cache302Request
            ), (fastCached.isDirectStream || (audioStreamIndex == nil && subtitleStreamIndex == nil)) {
                // 0ms synchronous fast-table hit (warmed on DetailView, episode hover/focus, or Home continue-watching)
                resource = fastCached
                DonbyNetworkSession.prewarmEdgeOrigin(fastCached.streamURL, laneCount: 4)
            } else {
                PlaybackIntentCoordinator.shared.warmServerOnConnectOrLaunch(server: server)
                resource = try await PlaybackIntentCoordinator.shared.resolveAndCacheResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    audioStreamIndex: audioStreamIndex,
                    subtitleStreamIndex: subtitleStreamIndex,
                    enable302Cache: enable302Cache,
                    defer302ProbeWhenTurbo: turboEnabled
                )
            }
            guard currentStartGen == playbackStartGeneration else { return }

            let startSec = fromBeginning ? 0 : targetItem.resumePositionSeconds
            let remotePoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 320)?.absoluteString

            let recTitle: String
            let recSubtitle: String?
            if targetItem.isEpisode {
                var sName = targetItem.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines)
                if sName == nil || sName!.isEmpty {
                    sName = cachedSeriesNames[targetItem.id] ?? cachedSeriesNames[targetItem.seriesId ?? ""]
                }
                if (sName == nil || sName!.isEmpty), let sid = targetItem.seriesId, !sid.isEmpty {
                    let capturedTarget = targetItem
                    let capturedServer = server
                    Task { [weak self] in
                        let seriesDetail: EmbyItem? = if let ext = DonbyMediaServiceRegistry.shared.provider(for: capturedServer.type) {
                            try? await ext.fetchItemDetail(server: capturedServer, item: EmbyItem(id: sid, name: "", type: "Series", uhdMediaType: "tv"))
                        } else {
                            try? await EmbyClient.shared.fetchItemDetail(server: capturedServer, itemId: sid)
                        }
                        if let seriesDetail, !seriesDetail.name.isEmpty {
                            await MainActor.run {
                                self?.cachedSeriesNames[capturedTarget.id] = seriesDetail.name
                                self?.cachedSeriesNames[sid] = seriesDetail.name
                                self?.saveCachedSeriesNamesToDisk()
                            }
                        }
                    }
                } else if let s = sName, !s.isEmpty {
                    cachedSeriesNames[targetItem.id] = s
                    if let sid = targetItem.seriesId { cachedSeriesNames[sid] = s }
                    saveCachedSeriesNamesToDisk()
                }
                let meta = formattedWatchRecordMetadata(for: targetItem, resolvedSeriesName: sName)
                recTitle = meta.title
                recSubtitle = meta.subtitle
            } else {
                let meta = formattedWatchRecordMetadata(for: targetItem)
                recTitle = meta.title
                recSubtitle = meta.subtitle
            }

            recordWatch(
                title: recTitle,
                subtitle: recSubtitle,
                posterKey: nil,
                posterURL: remotePoster,
                position: startSec,
                duration: targetItem.durationSeconds > 0 ? targetItem.durationSeconds : 7200,
                sourceType: "Emby",
                embyItemId: targetItem.id,
                resolutionTag: targetItem.resolutionBadge ?? "4K UHD",
                mediaType: targetItem.type,
                seriesId: targetItem.seriesId
            )
            DonbyLogger.shared.log("媒体流解析成功: \(PlaybackDiagnosticsRedactor.redact(resource.streamURL.absoluteString))", level: .info, subsystem: "Playback")
            lastCompletedPlaybackKey = startKey
            lastCompletedPlaybackTimestamp = ProcessInfo.processInfo.systemUptime
            self.activePlayback = ActivePlaybackSession(
                server: server,
                item: targetItem,
                episodesQueue: resolvedQueue.isEmpty ? [targetItem] : resolvedQueue,
                resource: resource,
                startPositionSeconds: startSec,
                selectedAudioIndex: audioStreamIndex,
                selectedSubtitleIndex: subtitleStreamIndex,
                subtitleExplicitlyOff: subtitleExplicitlyOff
            )
        } catch {
            guard currentStartGen == playbackStartGeneration else { return }
            DonbyLogger.shared.log("获取播放流失败: \(error.localizedDescription)", level: .error, subsystem: "Playback")
            showToast("获取播放流失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func playDirectURL(url: URL, title: String, startSeconds: Double = 0) {
        playbackStartGeneration &+= 1
        let isLocal = url.isFileURL || url.scheme == "file" || url.path.hasPrefix("/")
        let parsed = MediaTitleParser.parse(rawName: title)
        let resolvedTitle = isLocal ? parsed.mainTitle : title
        let resolvedSubtitle = isLocal ? parsed.subTitle : (url.isFileURL ? "本地文件" : "网络链接")

        let server = activeServer ?? DemoServerData.makeDefaultUHDServer()
        let dummySource = MediaSourceInfo(
            id: UUID().uuidString,
            name: url.pathExtension.isEmpty ? "Direct Stream" : url.pathExtension.uppercased(),
            path: isLocal ? url.path : url.absoluteString,
            container: url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        )
        let dummyItem = EmbyItem(
            id: UUID().uuidString,
            name: resolvedTitle,
            type: "Video",
            container: dummySource.container,
            mediaSources: [dummySource]
        )
        let resource = ResolvedPlaybackResource(
            streamURL: url,
            headers: [:],
            playSessionId: UUID().uuidString,
            mediaSource: dummySource,
            subtitleURLs: [],
            isDirectStream: true,
            routeNote: isLocal ? "本地文件" : "网络链接"
        )
        addRecentMedia(name: resolvedTitle, urlString: isLocal ? url.path : url.absoluteString, isLocal: isLocal)
        recordWatch(
            title: resolvedTitle,
            subtitle: resolvedSubtitle,
            posterKey: nil,
            position: startSeconds,
            duration: 3600,
            sourceType: isLocal ? "本地文件" : "网络直链",
            streamURLString: isLocal ? url.path : url.absoluteString,
            resolutionTag: isLocal ? "本地 4K" : "在线原画"
        )
        self.activePlayback = ActivePlaybackSession(
            server: server,
            item: dummyItem,
            episodesQueue: [dummyItem],
            resource: resource,
            startPositionSeconds: startSeconds,
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil
        )
    }

    public func copyStreamDirectURL(
        item: EmbyItem,
        preferredSourceId: String? = nil
    ) async {
        guard let server = activeServer else { return }
        do {
            let resource: ResolvedPlaybackResource = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                try await ext.resolvePlaybackResource(
                    server: server,
                    item: item,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache && server.cache302Request
                )
            } else {
                try await EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: item,
                    preferredSourceId: preferredSourceId,
                    enable302Cache: enable302Cache
                )
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resource.streamURL.absoluteString, forType: .string)
            showToast("已复制媒体直链", icon: "doc.on.doc.fill")
        } catch {
            showToast("解析播放链接失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func playOfflineDownload(_ entry: DownloadEntry) {
        guard let resource = DonbyDownloadManager.shared.offlinePlayableResource(for: entry) else {
            showToast("离线文件尚未下载完成或已损坏", icon: "exclamationmark.triangle.fill", isError: true)
            return
        }
        let targetServer = servers.first(where: { $0.id == entry.serverId }) ?? DemoServerData.makeDefaultUHDServer()
        let startSec = entry.itemSnapshot.resumePositionSeconds
        self.activePlayback = ActivePlaybackSession(
            server: targetServer,
            item: entry.hydratedItemSnapshot,
            episodesQueue: [entry.hydratedItemSnapshot],
            resource: resource,
            startPositionSeconds: startSec,
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil
        )
    }

    // MARK: - Subtitle Track Memory (Per-Item, Per-Series & Global Preferred)

    private func subtitleScopeKeys(serverId: UUID, item: EmbyItem) -> (itemKey: String, seriesKey: String?) {
        let srvPart = serverId.uuidString
        let itemKey = "\(srvPart)|item:\(item.id)"
        let seriesKey: String? = {
            if let sid = item.seriesId, !sid.isEmpty {
                return "\(srvPart)|series:\(sid)"
            }
            if item.isSeries {
                return "\(srvPart)|series:\(item.id)"
            }
            if let sName = item.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines), !sName.isEmpty {
                return "\(srvPart)|seriesName:\(sName.lowercased())"
            }
            return nil
        }()
        return (itemKey, seriesKey)
    }

    public func resolvedPrimarySubtitleMemory(serverId: UUID, item: EmbyItem) -> SubtitleTrackPreference? {
        guard rememberSubtitleSelection else { return nil }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        if let exact = subtitleMemoryByScope[keys.itemKey]?.primary {
            return exact
        }
        if let sKey = keys.seriesKey, let seriesPref = subtitleMemoryByScope[sKey]?.primary {
            // Avoid applying another episode's local external file path to sibling episodes
            var copy = seriesPref
            copy.localFilePath = nil
            return copy
        }
        if let global = globalPreferredSubtitle {
            var copy = global
            copy.localFilePath = nil
            copy.embyStreamIndex = nil
            return copy
        }
        return nil
    }

    public func resolvedSecondarySubtitleMemory(serverId: UUID, item: EmbyItem) -> SubtitleTrackPreference? {
        guard rememberSubtitleSelection else { return nil }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        if let exact = subtitleMemoryByScope[keys.itemKey]?.secondary {
            return exact
        }
        if let sKey = keys.seriesKey, let seriesPref = subtitleMemoryByScope[sKey]?.secondary {
            var copy = seriesPref
            copy.localFilePath = nil
            return copy
        }
        if let global = globalPreferredSecondarySubtitle {
            var copy = global
            copy.localFilePath = nil
            copy.embyStreamIndex = nil
            return copy
        }
        return nil
    }

    public func recordPrimarySubtitleChoice(
        serverId: UUID,
        item: EmbyItem,
        preference: SubtitleTrackPreference,
        updateGlobal: Bool = true
    ) {
        guard rememberSubtitleSelection else { return }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        var itemMem = subtitleMemoryByScope[keys.itemKey] ?? SeriesSubtitleMemory()
        itemMem.primary = preference
        itemMem.updatedAt = Date()
        subtitleMemoryByScope[keys.itemKey] = itemMem

        if let sKey = keys.seriesKey {
            var seriesMem = subtitleMemoryByScope[sKey] ?? SeriesSubtitleMemory()
            var seriesPref = preference
            seriesPref.localFilePath = nil
            seriesMem.primary = seriesPref
            seriesMem.updatedAt = Date()
            subtitleMemoryByScope[sKey] = seriesMem
        }

        if updateGlobal && !preference.isDisabled && preference.localFilePath == nil {
            var globalPref = preference
            globalPref.embyStreamIndex = nil
            globalPreferredSubtitle = globalPref
        }
    }

    public func recordSecondarySubtitleChoice(
        serverId: UUID,
        item: EmbyItem,
        preference: SubtitleTrackPreference,
        updateGlobal: Bool = true
    ) {
        guard rememberSubtitleSelection else { return }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        var itemMem = subtitleMemoryByScope[keys.itemKey] ?? SeriesSubtitleMemory()
        itemMem.secondary = preference
        itemMem.updatedAt = Date()
        subtitleMemoryByScope[keys.itemKey] = itemMem

        if let sKey = keys.seriesKey {
            var seriesMem = subtitleMemoryByScope[sKey] ?? SeriesSubtitleMemory()
            var seriesPref = preference
            seriesPref.localFilePath = nil
            seriesMem.secondary = seriesPref
            seriesMem.updatedAt = Date()
            subtitleMemoryByScope[sKey] = seriesMem
        }

        if updateGlobal && preference.localFilePath == nil {
            var globalPref = preference
            globalPref.embyStreamIndex = nil
            globalPreferredSecondarySubtitle = globalPref
        }
    }

    // MARK: - Per-Season Skip Preferences

    public func seasonSkipKey(serverId: UUID, item: EmbyItem) -> String {
        let seriesPart = item.seriesId ?? item.id
        let seasonPart = item.seasonId ?? "s\(item.parentIndexNumber ?? 0)"
        return "\(serverId.uuidString)|\(seriesPart)|\(seasonPart)"
    }

    public func effectiveSkipPreference(serverId: UUID, item: EmbyItem) -> SeasonSkipPreference {
        let key = seasonSkipKey(serverId: serverId, item: item)
        if let saved = seasonSkipPreferences[key] {
            return saved
        }
        return SeasonSkipPreference(
            introSeconds: Double(opSeconds),
            outroSeconds: Double(edSeconds),
            mode: autoSkipIntroOutro ? .automatic : .manual
        )
    }

    public func updateSeasonSkipPreference(serverId: UUID, item: EmbyItem, mutate: (inout SeasonSkipPreference) -> Void) {
        let key = seasonSkipKey(serverId: serverId, item: item)
        var pref = effectiveSkipPreference(serverId: serverId, item: item)
        mutate(&pref)
        seasonSkipPreferences[key] = pref
    }
}

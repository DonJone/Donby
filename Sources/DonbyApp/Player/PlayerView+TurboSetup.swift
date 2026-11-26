import SwiftUI
import DonbyCore
import DonbyNetwork

extension PlayerView {
    static func resolvedTurboPrefetchChunks(prefetchSeconds: Double, bitrateBps: Int64?) -> Int {
        let base = Int(prefetchSeconds * 1.2)
        if let bps = bitrateBps, bps > 0 {
            let bitrateBased = Int((Double(bps) / 8.0 / 524_288.0) * 18.0)
            return max(24, min(360, max(base, min(144, bitrateBased))))
        }
        return max(24, min(360, base))
    }

    func prepareTurboPlaybackHandle(
        urlStr: String,
        startSeconds: Double
    ) -> (handle: TurboStreamByteHandle?, store: TieredAssetChunkStore?, hadWarmCachedHeader: Bool) {
        let lowerURL = urlStr.lowercased()
        let isRemoteHTTPVOD = (lowerURL.hasPrefix("http://") || lowerURL.hasPrefix("https://"))
            && !lowerURL.contains(".m3u8")
            && !lowerURL.contains(".mpd")
        guard appState.turboEnabled && isRemoteHTTPVOD else {
            return (nil, nil, false)
        }

        let assetKey = DonbyTurboCacheEngine.makeAssetKey(
            serverId: session.server.id,
            itemId: currentItem.id,
            mediaSourceId: currentResource.mediaSource.id
        )
        let store = DonbyTurboCacheEngine.shared.store(
            for: assetKey,
            maxMemoryBytes: max(64, appState.turboMemoryCacheMB) * 1024 * 1024,
            persistDisk: true
        )
        let hadWarmCachedHeader = store.hasChunk(0)
        if let knownSize = currentResource.mediaSource.size, knownSize > 0 {
            store.setTotalSize(knownSize, sourceURL: urlStr)
        }
        let cachedMeta = appState.formattedWatchRecordMetadata(for: currentItem)
        let cachedPoster = EmbyClient.shared.imageURL(server: session.server, item: currentItem, kind: .primary, maxWidth: 400)?.absoluteString
        store.updateCachedMetadata(
            serverId: session.server.id,
            itemId: currentItem.id,
            mediaSourceId: currentResource.mediaSource.id,
            displayTitle: cachedMeta.title,
            subtitle: cachedMeta.subtitle,
            posterURLString: cachedPoster,
            itemSnapshot: currentItem,
            mediaSourceSnapshot: currentResource.mediaSource
        )
        let budget = appState.effectiveConnectionBudget(for: session.server)
        let enableRedirectCache = appState.enable302Cache && session.server.cache302Request
        let redirectKey = EmbyClient.redirectCacheKey(
            serverId: session.server.id,
            itemId: currentItem.id,
            mediaSourceId: currentResource.mediaSource.id,
            baseURL: session.server.activeBaseURL
        )
        let prefetchChunks = Self.resolvedTurboPrefetchChunks(
            prefetchSeconds: appState.turboPrefetchSeconds,
            bitrateBps: currentResource.mediaSource.bitrate.map(Int64.init)
        )
        let redirectCallback: (@Sendable (URL) -> Void)? = enableRedirectCache
            ? Self.makeRedirectStoreHandler(key: redirectKey)
            : nil
        let invalidateCallback: (@Sendable () -> Void)? = enableRedirectCache
            ? Self.makeRedirectInvalidateHandler(key: redirectKey)
            : nil
        let originURL = currentResource.originStreamURL ?? currentResource.streamURL
        let cachedRedirectURL: URL? = (currentResource.originStreamURL != nil && currentResource.originStreamURL != currentResource.streamURL)
            ? currentResource.streamURL
            : (enableRedirectCache ? NetworkRouteWarmStore.shared.cachedRedirect(for: redirectKey) : nil)
        let knownDurationSec = currentItem.durationSeconds > 0
            ? currentItem.durationSeconds
            : Double(currentResource.mediaSource.runTimeTicks ?? 0) / 10_000_000.0
        self.playbackNetworkPriorityToken = DonbyDownloadManager.shared.beginPlaybackNetworkPriority(activeAssetKey: assetKey)
        let handle = TurboStreamByteHandle(
            assetKey: assetKey,
            streamURL: originURL,
            initialRedirectedURL: cachedRedirectURL,
            headers: currentResource.headers,
            store: store,
            knownTotalSize: currentResource.mediaSource.size,
            connectionBudget: budget,
            prefetchAheadChunks: prefetchChunks,
            initialStartSeconds: startSeconds,
            knownDurationSeconds: knownDurationSec,
            onResolvedRedirectURL: redirectCallback,
            onInvalidatedRedirectURL: invalidateCallback
        )
        return (handle, store, hadWarmCachedHeader)
    }

    func computePreOpenTrackHints(
        audioIdx: Int?,
        subIdx: Int?,
        isExplicitSubOff: Bool
    ) -> (preAudioHint: Int32, preSubHint: Int32, preExternalSub: SubtitleResourceItem?) {
        let preAudioHint: Int32 = {
            guard let req = audioIdx else { return -1 }
            if let matched = embyAudioStreams.first(where: { $0.index == req }),
               let idx = matched.index {
                return Int32(idx)
            }
            return Int32(req)
        }()

        if isExplicitSubOff {
            return (preAudioHint, -2, nil)
        }

        let embeddedSubs = embySubtitleStreams.filter { $0.isExternal != true }
        var preOptions: [PlayerSubtitleTrackOption] = []
        for s in embeddedSubs {
            guard let idx = s.index else { continue }
            preOptions.append(PlayerSubtitleTrackOption(
                id: "pre-emb-\(idx)",
                selection: .embedded(avStreamIndex: idx),
                embyIndex: idx,
                label: s.readableLabel,
                badge: s.codec?.uppercased(),
                externalItem: nil,
                language: s.language,
                codec: s.codec,
                isDefault: s.isDefault == true
            ))
        }
        var seenURLs = Set<String>()
        for ext in currentResource.subtitleURLs where ext.isExternal || embeddedSubs.isEmpty {
            guard seenURLs.insert(ext.url.absoluteString).inserted else { continue }
            preOptions.append(PlayerSubtitleTrackOption(
                id: "pre-ext-\(ext.id)",
                selection: .remoteExternal(url: ext.url),
                embyIndex: ext.streamIndex,
                label: ext.name,
                badge: "外挂",
                externalItem: ext,
                language: nil,
                codec: ext.codec,
                isDefault: false
            ))
        }
        let preCandidates = preOptions.map(\.trackCandidate)

        if let reqSub = subIdx, reqSub >= 0 {
            if let opt = preOptions.first(where: { $0.embyIndex == reqSub }) {
                switch opt.selection {
                case .embedded(let avIdx):
                    return (preAudioHint, Int32(avIdx), nil)
                case .remoteExternal:
                    return (preAudioHint, -2, opt.externalItem)
                case .off, .localExternal:
                    return (preAudioHint, -2, nil)
                }
            }
            return (preAudioHint, Int32(reqSub), nil)
        }

        if let remembered = appState.resolvedPrimarySubtitleMemory(serverId: session.server.id, item: currentItem) {
            if remembered.isDisabled || remembered.localFilePath != nil {
                return (preAudioHint, -2, nil)
            }
            if let matchedIdx = SubtitleTrackMatcher.bestMatchIndex(in: preCandidates, for: remembered) {
                let opt = preOptions[matchedIdx]
                switch opt.selection {
                case .embedded(let avIdx):
                    return (preAudioHint, Int32(avIdx), nil)
                case .remoteExternal:
                    return (preAudioHint, -2, opt.externalItem)
                case .off, .localExternal:
                    return (preAudioHint, -2, nil)
                }
            }
        }

        if let fallbackIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: preCandidates) {
            let opt = preOptions[fallbackIdx]
            switch opt.selection {
            case .embedded(let avIdx):
                return (preAudioHint, Int32(avIdx), nil)
            case .remoteExternal:
                return (preAudioHint, -2, opt.externalItem)
            case .off, .localExternal:
                return (preAudioHint, -2, nil)
            }
        }
        return (preAudioHint, -1, nil)
    }

    nonisolated static func makeRedirectStoreHandler(key: String) -> @Sendable (URL) -> Void {
        { finalURL in
            Task {
                await RedirectCacheStore.shared.storeRedirect(finalURL, for: key)
            }
        }
    }

    nonisolated static func makeRedirectInvalidateHandler(key: String) -> @Sendable () -> Void {
        {
            Task {
                await RedirectCacheStore.shared.invalidateRedirect(for: key)
            }
        }
    }
}

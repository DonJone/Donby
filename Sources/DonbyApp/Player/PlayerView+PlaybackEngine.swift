import SwiftUI
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

private func dkTurboReadCB(
    _ opaque: UnsafeMutableRawPointer?,
    _ buf: UnsafeMutablePointer<UInt8>?,
    _ size: Int32
) -> Int32 {
    guard let opaque, let buf, size > 0 else { return -1 }
    let handle = Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeUnretainedValue()
    return Int32(handle.read(into: buf, count: Int(size)))
}

private func dkTurboSeekCB(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: Int64,
    _ whence: Int32
) -> Int64 {
    guard let opaque else { return -1 }
    let handle = Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeUnretainedValue()
    return handle.seek(offset: offset, whence: whence)
}

private func dkTurboAbortCB(_ opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    let handle = Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeUnretainedValue()
    handle.abort()
}

private func dkTurboCloseCB(_ opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    let handle = Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeRetainedValue()
    handle.close()
}

extension PlayerView {
    func handleProgressTimerTick() {
        let hudVisible = showControls || activeDrawer != nil
            guard let handle = playerHandle, !isScrubbing else { return }
            let nowUptime = ProcessInfo.processInfo.systemUptime
            let newPos = dk_player_get_position(handle)
            let sinceSeek = nowUptime - lastSeekCommitUptime
            let isSettlingSeek = sinceSeek < 2.5 && abs(newPos - lastSeekCommitTarget) > 8.0
            if !isSettlingSeek {
                autoHideBox.liveCurrentTime = newPos
                if hudVisible && abs(currentTime - newPos) > 0.05 {
                    currentTime = newPos
                }
            }
            let livePos = autoHideBox.liveCurrentTime
            if isPlaying && hasRenderedFirstFrame && !didHandlePlaybackEnded && !isOpeningMedia {
                if autoHideBox.lastObservedPos < 0 || abs(newPos - autoHideBox.lastObservedPos) > 0.04 {
                    autoHideBox.lastObservedPos = newPos
                    autoHideBox.lastObservedPosUptime = nowUptime
                    if isWaitingForSeekOrBuffer {
                        withAnimation(.easeOut(duration: 0.14)) {
                            isWaitingForSeekOrBuffer = false
                        }
                    }
                } else if (nowUptime - autoHideBox.lastObservedPosUptime) >= 0.48 {
                    if !isWaitingForSeekOrBuffer {
                        withAnimation(.easeIn(duration: 0.14)) {
                            isWaitingForSeekOrBuffer = true
                        }
                    }
                }
            } else if isWaitingForSeekOrBuffer {
                isWaitingForSeekOrBuffer = false
            }
            let newBuffered = dk_player_get_buffered_duration(handle)
            autoHideBox.liveBufferedAheadSeconds = newBuffered
            if hudVisible && abs(bufferedAheadSeconds - newBuffered) > 0.25 {
                bufferedAheadSeconds = newBuffered
            }
            let dur = dk_player_get_duration(handle)
            if dur > 0 {
                if abs(duration - dur) > 0.01 { duration = dur }
            } else if currentItem.durationSeconds > 0 && abs(duration - currentItem.durationSeconds) > 0.01 {
                duration = currentItem.durationSeconds
            }
            if showControls || activeDrawer == .mediaInfo || kernelStats.width == 0 {
                var freshStats = DKRuntimeStats()
                dk_player_get_stats(handle, &freshStats)
                if activeDrawer == .mediaInfo ||
                    kernelStats.width != freshStats.width ||
                    kernelStats.height != freshStats.height ||
                    kernelStats.is_hw_accelerated != freshStats.is_hw_accelerated ||
                    kernelStats.is_hdr != freshStats.is_hdr ||
                    kernelStats.is_dolby_vision != freshStats.is_dolby_vision ||
                    abs(kernelStats.fps - freshStats.fps) > 0.05 ||
                    abs(kernelStats.video_bitrate_mbps - freshStats.video_bitrate_mbps) > 0.1 {
                    kernelStats = freshStats
                }
                if let turboSpeed = activeTurboHandle?.currentWireSpeedMBs, turboSpeed > 0.01 {
                    if abs(displayDownloadSpeedMBs - turboSpeed) > 0.05 {
                        displayDownloadSpeedMBs = turboSpeed
                    }
                } else if abs(displayDownloadSpeedMBs - freshStats.download_speed_mbs) > 0.05 {
                    displayDownloadSpeedMBs = freshStats.download_speed_mbs
                }
            }

            let pState = dk_player_get_state(handle)
            companionBox.companion?.onProgressTick(
                nowUptime: nowUptime,
                livePos: livePos,
                isPlaying: isPlaying,
                hasRenderedFirstFrame: hasRenderedFirstFrame,
                isOpeningMedia: isOpeningMedia,
                isWaitingForSeekOrBuffer: isWaitingForSeekOrBuffer,
                didHandlePlaybackEnded: didHandlePlaybackEnded,
                playbackSpeed: playbackSpeed
            )
            if pState == DK_STATE_ENDED && !didHandlePlaybackEnded {
                didHandlePlaybackEnded = true
                isPlaying = false
                currentTime = livePos
                finishedItemPendingCleanup = (currentItem.id, currentResource.mediaSource.id)
                companionBox.companion?.onPlaybackEnded(livePos: livePos, playbackSpeed: playbackSpeed)
                if let ext = DonbyMediaServiceRegistry.shared.provider(for: session.server.type), !session.server.accessToken.isEmpty {
                    let srv = session.server
                    let itm = currentItem
                    let assetId = currentResource.mediaSource.id
                    let endPos = livePos
                    Task {
                        await ext.reportPlayback(server: srv, kind: .finished, item: itm, assetId: assetId, positionSeconds: endPos)
                    }
                } else if !session.server.host.isEmpty && !session.server.accessToken.isEmpty {
                    let srv = session.server
                    let itm = currentItem
                    let assetId = currentResource.mediaSource.id
                    let psId = currentResource.playSessionId
                    let endPos = livePos
                    Task {
                        await EmbyClient.shared.reportPlaybackStopped(
                            server: srv,
                            itemId: itm.id,
                            mediaSourceId: assetId,
                            playSessionId: psId,
                            positionSeconds: endPos
                        )
                        try? await EmbyClient.shared.setPlayed(server: srv, itemId: itm.id, played: true)
                    }
                }
                DonbyDownloadManager.shared.updateOfflinePlaybackProgress(
                    itemId: currentItem.id,
                    played: true,
                    positionSeconds: 0,
                    durationSeconds: duration,
                    persistDiskNow: true
                )
                if let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
                   session.episodesQueue.indices.contains(idx + 1) {
                    let nextEp = session.episodesQueue[idx + 1]
                    appState.showToast("正在自动连播下一集: \(nextEp.name)", icon: "forward.end.fill")
                    switchToEpisode(nextEp)
                    return
                }
            } else if pState == DK_STATE_ERROR && openingErrorMessage == nil {
                isPlaying = false
                openingErrorMessage = "媒体流读取中断或网络连接异常，请检查网络或更换线路"
                DonbyLogger.shared.log("播放内核报告流读取异常中断 (DK_STATE_ERROR)", level: .error, subsystem: "Player")
            }

            // Stall health check & auto-recovery
            let healthEval = healthPolicy.evaluate(
                now: Date().timeIntervalSinceReferenceDate,
                position: livePos,
                bufferedAhead: newBuffered,
                isPaused: !isPlaying,
                isOpening: isOpeningMedia,
                isEnded: didHandlePlaybackEnded,
                isScrubbing: isScrubbing,
                seekGeneration: seekGeneration
            )
            switch healthEval {
            case .none, .progressed:
                break
            case .recover:
                DonbyLogger.shared.log("触发播放卡顿自动恢复 at \(String(format: "%.1fs", livePos))", level: .warning, subsystem: "PlaybackHealth")
                appState.showToast("缓冲停滞，正在自动重连当前位置...", icon: "arrow.clockwise")
                startNativeKernelPlayback(startSeconds: livePos)
                return
            case .fail(let reason):
                isPlaying = false
                openingErrorMessage = "媒体流连续恢复失败，请尝试切换线路 (\(reason))"
                DonbyLogger.shared.log("播放健康检查终止: \(reason)", level: .error, subsystem: "PlaybackHealth")
                return
            }

            // Intro / outro chapter + per-season skip detector
            evaluateIntroOutroSkipWindow()
            prefetchNextEpisodeIfNearEnd()

            // Update watch history periodically (every 5s) to avoid UI frame drops
            if abs(livePos - lastRecordedPosition) >= 5.0 {
                lastRecordedPosition = livePos
                saveCurrentWatchProgress(isFinal: false)
            }
    }

    func startNativeKernelPlayback(startSeconds: Double) {
        stopNativeKernel()
        activePlaybackGeneration &+= 1
        let thisGeneration = activePlaybackGeneration
        isOpeningMedia = true
        hasRenderedFirstFrame = false
        isWaitingForSeekOrBuffer = false
        autoHideBox.lastObservedPos = -1.0
        autoHideBox.lastObservedPosUptime = ProcessInfo.processInfo.systemUptime
        autoHideBox.liveCurrentTime = max(0, startSeconds)
        autoHideBox.liveBufferedAheadSeconds = 0
        openingErrorMessage = nil
        didHandlePlaybackEnded = false
        finishedItemPendingCleanup = nil
        currentTime = max(0, startSeconds)
        duration = 1
        bufferedAheadSeconds = 0
        displayDownloadSpeedMBs = 0.0
        localExternalSubtitleName = nil
        secondaryLocalSubtitleName = nil
        activeSecondarySubtitleSelection = .off
        if appState.subtitleStyle.primaryDelaySeconds != 0 || appState.subtitleStyle.secondaryDelaySeconds != 0 {
            appState.subtitleStyle.primaryDelaySeconds = 0
            appState.subtitleStyle.secondaryDelaySeconds = 0
        }
        kernelChapters = []
        skipBannerLabel = nil
        didAutoSkipIntroForCurrentItem = false
        didAutoSkipOutroForCurrentItem = false
        prefetchedNextEpisodeResource = nil
        prefetchedNextEpisodeInFlightId = nil
        seekGeneration += 1
        healthPolicy.reset()

        let urlStr: String
        if currentResource.streamURL.isFileURL {
            urlStr = currentResource.streamURL.path
        } else if currentResource.streamURL.scheme == "file" {
            urlStr = currentResource.streamURL.path
        } else if let unescaped = currentResource.streamURL.absoluteString.removingPercentEncoding, unescaped.hasPrefix("file://") {
            urlStr = String(unescaped.dropFirst("file://".count))
        } else if currentResource.streamURL.absoluteString.hasPrefix("/") {
            urlStr = currentResource.streamURL.absoluteString
        } else {
            urlStr = currentResource.streamURL.absoluteString
        }
        let headersStr = currentResource.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let hwDecode = appState.enableHardwareDecode
        let cachePoolMB = Int32(appState.cachePoolSizeMB)
        let speed = playbackSpeed
        let vol = volume
        let muted = isMuted
        let audioIdx = selectedAudioIdx
        let subIdx = selectedSubIdx
        let isExplicitSubOff = explicitSubtitleOff
        let (preAudioHint, preSubHint, preExternalSub) = computePreOpenTrackHints(
            audioIdx: audioIdx,
            subIdx: subIdx,
            isExplicitSubOff: isExplicitSubOff
        )
        let reqHeadersForSub = currentResource.headers
        let openBox = OpeningPlayerBox()
        self.openingBox = openBox

        // Stop any background detail-page preload immediately so active playback owns full bandwidth
        // and inherits all already-preloaded chunks from the shared TieredAssetChunkStore.
        DonbyTurboCacheEngine.shared.cancelDetailPreload()

        // Prepare Turbo Multi-Connection Range Engine for remote HTTP(S) VOD streams
        let lowerURL = urlStr.lowercased()
        let isRemoteHTTPVOD = (lowerURL.hasPrefix("http://") || lowerURL.hasPrefix("https://"))
            && !lowerURL.contains(".m3u8")
            && !lowerURL.contains(".mpd")
        let preparedTurboHandle: TurboStreamByteHandle?
        if appState.turboEnabled && isRemoteHTTPVOD {
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
            let prefetchChunks = max(24, min(360, Int(appState.turboPrefetchSeconds * 1.2)))
            let redirectCallback: (@Sendable (URL) -> Void)? = enableRedirectCache
                ? Self.makeRedirectStoreHandler(key: redirectKey)
                : nil
            let originURL = currentResource.originStreamURL ?? currentResource.streamURL
            let cachedRedirectURL: URL? = (currentResource.originStreamURL != nil && currentResource.originStreamURL != currentResource.streamURL)
                ? currentResource.streamURL
                : nil
            preparedTurboHandle = TurboStreamByteHandle(
                assetKey: assetKey,
                streamURL: originURL,
                initialRedirectedURL: cachedRedirectURL,
                headers: currentResource.headers,
                store: store,
                knownTotalSize: currentResource.mediaSource.size,
                connectionBudget: budget,
                prefetchAheadChunks: prefetchChunks,
                onResolvedRedirectURL: redirectCallback
            )
        } else {
            preparedTurboHandle = nil
        }
        self.activeTurboHandle = preparedTurboHandle

        DonbyLogger.shared.log("启动原生播放内核 (URL: \(PlaybackDiagnosticsRedactor.redact(urlStr)), Turbo: \(preparedTurboHandle != nil))", level: .info, subsystem: "Player")

        Task.detached(priority: .userInitiated) {
            let prefetchedExtSubTask: Task<(url: URL, text: String, isAss: Bool)?, Never>? = preExternalSub.map { extItem in
                Task.detached(priority: .utility) {
                    var req = URLRequest(url: extItem.url, timeoutInterval: 15)
                    for (k, v) in reqHeadersForSub { req.setValue(v, forHTTPHeaderField: k) }
                    let ext = extItem.url.pathExtension.lowercased()
                    guard let (data, _) = try? await URLSession.shared.data(for: req),
                          let decoded = SubtitleTextDecoder.decode(data: data, fileExtension: ext) else {
                        return nil
                    }
                    let isAss = (ext == "ass" || ext == "ssa" || decoded.text.contains("[Script Info]"))
                    return (extItem.url, decoded.text, isAss)
                }
            }

            let handle = dk_player_create()
            guard let handle else {
                prefetchedExtSubTask?.cancel()
                preparedTurboHandle?.close()
                await MainActor.run {
                    if self.openingBox === openBox { self.openingBox = nil }
                    guard self.activePlaybackGeneration == thisGeneration else { return }
                    self.activeTurboHandle = nil
                    self.openingErrorMessage = "初始化原生播放内核失败"
                    self.isOpeningMedia = false
                }
                return
            }
            guard openBox.setHandle(handle) else {
                prefetchedExtSubTask?.cancel()
                preparedTurboHandle?.close()
                dk_player_destroy(handle)
                return
            }
            let styleSnap = await MainActor.run { appState.subtitleStyle }
            let initialAnchor = await MainActor.run { resolvedDualAnchorMode() }
            var initialSubCfg = Self.makeKernelSubtitleStyleConfig(styleSnap, anchorMode: initialAnchor)
            dk_player_set_subtitle_style(handle, &initialSubCfg)
            dk_player_set_buffer_limit_mb(handle, cachePoolMB)
            if let turboHandle = preparedTurboHandle {
                let handleAddr = UInt(bitPattern: handle)
                turboHandle.setShouldYieldReadHandler {
                    guard let ptr = OpaquePointer(bitPattern: handleAddr) else { return true }
                    return dk_player_should_yield_read(ptr)
                }
                let opaque = Unmanaged.passRetained(turboHandle).toOpaque()
                dk_player_set_custom_io(handle, opaque, dkTurboReadCB, dkTurboSeekCB, dkTurboAbortCB, dkTurboCloseCB)
            }
            let ret = dk_player_open_with_tracks(handle, urlStr, headersStr, startSeconds, hwDecode, preAudioHint, preSubHint)
            if ret == 0 {
                preparedTurboHandle?.markInitialOpenCompleted()
            } else {
                prefetchedExtSubTask?.cancel()
            }
            openBox.clear()
            let addr = UInt(bitPattern: handle)

            await MainActor.run {
                if self.openingBox === openBox { self.openingBox = nil }
                guard let validHandle = OpaquePointer(bitPattern: addr) else { return }
                guard self.activePlaybackGeneration == thisGeneration else {
                    Task.detached(priority: .userInitiated) {
                        dk_player_close(validHandle)
                        dk_player_destroy(validHandle)
                    }
                    return
                }
                if ret != 0 {
                    DonbyLogger.shared.log("内核打开视频流失败 (错误码: \(ret))", level: .error, subsystem: "Player")
                    self.activeTurboHandle = nil
                    self.openingErrorMessage = "解析流媒体格式失败 (错误码: \(ret))，请检查网络连接或更换线路"
                    self.isOpeningMedia = false
                    Task.detached(priority: .userInitiated) {
                        dk_player_destroy(validHandle)
                    }
                    return
                }

                self.playerHandle = validHandle
                self.isOpeningMedia = false

                dk_player_set_rate(validHandle, speed)
                dk_player_set_volume(validHandle, vol, muted)
                self.applyKernelSubtitleStyle()

                let discovered = Self.queryKernelTracks(handle: validHandle)
                self.kernelAudioTracks = discovered.audio
                self.kernelSubtitleTracks = discovered.subtitles
                self.kernelChapters = Self.queryKernelChapters(handle: validHandle)

                // Resolve initial audio track (mapping Emby MediaStream.index -> FFmpeg AVStream index via ordinal)
                let audioOpts = self.resolvedAudioOptions
                if let requestedEmbyAudio = audioIdx,
                   let matchedAudio = audioOpts.first(where: { $0.embyIndex == requestedEmbyAudio })
                       ?? audioOpts.first(where: { $0.avStreamIndex == requestedEmbyAudio }) {
                    self.activeAudioAVIndex = matchedAudio.avStreamIndex
                    if discovered.selectedAudioIndex != matchedAudio.avStreamIndex {
                        dk_player_select_track(validHandle, 1, Int32(matchedAudio.avStreamIndex))
                    }
                } else if let autoAudio = discovered.selectedAudioIndex {
                    self.activeAudioAVIndex = autoAudio
                }

                // Resolve initial subtitle track using explicit override -> per-item/series memory -> global preference -> smart default
                let subOpts = self.resolvedSubtitleOptions
                let candidates = subOpts.map(\.trackCandidate)
                if isExplicitSubOff {
                    self.activeSubtitleSelection = .off
                    if discovered.selectedSubIndex != nil {
                        dk_player_select_track(validHandle, 2, -1)
                    }
                } else if let requestedEmbySub = subIdx, requestedEmbySub >= 0 {
                    if let matchedOpt = subOpts.first(where: { $0.embyIndex == requestedEmbySub })
                        ?? subOpts.first(where: {
                            if case .embedded(let avIdx) = $0.selection { return avIdx == requestedEmbySub }
                            return false
                        }) {
                        self.applySubtitleOptionOnStartup(matchedOpt, handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex, generation: thisGeneration, prefetchedExternalTask: prefetchedExtSubTask)
                    } else if let autoSub = discovered.selectedSubIndex {
                        self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                    }
                } else if let remembered = self.appState.resolvedPrimarySubtitleMemory(serverId: self.session.server.id, item: self.currentItem) {
                    if remembered.isDisabled {
                        self.activeSubtitleSelection = .off
                        if discovered.selectedSubIndex != nil {
                            dk_player_select_track(validHandle, 2, -1)
                        }
                    } else if let localPath = remembered.localFilePath,
                              FileManager.default.fileExists(atPath: localPath) {
                        self.loadLocalExternalSubtitleURL(
                            URL(fileURLWithPath: localPath),
                            asSecondary: false,
                            silentToast: true,
                            persist: false
                        )
                    } else if let matchedIdx = SubtitleTrackMatcher.bestMatchIndex(in: candidates, for: remembered) {
                        self.applySubtitleOptionOnStartup(subOpts[matchedIdx], handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex, generation: thisGeneration, prefetchedExternalTask: prefetchedExtSubTask)
                    } else if let autoSub = discovered.selectedSubIndex {
                        self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                    } else if let fallbackIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: candidates) {
                        self.applySubtitleOptionOnStartup(subOpts[fallbackIdx], handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex, generation: thisGeneration, prefetchedExternalTask: prefetchedExtSubTask)
                    } else {
                        self.activeSubtitleSelection = .off
                    }
                } else if let autoSub = discovered.selectedSubIndex {
                    self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                } else if let fallbackIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: candidates) {
                    self.applySubtitleOptionOnStartup(subOpts[fallbackIdx], handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex, generation: thisGeneration, prefetchedExternalTask: prefetchedExtSubTask)
                } else {
                    self.activeSubtitleSelection = .off
                }

                // Restore secondary bilingual subtitle if remembered
                if let rememberedSecondary = self.appState.resolvedSecondarySubtitleMemory(serverId: self.session.server.id, item: self.currentItem),
                   !rememberedSecondary.isDisabled {
                    if let localPath = rememberedSecondary.localFilePath,
                       FileManager.default.fileExists(atPath: localPath) {
                        self.loadLocalExternalSubtitleURL(
                            URL(fileURLWithPath: localPath),
                            asSecondary: true,
                            silentToast: true,
                            persist: false
                        )
                    } else if let secIdx = SubtitleTrackMatcher.bestMatchIndex(in: candidates, for: rememberedSecondary) {
                        let secOpt = subOpts[secIdx]
                        switch secOpt.selection {
                        case .embedded(let avIdx):
                            self.secondaryLocalSubtitleName = nil
                            self.activeSecondarySubtitleSelection = .embedded(avStreamIndex: avIdx)
                            dk_player_select_secondary_subtitle_track(validHandle, Int32(avIdx))
                        case .remoteExternal:
                            if let ext = secOpt.externalItem {
                                self.loadRemoteExternalSubtitle(item: ext, embyStreamIndex: secOpt.embyIndex, silentToast: true, asSecondary: true)
                            }
                        case .off, .localExternal:
                            break
                        }
                    }
                } else {
                    self.activeSecondarySubtitleSelection = .off
                }
                self.applyKernelSubtitleStyle()
                self.isPlaying = true
                DonbyLogger.shared.log("原生播放器配置就绪，画面启动渲染 (章节: \(self.kernelChapters.count))", level: .info, subsystem: "Player")
            }
        }

        guard !session.server.host.isEmpty && !session.server.accessToken.isEmpty else { return }
        let srv = session.server
        let itm = currentItem
        let msId = currentResource.mediaSource.id
        let psId = currentResource.playSessionId
        Task {
            if let ext = DonbyMediaServiceRegistry.shared.provider(for: srv.type) {
                await ext.reportPlayback(server: srv, kind: .progress, item: itm, assetId: msId, positionSeconds: startSeconds)
            } else {
                await EmbyClient.shared.reportPlaybackStart(
                    server: srv,
                    itemId: itm.id,
                    mediaSourceId: msId,
                    playSessionId: psId,
                    positionSeconds: startSeconds
                )
            }
        }
    }

    private func computePreOpenTrackHints(
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

    private nonisolated static func makeRedirectStoreHandler(key: String) -> @Sendable (URL) -> Void {
        { finalURL in
            Task {
                await RedirectCacheStore.shared.storeRedirect(finalURL, for: key)
            }
        }
    }

    func stopNativeKernel() {
        activePlaybackGeneration &+= 1
        let activeHandle = playerHandle
        self.playerHandle = nil
        if let activeHandle {
            dk_player_request_abort(activeHandle)
        }
        openingBox?.abort()
        openingBox = nil
        let turboToClose = activeTurboHandle
        self.activeTurboHandle = nil
        turboToClose?.abort()
        episodeSwitchTask?.cancel()
        episodeSwitchTask = nil
        displayDownloadSpeedMBs = 0.0
        bufferedAheadSeconds = 0
        skipBannerLabel = nil
        isAutoAligningSubtitle = false
        lastAutoAlignSummary = nil
        lastSubtitleAlignUndo = nil
        secondarySubtitleTimeScale = 1.0
        isSecondaryAlignedToPrimary = false
        guard activeHandle != nil || turboToClose != nil else { return }
        Task.detached(priority: .userInitiated) {
            if let handle = activeHandle {
                dk_player_close(handle)
                dk_player_destroy(handle)
            }
            // Close off MainActor in case flushMeta / store locks contend with disk I/O
            turboToClose?.close()
        }
    }

    func togglePlayPause() {
        guard let handle = playerHandle else { return }
        if dk_player_get_state(handle) == DK_STATE_ENDED {
            didHandlePlaybackEnded = false
            finishedItemPendingCleanup = nil
            autoHideBox.liveCurrentTime = 0
            currentTime = 0
            dk_player_seek(handle, 0, true)
            dk_player_play(handle)
            isPlaying = true
            return
        }
        if isPlaying {
            dk_player_pause(handle)
            isPlaying = false
            saveCurrentWatchProgress(isFinal: false)
            appState.flushWatchHistory()
        } else {
            dk_player_play(handle)
            isPlaying = true
        }
        companionBox.companion?.onLocalPlayPauseChanged(
            isPlaying: isPlaying,
            livePos: autoHideBox.liveCurrentTime,
            playbackSpeed: playbackSpeed
        )
    }

    func seekRelative(_ delta: Double) {
        let target = max(0, min(duration, autoHideBox.liveCurrentTime + delta))
        seekTo(target)
    }

    func seekTo(_ seconds: Double, accurate: Bool = false) {
        didHandlePlaybackEnded = false
        seekGeneration += 1
        lastSeekCommitUptime = ProcessInfo.processInfo.systemUptime
        lastSeekCommitTarget = seconds
        autoHideBox.lastObservedPos = seconds
        autoHideBox.lastObservedPosUptime = lastSeekCommitUptime
        autoHideBox.liveCurrentTime = seconds
        currentTime = seconds
        if let handle = playerHandle {
            dk_player_seek(handle, seconds, accurate)
            activeTurboHandle?.wakeWaitingReads()
        }
        companionBox.companion?.onLocalSeek(seconds: seconds, isPlaying: isPlaying, playbackSpeed: playbackSpeed)
    }

    static func queryKernelChapters(handle: OpaquePointer) -> [PlaybackChapterItem] {
        let count = dk_player_get_chapter_count(handle)
        guard count > 0 else { return [] }
        var chapters: [PlaybackChapterItem] = []
        chapters.reserveCapacity(Int(count))
        for ord in 0..<count {
            var info = DKChapterInfo()
            if dk_player_get_chapter_info(handle, ord, &info) {
                chapters.append(PlaybackChapterItem(
                    id: Int(info.index),
                    startSeconds: info.start_sec,
                    endSeconds: info.end_sec,
                    title: cString(from: info.title)
                ))
            }
        }
        return chapters
    }

    static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            var length = 0
            while length < raw.count && base[length] != 0 {
                length += 1
            }
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
}
}

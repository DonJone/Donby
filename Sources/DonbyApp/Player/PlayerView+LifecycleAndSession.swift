import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

extension PlayerView {
    func handleEmbySyncTimerTick() {
        guard !isOpeningMedia, openingErrorMessage == nil, playerHandle != nil, !didHandlePlaybackEnded else { return }
        let srv = resolvedServer
        guard !srv.host.isEmpty && !srv.accessToken.isEmpty else { return }
        let livePos = autoHideBox.liveCurrentTime
        let itm = currentItem
        let assetId = currentResource.mediaSource.id
        let playSessionId = currentResource.playSessionId
        let paused = !isPlaying
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: srv.type) {
            Task {
                await ext.reportPlayback(server: srv, kind: .progress, item: itm, assetId: assetId, positionSeconds: livePos)
            }
        } else {
            Task {
                await EmbyClient.shared.reportPlaybackProgress(
                    server: srv,
                    itemId: itm.id,
                    mediaSourceId: assetId,
                    playSessionId: playSessionId,
                    positionSeconds: livePos,
                    isPaused: paused
                )
            }
        }
    }

    func prefetchNextEpisodeIfNearEnd() {
        let livePos = autoHideBox.liveCurrentTime
        let dur = telemetryBox.duration
        guard dur > 90, livePos >= max(dur * 0.72, dur - 120) else { return }
        guard let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
              session.episodesQueue.indices.contains(idx + 1) else {
            return
        }
        let nextEp = session.episodesQueue[idx + 1]
        let server = resolvedServer
        if DonbyDownloadManager.shared.completedEntry(for: nextEp.id, serverId: server.id) != nil {
            return
        }
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // If control-plane resource is already resolved, opportunistically micro-stage Head + Cues + Intro-Skip landing
        // once current playback buffer has >= 12s cushion so episode handoff starts in <150ms.
        if let ready = prefetchedNextEpisodeResource, ready.itemId == nextEp.id {
            guard appState.turboEnabled,
                  autoHideBox.liveBufferedAheadSeconds >= 12.0,
                  !isWaitingForSeekOrBuffer else { return }
            let res = ready.resource
            let urlLower = res.streamURL.absoluteString.lowercased()
            guard (urlLower.hasPrefix("http://") || urlLower.hasPrefix("https://")),
                  !urlLower.contains(".m3u8"),
                  !urlLower.contains(".mpd") else { return }
            let nextAssetKey = DonbyTurboCacheEngine.makeAssetKey(
                serverId: server.id,
                itemId: nextEp.id,
                mediaSourceId: res.mediaSource.id
            )
            let memoryCap = max(64, appState.turboMemoryCacheMB) * 1024 * 1024
            let nextStore = DonbyTurboCacheEngine.shared.store(for: nextAssetKey, maxMemoryBytes: memoryCap, persistDisk: true)
            guard !nextStore.hasChunk(0) else { return }

            let nextPref = appState.effectiveSkipPreference(serverId: server.id, item: nextEp)
            let nextStartSec: Double = {
                if nextEp.resumePositionSeconds > 0.5 { return nextEp.resumePositionSeconds }
                if nextPref.introEnabled && nextPref.mode == .automatic && nextPref.introSeconds > 5 {
                    return nextPref.introSeconds
                }
                return 0.0
            }()
            let redirectKey = EmbyClient.redirectCacheKey(
                serverId: server.id,
                itemId: nextEp.id,
                mediaSourceId: res.mediaSource.id,
                baseURL: server.activeBaseURL
            )
            let originURL = res.originStreamURL ?? res.streamURL
            let cachedRedirect: URL? = (res.originStreamURL != nil && res.originStreamURL != res.streamURL)
                ? res.streamURL
                : NetworkRouteWarmStore.shared.cachedRedirect(for: redirectKey)
            let nextDuration = Double(nextEp.runTimeTicks ?? res.mediaSource.runTimeTicks ?? 0) / 10_000_000.0
            let shouldSave302 = appState.enable302Cache && server.cache302Request

            DonbyTurboCacheEngine.shared.startMicroStagePreload(
                assetKey: nextAssetKey,
                streamURL: originURL,
                cachedRedirectURL: cachedRedirect,
                headers: res.headers,
                knownTotalSize: res.mediaSource.size,
                durationSeconds: nextDuration,
                startPositionSeconds: nextStartSec,
                maxMemoryBytes: memoryCap,
                onResolvedRedirectURL: shouldSave302 ? Self.makeRedirectStoreHandler(key: redirectKey) : nil
            )
            return
        }

        if prefetchedNextEpisodeInFlightId == nextEp.id {
            return
        }
        let preset = appState.preferredVersionPreset
        let audioIdx = selectedAudioIdx
        let enable302 = appState.enable302Cache
        let defer302 = appState.turboEnabled
        prefetchedNextEpisodeInFlightId = nextEp.id

        Task {
            let resolved = try? await PlaybackIntentCoordinator.shared.resolveAndCacheResource(
                server: server,
                item: nextEp,
                preferredPreset: preset,
                audioStreamIndex: audioIdx,
                subtitleStreamIndex: nil,
                enable302Cache: enable302,
                defer302ProbeWhenTurbo: defer302
            )
            await MainActor.run {
                if self.prefetchedNextEpisodeInFlightId == nextEp.id {
                    self.prefetchedNextEpisodeInFlightId = nil
                }
                if let resolved {
                    self.prefetchedNextEpisodeResource = (itemId: nextEp.id, resource: resolved)
                }
            }
        }
    }

    func evaluateIntroOutroSkipWindow() {
        let dur = telemetryBox.duration
        guard dur > 60 else {
            skipBannerLabel = nil
            return
        }
        let pref = appState.effectiveSkipPreference(serverId: resolvedServer.id, item: currentItem)
        let chapterIntroEnd = pref.chapterDetection
            ? ChapterSkipDetector.detectIntroEndSeconds(chapters: kernelChapters, duration: dur)
            : nil
        let chapterOutroStart = pref.chapterDetection
            ? ChapterSkipDetector.detectOutroStartSeconds(chapters: kernelChapters, duration: dur)
            : nil

        let introEnd: Double? = {
            guard pref.introEnabled else { return nil }
            if pref.hasUserMarkedIntro { return pref.introSeconds > 5 ? pref.introSeconds : nil }
            if let ch = chapterIntroEnd { return ch }
            return pref.introSeconds > 5 ? pref.introSeconds : nil
        }()

        let outroStart: Double? = {
            guard pref.outroEnabled else { return nil }
            if pref.hasUserMarkedOutro && pref.outroSeconds > 5 { return max(60, dur - pref.outroSeconds) }
            if let ch = chapterOutroStart { return ch }
            return pref.outroSeconds > 5 ? max(60, dur - pref.outroSeconds) : nil
        }()

        let hasNextEp: Bool = {
            if let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }) {
                return session.episodesQueue.indices.contains(idx + 1)
            }
            return false
        }()

        let livePos = autoHideBox.liveCurrentTime
        if let introEnd, livePos >= 1.5, livePos < introEnd - 1.5 {
            if pref.mode == .automatic && !didAutoSkipIntroForCurrentItem && currentItemStartPositionSeconds < introEnd {
                didAutoSkipIntroForCurrentItem = true
                seekTo(introEnd)
                appState.showToast("已自动跳过片头 (\(formatTime(introEnd)))", icon: "forward.fill")
                skipBannerLabel = nil
                return
            }
            if skipBannerIsOutro || skipBannerLabel != "跳过片头" {
                skipBannerLabel = "跳过片头"
                skipBannerTargetSec = introEnd
                skipBannerIsOutro = false
            }
            return
        }

        if let outroStart, livePos >= outroStart, livePos < dur - 2.0, hasNextEp {
            if pref.mode == .automatic && appState.autoNextEpisode && !didAutoSkipOutroForCurrentItem {
                didAutoSkipOutroForCurrentItem = true
                if let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
                   session.episodesQueue.indices.contains(idx + 1) {
                    let nextEp = session.episodesQueue[idx + 1]
                    appState.showToast("片尾自动连播下一集: \(nextEp.name)", icon: "forward.end.fill")
                    switchToEpisode(nextEp)
                }
                skipBannerLabel = nil
                return
            }
            if !skipBannerIsOutro || skipBannerLabel != "跳过片尾 · 下一集" {
                skipBannerLabel = "跳过片尾 · 下一集"
                skipBannerTargetSec = dur
                skipBannerIsOutro = true
            }
            return
        }

        if skipBannerLabel != nil {
            skipBannerLabel = nil
        }
    }

    private static let diagnosticsDateFormatter = ISO8601DateFormatter()

    func exportRedactedDiagnostics() {
        let appVer = DonbyAppInfo.version
        let stats = telemetryBox.kernelStats
        var lines: [String] = []
        lines.append("Donby Diagnostics Report (v\(appVer))")
        lines.append("Time: \(Self.diagnosticsDateFormatter.string(from: Date()))")
        let srv = resolvedServer
        lines.append("Server Type: \(srv.type.rawValue) | Line: \(srv.activeLineName)")
        lines.append("Item: \(currentItem.name) | Route: \(currentResource.routeNote)")
        lines.append("Stream URL: \(currentResource.streamURL.absoluteString)")
        lines.append("Decoder: \(stats.is_hw_accelerated ? "VideoToolbox HW" : "Software") | \(stats.width)x\(stats.height) @ \(String(format: "%.3f", stats.fps))fps")
        lines.append("HDR: DoVi=\(stats.is_dolby_vision) HDR=\(stats.is_hdr) | Codec: \(Self.cString(from: stats.video_codec)) / \(Self.cString(from: stats.audio_codec))")
        lines.append("Position: \(String(format: "%.2f", autoHideBox.liveCurrentTime)) / \(String(format: "%.2f", telemetryBox.duration)) | BufferedAhead: \(String(format: "%.2f", autoHideBox.liveBufferedAheadSeconds))s | Turbo: \(activeTurboHandle != nil)")
        lines.append("Recent Logs:")
        let allLogs = DonbyLogger.shared.exportAllText().components(separatedBy: .newlines).suffix(80)
        lines.append(contentsOf: allLogs)

        let redacted = PlaybackDiagnosticsRedactor.redact(lines.joined(separator: "\n"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redacted, forType: .string)
        appState.showToast("已复制脱敏诊断报告到剪贴板", icon: "checkmark.shield.fill")
    }

    func playAdjacentEpisode(offset: Int) {
        guard let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let targetIdx = idx + offset
        guard session.episodesQueue.indices.contains(targetIdx) else {
            appState.showToast(offset > 0 ? "已经是最后一集" : "已经是第一集", icon: "info.circle")
            return
        }
        switchToEpisode(session.episodesQueue[targetIdx])
    }

    private func isCurrentPlaybackConsideredFinished() -> Bool {
        if didHandlePlaybackEnded || didAutoSkipOutroForCurrentItem { return true }
        if let pending = finishedItemPendingCleanup, pending.itemId == currentItem.id { return true }
        let dur = telemetryBox.duration
        let pos = autoHideBox.liveCurrentTime
        return dur > 60 && pos > 0 && (pos / dur) >= 0.92
    }

    func switchToEpisode(_ nextEp: EmbyItem) {
        episodeSwitchTask?.cancel()
        let server = resolvedServer
        let preset = appState.preferredVersionPreset
        let audioIdx = selectedAudioIdx
        let enable302 = appState.enable302Cache
        let prevItem = currentItem
        let prevSourceId = currentResource.mediaSource.id
        let prevSessionId = currentResource.playSessionId
        let prevPos = autoHideBox.liveCurrentTime
        let prevWasFinished = isCurrentPlaybackConsideredFinished()
        finishedItemPendingCleanup = nil
        saveCurrentWatchProgress(isFinal: true)

        func commitEpisodeSwitch(with res: ResolvedPlaybackResource) {
            if !server.host.isEmpty && !server.accessToken.isEmpty {
                Task {
                    if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                        await ext.reportPlayback(server: server, kind: .stopped, item: prevItem, assetId: prevSourceId, positionSeconds: prevPos)
                    } else {
                        await EmbyClient.shared.reportPlaybackStopped(
                            server: server,
                            itemId: prevItem.id,
                            mediaSourceId: prevSourceId,
                            playSessionId: prevSessionId,
                            positionSeconds: prevPos
                        )
                    }
                }
            }
            episodeSwitchTask = nil
            explicitSubtitleOff = false
            selectedSubIdx = nil
            currentItem = nextEp
            currentResource = res
            currentItemStartPositionSeconds = nextEp.resumePositionSeconds
            appState.updateDetailFocusedEpisodeIfActive(forItem: nextEp)
            companionBox.companion?.onLocalEpisodeSwitched(
                assetId: res.mediaSource.id,
                positionSeconds: nextEp.resumePositionSeconds,
                playbackSpeed: playbackSpeed
            )
            startNativeKernelPlayback(startSeconds: nextEp.resumePositionSeconds)
            if prevWasFinished {
                appState.cleanupAutoArchivedEntryIfFinished(itemId: prevItem.id, mediaSourceId: prevSourceId)
            }
        }

        // Synchronous 0ms fast-cut when next episode is already prefetched, offline, or in PlaybackIntentCoordinator
        if let cachedNext = prefetchedNextEpisodeResource, cachedNext.itemId == nextEp.id {
            let upgraded = PlaybackIntentCoordinator.shared.cachedResolvedResource(
                server: server,
                itemId: nextEp.id,
                preferredSourceId: cachedNext.resource.mediaSource.id,
                preferredPreset: preset,
                enable302Cache: enable302 && server.cache302Request
            ) ?? cachedNext.resource
            commitEpisodeSwitch(with: upgraded)
            return
        }
        if let offlineEntry = DonbyDownloadManager.shared.completedEntry(
            for: nextEp.id,
            serverId: server.id
        ) ?? DonbyDownloadManager.shared.completedEntry(for: nextEp.id),
           let offlineRes = DonbyDownloadManager.shared.offlinePlayableResource(for: offlineEntry) {
            commitEpisodeSwitch(with: offlineRes)
            return
        }
        if let fastRes = PlaybackIntentCoordinator.shared.cachedResolvedResource(
            server: server,
            itemId: nextEp.id,
            preferredPreset: preset,
            enable302Cache: enable302 && server.cache302Request
        ), fastRes.isDirectStream {
            commitEpisodeSwitch(with: fastRes)
            return
        }

        episodeSwitchTask = Task {
            do {
                let res = try await PlaybackIntentCoordinator.shared.resolveAndCacheResource(
                    server: server,
                    item: nextEp,
                    preferredPreset: preset,
                    audioStreamIndex: audioIdx,
                    subtitleStreamIndex: nil,
                    enable302Cache: enable302,
                    defer302ProbeWhenTurbo: appState.turboEnabled
                )
                guard !Task.isCancelled else { return }
                commitEpisodeSwitch(with: res)
            } catch {
                guard !Task.isCancelled else { return }
                episodeSwitchTask = nil
                appState.showToast("切换剧集失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    func toggleFullScreen() { (autoHideBox.hostWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil) }

    func exitPlayer() {
        autoHideBox.autoHideTask?.cancel()
        autoHideBox.lineReloadTask?.cancel()
        autoHideBox.lineReloadTask = nil
        autoHideBox.coalescedSeekTask?.cancel()
        autoHideBox.coalescedSeekTask = nil
        if let mm = mouseMonitor { NSEvent.removeMonitor(mm); mouseMonitor = nil }
        if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }

        let exitingItemId = currentItem.id
        let exitingSourceId = currentResource.mediaSource.id
        let wasOpenedSuccessfully = (!isOpeningMedia && openingErrorMessage == nil && playerHandle != nil)
        let exitingWasFinished = wasOpenedSuccessfully && isCurrentPlaybackConsideredFinished()
        finishedItemPendingCleanup = nil

        if wasOpenedSuccessfully {
            saveCurrentWatchProgress(isFinal: true)

            let srv = resolvedServer
            if !srv.host.isEmpty && !srv.accessToken.isEmpty {
                let itm = currentItem
                let msId = currentResource.mediaSource.id
                let psId = currentResource.playSessionId
                let pos = autoHideBox.liveCurrentTime
                Task {
                    if let ext = DonbyMediaServiceRegistry.shared.provider(for: srv.type) {
                        await ext.reportPlayback(server: srv, kind: .stopped, item: itm, assetId: msId, positionSeconds: pos)
                    } else {
                        await EmbyClient.shared.reportPlaybackStopped(
                            server: srv,
                            itemId: itm.id,
                            mediaSourceId: msId,
                            playSessionId: psId,
                            positionSeconds: pos
                        )
                    }
                }
            }
        }

        appState.updateDetailFocusedEpisodeIfActive(forItem: currentItem)
        companionBox.companion?.onPlayerClose()
        stopNativeKernel()
        if exitingWasFinished {
            appState.cleanupAutoArchivedEntryIfFinished(itemId: exitingItemId, mediaSourceId: exitingSourceId)
        }
        appState.activePlayback = nil
    }

    // MARK: - Optional UHD Watch Party & Danmu Extension Hooks

    @ViewBuilder
    var watchPartyDrawerContent: some View {
        if let companion = companionBox.companion {
            companion.makeDrawerContent(accentTint: drawerSelectedAccentTint())
        }
    }

    func configureAndBindCompanionIfNeeded() {
        companionBox.configureIfNeeded(server: resolvedServer, appState: appState)
        guard let companion = companionBox.companion else { return }
        companion.bindDriver(
            pauseAndGetPosition: {
                guard let handle = playerHandle else { return autoHideBox.liveCurrentTime }
                dk_player_pause(handle)
                isPlaying = false
                let exactPos = dk_player_get_position(handle)
                autoHideBox.liveCurrentTime = exactPos
                telemetryBox.updateCurrentTime(exactPos, force: true, syncLegacy: activeDrawer == .mediaInfo)
                return exactPos
            },
            play: {
                if let handle = playerHandle {
                    autoHideBox.lastObservedPos = dk_player_get_position(handle)
                    autoHideBox.lastObservedPosUptime = ProcessInfo.processInfo.systemUptime
                    isWaitingForSeekOrBuffer = false
                    dk_player_play(handle)
                    isPlaying = true
                }
            },
            pause: {
                if let handle = playerHandle {
                    dk_player_pause(handle)
                    isPlaying = false
                }
            },
            seekAccurate: { sec in
                seekTo(sec, accurate: true)
            },
            setRate: { rate in
                playbackSpeed = rate
                if let handle = playerHandle {
                    dk_player_set_rate(handle, rate)
                }
            },
            switchMedia: { item, res, startSec in
                currentItem = item
                currentResource = res
                currentItemStartPositionSeconds = startSec
                startNativeKernelPlayback(startSeconds: startSec)
            },
            snapshot: {
                DonbyPlayerStateSnapshot(
                    isPlaying: isPlaying,
                    hasRenderedFirstFrame: hasRenderedFirstFrame,
                    isOpeningMedia: isOpeningMedia,
                    playbackSpeed: playbackSpeed,
                    liveCurrentTime: autoHideBox.liveCurrentTime,
                    currentMediaSourceId: currentResource.mediaSource.id
                )
            }
        )
        companion.onAppear()
    }

    func saveCurrentWatchProgress(isFinal: Bool = false) {
        let livePos = autoHideBox.liveCurrentTime
        let dur = telemetryBox.duration
        guard dur > 0 || livePos > 0 else { return }

        let isLocal = currentResource.streamURL.isFileURL ||
                      currentResource.streamURL.scheme == "file" ||
                      currentResource.streamURL.path.hasPrefix("/")
        let srv = resolvedServer
        let isEmby = !isLocal && !srv.host.isEmpty && srv.host != "127.0.0.1" && srv.host != "local"

        // Capture stop frame / current video snapshot for local files
        if isLocal {
            let localPath = currentResource.streamURL.path
            let thumbKey = "local_frame_\(localPath)"
            let shouldCapture = isFinal || ArtworkImageCache.shared.imageFromMemory(for: thumbKey) == nil
            if shouldCapture, let input = DKMetalLayerView.activeInstance?.currentFrameSnapshotInput() {
                Task.detached(priority: .utility) {
                    if let cgImg = DKMetalLayerView.renderOffscreenCGImage(
                        pixelBuffer: input.pixelBuffer,
                        colorUniforms: input.colorUniforms,
                        edrHeadroom: input.edrHeadroom,
                        maxDimension: 480
                    ) {
                        let snapshot = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                        ArtworkImageCache.shared.store(
                            snapshot,
                            for: thumbKey,
                            aliases: ["record_thumb_local:\(localPath)_", "local:\(localPath)"]
                        )
                    }
                }
            }
        }

        let recTitle: String
        let recSubtitle: String?

        if isLocal {
            let localPath = currentResource.streamURL.path
            let parsed = MediaTitleParser.parse(rawName: localPath.components(separatedBy: "/").last ?? currentItem.name)
            recTitle = parsed.mainTitle
            recSubtitle = parsed.subTitle
        } else {
            let meta = appState.formattedWatchRecordMetadata(for: currentItem)
            recTitle = meta.title
            recSubtitle = meta.subtitle
        }

        let resolvedSourceType = isLocal ? "本地文件" : (isEmby ? "Emby" : "网络直链")
        let streamStr = isLocal ? currentResource.streamURL.path : currentResource.streamURL.absoluteString
        let embyId = isLocal ? nil : (isEmby ? currentItem.id : nil)

        appState.recordWatch(
            title: recTitle,
            subtitle: recSubtitle,
            posterKey: isLocal ? "local_frame_\(streamStr)" : nil,
            posterURL: isEmby ? EmbyClient.shared.imageURL(server: srv, item: currentItem, kind: .primary, maxWidth: 320)?.absoluteString : nil,
            position: livePos,
            duration: dur > 0 ? dur : 3600,
            sourceType: resolvedSourceType,
            streamURLString: streamStr,
            embyItemId: embyId,
            resolutionTag: isLocal ? (telemetryBox.kernelStats.is_hw_accelerated ? "本地 4K" : "本地文件") : (telemetryBox.kernelStats.is_hw_accelerated ? "HW 4K" : "4K UHD"),
            mediaType: isEmby ? currentItem.type : nil,
            seriesId: isEmby ? currentItem.seriesId : nil
        )

        DonbyDownloadManager.shared.updateOfflinePlaybackProgress(
            itemId: currentItem.id,
            played: nil,
            positionSeconds: livePos,
            durationSeconds: dur,
            persistDiskNow: isFinal
        )

        if isFinal {
            appState.flushWatchHistory()
        }
    }

    func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec >= 0 else { return "00:00" }
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

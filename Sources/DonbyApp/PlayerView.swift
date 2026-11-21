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

public struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    public let session: ActivePlaybackSession

    @State private var playerHandle: OpaquePointer? = nil
    @State private var openingBox: OpeningPlayerBox? = nil
    @State private var episodeSwitchTask: Task<Void, Never>? = nil
    @State private var currentItem: EmbyItem
    @State private var currentResource: DonbyCore.ResolvedPlaybackResource
    @State private var isPlaying: Bool = true
    @State private var currentTime: Double = 0
    @State private var bufferedAheadSeconds: Double = 0
    @State private var duration: Double = 1
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var volume: Float = 1.0
    @State private var isMuted: Bool = false
    @State private var playbackSpeed: Float = 1.0
    @State private var showRemainingTime: Bool = false
    @State private var showControls: Bool = true
    @State private var isOpeningMedia: Bool = true
    @State private var hasRenderedFirstFrame: Bool = false
    @State private var isWaitingForSeekOrBuffer: Bool = false
    @State private var openingErrorMessage: String? = nil
    @State private var showLogSheet: Bool = false
    @State private var activeDrawer: PlayerDrawerTab? = nil
    @State private var selectedAudioIdx: Int?
    @State private var selectedSubIdx: Int?
    @State private var activeAudioAVIndex: Int? = nil
    @State private var activeSubtitleSelection: PlayerSubtitleSelection = .off
    @State private var localExternalSubtitleName: String? = nil
    @State private var kernelAudioTracks: [MediaStream] = []
    @State private var kernelSubtitleTracks: [MediaStream] = []
    @State private var didHandlePlaybackEnded: Bool = false
    @State private var systemClockString: String = ""
    @State private var kernelStats = DKRuntimeStats()
    @State private var autoHideBox = PlayerAutoHideBox()
    @State private var mouseMonitor: Any? = nil
    @State private var keyMonitor: Any? = nil
    @State private var lastRecordedPosition: Double = -10
    @State private var activePlaybackGeneration: Int = 0
    @State private var displayDownloadSpeedMBs: Double = 0.0
    @State private var bottomControlBarHeight: CGFloat = 96
    @State private var activeTurboHandle: TurboStreamByteHandle? = nil
    @State private var activeSecondarySubtitleSelection: PlayerSubtitleSelection = .off
    @State private var secondaryLocalSubtitleName: String? = nil
    @State private var explicitSubtitleOff: Bool = false
    @State private var kernelChapters: [PlaybackChapterItem] = []
    @State private var healthPolicy = PlaybackHealthPolicy()
    @State private var seekGeneration: Int = 0
    @State private var lastSeekCommitUptime: TimeInterval = 0
    @State private var lastSeekCommitTarget: Double = 0
    @State private var skipBannerLabel: String? = nil
    @State private var skipBannerTargetSec: Double = 0
    @State private var skipBannerIsOutro: Bool = false
    @State private var didAutoSkipIntroForCurrentItem: Bool = false
    @State private var didAutoSkipOutroForCurrentItem: Bool = false
    @State private var finishedItemPendingCleanup: (itemId: String, mediaSourceId: String)? = nil
    @State private var prefetchedNextEpisodeResource: (itemId: String, resource: ResolvedPlaybackResource)? = nil
    @State private var prefetchedNextEpisodeInFlightId: String? = nil
    @State private var subtitleStyleRevision: Int = 0
    @State private var isAdjustingSubtitleLayout: Bool = false
    @State private var showMoreSubtitleOptions: Bool = false
    @State private var tracksDrawerSection: TracksDrawerSection = .tracks
    @State private var isAutoAligningSubtitle: Bool = false
    @State private var lastAutoAlignSummary: String? = nil
    @State private var lastSubtitleAlignUndo: SubtitleAlignUndoState? = nil
    @State private var secondarySubtitleTimeScale: Double = 1.0
    @State private var isSecondaryAlignedToPrimary: Bool = false

    private enum TracksDrawerSection: String, CaseIterable, Identifiable {
        case tracks = "轨道"
        case style = "样式与对齐"
        var id: String { rawValue }
    }

    private struct SubtitleAlignUndoState {
        let primaryDelay: Double
        let secondaryDelay: Double
        let secondaryTimeScale: Double
        let wasSecondaryAligned: Bool
        let label: String
    }

    // Use `.default` RunLoop mode so timers automatically pause during macOS NSMenu `.eventTracking`,
    // preventing 0.25s body re-evaluations from flickering open subtitle/audio/speed dropdown menus.
    private let progressTimer = Timer.publish(every: 0.25, on: .main, in: .default).autoconnect()
    private let embySyncTimer = Timer.publish(every: 10.0, on: .main, in: .default).autoconnect()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let snapshotDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    public init(session: ActivePlaybackSession) {
        self.session = session
        self._currentItem = State(initialValue: session.item)
        self._currentResource = State(initialValue: session.resource)
        self._selectedAudioIdx = State(initialValue: session.selectedAudioIndex)
        self._selectedSubIdx = State(initialValue: session.selectedSubtitleIndex)
        self._explicitSubtitleOff = State(initialValue: session.subtitleExplicitlyOff)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // C++ / Metal Native Engine Video Surface
            DKMetalVideoView(
                playerHandle: playerHandle,
                controlsOcclusionHeight: (isPlaying && showControls && !isAdjustingSubtitleLayout && activeDrawer == nil) ? bottomControlBarHeight : 0,
                subtitleHDRPeakNits: Float(appState.subtitleStyle.hdrPeakNits.rawValue),
                antiOcclusionEnabled: appState.subtitleStyle.antiOcclusionEnabled,
                subtitleStyleRevision: subtitleStyleRevision,
                onFirstFrameRendered: {
                    if !hasRenderedFirstFrame {
                        withAnimation(.easeOut(duration: 0.16)) {
                            hasRenderedFirstFrame = true
                        }
                    }
                }
            )
                .ignoresSafeArea()
                .onContinuousHover { _ in
                    showControlsAndResetTimer()
                }
                .onTapGesture(count: 2) {
                    toggleFullScreen()
                    showControlsAndResetTimer()
                }
                .onTapGesture(count: 1) {
                    if activeDrawer != nil {
                        withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = nil }
                    } else {
                        if !showControls {
                            syncVisiblePlaybackStateFromBox()
                        }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showControls.toggle()
                        }
                        if showControls {
                            showControlsAndResetTimer()
                        } else {
                            autoHideBox.autoHideTask?.cancel()
                            autoHideBox.autoHideTask = nil
                        }
                    }
                }

            if isOpeningMedia || (!hasRenderedFirstFrame && openingErrorMessage == nil) {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.78))
                        Text("正在加载...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))

                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 0.75, height: 12)

                        Button {
                            exitPlayer()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text("取消")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.88))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7.5)
                    .background(
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(Color.black.opacity(0.42))
                            Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                        }
                    )
                    .padding(.bottom, 34)
                }
                .transition(.opacity)
            } else if isWaitingForSeekOrBuffer && openingErrorMessage == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.82))
                        Text("正在缓冲...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                        if displayDownloadSpeedMBs > 0.05 {
                            Text(String(format: "%.1f MB/s", displayDownloadSpeedMBs))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(Color.black.opacity(0.48))
                            Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                        }
                    )
                    .padding(.bottom, showControls ? (bottomControlBarHeight + 18) : 34)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if let err = openingErrorMessage {
                ZStack {
                    Color.black.opacity(0.82)
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("打开媒体流失败")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        HStack(spacing: 12) {
                            Button("重试播放") {
                                startNativeKernelPlayback(startSeconds: autoHideBox.liveCurrentTime)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(appState.accentColor)

                            Button("切换线路") {
                                appState.linePickerServer = session.server
                            }
                            .buttonStyle(.bordered)

                            Button("查看运行日志") {
                                showLogSheet = true
                            }
                            .buttonStyle(.bordered)

                            Button("退出播放") {
                                exitPlayer()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(32)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.black.opacity(0.72))
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                        }
                    )
                }
                .transition(.opacity)
            }

            if showControls || isOpeningMedia || openingErrorMessage != nil {
                VStack {
                    topOSDBar
                        .onContinuousHover { _ in showControlsAndResetTimer() }
                    Spacer()
                    if showControls && !isOpeningMedia && openingErrorMessage == nil {
                        if let bannerTitle = skipBannerLabel {
                            HStack {
                                Spacer()
                                Button {
                                    if skipBannerIsOutro,
                                       let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
                                       session.episodesQueue.indices.contains(idx + 1) {
                                        switchToEpisode(session.episodesQueue[idx + 1])
                                    } else {
                                        seekTo(skipBannerTargetSec)
                                    }
                                    skipBannerLabel = nil
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: skipBannerIsOutro ? "forward.end.fill" : "forward.fill")
                                        Text(bannerTitle)
                                    }
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        ZStack {
                                            Capsule().fill(.ultraThinMaterial)
                                            Capsule().fill(Color.black.opacity(0.55))
                                            Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 24)
                                .padding(.bottom, 8)
                            }
                        }
                        bottomControlBar
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear { bottomControlBarHeight = geo.size.height }
                                        .onChange(of: geo.size.height) { _, newH in
                                            if abs(bottomControlBarHeight - newH) > 0.5 {
                                                bottomControlBarHeight = newH
                                            }
                                        }
                                }
                            )
                            .onContinuousHover { _ in showControlsAndResetTimer() }
                    }
                }
                .transition(.opacity)
            }

            if let drawer = activeDrawer {
                HStack {
                    Spacer()
                    rightDrawerPanel(tab: drawer)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .onContinuousHover { _ in
                            autoHideBox.autoHideTask?.cancel()
                            autoHideBox.autoHideTask = nil
                        }
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            LogViewerSheet()
                .environmentObject(appState)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { seekRelative(-10); return .handled }
        .onKeyPress(.rightArrow) { seekRelative(10); return .handled }
        .onKeyPress(.upArrow) { adjustVolume(delta: 0.05); return .handled }
        .onKeyPress(.downArrow) { adjustVolume(delta: -0.05); return .handled }
        .onKeyPress(KeyEquivalent("f")) { toggleFullScreen(); return .handled }
        .onKeyPress(KeyEquivalent("F")) { toggleFullScreen(); return .handled }
        .onKeyPress(KeyEquivalent("l")) { showLogSheet.toggle(); return .handled }
        .onKeyPress(KeyEquivalent("L")) { showLogSheet.toggle(); return .handled }
        .onKeyPress(.escape) { exitPlayer(); return .handled }
        .onExitCommand { exitPlayer() }
        .onAppear {
            playbackSpeed = Float(appState.defaultPlaySpeed)
            updateClock()
            startNativeKernelPlayback(startSeconds: session.startPositionSeconds)
            showControlsAndResetTimer()

            // Setup global window monitors for mouse activity and keyboard shortcuts
            if let mm = mouseMonitor { NSEvent.removeMonitor(mm); mouseMonitor = nil }
            if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { event in
                guard NSApp.modalWindow == nil else { return event }
                let now = ProcessInfo.processInfo.systemUptime
                if event.type != .mouseMoved || now - autoHideBox.lastMouseMoveTimestamp > 0.15 {
                    autoHideBox.lastMouseMoveTimestamp = now
                    showControlsAndResetTimer()
                }
                return event
            }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let hasSheet = showLogSheet || appState.showLogViewer || appState.showAddServerSheet || appState.linePickerServer != nil
                if hasSheet || NSApp.modalWindow != nil || event.window?.attachedSheet != nil || (NSApp.keyWindow?.firstResponder is NSTextView) {
                    return event
                }
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                if !mods.isEmpty {
                    return event
                }
                showControlsAndResetTimer()
                switch event.keyCode {
                case 49: // Space
                    togglePlayPause()
                    return nil
                case 123: // Left Arrow (-10s)
                    seekRelative(-10)
                    return nil
                case 124: // Right Arrow (+10s)
                    seekRelative(10)
                    return nil
                case 126: // Up Arrow (+5% volume)
                    adjustVolume(delta: 0.05)
                    return nil
                case 125: // Down Arrow (-5% volume)
                    adjustVolume(delta: -0.05)
                    return nil
                case 53: // Esc
                    exitPlayer()
                    return nil
                default:
                    let char = event.charactersIgnoringModifiers?.lowercased()
                    if char == "f" {
                        toggleFullScreen()
                        return nil
                    }
                    if char == "l" {
                        showLogSheet.toggle()
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            autoHideBox.autoHideTask?.cancel()
            if let mm = mouseMonitor { NSEvent.removeMonitor(mm); mouseMonitor = nil }
            if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }
            stopNativeKernel()
        }
        .onReceive(progressTimer) { _ in
            let hudVisible = showControls || activeDrawer != nil
            if hudVisible {
                updateClock()
            }
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
            if pState == DK_STATE_ENDED && !didHandlePlaybackEnded {
                didHandlePlaybackEnded = true
                isPlaying = false
                currentTime = livePos
                finishedItemPendingCleanup = (currentItem.id, currentResource.mediaSource.id)
                if session.server.type == .uhdNative && !session.server.accessToken.isEmpty {
                    let srv = session.server
                    let itm = currentItem
                    let assetId = currentResource.mediaSource.id
                    let endPos = livePos
                    Task {
                        await UHDStreamClient.shared.reportPlayback(server: srv, kind: .finished, item: itm, assetId: assetId, positionSeconds: endPos)
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
        .onChange(of: appState.cachePoolSizeMB) { _, newValue in
            if let handle = playerHandle {
                dk_player_set_buffer_limit_mb(handle, Int32(newValue))
            }
        }
        .onChange(of: appState.subtitleStyle) { _, _ in
            applyKernelSubtitleStyle()
        }
        .onChange(of: appState.turboConnectionBudget) { _, _ in
            let budget = appState.effectiveConnectionBudget(for: session.server)
            activeTurboHandle?.updateTuning(
                connectionBudget: budget,
                prefetchAheadChunks: max(24, min(360, Int(appState.turboPrefetchSeconds * 1.2)))
            )
        }
        .onReceive(embySyncTimer) { _ in
            guard !session.server.host.isEmpty && !session.server.accessToken.isEmpty else { return }
            let livePos = autoHideBox.liveCurrentTime
            if session.server.type == .uhdNative {
                let srv = session.server
                let itm = currentItem
                let assetId = currentResource.mediaSource.id
                Task {
                    await UHDStreamClient.shared.reportPlayback(server: srv, kind: .progress, item: itm, assetId: assetId, positionSeconds: livePos)
                }
            } else {
                Task {
                    await EmbyClient.shared.reportPlaybackProgress(
                        server: session.server,
                        itemId: currentItem.id,
                        mediaSourceId: currentResource.mediaSource.id,
                        playSessionId: currentResource.playSessionId,
                        positionSeconds: livePos,
                        isPaused: !isPlaying
                    )
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private var topBarTitleString: String {
        if currentItem.isEpisode {
            var parts: [String] = []
            if let series = currentItem.seriesName, !series.isEmpty {
                parts.append(series)
            }
            if let code = currentItem.episodeCodeString, !code.isEmpty {
                parts.append(code)
            }
            if !currentItem.name.isEmpty {
                parts.append(currentItem.name)
            }
            return parts.joined(separator: " ")
        }
        return currentItem.name
    }

    private var topOSDBar: some View {
        ZStack {
            HStack {
                Button {
                    exitPlayer()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13.5, weight: .semibold))
                        if isOpeningMedia || openingErrorMessage != nil {
                            Text("退出")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, (isOpeningMedia || openingErrorMessage != nil) ? 11 : 0)
                    .frame(width: (isOpeningMedia || openingErrorMessage != nil) ? nil : 32, height: 32)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("退出播放 (Esc)")
                Spacer()
            }

            Text(topBarTitleString)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 620)

            HStack {
                Spacer()
                Text(String(format: "%.1f MB/s", max(0.0, displayDownloadSpeedMBs)))
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.75), Color.black.opacity(0.32), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var midRightActionPill: some View {
        VStack(spacing: 16) {
            Button {
                takeVideoSnapshot()
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("截取当前画面 (保存至图库并复制到剪贴板)")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    activeDrawer = (activeDrawer == .playlist) ? nil : .playlist
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(activeDrawer == .playlist ? appState.accentColor : .white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("选集播放列表")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.68))
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 10, y: 3)
        )
        .padding(.trailing, 24)
    }

    private func playerSpecBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
            )
    }

    private var specVideoCodecString: String {
        let vCodec = Self.cString(from: kernelStats.video_codec)
        if !vCodec.isEmpty && vCodec != "Unknown" {
            let uc = vCodec.uppercased()
            if uc.contains("HEVC") || uc.contains("H265") { return "HEVC" }
            if uc.contains("H264") || uc.contains("AVC") { return "AVC" }
            if uc.contains("AV1") { return "AV1" }
            if uc.contains("VP9") { return "VP9" }
            return uc
        }
        if let tag = currentItem.videoCodecTag {
            return tag.uppercased()
        }
        return "HEVC"
    }

    private var specDynamicRangeString: String {
        if kernelStats.is_dolby_vision { return "DOVI" }
        if kernelStats.is_hdr { return "HDR" }
        return "SDR"
    }

    private var specResolutionString: String {
        let w = kernelStats.width > 0 ? kernelStats.width : Int32(currentItem.primaryVideoStream?.width ?? 0)
        let h = kernelStats.height > 0 ? kernelStats.height : Int32(currentItem.primaryVideoStream?.height ?? 0)
        if w >= 3600 || h >= 2000 { return "2160P" }
        if w >= 2500 || h >= 1400 { return "1440P" }
        if w >= 1800 || h >= 1000 { return "1080P" }
        if w >= 1200 || h >= 700  { return "720P" }
        if h > 0     { return "\(h)P" }
        if let res = currentItem.resolutionBadge, !res.isEmpty {
            let u = res.uppercased()
            if u.contains("4K") { return "2160P" }
            if u.contains("1080") { return "1080P" }
            if u.contains("720") { return "720P" }
            return u
        }
        return "2160P"
    }

    private var specFpsString: String {
        let fps = kernelStats.fps > 0 ? kernelStats.fps : 24.0
        return "\(Int(fps.rounded()))FPS"
    }

    private var specBitrateString: String? {
        if kernelStats.video_bitrate_mbps > 0.05 {
            return String(format: "%.1fmbps", kernelStats.video_bitrate_mbps)
        }
        if let br = currentItem.primaryVideoStream?.bitRate, br > 0 {
            return String(format: "%.1fmbps", Double(br) / 1_000_000.0)
        }
        return nil
    }

    private var bottomControlBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Badges row positioned above the bottom control bar on the left
            HStack(spacing: 6) {
                playerSpecBadge(text: kernelStats.is_hw_accelerated ? "HW" : "SW")
                playerSpecBadge(text: specVideoCodecString)
                playerSpecBadge(text: specDynamicRangeString)
                playerSpecBadge(text: specResolutionString)
                playerSpecBadge(text: specFpsString)
                if let br = specBitrateString {
                    playerSpecBadge(text: br)
                }
            }
            .padding(.leading, 24)
            .padding(.bottom, 8)

            // Main single unified horizontal control bar
            HStack(spacing: 14) {
                // Left controls: Previous, Rewind 10s, Play/Pause, Forward 10s, Next, Current Time
                HStack(spacing: 6) {
                    Button { playAdjacentEpisode(offset: -1) } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.episodesQueue.count > 1 ? .white : .white.opacity(0.35))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.episodesQueue.count <= 1)
                    .help("上一集")

                    Button { seekRelative(-10) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("快退 10 秒")

                    Button { togglePlayPause() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "暂停 (空格)" : "播放 (空格)")

                    Button { seekRelative(10) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("快进 10 秒")

                    Button { playAdjacentEpisode(offset: 1) } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.episodesQueue.count > 1 ? .white : .white.opacity(0.35))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.episodesQueue.count <= 1)
                    .help("下一集")

                    Text(formatTime(isScrubbing ? scrubTime : currentTime))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(minWidth: 46, alignment: .leading)
                        .padding(.leading, 4)
                }

                // Center: sleek timeline scrubber
                PlayerTimelineScrubberView(
                    currentTime: currentTime,
                    bufferedAheadSeconds: bufferedAheadSeconds,
                    duration: duration,
                    accentColor: appState.accentColor,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    onCommitSeek: { target in seekTo(target) }
                )

                // Right controls: Duration, Volume Icon, Mini Volume Slider, 5 Circular Buttons
                HStack(spacing: 10) {
                    Button { showRemainingTime.toggle() } label: {
                        Text(showRemainingTime ? "-\(formatTime(max(0, duration - currentTime)))" : formatTime(duration))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(minWidth: 48, minHeight: 28, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("切换显示总时长 / 剩余时长")

                    Button {
                        isMuted.toggle()
                        if let handle = playerHandle {
                            dk_player_set_volume(handle, volume, isMuted)
                        }
                    } label: {
                        Image(systemName: isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "取消静音" : "静音")

                    MiniVolumeSlider(volume: $volume, isMuted: $isMuted) { v in
                        if let handle = playerHandle {
                            dk_player_set_volume(handle, v, isMuted)
                        }
                    }

                    // 1. Audio tracks circular button
                    PlayerCircleMenu(tooltip: "音频轨道") {
                        Image(systemName: "waveform")
                            .font(.system(size: 12, weight: .semibold))
                    } menuItems: {
                        audioMenuContent
                    }

                    // 2. Subtitle circular button
                    PlayerCircleMenu(tooltip: "字幕选择") {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .bold))
                    } menuItems: {
                        subtitleMenuContent
                    }

                    // 3. ( D ) Decoder & display info circular button
                    PlayerCircleMenu(tooltip: "解码与显示信息") {
                        Text("D")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    } menuItems: {
                        decoderMenuContent
                    }

                    // 4. Playback speed gauge circular button
                    PlayerCircleMenu(tooltip: "播放速度") {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 12, weight: .semibold))
                    } menuItems: {
                        speedMenuContent
                    }

                    // 5. More options circular button
                    PlayerCircleMenu(tooltip: "更多选项") {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .bold))
                    } menuItems: {
                        moreMenuContent
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.72), Color.black.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    ),
                alignment: .top
            )
            .contentShape(Rectangle())
            .onTapGesture {}
        }
    }

    // MARK: - Dropdown Menu Contents for Bottom Control Bar Circular Buttons

    @ViewBuilder
    private var audioMenuContent: some View {
        Text("选择音频轨道")
        Divider()
        let audioOpts = resolvedAudioOptions
        if audioOpts.isEmpty {
            Text("未检测到可用音轨")
        } else {
            ForEach(audioOpts) { option in
                Button {
                    selectAudioOption(option)
                } label: {
                    if activeAudioAVIndex == option.avStreamIndex {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        }
        Divider()
        Button("打开轨道管理面板...") {
            tracksDrawerSection = .tracks
            withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = .tracks }
        }
    }

    @ViewBuilder
    private var subtitleMenuContent: some View {
        Text("选择字幕语言")
        Divider()
        Button {
            disableSubtitles(showFeedback: true)
        } label: {
            if activeSubtitleSelection == .off {
                Label("关闭字幕", systemImage: "checkmark")
            } else {
                Text("关闭字幕")
            }
        }
        Divider()
        let subOpts = resolvedSubtitleOptions
        ForEach(subOpts) { option in
            Button {
                selectSubtitleOption(option)
            } label: {
                let isSel = (activeSubtitleSelection == option.selection)
                let title = option.badge != nil ? "\(option.label) [\(option.badge!)]" : option.label
                if isSel {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
        Divider()
        Section("智能对齐") {
            Button {
                runAutoAlignAudioToSubtitle()
            } label: {
                let suffix = abs(appState.subtitleStyle.primaryDelaySeconds) > 0.01
                    ? " (\(Self.formatSubtitleDelay(appState.subtitleStyle.primaryDelaySeconds)))"
                    : ""
                Label(
                    isAutoAligningSubtitle ? "正在字音对齐..." : "字音自动对齐\(suffix)",
                    systemImage: "waveform.badge.magnifyingglass"
                )
            }
            .disabled(activeSubtitleSelection == .off || isAutoAligningSubtitle || playerHandle == nil)

            Button {
                runAutoAlignDualSubtitles()
            } label: {
                let suffix = (activeSecondarySubtitleSelection != .off && abs(appState.subtitleStyle.secondaryDelaySeconds) > 0.01)
                    ? " (副 \(Self.formatSubtitleDelay(appState.subtitleStyle.secondaryDelaySeconds)))"
                    : ""
                Label("双字幕自动对齐\(suffix)", systemImage: "arrow.left.arrow.right")
            }
            .disabled(activeSubtitleSelection == .off || activeSecondarySubtitleSelection == .off || isAutoAligningSubtitle || playerHandle == nil)

            if let undo = lastSubtitleAlignUndo {
                Button {
                    undoLastSubtitleAlignment()
                } label: {
                    Label("撤销\(undo.label)", systemImage: "arrow.uturn.backward")
                }
            }
        }
        Divider()
        Menu("双语副字幕") {
            Button {
                disableSecondarySubtitle()
            } label: {
                if activeSecondarySubtitleSelection == .off {
                    Label("关闭副字幕", systemImage: "checkmark")
                } else {
                    Text("关闭副字幕")
                }
            }
            Divider()
            ForEach(subOpts) { option in
                Button {
                    selectSecondarySubtitleOption(option)
                } label: {
                    if activeSecondarySubtitleSelection == option.selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
            Divider()
            Button("加载本地副字幕文件...") {
                promptLocalExternalSubtitleFile(asSecondary: true)
            }
        }
        Menu("实时简繁转换 (\(appState.subtitleStyle.transform.shortTitle))") {
            ForEach(SubtitleTextTransform.allCases) { tf in
                Button {
                    appState.subtitleStyle.transform = tf
                } label: {
                    if appState.subtitleStyle.transform == tf {
                        Label(tf.title, systemImage: "checkmark")
                    } else {
                        Text(tf.title)
                    }
                }
            }
        }
        Divider()
        Button("加载本地字幕文件 (.srt / .ass)...") {
            promptLocalExternalSubtitleFile(asSecondary: false)
        }
        Button("字幕样式与微调...") {
            tracksDrawerSection = .style
            withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = .tracks }
        }
    }

    @ViewBuilder
    private var decoderMenuContent: some View {
        Section("媒体信息") {
            Text("解码: \(kernelStats.is_hw_accelerated ? "硬件解码" : "软件解码")")
            Text("动态范围: \(kernelStats.is_dolby_vision ? "Dolby Vision" : (kernelStats.is_hdr ? "HDR10" : "SDR"))")
            Text("分辨率: \(specResolutionString)")
            Text("帧率: \(specFpsString)")
            if let br = specBitrateString {
                Text("码率: \(br)")
            }
        }
        Divider()
        Section("解码与线路") {
            Button(appState.enableHardwareDecode ? "切换为软件解码" : "启用硬件解码") {
                appState.enableHardwareDecode.toggle()
                startNativeKernelPlayback(startSeconds: currentTime)
            }
            Button("切换播放线路 (\(session.server.activeLineName))...") {
                appState.linePickerServer = session.server
            }
        }
        Divider()
        Button("查看详细流媒体参数...") {
            withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = .mediaInfo }
        }
    }

    @ViewBuilder
    private var speedMenuContent: some View {
        Text("选择播放倍速")
        Divider()
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { spd in
            Button {
                playbackSpeed = Float(spd)
                if let handle = playerHandle { dk_player_set_rate(handle, playbackSpeed) }
            } label: {
                let isSel = abs(playbackSpeed - Float(spd)) < 0.05
                let title = String(format: "%.2gx 倍速", spd)
                if isSel {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        Section("片头片尾与按季记忆") {
            let skipPref = appState.effectiveSkipPreference(serverId: session.server.id, item: currentItem)
            Button("跳过片头 (+\(Int(skipPref.introSeconds))s)") {
                seekTo(skipPref.introSeconds)
                appState.showToast("已跳至片头结束点 \(formatTime(skipPref.introSeconds))", icon: "forward.end.alt.fill")
            }
            Button("设当前位置为本季片头结束 (\(formatTime(currentTime)))") {
                appState.updateSeasonSkipPreference(serverId: session.server.id, item: currentItem) { pref in
                    pref.introSeconds = currentTime
                    pref.hasUserMarkedIntro = true
                }
                appState.showToast("已记忆本季片头长度：\(formatTime(currentTime))", icon: "checkmark.circle.fill")
            }
            Button("设当前位置为本季片尾开始 (剩余 \(formatTime(max(0, duration - currentTime))))") {
                let tailLen = max(0, duration - currentTime)
                appState.updateSeasonSkipPreference(serverId: session.server.id, item: currentItem) { pref in
                    pref.outroSeconds = tailLen
                    pref.hasUserMarkedOutro = true
                }
                appState.showToast("已记忆本季片尾长度：\(formatTime(tailLen))", icon: "checkmark.circle.fill")
            }
            Menu("本季跳过模式：\(skipPref.mode.title)") {
                ForEach(SeasonSkipMode.allCases) { m in
                    Button(m.title) {
                        appState.updateSeasonSkipPreference(serverId: session.server.id, item: currentItem) { $0.mode = m }
                    }
                }
            }
        }
        Divider()
        Section("面板与工具") {
            Button("选集播放列表") {
                withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = .playlist }
            }
            Button("查看运行日志 (L)") {
                showLogSheet = true
            }
        }
        Divider()
        Button("切换全屏 (F)") {
            toggleFullScreen()
        }
        Button("退出播放 (Esc)") {
            exitPlayer()
        }
    }

    private func takeVideoSnapshot() {
        guard let input = DKMetalLayerView.activeInstance?.currentFrameSnapshotInput() else {
            appState.showToast("截图失败：未捕获到视频画面", icon: "camera.fill", isError: true)
            return
        }

        let itemTitle = currentItem.name
        let timestamp = Self.snapshotDateFormatter.string(from: Date())
        Task.detached(priority: .userInitiated) {
            guard let cgImg = DKMetalLayerView.renderOffscreenCGImage(
                pixelBuffer: input.pixelBuffer,
                colorUniforms: input.colorUniforms,
                edrHeadroom: input.edrHeadroom
            ) else {
                await MainActor.run {
                    appState.showToast("截图失败：未捕获到视频画面", icon: "camera.fill", isError: true)
                }
                return
            }

            let image = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            let donbyDir = picturesURL.appendingPathComponent("Donby", isDirectory: true)
            try? FileManager.default.createDirectory(at: donbyDir, withIntermediateDirectories: true)

            let safeTitle = itemTitle.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let fileURL = donbyDir.appendingPathComponent("\(safeTitle)_\(timestamp).png")

            if let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImg, nil)
                CGImageDestinationFinalize(dest)
            }

            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
                appState.showToast("已截图并保存至照片与剪贴板", icon: "camera.fill")
            }
        }
    }

    // MARK: - Deterministic FFmpeg AVStream <-> Emby MediaSource Track Resolution

    private var embyAudioStreams: [MediaStream] {
        let sourceStreams = currentResource.mediaSource.mediaStreams ?? currentItem.allStreams
        return sourceStreams.filter { $0.type?.lowercased() == "audio" }
    }

    private var embySubtitleStreams: [MediaStream] {
        let sourceStreams = currentResource.mediaSource.mediaStreams ?? currentItem.allStreams
        return sourceStreams.filter { $0.type?.lowercased() == "subtitle" }
    }

    private var resolvedAudioOptions: [PlayerAudioTrackOption] {
        let embyAudios = embyAudioStreams
        if !kernelAudioTracks.isEmpty {
            return kernelAudioTracks.enumerated().map { ord, kStream in
                let avIdx = kStream.index ?? ord
                let matchedEmby = embyAudios.indices.contains(ord)
                    ? embyAudios[ord]
                    : embyAudios.first(where: { $0.index == avIdx })
                let label = matchedEmby?.readableLabel ?? kStream.readableLabel
                return PlayerAudioTrackOption(
                    avStreamIndex: avIdx,
                    embyIndex: matchedEmby?.index,
                    label: label
                )
            }
        }
        return embyAudios.compactMap { eStream in
            guard let idx = eStream.index else { return nil }
            return PlayerAudioTrackOption(avStreamIndex: idx, embyIndex: idx, label: eStream.readableLabel)
        }
    }

    private var resolvedSubtitleOptions: [PlayerSubtitleTrackOption] {
        var options: [PlayerSubtitleTrackOption] = []
        let embyEmbeddedSubs = embySubtitleStreams.filter { $0.isExternal != true }

        // 1. Embedded subtitle tracks backed by real FFmpeg AVStream indices
        for (ord, kStream) in kernelSubtitleTracks.enumerated() {
            guard let avIdx = kStream.index else { continue }
            let matchedEmby = embyEmbeddedSubs.indices.contains(ord)
                ? embyEmbeddedSubs[ord]
                : embyEmbeddedSubs.first(where: { $0.index == avIdx })
            let label = matchedEmby?.readableLabel ?? kStream.readableLabel
            let codecTag = (kStream.codec ?? matchedEmby?.codec)?.uppercased()
            options.append(PlayerSubtitleTrackOption(
                id: "emb-\(avIdx)",
                selection: .embedded(avStreamIndex: avIdx),
                embyIndex: matchedEmby?.index,
                label: label,
                badge: codecTag,
                externalItem: nil,
                language: matchedEmby?.language ?? kStream.language,
                codec: matchedEmby?.codec ?? kStream.codec,
                isDefault: (matchedEmby?.isDefault ?? kStream.isDefault) == true
            ))
        }

        // 2. External text subtitle tracks (or fallback remote tracks when container has no embedded subs)
        let extCandidates = kernelSubtitleTracks.isEmpty
            ? currentResource.subtitleURLs
            : currentResource.subtitleURLs.filter(\.isExternal)
        var seenURLs = Set<String>()
        for ext in extCandidates {
            guard seenURLs.insert(ext.url.absoluteString).inserted else { continue }
            options.append(PlayerSubtitleTrackOption(
                id: "ext-\(ext.id)",
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

        // 3. Currently loaded local subtitle file (if any)
        if case .localExternal(let localURL) = activeSubtitleSelection {
            options.append(PlayerSubtitleTrackOption(
                id: "local-\(localURL.absoluteString)",
                selection: .localExternal(url: localURL),
                embyIndex: nil,
                label: localExternalSubtitleName ?? localURL.lastPathComponent,
                badge: "本地",
                externalItem: nil,
                language: nil,
                codec: localURL.pathExtension.lowercased(),
                isDefault: true
            ))
        }

        return options
    }

    private func drawerGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.65)
        )
    }

    private func drawerRowBackground(isSelected: Bool) -> some View {
        let fill: Color = {
            if !isSelected { return Color.white.opacity(0.045) }
            return appState.isMonochromeTheme ? Color.white.opacity(0.18) : appState.accentColor.opacity(0.24)
        }()
        let stroke: Color = {
            if !isSelected { return Color.white.opacity(0.06) }
            return appState.isMonochromeTheme ? Color.white.opacity(0.36) : appState.accentColor.opacity(0.68)
        }()
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(stroke, lineWidth: isSelected ? 0.85 : 0.55)
            )
    }

    private func drawerSelectedAccentTint() -> Color {
        appState.isMonochromeTheme ? .white : appState.accentColor
    }

    private func drawerDelayStepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.90))
                .frame(minWidth: 36, minHeight: 24)
                .padding(.horizontal, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func drawerSegmentedPill<T: Hashable & Identifiable>(
        options: [T],
        selection: T,
        title: @escaping (T) -> String,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                let isSelected = (option == selection)
                let labelText = title(option)
                let fgColor: Color = isSelected ? .white : Color.white.opacity(0.62)
                let fillColor: Color = isSelected ? Color.white.opacity(0.18) : .clear
                let strokeColor: Color = isSelected ? Color.white.opacity(0.18) : .clear
                Button {
                    onSelect(option)
                } label: {
                    Text(labelText)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(fgColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(fillColor))
                        .overlay(Capsule(style: .continuous).strokeBorder(strokeColor, lineWidth: 0.6))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.6)
        )
    }

    private func rightDrawerPanel(tab: PlayerDrawerTab) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Liquid Glass Drawer Header
            HStack(spacing: 8) {
                drawerSegmentedPill(
                    options: PlayerDrawerTab.allCases,
                    selection: tab,
                    title: { $0.rawValue },
                    onSelect: { nextTab in
                        syncVisiblePlaybackStateFromBox()
                        activeDrawer = nextTab
                    }
                )

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭面板")
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 0.6)

            ScrollView(showsIndicators: false) {
                switch tab {
                case .playlist:
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(session.episodesQueue.enumerated()), id: \.offset) { _, ep in
                            let isCurrent = ep.id == currentItem.id
                            Button { switchToEpisode(ep) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isCurrent ? "play.circle.fill" : "film")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(isCurrent ? drawerSelectedAccentTint() : .white.opacity(0.55))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ep.episodeCodeString != nil ? "\(ep.episodeCodeString!) · \(ep.name)" : ep.name)
                                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        if let rt = ep.runtimeMinutesString {
                                            Text(rt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.58))
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .background(drawerRowBackground(isSelected: isCurrent))
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                case .tracks:
                    VStack(alignment: .leading, spacing: 12) {
                        drawerSegmentedPill(
                            options: TracksDrawerSection.allCases,
                            selection: tracksDrawerSection,
                            title: { $0.rawValue },
                            onSelect: { tracksDrawerSection = $0 }
                        )

                        if tracksDrawerSection == .tracks {
                            let audioOptions = resolvedAudioOptions
                            let subOptions = resolvedSubtitleOptions

                            drawerGlassCard {
                                HStack {
                                    Label("音频轨道", systemImage: "waveform")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.68))
                                    Spacer()
                                    if !audioOptions.isEmpty {
                                        Text("\(audioOptions.count)")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }

                                if audioOptions.isEmpty {
                                    Text("未检测到可用音轨")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.48))
                                        .padding(.vertical, 2)
                                } else {
                                    VStack(spacing: 6) {
                                        ForEach(audioOptions) { option in
                                            let isSel = (activeAudioAVIndex == option.avStreamIndex)
                                            Button {
                                                selectAudioOption(option)
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                                                        .font(.system(size: 12.5, weight: .semibold))
                                                        .foregroundStyle(isSel ? drawerSelectedAccentTint() : .white.opacity(0.40))
                                                    Text(option.label)
                                                        .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                                                        .foregroundStyle(.white)
                                                        .lineLimit(1)
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 8)
                                                .background(drawerRowBackground(isSelected: isSel))
                                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            drawerGlassCard {
                                HStack {
                                    Label("主字幕", systemImage: "captions.bubble.fill")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.68))
                                    Spacer()
                                    Button {
                                        promptLocalExternalSubtitleFile(asSecondary: false)
                                    } label: {
                                        Text("加载本地...")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(drawerSelectedAccentTint())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.white.opacity(0.08)))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                VStack(spacing: 6) {
                                    Button {
                                        disableSubtitles(showFeedback: true)
                                    } label: {
                                        let isOff = (activeSubtitleSelection == .off)
                                        HStack(spacing: 8) {
                                            Image(systemName: isOff ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(isOff ? drawerSelectedAccentTint() : .white.opacity(0.40))
                                            Text("关闭字幕")
                                                .font(.system(size: 12, weight: isOff ? .semibold : .regular))
                                                .foregroundStyle(.white)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(drawerRowBackground(isSelected: isOff))
                                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                    .buttonStyle(.plain)

                                    ForEach(subOptions) { option in
                                        let isSel = (activeSubtitleSelection == option.selection)
                                        Button {
                                            selectSubtitleOption(option)
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                                                    .font(.system(size: 12.5, weight: .semibold))
                                                    .foregroundStyle(isSel ? drawerSelectedAccentTint() : .white.opacity(0.40))
                                                Text(option.label)
                                                    .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                Spacer()
                                                if let badge = option.badge, !badge.isEmpty {
                                                    Text(badge)
                                                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                                        .foregroundStyle(.white.opacity(0.88))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill(Color.white.opacity(0.14)))
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(drawerRowBackground(isSelected: isSel))
                                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            drawerGlassCard {
                                Label("双语副字幕", systemImage: "text.bubble")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.68))

                                ZStack {
                                    HStack(spacing: 8) {
                                        Image(systemName: "captions.bubble")
                                            .font(.system(size: 12))
                                            .foregroundStyle(activeSecondarySubtitleSelection == .off ? .white.opacity(0.55) : drawerSelectedAccentTint())
                                        Text(secondarySubtitleStatusTitle(options: subOptions))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                                    .background(drawerRowBackground(isSelected: activeSecondarySubtitleSelection != .off))
                                    .allowsHitTesting(false)
                                }
                                .overlay {
                                    Menu {
                                        Button("关闭副字幕") { disableSecondarySubtitle() }
                                        Divider()
                                        ForEach(subOptions) { opt in
                                            Button(opt.label) { selectSecondarySubtitleOption(opt) }
                                        }
                                        Divider()
                                        Button("加载本地副字幕文件...") { promptLocalExternalSubtitleFile(asSecondary: true) }
                                    } label: {
                                        Color.clear
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                    .menuStyle(.button)
                                    .buttonStyle(.plain)
                                    .menuIndicator(.hidden)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                            }
                        } else {
                            // 样式与对齐 — Liquid Glass card stack
                            drawerGlassCard {
                                Label("智能对齐与延迟", systemImage: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.68))

                                HStack(spacing: 7) {
                                    let audioAlignDisabled = (activeSubtitleSelection == .off || isAutoAligningSubtitle || playerHandle == nil)
                                    Button {
                                        runAutoAlignAudioToSubtitle()
                                    } label: {
                                        HStack(spacing: 5) {
                                            if isAutoAligningSubtitle {
                                                ProgressView().controlSize(.mini)
                                            } else {
                                                Image(systemName: "waveform")
                                                    .font(.system(size: 11, weight: .semibold))
                                            }
                                            Text("字音对齐")
                                        }
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(audioAlignDisabled ? 0.42 : 0.95))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(Color.white.opacity(audioAlignDisabled ? 0.04 : 0.12))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .strokeBorder(Color.white.opacity(audioAlignDisabled ? 0.05 : 0.14), lineWidth: 0.65)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(audioAlignDisabled)
                                    .help("以音轨为基准，通过 Silero VAD 自动校准字幕时间轴")

                                    let dualAlignDisabled = (activeSubtitleSelection == .off || activeSecondarySubtitleSelection == .off || isAutoAligningSubtitle || playerHandle == nil)
                                    Button {
                                        runAutoAlignDualSubtitles()
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "arrow.left.arrow.right")
                                                .font(.system(size: 10.5, weight: .semibold))
                                            Text("双字对齐")
                                        }
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(dualAlignDisabled ? 0.42 : 0.95))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(Color.white.opacity(dualAlignDisabled ? 0.04 : 0.12))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .strokeBorder(Color.white.opacity(dualAlignDisabled ? 0.05 : 0.14), lineWidth: 0.65)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(dualAlignDisabled)
                                    .help("对齐主/副字幕偏移及 23.976/25fps 帧率漂移（自动校验音轨基准）")

                                    if lastSubtitleAlignUndo != nil {
                                        Button {
                                            undoLastSubtitleAlignment()
                                        } label: {
                                            Text("撤销")
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundStyle(drawerSelectedAccentTint())
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                        .fill(Color.white.opacity(0.08))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.65)
                                                )
                                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                if let summary = lastAutoAlignSummary {
                                    HStack(spacing: 6) {
                                        Text(summary)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.white.opacity(0.68))
                                            .lineLimit(2)
                                        Spacer()
                                        if abs(secondarySubtitleTimeScale - 1.0) > 5e-4 {
                                            Button {
                                                resetSecondarySubtitleTimeScale()
                                            } label: {
                                                Text("重置速率")
                                                    .font(.system(size: 10.5, weight: .semibold))
                                                    .foregroundStyle(drawerSelectedAccentTint())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .contentShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                HStack(spacing: 5) {
                                    Text("主延迟")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.86))
                                    Text(Self.formatSubtitleDelay(appState.subtitleStyle.primaryDelaySeconds))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.65))
                                    Spacer()
                                    drawerDelayStepButton("-0.5s") { appState.subtitleStyle.primaryDelaySeconds = max(-120, appState.subtitleStyle.primaryDelaySeconds - 0.5) }
                                    drawerDelayStepButton("0") { appState.subtitleStyle.primaryDelaySeconds = 0 }
                                    drawerDelayStepButton("+0.5s") { appState.subtitleStyle.primaryDelaySeconds = min(120, appState.subtitleStyle.primaryDelaySeconds + 0.5) }
                                }

                                if activeSecondarySubtitleSelection != .off {
                                    HStack(spacing: 5) {
                                        Text("副延迟")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.80))
                                        Text(Self.formatSubtitleDelay(appState.subtitleStyle.secondaryDelaySeconds))
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.62))
                                        Spacer()
                                        drawerDelayStepButton("-0.5s") { appState.subtitleStyle.secondaryDelaySeconds = max(-120, appState.subtitleStyle.secondaryDelaySeconds - 0.5) }
                                        drawerDelayStepButton("0") { appState.subtitleStyle.secondaryDelaySeconds = 0 }
                                        drawerDelayStepButton("+0.5s") { appState.subtitleStyle.secondaryDelaySeconds = min(120, appState.subtitleStyle.secondaryDelaySeconds + 0.5) }
                                    }
                                }
                            }

                            drawerGlassCard {
                                HStack {
                                    Label("基础样式", systemImage: "textformat.size")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.68))
                                    Spacer()
                                    Button {
                                        let prevDelay1 = appState.subtitleStyle.primaryDelaySeconds
                                        let prevDelay2 = appState.subtitleStyle.secondaryDelaySeconds
                                        var fresh = SubtitleStyleConfiguration()
                                        fresh.primaryDelaySeconds = prevDelay1
                                        fresh.secondaryDelaySeconds = prevDelay2
                                        appState.subtitleStyle = fresh
                                    } label: {
                                        Text("恢复默认")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(drawerSelectedAccentTint())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.white.opacity(0.08)))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("大小").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                        Spacer()
                                        Text(String(format: "%.2fx", appState.subtitleStyle.scale))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.72))
                                        if abs(appState.subtitleStyle.scale - 1.0) > 0.01 {
                                            Button { appState.subtitleStyle.scale = 1.0 } label: {
                                                Text("重置")
                                                    .font(.system(size: 10.5, weight: .semibold))
                                                    .foregroundStyle(drawerSelectedAccentTint())
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 2)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    Slider(
                                        value: $appState.subtitleStyle.scale,
                                        in: 0.6...1.8,
                                        step: 0.05,
                                        onEditingChanged: { editing in
                                            withAnimation(.easeInOut(duration: 0.15)) { isAdjustingSubtitleLayout = editing }
                                        }
                                    )
                                    .tint(drawerSelectedAccentTint())
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("位置").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                        Spacer()
                                        Text("\(Int(appState.subtitleStyle.verticalPositionPercent))%")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.72))
                                        if abs(appState.subtitleStyle.verticalPositionPercent - 92.0) > 0.5 {
                                            Button { appState.subtitleStyle.verticalPositionPercent = 92.0 } label: {
                                                Text("重置")
                                                    .font(.system(size: 10.5, weight: .semibold))
                                                    .foregroundStyle(drawerSelectedAccentTint())
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 2)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    Slider(
                                        value: $appState.subtitleStyle.verticalPositionPercent,
                                        in: 60...100,
                                        step: 1,
                                        onEditingChanged: { editing in
                                            withAnimation(.easeInOut(duration: 0.15)) { isAdjustingSubtitleLayout = editing }
                                        }
                                    )
                                    .tint(drawerSelectedAccentTint())
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("简繁转换")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.86))
                                    drawerSegmentedPill(
                                        options: SubtitleTextTransform.allCases,
                                        selection: appState.subtitleStyle.transform,
                                        title: { $0.shortTitle },
                                        onSelect: { appState.subtitleStyle.transform = $0 }
                                    )
                                }
                            }

                            drawerGlassCard {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showMoreSubtitleOptions.toggle()
                                    }
                                } label: {
                                    HStack {
                                        Label("高级外观", systemImage: "slider.horizontal.3")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.84))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .rotationEffect(.degrees(showMoreSubtitleOptions ? 90 : 0))
                                    }
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if showMoreSubtitleOptions {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Toggle("统一苹方与影院双语配对", isOn: $appState.subtitleStyle.unifyPingFangFont)
                                        Toggle("外语经典橙金增强", isOn: $appState.subtitleStyle.enhanceSecondaryYellow)

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(String(format: "外语副行比例 %.2fx", appState.subtitleStyle.secondaryScale))
                                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                                                Spacer()
                                                if abs(appState.subtitleStyle.secondaryScale - 0.60) > 0.01 {
                                                    Button { appState.subtitleStyle.secondaryScale = 0.60 } label: {
                                                        Text("重置")
                                                            .font(.system(size: 10.5, weight: .semibold))
                                                            .foregroundStyle(drawerSelectedAccentTint())
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 2)
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            Slider(
                                                value: $appState.subtitleStyle.secondaryScale,
                                                in: 0.45...0.90,
                                                step: 0.02,
                                                onEditingChanged: { editing in
                                                    withAnimation(.easeInOut(duration: 0.15)) { isAdjustingSubtitleLayout = editing }
                                                }
                                            )
                                            .tint(drawerSelectedAccentTint())
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(String(format: "双语行间距 %.0f px", appState.subtitleStyle.dualSubtitleGapPx))
                                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                                            Slider(
                                                value: $appState.subtitleStyle.dualSubtitleGapPx,
                                                in: 2...20,
                                                step: 1,
                                                onEditingChanged: { editing in
                                                    withAnimation(.easeInOut(duration: 0.15)) { isAdjustingSubtitleLayout = editing }
                                                }
                                            )
                                            .tint(drawerSelectedAccentTint())
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("双语排版")
                                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                                            HStack(spacing: 3) {
                                                ForEach([(0, "底部语义配对"), (1, "主底副顶分离")], id: \.0) { mode, label in
                                                    let isSel = (appState.subtitleStyle.dualLayoutMode == mode)
                                                    Button {
                                                        appState.subtitleStyle.dualLayoutMode = mode
                                                    } label: {
                                                        Text(label)
                                                            .font(.system(size: 11, weight: isSel ? .semibold : .medium))
                                                            .foregroundStyle(isSel ? .white : .white.opacity(0.62))
                                                            .frame(maxWidth: .infinity)
                                                            .padding(.vertical, 5.5)
                                                            .background(Capsule().fill(isSel ? Color.white.opacity(0.18) : Color.clear))
                                                            .contentShape(Capsule())
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(3)
                                            .background(Capsule().fill(Color.white.opacity(0.06)))
                                        }

                                        if appState.subtitleStyle.dualLayoutMode == 0 {
                                            Toggle("主字幕在上、副字幕在下", isOn: $appState.subtitleStyle.primaryOnTop)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(String(format: "描边宽度 %.1f", appState.subtitleStyle.borderWidth))
                                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                                            Slider(value: $appState.subtitleStyle.borderWidth, in: 0...6, step: 0.25)
                                                .tint(drawerSelectedAccentTint())
                                        }

                                        HStack {
                                            Text("HDR 亮度")
                                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.86))
                                            Spacer()
                                            ZStack {
                                                HStack(spacing: 5) {
                                                    Text(appState.subtitleStyle.hdrPeakNits.title)
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                    Image(systemName: "chevron.up.chevron.down")
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .foregroundStyle(.white.opacity(0.6))
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(Capsule().fill(Color.white.opacity(0.10)))
                                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                                                .allowsHitTesting(false)
                                            }
                                            .overlay {
                                                Menu {
                                                    ForEach(SubtitleHDRPeakNits.allCases) { nits in
                                                        Button {
                                                            appState.subtitleStyle.hdrPeakNits = nits
                                                        } label: {
                                                            if appState.subtitleStyle.hdrPeakNits == nits {
                                                                Label(nits.title, systemImage: "checkmark")
                                                            } else {
                                                                Text(nits.title)
                                                            }
                                                        }
                                                    }
                                                } label: {
                                                    Color.clear
                                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                        .contentShape(Capsule())
                                                }
                                                .menuStyle(.button)
                                                .buttonStyle(.plain)
                                                .menuIndicator(.hidden)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .contentShape(Capsule())
                                            }
                                        }

                                        Toggle("完全覆盖内封 ASS 样式", isOn: $appState.subtitleStyle.overrideASSStyle)
                                        Toggle("仅保留强制字幕 (Forced)", isOn: $appState.subtitleStyle.forcedOnly)
                                        Toggle("控制栏显示时上移字幕", isOn: $appState.subtitleStyle.antiOcclusionEnabled)
                                    }
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .tint(drawerSelectedAccentTint())
                                    .padding(.top, 4)
                                }
                            }
                        }
                    }

                case .mediaInfo:
                    VStack(alignment: .leading, spacing: 10) {
                        drawerGlassCard {
                            osdInfoRow("解码方式", kernelStats.is_hw_accelerated ? "硬件解码" : "软件解码")
                            osdInfoRow("动态范围", kernelStats.is_dolby_vision ? "Dolby Vision" : (kernelStats.is_hdr ? "HDR10" : "SDR"))
                            osdInfoRow("当前速率", String(format: "%.1f MB/s", max(0.0, displayDownloadSpeedMBs)))
                            osdInfoRow("缓冲时长", String(format: "+%.1f 秒", bufferedAheadSeconds))
                            osdInfoRow("预读缓存", "\(kernelStats.cached_bytes / 1024 / 1024) MB")
                            osdInfoRow("加载方式", activeTurboHandle != nil ? "多线程并发 (\(appState.effectiveConnectionBudget(for: session.server)) 线程)" : "顺序读取")
                            osdInfoRow("分辨率", "\(kernelStats.width) × \(kernelStats.height)")
                            osdInfoRow("帧率", String(format: "%.3f fps", kernelStats.fps))
                            osdInfoRow("视频编码", Self.cString(from: kernelStats.video_codec))
                            osdInfoRow("音频编码", Self.cString(from: kernelStats.audio_codec))
                            osdInfoRow("播放线路", session.server.activeLineName)
                        }

                        Button {
                            exportRedactedDiagnostics()
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard")
                                Text("复制脱敏诊断报告")
                                Spacer()
                                Image(systemName: "checkmark.shield").font(.system(size: 11)).foregroundStyle(.green)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(11)
                            .background(drawerRowBackground(isSelected: false))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showLogSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "terminal.fill")
                                Text("查看运行日志 (快捷键 L)")
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(drawerSelectedAccentTint())
                            .padding(11)
                            .background(drawerRowBackground(isSelected: false))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 324)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color(red: 0.055, green: 0.06, blue: 0.075).opacity(0.76))
                Rectangle().strokeBorder(Color.white.opacity(0.11), lineWidth: 0.65)
            }
            .opacity(isAdjustingSubtitleLayout ? 0.14 : 1.0)
        )
        .opacity(isAdjustingSubtitleLayout ? 0.42 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func osdInfoRow(_ key: String, _ val: String) -> some View {
        HStack {
            Text(key).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(val).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private func syncVisiblePlaybackStateFromBox() {
        if abs(currentTime - autoHideBox.liveCurrentTime) > 0.05 {
            currentTime = autoHideBox.liveCurrentTime
        }
        if abs(bufferedAheadSeconds - autoHideBox.liveBufferedAheadSeconds) > 0.25 {
            bufferedAheadSeconds = autoHideBox.liveBufferedAheadSeconds
        }
    }

    private func showControlsAndResetTimer() {
        // Avoid mutating SwiftUI state or scheduling hide while a macOS NSMenu is open
        if RunLoop.current.currentMode == .eventTracking {
            return
        }
        if !showControls {
            syncVisiblePlaybackStateFromBox()
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls = true
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        autoHideBox.autoHideDeadlineUptime = now + 3.0
        guard autoHideBox.autoHideTask == nil else { return }
        autoHideBox.autoHideTask = Task {
            while !Task.isCancelled {
                let remaining = autoHideBox.autoHideDeadlineUptime - ProcessInfo.processInfo.systemUptime
                if remaining > 0.05 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    continue
                }
                break
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                autoHideBox.autoHideTask = nil
                if RunLoop.current.currentMode != .eventTracking &&
                    activeDrawer == nil && !isScrubbing && !isOpeningMedia && openingErrorMessage == nil {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showControls = false
                    }
                }
            }
        }
    }

    private func adjustVolume(delta: Float) {
        let newVol = max(0, min(1.0, volume + delta))
        volume = newVol
        isMuted = (newVol == 0)
        if let handle = playerHandle {
            dk_player_set_volume(handle, newVol, isMuted)
        }
        appState.showToast("音量: \(Int(newVol * 100))%", icon: newVol == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        showControlsAndResetTimer()
    }

    private func startNativeKernelPlayback(startSeconds: Double) {
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
            if srv.type == .uhdNative {
                await UHDStreamClient.shared.reportPlayback(server: srv, kind: .progress, item: itm, assetId: msId, positionSeconds: startSeconds)
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

    private func prefetchNextEpisodeIfNearEnd() {
        let livePos = autoHideBox.liveCurrentTime
        guard duration > 90, livePos >= max(duration * 0.72, duration - 120) else { return }
        guard let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
              session.episodesQueue.indices.contains(idx + 1) else {
            return
        }
        let nextEp = session.episodesQueue[idx + 1]
        if prefetchedNextEpisodeResource?.itemId == nextEp.id || prefetchedNextEpisodeInFlightId == nextEp.id {
            return
        }
        if DonbyDownloadManager.shared.completedEntry(for: nextEp.id, serverId: session.server.id) != nil {
            return
        }
        let server = session.server
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let preset = appState.preferredVersionPreset
        let audioIdx = selectedAudioIdx
        let enable302 = appState.enable302Cache
        let defer302 = appState.turboEnabled
        prefetchedNextEpisodeInFlightId = nextEp.id

        Task {
            let resolved: ResolvedPlaybackResource? = try? await {
                if server.type == .uhdNative {
                    return try await UHDStreamClient.shared.resolvePlaybackResource(
                        server: server,
                        item: nextEp,
                        preferredPreset: preset
                    )
                } else {
                    return try await EmbyClient.shared.resolvePlaybackResource(
                        server: server,
                        item: nextEp,
                        preferredPreset: preset,
                        audioStreamIndex: audioIdx,
                        subtitleStreamIndex: nil,
                        enable302Cache: enable302,
                        defer302ProbeWhenTurbo: defer302
                    )
                }
            }()
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

    private nonisolated static func makeRedirectStoreHandler(key: String) -> @Sendable (URL) -> Void {
        { finalURL in
            Task {
                await RedirectCacheStore.shared.storeRedirect(finalURL, for: key)
            }
        }
    }

    private func stopNativeKernel() {
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

    private func togglePlayPause() {
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
    }

    private func seekRelative(_ delta: Double) {
        let target = max(0, min(duration, autoHideBox.liveCurrentTime + delta))
        seekTo(target)
    }

    private func seekTo(_ seconds: Double, accurate: Bool = false) {
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
    }

    /// Weighted consensus for dual-subtitle timing & speaker-split anchor:
    /// - Native Chinese media (CJK OriginalTitle / non-dub Chinese audio) -> Chinese subtitle track is anchor.
    /// - All other media (English-native, Japanese/Korean/European, or unknown) -> English subtitle track is anchor.
    /// Returns: 0 = auto (kernel English-preferred fallback), 1 = primary track anchor, 2 = secondary track anchor.
    private func resolvedDualAnchorMode() -> Int32 {
        func isChineseTag(_ raw: String) -> Bool {
            let l = raw.lowercased()
            return l.contains("chi") || l.contains("zho") || l.contains("zh") ||
                   l.contains("cmn") || l.contains("yue") || l.contains("chs") || l.contains("cht") ||
                   l.contains("简") || l.contains("繁") || l.contains("中") || l.contains("国语") || l.contains("粤语")
        }
        func isEnglishTag(_ raw: String) -> Bool {
            let l = raw.lowercased()
            return l.contains("eng") || l.contains("english") || l.contains("英")
        }
        func isDubAudioTitle(_ raw: String) -> Bool {
            let l = raw.lowercased()
            return l.contains("国配") || l.contains("台配") || l.contains("粤配") ||
                   l.contains("配音") || l.contains("dub")
        }

        // 1. Metadata OriginalTitle script consensus (immune to dubbed remux audio track 0)
        var titleSaysChinese = false
        var titleSaysNonChinese = false
        if let orig = currentItem.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
            var cjk = 0, kana = 0, hangul = 0, latin = 0
            for scalar in orig.unicodeScalars {
                let v = scalar.value
                if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) {
                    cjk += 1
                } else if (v >= 0x3040 && v <= 0x30FF) {
                    kana += 1
                } else if (v >= 0xAC00 && v <= 0xD7AF) {
                    hangul += 1
                } else if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) {
                    latin += 1
                }
            }
            if cjk > 0 && kana == 0 && hangul == 0 && latin <= cjk {
                titleSaysChinese = true
            } else if kana > 0 || hangul > 0 || (latin > 0 && cjk == 0) {
                titleSaysNonChinese = true
            }
        }

        // 2. Active (or default) audio track language check (ignoring dubbed tracks)
        let audioStreams = !kernelAudioTracks.isEmpty
            ? kernelAudioTracks
            : (currentResource.mediaSource.mediaStreams?.filter { ($0.type ?? "").lowercased() == "audio" } ?? [])
        let activeAudio = audioStreams.first(where: { $0.index == activeAudioAVIndex })
            ?? audioStreams.first(where: { $0.isDefault == true })
            ?? audioStreams.first
        let audioLangTitle = [activeAudio?.language, activeAudio?.displayLanguage, activeAudio?.title, activeAudio?.displayTitle]
            .compactMap { $0 }.joined(separator: " ")
        let audioIsNonDubChinese = !audioLangTitle.isEmpty && isChineseTag(audioLangTitle) && !isDubAudioTitle(audioLangTitle)

        let preferChineseAnchor = titleSaysChinese || (!titleSaysNonChinese && audioIsNonDubChinese)

        // 3. Map preferred anchor language to primary (1) or secondary (2) slot
        let options = resolvedSubtitleOptions
        let priOpt = options.first(where: { $0.selection == activeSubtitleSelection })
        let secOpt = options.first(where: { $0.selection == activeSecondarySubtitleSelection })
        let priDesc = [priOpt?.language, priOpt?.label].compactMap { $0 }.joined(separator: " ")
        let secDesc = [secOpt?.language, secOpt?.label].compactMap { $0 }.joined(separator: " ")

        if preferChineseAnchor {
            if isChineseTag(priDesc) && !isEnglishTag(priDesc) { return 1 }
            if isChineseTag(secDesc) && !isEnglishTag(secDesc) { return 2 }
        } else {
            if isEnglishTag(secDesc) && !isChineseTag(secDesc) { return 2 }
            if isEnglishTag(priDesc) && !isChineseTag(priDesc) { return 1 }
        }
        return 0
    }

    nonisolated private static func makeKernelSubtitleStyleConfig(
        _ s: SubtitleStyleConfiguration,
        anchorMode: Int32
    ) -> DKSubtitleStyleConfig {
        DKSubtitleStyleConfig(
            scale: Float(s.scale),
            border_width: Float(s.borderWidth),
            vertical_pos_percent: Float(s.verticalPositionPercent),
            primary_delay_sec: s.primaryDelaySeconds,
            secondary_delay_sec: s.secondaryDelaySeconds,
            text_transform: Int32(s.transform.rawValue),
            override_ass_style: s.overrideASSStyle,
            forced_only: s.forcedOnly,
            unify_pingfang_font: s.unifyPingFangFont,
            enhance_secondary_yellow: s.enhanceSecondaryYellow,
            secondary_scale: Float(s.secondaryScale),
            dual_gap_px: Float(s.dualSubtitleGapPx),
            primary_on_top: s.primaryOnTop,
            dual_layout_mode: Int32(s.dualLayoutMode),
            dual_anchor_mode: anchorMode
        )
    }

    private func applyKernelSubtitleStyle() {
        guard let handle = playerHandle else { return }
        var cfg = Self.makeKernelSubtitleStyleConfig(appState.subtitleStyle, anchorMode: resolvedDualAnchorMode())
        dk_player_set_subtitle_style(handle, &cfg)
        subtitleStyleRevision &+= 1
    }

    private static func queryKernelChapters(handle: OpaquePointer) -> [PlaybackChapterItem] {
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

    private func evaluateIntroOutroSkipWindow() {
        guard duration > 60 else {
            skipBannerLabel = nil
            return
        }
        let pref = appState.effectiveSkipPreference(serverId: session.server.id, item: currentItem)
        let chapterIntroEnd = pref.chapterDetection
            ? ChapterSkipDetector.detectIntroEndSeconds(chapters: kernelChapters, duration: duration)
            : nil
        let chapterOutroStart = pref.chapterDetection
            ? ChapterSkipDetector.detectOutroStartSeconds(chapters: kernelChapters, duration: duration)
            : nil

        let introEnd: Double? = {
            guard pref.introEnabled else { return nil }
            if pref.hasUserMarkedIntro { return pref.introSeconds > 5 ? pref.introSeconds : nil }
            if let ch = chapterIntroEnd { return ch }
            return pref.introSeconds > 5 ? pref.introSeconds : nil
        }()

        let outroStart: Double? = {
            guard pref.outroEnabled else { return nil }
            if pref.hasUserMarkedOutro && pref.outroSeconds > 5 { return max(60, duration - pref.outroSeconds) }
            if let ch = chapterOutroStart { return ch }
            return pref.outroSeconds > 5 ? max(60, duration - pref.outroSeconds) : nil
        }()

        let hasNextEp: Bool = {
            if let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }) {
                return session.episodesQueue.indices.contains(idx + 1)
            }
            return false
        }()

        let livePos = autoHideBox.liveCurrentTime
        if let introEnd, livePos >= 1.5, livePos < introEnd - 1.5 {
            if pref.mode == .automatic && !didAutoSkipIntroForCurrentItem && session.startPositionSeconds < introEnd {
                didAutoSkipIntroForCurrentItem = true
                seekTo(introEnd)
                appState.showToast("已自动跳过片头 (\(formatTime(introEnd)))", icon: "forward.fill")
                skipBannerLabel = nil
                return
            }
            if !skipBannerIsOutro || skipBannerLabel != "跳过片头" {
                skipBannerLabel = "跳过片头"
                skipBannerTargetSec = introEnd
                skipBannerIsOutro = false
            }
            return
        }

        if let outroStart, livePos >= outroStart, livePos < duration - 2.0, hasNextEp {
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
            if skipBannerLabel != "跳过片尾 · 下一集" {
                skipBannerLabel = "跳过片尾 · 下一集"
                skipBannerTargetSec = duration
                skipBannerIsOutro = true
            }
            return
        }

        if skipBannerLabel != nil {
            skipBannerLabel = nil
        }
    }

    private func exportRedactedDiagnostics() {
        let appVer = DonbyAppInfo.version
        var lines: [String] = []
        lines.append("Donby Diagnostics Report (v\(appVer))")
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Server Type: \(session.server.type.rawValue) | Line: \(session.server.activeLineName)")
        lines.append("Item: \(currentItem.name) | Route: \(currentResource.routeNote)")
        lines.append("Stream URL: \(currentResource.streamURL.absoluteString)")
        lines.append("Decoder: \(kernelStats.is_hw_accelerated ? "VideoToolbox HW" : "Software") | \(kernelStats.width)x\(kernelStats.height) @ \(String(format: "%.3f", kernelStats.fps))fps")
        lines.append("HDR: DoVi=\(kernelStats.is_dolby_vision) HDR=\(kernelStats.is_hdr) | Codec: \(Self.cString(from: kernelStats.video_codec)) / \(Self.cString(from: kernelStats.audio_codec))")
        lines.append("Position: \(String(format: "%.2f", currentTime)) / \(String(format: "%.2f", duration)) | BufferedAhead: \(String(format: "%.2f", bufferedAheadSeconds))s | Turbo: \(activeTurboHandle != nil)")
        lines.append("Recent Logs:")
        let allLogs = DonbyLogger.shared.exportAllText().components(separatedBy: .newlines).suffix(80)
        lines.append(contentsOf: allLogs)

        let redacted = PlaybackDiagnosticsRedactor.redact(lines.joined(separator: "\n"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redacted, forType: .string)
        appState.showToast("已复制脱敏诊断报告到剪贴板", icon: "checkmark.shield.fill")
    }

    private static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            var length = 0
            while length < raw.count && base[length] != 0 {
                length += 1
            }
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
    }

    private static func queryKernelTracks(handle: OpaquePointer) -> (
        audio: [MediaStream],
        subtitles: [MediaStream],
        selectedAudioIndex: Int?,
        selectedSubIndex: Int?
    ) {
        var audios: [MediaStream] = []
        var selAudio: Int? = nil
        let aCount = dk_player_get_track_count(handle, 1)
        for ord in 0..<aCount {
            var info = DKTrackInfo()
            guard dk_player_get_track_info(handle, 1, ord, &info) else { continue }
            let idx = Int(info.stream_index)
            let codec = cString(from: info.codec)
            let lang = cString(from: info.language)
            let title = cString(from: info.title)
            let chLayout: String? = info.channels >= 8 ? "7.1" : (info.channels == 6 ? "5.1" : (info.channels > 0 ? "\(info.channels).0" : nil))
            if info.is_selected { selAudio = idx }
            audios.append(MediaStream(
                index: idx,
                type: "Audio",
                codec: codec.isEmpty ? nil : codec,
                language: lang.isEmpty ? nil : lang,
                title: title.isEmpty ? nil : title,
                isDefault: info.is_default,
                channels: Int(info.channels),
                channelLayout: chLayout
            ))
        }

        var subs: [MediaStream] = []
        var selSub: Int? = nil
        let sCount = dk_player_get_track_count(handle, 2)
        for ord in 0..<sCount {
            var info = DKTrackInfo()
            guard dk_player_get_track_info(handle, 2, ord, &info) else { continue }
            let idx = Int(info.stream_index)
            let codec = cString(from: info.codec)
                .replacingOccurrences(of: "hdmv_pgs_subtitle", with: "PGS")
                .replacingOccurrences(of: "subrip", with: "SRT")
            let lang = cString(from: info.language)
            let title = cString(from: info.title)
            if info.is_selected { selSub = idx }
            subs.append(MediaStream(
                index: idx,
                type: "Subtitle",
                codec: codec.isEmpty ? nil : codec,
                language: lang.isEmpty ? nil : lang,
                title: title.isEmpty ? nil : title,
                isDefault: info.is_default,
                isForced: info.is_forced
            ))
        }

        return (audios, subs, selAudio, selSub)
    }

    private func selectAudioOption(_ option: PlayerAudioTrackOption) {
        activeAudioAVIndex = option.avStreamIndex
        selectedAudioIdx = option.embyIndex ?? option.avStreamIndex
        if let handle = playerHandle {
            dk_player_select_track(handle, 1, Int32(option.avStreamIndex))
            applyKernelSubtitleStyle()
            activeTurboHandle?.wakeWaitingReads()
            appState.showToast("已切换音轨: \(option.label)", icon: "speaker.wave.2.fill")
        }
    }

    private func disableSubtitles(showFeedback: Bool, persist: Bool = true) {
        explicitSubtitleOff = true
        selectedSubIdx = nil
        activeSubtitleSelection = .off
        localExternalSubtitleName = nil
        if persist {
            appState.recordPrimarySubtitleChoice(
                serverId: session.server.id,
                item: currentItem,
                preference: .disabled,
                updateGlobal: false
            )
        }
        if let handle = playerHandle {
            dk_player_select_track(handle, 2, -1)
            if showFeedback {
                appState.showToast("已关闭字幕", icon: "captions.bubble")
            }
        }
    }

    private func applySubtitleOptionOnStartup(
        _ option: PlayerSubtitleTrackOption,
        handle: OpaquePointer,
        defaultSelectedAV: Int?,
        generation: Int,
        prefetchedExternalTask: Task<(url: URL, text: String, isAss: Bool)?, Never>? = nil
    ) {
        explicitSubtitleOff = false
        switch option.selection {
        case .off:
            activeSubtitleSelection = .off
            dk_player_select_track(handle, 2, -1)
        case .embedded(let avIdx):
            activeSubtitleSelection = .embedded(avStreamIndex: avIdx)
            selectedSubIdx = option.embyIndex ?? avIdx
            if defaultSelectedAV != avIdx {
                dk_player_select_track(handle, 2, Int32(avIdx))
            }
            applyKernelSubtitleStyle()
        case .remoteExternal(let extURL):
            if let preTask = prefetchedExternalTask {
                selectedSubIdx = option.embyIndex
                activeSubtitleSelection = .remoteExternal(url: extURL)
                let fallbackItem = option.externalItem
                let fallbackEmbyIdx = option.embyIndex
                Task { @MainActor in
                    let pre = await preTask.value
                    guard self.activePlaybackGeneration == generation,
                          let currentHandle = self.playerHandle,
                          case .remoteExternal(let curURL) = self.activeSubtitleSelection,
                          curURL == extURL else { return }
                    if let pre, pre.url == extURL {
                        dk_player_load_external_subtitle(currentHandle, pre.text, pre.isAss)
                        self.applyKernelSubtitleStyle()
                    } else if let fallbackItem {
                        self.loadRemoteExternalSubtitle(item: fallbackItem, embyStreamIndex: fallbackEmbyIdx, silentToast: true)
                    }
                }
            } else if let ext = option.externalItem {
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: true)
            }
        case .localExternal:
            break
        }
    }

    private func selectSubtitleOption(_ option: PlayerSubtitleTrackOption) {
        explicitSubtitleOff = false
        selectedSubIdx = option.embyIndex
        switch option.selection {
        case .off:
            disableSubtitles(showFeedback: true)
        case .embedded(let avIdx):
            localExternalSubtitleName = nil
            activeSubtitleSelection = .embedded(avStreamIndex: avIdx)
            appState.recordPrimarySubtitleChoice(
                serverId: session.server.id,
                item: currentItem,
                preference: option.toPreference()
            )
            if let handle = playerHandle {
                dk_player_select_track(handle, 2, Int32(avIdx))
                applyKernelSubtitleStyle()
                appState.showToast("已切换字幕: \(option.label)", icon: "captions.bubble.fill")
            }
        case .remoteExternal:
            if let ext = option.externalItem {
                localExternalSubtitleName = nil
                appState.recordPrimarySubtitleChoice(
                    serverId: session.server.id,
                    item: currentItem,
                    preference: option.toPreference()
                )
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: false)
            }
        case .localExternal:
            break
        }
    }

    private func secondarySubtitleStatusTitle(options: [PlayerSubtitleTrackOption]) -> String {
        switch activeSecondarySubtitleSelection {
        case .off:
            return "关闭副字幕"
        case .localExternal(let url):
            return "副: \(secondaryLocalSubtitleName ?? url.lastPathComponent)"
        default:
            if let matched = options.first(where: { $0.selection == activeSecondarySubtitleSelection }) {
                return "副: \(matched.label)"
            }
            return "关闭副字幕"
        }
    }

    private func disableSecondarySubtitle() {
        activeSecondarySubtitleSelection = .off
        secondaryLocalSubtitleName = nil
        secondarySubtitleTimeScale = 1.0
        isSecondaryAlignedToPrimary = false
        if appState.subtitleStyle.secondaryDelaySeconds != 0 {
            appState.subtitleStyle.secondaryDelaySeconds = 0
        }
        appState.recordSecondarySubtitleChoice(
            serverId: session.server.id,
            item: currentItem,
            preference: .disabled
        )
        if let handle = playerHandle {
            dk_player_select_secondary_subtitle_track(handle, -1)
        }
        appState.showToast("已关闭副字幕", icon: "captions.bubble")
    }

    private func selectSecondarySubtitleOption(_ option: PlayerSubtitleTrackOption) {
        switch option.selection {
        case .off:
            disableSecondarySubtitle()
        case .embedded(let avIdx):
            secondaryLocalSubtitleName = nil
            secondarySubtitleTimeScale = 1.0
            isSecondaryAlignedToPrimary = false
            if appState.subtitleStyle.secondaryDelaySeconds != 0 {
                appState.subtitleStyle.secondaryDelaySeconds = 0
            }
            activeSecondarySubtitleSelection = .embedded(avStreamIndex: avIdx)
            appState.recordSecondarySubtitleChoice(
                serverId: session.server.id,
                item: currentItem,
                preference: option.toPreference()
            )
            if let handle = playerHandle {
                dk_player_select_secondary_subtitle_track(handle, Int32(avIdx))
                applyKernelSubtitleStyle()
                appState.showToast("已开启双语副字幕: \(option.label)", icon: "captions.bubble.fill")
            }
        case .remoteExternal:
            if let ext = option.externalItem {
                appState.recordSecondarySubtitleChoice(
                    serverId: session.server.id,
                    item: currentItem,
                    preference: option.toPreference()
                )
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: false, asSecondary: true)
            }
        case .localExternal:
            break
        }
    }

    private func loadRemoteExternalSubtitle(
        item: SubtitleResourceItem,
        embyStreamIndex: Int?,
        silentToast: Bool,
        asSecondary: Bool = false
    ) {
        if asSecondary {
            activeSecondarySubtitleSelection = .remoteExternal(url: item.url)
        } else {
            selectedSubIdx = embyStreamIndex
            activeSubtitleSelection = .remoteExternal(url: item.url)
        }
        let expectedGeneration = activePlaybackGeneration
        let headers = currentResource.headers
        let url = item.url
        let label = item.name
        let ext = url.pathExtension.lowercased()
        Task.detached(priority: .userInitiated) {
            var req = URLRequest(url: url, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let decoded = SubtitleTextDecoder.decode(data: data, fileExtension: ext) else {
                await MainActor.run {
                    appState.showToast("下载外挂字幕失败", icon: "exclamationmark.triangle.fill", isError: true)
                }
                return
            }
            let text = decoded.text
            let isAss = (ext == "ass" || ext == "ssa" || text.contains("[Script Info]"))
            await MainActor.run {
                guard self.activePlaybackGeneration == expectedGeneration else { return }
                if let handle = self.playerHandle {
                    if asSecondary {
                        self.secondarySubtitleTimeScale = 1.0
                        self.isSecondaryAlignedToPrimary = false
                        dk_player_load_secondary_external_subtitle(handle, text, isAss)
                    } else {
                        dk_player_load_external_subtitle(handle, text, isAss)
                    }
                    self.applyKernelSubtitleStyle()
                    if !silentToast {
                        let prefix = asSecondary ? "已加载副字幕" : "已加载外挂字幕"
                        self.appState.showToast("\(prefix): \(label) (\(decoded.encoding.rawValue))", icon: "captions.bubble.fill")
                    }
                }
            }
        }
    }

    private func promptLocalExternalSubtitleFile(asSecondary: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = asSecondary ? "选择双语副字幕文件 (.srt / .ass / .ssa / .vtt)" : "选择外挂字幕文件 (.srt / .ass / .ssa / .vtt)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        for ext in ["srt", "ass", "ssa", "vtt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            loadLocalExternalSubtitleURL(url, asSecondary: asSecondary, silentToast: false, persist: true)
        }
    }

    private func loadLocalExternalSubtitleURL(
        _ url: URL,
        asSecondary: Bool,
        silentToast: Bool,
        persist: Bool
    ) {
        let ext = url.pathExtension.lowercased()
        guard let data = try? Data(contentsOf: url),
              let decoded = SubtitleTextDecoder.decode(data: data, fileExtension: ext) else {
            if !silentToast {
                appState.showToast("读取字幕文件失败", icon: "exclamationmark.triangle.fill", isError: true)
            }
            return
        }
        let text = decoded.text
        let isAss = (ext == "ass" || ext == "ssa" || text.contains("[Script Info]"))
        if let handle = playerHandle {
            if asSecondary {
                secondaryLocalSubtitleName = url.lastPathComponent
                secondarySubtitleTimeScale = 1.0
                isSecondaryAlignedToPrimary = false
                activeSecondarySubtitleSelection = .localExternal(url: url)
                dk_player_load_secondary_external_subtitle(handle, text, isAss)
            } else {
                explicitSubtitleOff = false
                selectedSubIdx = nil
                localExternalSubtitleName = url.lastPathComponent
                activeSubtitleSelection = .localExternal(url: url)
                dk_player_load_external_subtitle(handle, text, isAss)
            }
            applyKernelSubtitleStyle()
            if persist {
                let pref = SubtitleTrackPreference(
                    isDisabled: false,
                    language: nil,
                    titleHint: url.lastPathComponent,
                    codec: ext,
                    isExternal: true,
                    embyStreamIndex: nil,
                    localFilePath: url.path
                )
                if asSecondary {
                    appState.recordSecondarySubtitleChoice(serverId: session.server.id, item: currentItem, preference: pref, updateGlobal: false)
                } else {
                    appState.recordPrimarySubtitleChoice(serverId: session.server.id, item: currentItem, preference: pref, updateGlobal: false)
                }
            }
            if !silentToast {
                let tag = asSecondary ? "已加载本地副字幕" : "已加载本地字幕"
                appState.showToast("\(tag): \(url.lastPathComponent) (\(decoded.encoding.rawValue))", icon: "captions.bubble.fill")
            }
        }
    }

    private static func formatSubtitleDelay(_ seconds: Double) -> String {
        let roundedHalf = (seconds * 2.0).rounded() / 2.0
        if abs(seconds - roundedHalf) < 0.015 {
            return String(format: "%+.1fs", seconds)
        }
        return String(format: "%+.2fs", seconds)
    }

    private static func snapshotSubtitleIntervals(handle: OpaquePointer, isSecondary: Bool) -> [SubtitleCueInterval] {
        let count = Int(dk_player_get_subtitle_intervals(handle, isSecondary, nil, 0))
        guard count > 0 else { return [] }
        let capped = min(count, 50_000)
        var raw = [DKSubtitleInterval](repeating: DKSubtitleInterval(start_sec: 0, end_sec: 0), count: capped)
        let copied = Int(raw.withUnsafeMutableBufferPointer { buf in
            dk_player_get_subtitle_intervals(handle, isSecondary, buf.baseAddress, Int32(capped))
        })
        guard copied > 0 else { return [] }
        var out: [SubtitleCueInterval] = []
        out.reserveCapacity(copied)
        for i in 0..<copied {
            out.append(SubtitleCueInterval(startSeconds: raw[i].start_sec, endSeconds: raw[i].end_sec))
        }
        return out
    }

    private func runAutoAlignAudioToSubtitle() {
        guard let handle = playerHandle, !isAutoAligningSubtitle, activeSubtitleSelection != .off else { return }

        let availSamples = Int(dk_player_copy_recent_audio_16k(handle, nil, 0, nil))
        guard availSamples >= SileroVAD.sampleRate * 10 else {
            let sec = Double(availSamples) / Double(SileroVAD.sampleRate)
            DonbyLogger.shared.log(String(format: "字音对齐跳过: 可用音频仅 %.1fs (<10s)", sec), level: .warning, subsystem: "SubtitleAlign")
            appState.showToast("已捕获音频不足 10 秒，请播放一小段对白后再点字音对齐", icon: "waveform.badge.magnifyingglass", isError: true)
            return
        }
        var pcm = [Float](repeating: 0, count: availSamples)
        var audioStartPTS: Double = 0
        let copied = Int(pcm.withUnsafeMutableBufferPointer { buf in
            dk_player_copy_recent_audio_16k(handle, buf.baseAddress, Int32(availSamples), &audioStartPTS)
        })
        if copied < pcm.count { pcm.removeLast(pcm.count - max(0, copied)) }

        let primaryCues = Self.snapshotSubtitleIntervals(handle: handle, isSecondary: false)
        let secondaryCues = (activeSecondarySubtitleSelection != .off)
            ? Self.snapshotSubtitleIntervals(handle: handle, isSecondary: true)
            : []
        guard primaryCues.count >= 5 else {
            DonbyLogger.shared.log("字音对齐跳过: 可用主字幕仅 \(primaryCues.count) 条", level: .warning, subsystem: "SubtitleAlign")
            appState.showToast("当前窗口内可用字幕不足，请播放约 15 秒或使用外挂字幕后重试", icon: "captions.bubble", isError: true)
            return
        }

        let generation = activePlaybackGeneration
        let curPrimaryDelay = appState.subtitleStyle.primaryDelaySeconds
        let curSecondaryDelay = appState.subtitleStyle.secondaryDelaySeconds
        let curSecScale = secondarySubtitleTimeScale
        let prevAligned = isSecondaryAlignedToPrimary
        isAutoAligningSubtitle = true

        Task.detached(priority: .userInitiated) {
            do {
                let outcome = try SubtitleAutoAligner.alignAudioFirst(
                    pcm16k: pcm,
                    audioStartPTS: audioStartPTS,
                    primaryCues: primaryCues,
                    secondaryCues: secondaryCues,
                    currentPrimaryDelay: curPrimaryDelay,
                    currentSecondaryDelay: curSecondaryDelay,
                    currentSecondaryScale: curSecScale,
                    maxShiftSeconds: 30.0
                )
                await MainActor.run {
                    guard self.activePlaybackGeneration == generation else { return }
                    self.isAutoAligningSubtitle = false
                    guard let currentHandle = self.playerHandle else { return }
                    switch outcome {
                    case .applied(let plan):
                        DonbyLogger.shared.log("字音对齐完成: \(plan.diagnosticLog)", subsystem: "SubtitleAlign")
                        if !plan.alreadyAligned {
                            self.lastSubtitleAlignUndo = SubtitleAlignUndoState(
                                primaryDelay: curPrimaryDelay,
                                secondaryDelay: curSecondaryDelay,
                                secondaryTimeScale: curSecScale,
                                wasSecondaryAligned: prevAligned,
                                label: "字音对齐"
                            )
                            dk_player_set_secondary_subtitle_time_scale(currentHandle, plan.secondaryTimeScale)
                            self.secondarySubtitleTimeScale = plan.secondaryTimeScale
                            if !secondaryCues.isEmpty {
                                self.isSecondaryAlignedToPrimary = true
                            }
                            self.appState.subtitleStyle.primaryDelaySeconds = plan.primaryDelaySeconds
                            self.appState.subtitleStyle.secondaryDelaySeconds = plan.secondaryDelaySeconds
                            self.applyKernelSubtitleStyle()
                        }
                        self.lastAutoAlignSummary = plan.summaryMessage
                        self.appState.showToast(plan.summaryMessage, icon: "waveform.badge.magnifyingglass")
                    case .failed(let userMsg, let diag):
                        DonbyLogger.shared.log("字音对齐未应用: \(diag)", level: .warning, subsystem: "SubtitleAlign")
                        self.appState.showToast(userMsg, icon: "exclamationmark.triangle.fill", isError: true)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.activePlaybackGeneration == generation else { return }
                    self.isAutoAligningSubtitle = false
                    DonbyLogger.shared.log("字音对齐异常: \(error.localizedDescription)", level: .error, subsystem: "SubtitleAlign")
                    self.appState.showToast(error.localizedDescription, icon: "exclamationmark.triangle.fill", isError: true)
                }
            }
        }
    }

    private func runAutoAlignDualSubtitles() {
        guard let handle = playerHandle,
              !isAutoAligningSubtitle,
              activeSubtitleSelection != .off,
              activeSecondarySubtitleSelection != .off else { return }

        let primaryCues = Self.snapshotSubtitleIntervals(handle: handle, isSecondary: false)
        let secondaryCues = Self.snapshotSubtitleIntervals(handle: handle, isSecondary: true)
        guard primaryCues.count >= 5, secondaryCues.count >= 5 else {
            DonbyLogger.shared.log("双字对齐跳过: 主字幕 \(primaryCues.count) / 副字幕 \(secondaryCues.count)", level: .warning, subsystem: "SubtitleAlign")
            appState.showToast("已缓冲主/副字幕不足 (主 \(primaryCues.count) / 副 \(secondaryCues.count))，请播放约 15 秒后再试", icon: "captions.bubble", isError: true)
            return
        }

        // Also snapshot recent 16kHz audio so dual alignment validates which track matches the true audio!
        var pcm: [Float] = []
        var audioStartPTS: Double = 0
        let availSamples = Int(dk_player_copy_recent_audio_16k(handle, nil, 0, nil))
        if availSamples >= SileroVAD.sampleRate * 10 {
            pcm = [Float](repeating: 0, count: availSamples)
            let copied = Int(pcm.withUnsafeMutableBufferPointer { buf in
                dk_player_copy_recent_audio_16k(handle, buf.baseAddress, Int32(availSamples), &audioStartPTS)
            })
            if copied < pcm.count { pcm.removeLast(pcm.count - max(0, copied)) }
        }

        let generation = activePlaybackGeneration
        let curPrimaryDelay = appState.subtitleStyle.primaryDelaySeconds
        let curSecondaryDelay = appState.subtitleStyle.secondaryDelaySeconds
        let curSecScale = secondarySubtitleTimeScale
        let prevAligned = isSecondaryAlignedToPrimary
        isAutoAligningSubtitle = true

        Task.detached(priority: .userInitiated) {
            let outcome = SubtitleAutoAligner.alignDualAudioAnchored(
                primaryCues: primaryCues,
                secondaryCues: secondaryCues,
                pcm16k: pcm,
                audioStartPTS: audioStartPTS,
                currentPrimaryDelay: curPrimaryDelay,
                currentSecondaryDelay: curSecondaryDelay,
                currentSecondaryScale: curSecScale,
                maxShiftSeconds: 120.0
            )
            await MainActor.run {
                guard self.activePlaybackGeneration == generation else { return }
                self.isAutoAligningSubtitle = false
                guard let currentHandle = self.playerHandle else { return }
                switch outcome {
                case .applied(let plan):
                    DonbyLogger.shared.log("双字对齐完成: \(plan.diagnosticLog)", subsystem: "SubtitleAlign")
                    if !plan.alreadyAligned {
                        self.lastSubtitleAlignUndo = SubtitleAlignUndoState(
                            primaryDelay: curPrimaryDelay,
                            secondaryDelay: curSecondaryDelay,
                            secondaryTimeScale: curSecScale,
                            wasSecondaryAligned: prevAligned,
                            label: "双字对齐"
                        )
                        dk_player_set_secondary_subtitle_time_scale(currentHandle, plan.secondaryTimeScale)
                        self.secondarySubtitleTimeScale = plan.secondaryTimeScale
                        self.isSecondaryAlignedToPrimary = true
                        self.appState.subtitleStyle.primaryDelaySeconds = plan.primaryDelaySeconds
                        self.appState.subtitleStyle.secondaryDelaySeconds = plan.secondaryDelaySeconds
                        self.applyKernelSubtitleStyle()
                    }
                    self.lastAutoAlignSummary = plan.summaryMessage
                    self.appState.showToast(plan.summaryMessage, icon: "arrow.left.arrow.right")
                case .failed(let userMsg, let diag):
                    DonbyLogger.shared.log("双字对齐未应用: \(diag)", level: .warning, subsystem: "SubtitleAlign")
                    self.appState.showToast(userMsg, icon: "exclamationmark.triangle.fill", isError: true)
                }
            }
        }
    }

    private func undoLastSubtitleAlignment() {
        guard let undo = lastSubtitleAlignUndo else { return }
        lastSubtitleAlignUndo = nil
        lastAutoAlignSummary = nil
        secondarySubtitleTimeScale = undo.secondaryTimeScale
        isSecondaryAlignedToPrimary = undo.wasSecondaryAligned
        appState.subtitleStyle.primaryDelaySeconds = undo.primaryDelay
        appState.subtitleStyle.secondaryDelaySeconds = undo.secondaryDelay
        if let handle = playerHandle {
            dk_player_set_secondary_subtitle_time_scale(handle, undo.secondaryTimeScale)
            applyKernelSubtitleStyle()
        }
        appState.showToast("已撤销\(undo.label)", icon: "arrow.uturn.backward")
    }

    private func resetSecondarySubtitleTimeScale() {
        secondarySubtitleTimeScale = 1.0
        if let handle = playerHandle {
            dk_player_set_secondary_subtitle_time_scale(handle, 1.0)
            applyKernelSubtitleStyle()
        }
        lastAutoAlignSummary = "副字幕速率已重置为 1.0000x"
        appState.showToast("副字幕速率已重置为 1.0x", icon: "arrow.counterclockwise")
    }

    private func playAdjacentEpisode(offset: Int) {
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
        return duration > 60 && currentTime > 0 && (currentTime / duration) >= 0.92
    }

    private func switchToEpisode(_ nextEp: EmbyItem) {
        episodeSwitchTask?.cancel()
        let server = session.server
        let preset = appState.preferredVersionPreset
        let audioIdx = selectedAudioIdx
        let enable302 = appState.enable302Cache
        let prevItem = currentItem
        let prevSourceId = currentResource.mediaSource.id
        let prevSessionId = currentResource.playSessionId
        let prevPos = currentTime
        let prevWasFinished = isCurrentPlaybackConsideredFinished()
        finishedItemPendingCleanup = nil
        saveCurrentWatchProgress(isFinal: true)
        episodeSwitchTask = Task {
            do {
                let res: ResolvedPlaybackResource
                if let cachedNext = prefetchedNextEpisodeResource, cachedNext.itemId == nextEp.id {
                    res = cachedNext.resource
                } else if let offlineEntry = DonbyDownloadManager.shared.completedEntry(
                    for: nextEp.id,
                    serverId: server.id
                ) ?? DonbyDownloadManager.shared.completedEntry(for: nextEp.id),
                   let offlineRes = DonbyDownloadManager.shared.offlinePlayableResource(for: offlineEntry) {
                    res = offlineRes
                } else if server.type == .uhdNative {
                    res = try await UHDStreamClient.shared.resolvePlaybackResource(
                        server: server,
                        item: nextEp,
                        preferredPreset: preset
                    )
                } else {
                    res = try await EmbyClient.shared.resolvePlaybackResource(
                        server: server,
                        item: nextEp,
                        preferredPreset: preset,
                        audioStreamIndex: audioIdx,
                        subtitleStreamIndex: nil,
                        enable302Cache: enable302,
                        defer302ProbeWhenTurbo: appState.turboEnabled
                    )
                }
                guard !Task.isCancelled else { return }
                if !server.host.isEmpty && !server.accessToken.isEmpty {
                    Task {
                        if server.type == .uhdNative {
                            await UHDStreamClient.shared.reportPlayback(server: server, kind: .stopped, item: prevItem, assetId: prevSourceId, positionSeconds: prevPos)
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
                appState.updateDetailFocusedEpisodeIfActive(forItem: nextEp)
                startNativeKernelPlayback(startSeconds: nextEp.resumePositionSeconds)
                if prevWasFinished {
                    appState.cleanupAutoArchivedEntryIfFinished(itemId: prevItem.id, mediaSourceId: prevSourceId)
                }
            } catch {
                guard !Task.isCancelled else { return }
                episodeSwitchTask = nil
                appState.showToast("切换剧集失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    private func exitPlayer() {
        autoHideBox.autoHideTask?.cancel()
        if let mm = mouseMonitor { NSEvent.removeMonitor(mm); mouseMonitor = nil }
        if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }

        let exitingItemId = currentItem.id
        let exitingSourceId = currentResource.mediaSource.id
        let wasOpenedSuccessfully = (!isOpeningMedia && openingErrorMessage == nil && playerHandle != nil)
        let exitingWasFinished = wasOpenedSuccessfully && isCurrentPlaybackConsideredFinished()
        finishedItemPendingCleanup = nil

        if wasOpenedSuccessfully {
            saveCurrentWatchProgress(isFinal: true)

            if !session.server.host.isEmpty && !session.server.accessToken.isEmpty {
                let srv = session.server
                let itm = currentItem
                let msId = currentResource.mediaSource.id
                let psId = currentResource.playSessionId
                let pos = currentTime
                Task {
                    if srv.type == .uhdNative {
                        await UHDStreamClient.shared.reportPlayback(server: srv, kind: .stopped, item: itm, assetId: msId, positionSeconds: pos)
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
        stopNativeKernel()
        if exitingWasFinished {
            appState.cleanupAutoArchivedEntryIfFinished(itemId: exitingItemId, mediaSourceId: exitingSourceId)
        }
        appState.activePlayback = nil
    }

    private func saveCurrentWatchProgress(isFinal: Bool = false) {
        let livePos = autoHideBox.liveCurrentTime
        guard duration > 0 || livePos > 0 else { return }

        let isLocal = currentResource.streamURL.isFileURL ||
                      currentResource.streamURL.scheme == "file" ||
                      currentResource.streamURL.path.hasPrefix("/")
        let isEmby = !isLocal && !session.server.host.isEmpty && session.server.host != "127.0.0.1" && session.server.host != "local"

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
            posterURL: isEmby ? EmbyClient.shared.imageURL(server: session.server, item: currentItem, kind: .primary, maxWidth: 320)?.absoluteString : nil,
            position: livePos,
            duration: duration > 0 ? duration : 3600,
            sourceType: resolvedSourceType,
            streamURLString: streamStr,
            embyItemId: embyId,
            resolutionTag: isLocal ? (kernelStats.is_hw_accelerated ? "本地 4K" : "本地文件") : (kernelStats.is_hw_accelerated ? "HW 4K" : "4K UHD")
        )

        DonbyDownloadManager.shared.updateOfflinePlaybackProgress(
            itemId: currentItem.id,
            played: nil,
            positionSeconds: livePos,
            durationSeconds: duration,
            persistDiskNow: isFinal
        )

        if isFinal {
            appState.flushWatchHistory()
        }
    }

    private var playerStreamMetaSubtitle: String {
        var parts: [String] = []
        if kernelStats.width > 0 && kernelStats.height > 0 {
            if kernelStats.width >= 3800 || kernelStats.height >= 2100 { parts.append("4K UHD") }
            else if kernelStats.width >= 1900 || kernelStats.height >= 1000 { parts.append("1080P") }
            else { parts.append("\(kernelStats.width)×\(kernelStats.height)") }
        } else if let res = currentItem.resolutionBadge {
            parts.append(res)
        }

        let vCodec = Self.cString(from: kernelStats.video_codec)
        if !vCodec.isEmpty && vCodec != "Unknown" {
            parts.append(vCodec.uppercased())
        } else if let tag = currentItem.videoCodecTag {
            parts.append(tag)
        }

        if kernelStats.is_dolby_vision {
            parts.append("Dolby Vision")
        } else if kernelStats.is_hdr {
            parts.append("HDR10")
        }

        if let audioTag = currentItem.audioSummaryTag {
            parts.append(audioTag)
        }

        if !session.server.host.isEmpty {
            parts.append("线路: \(session.server.activeLineName)")
        } else if currentResource.isDirectStream {
            parts.append("原画直链")
        } else {
            parts.append("Emby 直连")
        }

        return parts.isEmpty ? "正在播放" : parts.joined(separator: " · ")
    }

    private func updateClock() {
        let formatted = Self.clockFormatter.string(from: Date())
        if systemClockString != formatted {
            systemClockString = formatted
        }
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec >= 0 else { return "00:00" }
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

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
    @State private var autoHideTask: Task<Void, Never>? = nil
    @State private var mouseMonitor: Any? = nil
    @State private var keyMonitor: Any? = nil
    @State private var lastRecordedPosition: Double = -10
    @State private var lastMouseMoveTimestamp: TimeInterval = 0
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
    @State private var skipBannerLabel: String? = nil
    @State private var skipBannerTargetSec: Double = 0
    @State private var skipBannerIsOutro: Bool = false
    @State private var didAutoSkipIntroForCurrentItem: Bool = false
    @State private var didAutoSkipOutroForCurrentItem: Bool = false
    @State private var finishedItemPendingCleanup: (itemId: String, mediaSourceId: String)? = nil

    private let progressTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let embySyncTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

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
                controlsOcclusionHeight: showControls ? bottomControlBarHeight : 0,
                subtitleHDRPeakNits: Float(appState.subtitleStyle.hdrPeakNits.rawValue),
                antiOcclusionEnabled: appState.subtitleStyle.antiOcclusionEnabled
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
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showControls.toggle()
                        }
                        if showControls {
                            showControlsAndResetTimer()
                        } else {
                            autoHideTask?.cancel()
                        }
                    }
                }

            if isOpeningMedia {
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
                                startNativeKernelPlayback(startSeconds: currentTime)
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
                        .onContinuousHover { _ in autoHideTask?.cancel() }
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
                if event.type != .mouseMoved || now - lastMouseMoveTimestamp > 0.08 {
                    lastMouseMoveTimestamp = now
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
            autoHideTask?.cancel()
            if let mm = mouseMonitor { NSEvent.removeMonitor(mm); mouseMonitor = nil }
            if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }
            stopNativeKernel()
        }
        .onReceive(progressTimer) { _ in
            updateClock()
            guard let handle = playerHandle, !isScrubbing else { return }
            let newPos = dk_player_get_position(handle)
            if abs(currentTime - newPos) > 0.05 {
                currentTime = newPos
            }
            let newBuffered = dk_player_get_buffered_duration(handle)
            if abs(bufferedAheadSeconds - newBuffered) > 0.25 {
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
                finishedItemPendingCleanup = (currentItem.id, currentResource.mediaSource.id)
                if session.server.type == .uhdNative && !session.server.accessToken.isEmpty {
                    let srv = session.server
                    let itm = currentItem
                    let assetId = currentResource.mediaSource.id
                    let endPos = currentTime
                    Task {
                        await UHDStreamClient.shared.reportPlayback(server: srv, kind: .finished, item: itm, assetId: assetId, positionSeconds: endPos)
                    }
                } else if !session.server.host.isEmpty && !session.server.accessToken.isEmpty {
                    let srv = session.server
                    let itm = currentItem
                    let assetId = currentResource.mediaSource.id
                    let psId = currentResource.playSessionId
                    let endPos = currentTime
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
                position: currentTime,
                bufferedAhead: bufferedAheadSeconds,
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
                DonbyLogger.shared.log("触发播放卡顿自动恢复 at \(String(format: "%.1fs", currentTime))", level: .warning, subsystem: "PlaybackHealth")
                appState.showToast("缓冲停滞，正在自动重连当前位置...", icon: "arrow.clockwise")
                startNativeKernelPlayback(startSeconds: currentTime)
                return
            case .fail(let reason):
                isPlaying = false
                openingErrorMessage = "媒体流连续恢复失败，请尝试切换线路 (\(reason))"
                DonbyLogger.shared.log("播放健康检查终止: \(reason)", level: .error, subsystem: "PlaybackHealth")
                return
            }

            // Intro / outro chapter + per-season skip detector
            evaluateIntroOutroSkipWindow()

            // Update watch history periodically (every 5s) to avoid UI frame drops
            if abs(currentTime - lastRecordedPosition) >= 5.0 {
                lastRecordedPosition = currentTime
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
            activeTurboHandle?.updateTuning(connectionBudget: budget, prefetchAheadChunks: 12)
        }
        .onReceive(embySyncTimer) { _ in
            guard !session.server.host.isEmpty && !session.server.accessToken.isEmpty else { return }
            if session.server.type == .uhdNative {
                let srv = session.server
                let itm = currentItem
                let assetId = currentResource.mediaSource.id
                let pos = currentTime
                Task {
                    await UHDStreamClient.shared.reportPlayback(server: srv, kind: .progress, item: itm, assetId: assetId, positionSeconds: pos)
                }
            } else {
                Task {
                    await EmbyClient.shared.reportPlaybackProgress(
                        server: session.server,
                        itemId: currentItem.id,
                        mediaSourceId: currentResource.mediaSource.id,
                        playSessionId: currentResource.playSessionId,
                        positionSeconds: currentTime,
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
        let h = kernelStats.height > 0 ? kernelStats.height : Int32(currentItem.primaryVideoStream?.height ?? 0)
        if h >= 2000 { return "2160P" }
        if h >= 1400 { return "1440P" }
        if h >= 1000 { return "1080P" }
        if h >= 700  { return "720P" }
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
                HStack(spacing: 14) {
                    Button { playAdjacentEpisode(offset: -1) } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.episodesQueue.count > 1 ? .white : .white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(session.episodesQueue.count <= 1)
                    .help("上一集")

                    Button { seekRelative(-10) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("快退 10 秒")

                    Button { togglePlayPause() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "暂停 (空格)" : "播放 (空格)")

                    Button { seekRelative(10) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("快进 10 秒")

                    Button { playAdjacentEpisode(offset: 1) } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.episodesQueue.count > 1 ? .white : .white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(session.episodesQueue.count <= 1)
                    .help("下一集")

                    Text(formatTime(isScrubbing ? scrubTime : currentTime))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(minWidth: 46, alignment: .leading)
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
                HStack(spacing: 12) {
                    Button { showRemainingTime.toggle() } label: {
                        Text(showRemainingTime ? "-\(formatTime(max(0, duration - currentTime)))" : formatTime(duration))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(minWidth: 46, alignment: .trailing)
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
        Button("打开高级音轨面板...") {
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
        Divider()
        Button("加载本地字幕文件 (.srt / .ass)...") {
            promptLocalExternalSubtitleFile(asSecondary: false)
        }
        Button("打开字幕样式与双语面板...") {
            withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = .tracks }
        }
    }

    @ViewBuilder
    private var decoderMenuContent: some View {
        Section("流媒体规格") {
            Text("解码: \(kernelStats.is_hw_accelerated ? "VideoToolbox 硬件解码" : "CPU 软件解码")")
            Text("动态范围: \(kernelStats.is_dolby_vision ? "Dolby Vision" : (kernelStats.is_hdr ? "HDR10" : "SDR"))")
            Text("分辨率: \(specResolutionString)")
            Text("帧率: \(specFpsString)")
            if let br = specBitrateString {
                Text("码率: \(br)")
            }
        }
        Divider()
        Section("解码与线路控制") {
            Button(appState.enableHardwareDecode ? "切换为 CPU 软件解码" : "启用 Apple 硬件加速解码") {
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

    private func rightDrawerPanel(tab: PlayerDrawerTab) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: Binding(get: { tab }, set: { activeDrawer = $0 })) {
                    ForEach(PlayerDrawerTab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)

                Button { withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.2)

            ScrollView {
                switch tab {
                case .playlist:
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(session.episodesQueue.enumerated()), id: \.offset) { _, ep in
                            let isCurrent = ep.id == currentItem.id
                            Button { switchToEpisode(ep) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isCurrent ? "play.circle.fill" : "film")
                                        .foregroundStyle(isCurrent ? appState.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ep.episodeCodeString != nil ? "\(ep.episodeCodeString!) · \(ep.name)" : ep.name)
                                            .font(.system(size: 12.5, weight: isCurrent ? .bold : .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        if let rt = ep.runtimeMinutesString {
                                            Text(rt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(isCurrent ? appState.accentColor.opacity(0.22) : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                case .tracks:
                    VStack(alignment: .leading, spacing: 16) {
                        let audioOptions = resolvedAudioOptions
                        let subOptions = resolvedSubtitleOptions

                        Text("音频轨道").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        if audioOptions.isEmpty {
                            Text("未检测到可用音轨").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(audioOptions) { option in
                            let isSel = (activeAudioAVIndex == option.avStreamIndex)
                            Button {
                                selectAudioOption(option)
                            } label: {
                                HStack {
                                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle").foregroundStyle(isSel ? appState.accentColor : .secondary)
                                    Text(option.label).font(.system(size: 12, weight: isSel ? .semibold : .regular)).foregroundStyle(.white)
                                    Spacer()
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSel ? appState.accentColor.opacity(0.88) : Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(isSel ? Color.white.opacity(0.25) : Color.white.opacity(0.08), lineWidth: 0.6)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Text("字幕轨道").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
                        Button {
                            disableSubtitles(showFeedback: true)
                        } label: {
                            HStack {
                                let isOff = (activeSubtitleSelection == .off)
                                Image(systemName: isOff ? "checkmark.circle.fill" : "circle").foregroundStyle(isOff ? appState.accentColor : .secondary)
                                Text("关闭字幕").font(.system(size: 12, weight: isOff ? .semibold : .regular)).foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(activeSubtitleSelection == .off ? appState.accentColor.opacity(0.88) : Color.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(activeSubtitleSelection == .off ? Color.white.opacity(0.25) : Color.white.opacity(0.08), lineWidth: 0.6)
                                    )
                            )
                        }
                        .buttonStyle(.plain)

                        ForEach(subOptions) { option in
                            let isSel = (activeSubtitleSelection == option.selection)
                            Button {
                                selectSubtitleOption(option)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle").foregroundStyle(isSel ? appState.accentColor : .secondary)
                                    Text(option.label)
                                        .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    Spacer()
                                    if let badge = option.badge, !badge.isEmpty {
                                        Text(badge)
                                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.14))
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSel ? appState.accentColor.opacity(0.88) : Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(isSel ? Color.white.opacity(0.25) : Color.white.opacity(0.08), lineWidth: 0.6)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            promptLocalExternalSubtitleFile(asSecondary: false)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus").font(.system(size: 12, weight: .semibold))
                                Text("加载本地外挂字幕 (.srt / .ass / .vtt)...").font(.system(size: 12, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(appState.accentColor)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                                    )
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().opacity(0.2)

                        Text("副字幕 / 双语对照").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        Menu {
                            Button("关闭副字幕") { disableSecondarySubtitle() }
                            Divider()
                            ForEach(subOptions) { opt in
                                Button(opt.label) { selectSecondarySubtitleOption(opt) }
                            }
                            Divider()
                            Button("加载本地副字幕文件...") { promptLocalExternalSubtitleFile(asSecondary: true) }
                        } label: {
                            HStack {
                                Image(systemName: "captions.bubble")
                                Text(secondarySubtitleStatusTitle(options: subOptions))
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                            }
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        Divider().opacity(0.2)

                        Text("字幕实时调节与 HDR 校准").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 10) {
                            Picker("简繁转换", selection: $appState.subtitleStyle.transform) {
                                ForEach(SubtitleTextTransform.allCases) { tf in
                                    Text(tf.shortTitle).tag(tf)
                                }
                            }
                            .pickerStyle(.segmented)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(format: "缩放 %.2fx · 位置 %d%%", appState.subtitleStyle.scale, Int(appState.subtitleStyle.verticalPositionPercent)))
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                                Slider(value: $appState.subtitleStyle.scale, in: 0.6...1.8, step: 0.05)
                                Slider(value: $appState.subtitleStyle.verticalPositionPercent, in: 60...100, step: 1)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(format: "描边宽度 %.1f", appState.subtitleStyle.borderWidth))
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                                Slider(value: $appState.subtitleStyle.borderWidth, in: 0...6, step: 0.25)
                            }

                            HStack {
                                Text("主延迟 \(String(format: "%.1fs", appState.subtitleStyle.primaryDelaySeconds))")
                                    .font(.system(size: 11))
                                Spacer()
                                Button("-0.5s") { appState.subtitleStyle.primaryDelaySeconds = max(-30, appState.subtitleStyle.primaryDelaySeconds - 0.5) }.controlSize(.mini)
                                Button("0") { appState.subtitleStyle.primaryDelaySeconds = 0 }.controlSize(.mini)
                                Button("+0.5s") { appState.subtitleStyle.primaryDelaySeconds = min(30, appState.subtitleStyle.primaryDelaySeconds + 0.5) }.controlSize(.mini)
                            }

                            HStack {
                                Text("副延迟 \(String(format: "%.1fs", appState.subtitleStyle.secondaryDelaySeconds))")
                                    .font(.system(size: 11))
                                Spacer()
                                Button("-0.5s") { appState.subtitleStyle.secondaryDelaySeconds = max(-30, appState.subtitleStyle.secondaryDelaySeconds - 0.5) }.controlSize(.mini)
                                Button("0") { appState.subtitleStyle.secondaryDelaySeconds = 0 }.controlSize(.mini)
                                Button("+0.5s") { appState.subtitleStyle.secondaryDelaySeconds = min(30, appState.subtitleStyle.secondaryDelaySeconds + 0.5) }.controlSize(.mini)
                            }

                            Picker("HDR 亮度", selection: $appState.subtitleStyle.hdrPeakNits) {
                                ForEach(SubtitleHDRPeakNits.allCases) { nits in
                                    Text(nits.title).tag(nits)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("覆盖内封 ASS 样式", isOn: $appState.subtitleStyle.overrideASSStyle)
                            Toggle("仅保留强制字幕 (Forced)", isOn: $appState.subtitleStyle.forcedOnly)
                            Toggle("控制栏防遮挡平滑上移", isOn: $appState.subtitleStyle.antiOcclusionEnabled)
                        }
                        .font(.system(size: 11.5))
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                case .mediaInfo:
                    VStack(alignment: .leading, spacing: 10) {
                        osdInfoRow("解码方式", kernelStats.is_hw_accelerated ? "Apple VideoToolbox 硬件解码" : "CPU 软件解码")
                        osdInfoRow("动态范围", kernelStats.is_dolby_vision ? "Dolby Vision" : (kernelStats.is_hdr ? "HDR10" : "SDR"))
                        osdInfoRow("实时下载速率", String(format: "%.1f MB/s", max(0.0, displayDownloadSpeedMBs)))
                        osdInfoRow("超前缓冲时长", String(format: "+%.1f 秒", bufferedAheadSeconds))
                        osdInfoRow("流预读缓存", "\(kernelStats.cached_bytes / 1024 / 1024) MB")
                        osdInfoRow("传输引擎", activeTurboHandle != nil ? "Turbo Range (\(appState.effectiveConnectionBudget(for: session.server)) 线程)" : "原生顺序读取")
                        osdInfoRow("分辨率", "\(kernelStats.width) × \(kernelStats.height)")
                        osdInfoRow("帧率", String(format: "%.3f fps", kernelStats.fps))
                        osdInfoRow("视频编码", Self.cString(from: kernelStats.video_codec))
                        osdInfoRow("音频编码", Self.cString(from: kernelStats.audio_codec))
                        osdInfoRow("播放线路", session.server.activeLineName)

                        Divider().opacity(0.2).padding(.vertical, 4)

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
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showLogSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "terminal.fill")
                                Text("查看运行日志 (快捷键 L)")
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(appState.accentColor)
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.black.opacity(0.58))
                Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
            }
        )
    }

    private func osdInfoRow(_ key: String, _ val: String) -> some View {
        HStack {
            Text(key).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(val).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private func showControlsAndResetTimer() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls = true
            }
        }
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    if activeDrawer == nil && !isScrubbing && !isOpeningMedia && openingErrorMessage == nil {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showControls = false
                        }
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
        kernelChapters = []
        skipBannerLabel = nil
        didAutoSkipIntroForCurrentItem = false
        didAutoSkipOutroForCurrentItem = false
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
        let openBox = OpeningPlayerBox()
        self.openingBox = openBox

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
            preparedTurboHandle = TurboStreamByteHandle(
                assetKey: assetKey,
                streamURL: currentResource.streamURL,
                headers: currentResource.headers,
                store: store,
                knownTotalSize: currentResource.mediaSource.size,
                connectionBudget: budget,
                prefetchAheadChunks: max(12, Int(appState.turboPrefetchSeconds * 0.6))
            )
        } else {
            preparedTurboHandle = nil
        }
        self.activeTurboHandle = preparedTurboHandle

        DonbyLogger.shared.log("启动原生播放内核 (URL: \(PlaybackDiagnosticsRedactor.redact(urlStr)), Turbo: \(preparedTurboHandle != nil))", level: .info, subsystem: "Player")

        Task.detached(priority: .userInitiated) {
            let handle = dk_player_create()
            guard let handle else {
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
                preparedTurboHandle?.close()
                dk_player_destroy(handle)
                return
            }
            dk_player_set_buffer_limit_mb(handle, cachePoolMB)
            if let turboHandle = preparedTurboHandle {
                let opaque = Unmanaged.passRetained(turboHandle).toOpaque()
                dk_player_set_custom_io(handle, opaque, dkTurboReadCB, dkTurboSeekCB, dkTurboAbortCB, dkTurboCloseCB)
            }
            let ret = dk_player_open(handle, urlStr, headersStr, startSeconds, hwDecode)
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
                        self.applySubtitleOptionOnStartup(matchedOpt, handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex)
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
                        self.applySubtitleOptionOnStartup(subOpts[matchedIdx], handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex)
                    } else if let autoSub = discovered.selectedSubIndex {
                        self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                    } else if let fallbackIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: candidates) {
                        self.applySubtitleOptionOnStartup(subOpts[fallbackIdx], handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex)
                    } else {
                        self.activeSubtitleSelection = .off
                    }
                } else if let autoSub = discovered.selectedSubIndex {
                    self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                } else if let fallbackIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: candidates) {
                    self.applySubtitleOptionOnStartup(subOpts[fallbackIdx], handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex)
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

    private func stopNativeKernel() {
        activePlaybackGeneration &+= 1
        openingBox?.abort()
        openingBox = nil
        activeTurboHandle?.abort()
        activeTurboHandle?.close()
        activeTurboHandle = nil
        episodeSwitchTask?.cancel()
        episodeSwitchTask = nil
        displayDownloadSpeedMBs = 0.0
        bufferedAheadSeconds = 0
        skipBannerLabel = nil
        guard let handle = playerHandle else { return }
        self.playerHandle = nil
        dk_player_request_abort(handle)
        Task.detached(priority: .userInitiated) {
            dk_player_close(handle)
            dk_player_destroy(handle)
        }
    }

    private func togglePlayPause() {
        guard let handle = playerHandle else { return }
        if dk_player_get_state(handle) == DK_STATE_ENDED {
            didHandlePlaybackEnded = false
            finishedItemPendingCleanup = nil
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
        let target = max(0, min(duration, currentTime + delta))
        seekTo(target)
    }

    private func seekTo(_ seconds: Double) {
        didHandlePlaybackEnded = false
        seekGeneration += 1
        currentTime = seconds
        if let handle = playerHandle {
            dk_player_seek(handle, seconds, true)
        }
    }

    private func applyKernelSubtitleStyle() {
        guard let handle = playerHandle else { return }
        let s = appState.subtitleStyle
        var cfg = DKSubtitleStyleConfig(
            scale: Float(s.scale),
            border_width: Float(s.borderWidth),
            vertical_pos_percent: Float(s.verticalPositionPercent),
            primary_delay_sec: s.primaryDelaySeconds,
            secondary_delay_sec: s.secondaryDelaySeconds,
            text_transform: Int32(s.transform.rawValue),
            override_ass_style: s.overrideASSStyle,
            forced_only: s.forcedOnly
        )
        dk_player_set_subtitle_style(handle, &cfg)
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

        if let introEnd, currentTime >= 1.5, currentTime < introEnd - 1.5 {
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

        if let outroStart, currentTime >= outroStart, currentTime < duration - 2.0, hasNextEp {
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
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.25"
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

    private func applySubtitleOptionOnStartup(_ option: PlayerSubtitleTrackOption, handle: OpaquePointer, defaultSelectedAV: Int?) {
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
        case .remoteExternal:
            if let ext = option.externalItem {
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
                if let offlineEntry = DonbyDownloadManager.shared.completedEntry(
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
                        enable302Cache: enable302
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
        autoHideTask?.cancel()
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

        stopNativeKernel()
        if exitingWasFinished {
            appState.cleanupAutoArchivedEntryIfFinished(itemId: exitingItemId, mediaSourceId: exitingSourceId)
        }
        appState.activePlayback = nil
    }

    private func saveCurrentWatchProgress(isFinal: Bool = false) {
        guard duration > 0 || currentTime > 0 else { return }

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
            position: currentTime,
            duration: duration > 0 ? duration : 3600,
            sourceType: resolvedSourceType,
            streamURLString: streamStr,
            embyItemId: embyId,
            resolutionTag: isLocal ? (kernelStats.is_hw_accelerated ? "本地 4K" : "本地文件") : (kernelStats.is_hw_accelerated ? "HW 4K" : "4K UHD")
        )

        DonbyDownloadManager.shared.updateOfflinePlaybackProgress(
            itemId: currentItem.id,
            played: nil,
            positionSeconds: currentTime,
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

import SwiftUI
import Combine
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

public struct PlayerView: View {
    @EnvironmentObject var appState: AppState
    public let session: ActivePlaybackSession

    @State var playerHandle: OpaquePointer? = nil
    @State var openingBox: OpeningPlayerBox? = nil
    @State var episodeSwitchTask: Task<Void, Never>? = nil
    @State var currentItem: EmbyItem
    @State var currentResource: DonbyCore.ResolvedPlaybackResource
    @State var isPlaying: Bool = true
    @State var currentTime: Double = 0
    @State var bufferedAheadSeconds: Double = 0
    @State var duration: Double = 1
    @State var isScrubbing: Bool = false
    @State var scrubTime: Double = 0
    @State var volume: Float = 1.0
    @State var isMuted: Bool = false
    @State var playbackSpeed: Float = 1.0
    @State var showRemainingTime: Bool = false
    @State var showControls: Bool = true
    @State var isOpeningMedia: Bool = true
    @State var hasRenderedFirstFrame: Bool = false
    @State var isWaitingForSeekOrBuffer: Bool = false
    @State var openingErrorMessage: String? = nil
    @State var showLogSheet: Bool = false
    @State var activeDrawer: PlayerDrawerTab? = nil
    @State var selectedAudioIdx: Int?
    @State var selectedSubIdx: Int?
    @State var activeAudioAVIndex: Int? = nil
    @State var activeSubtitleSelection: PlayerSubtitleSelection = .off
    @State var localExternalSubtitleName: String? = nil
    @State var kernelAudioTracks: [MediaStream] = []
    @State var kernelSubtitleTracks: [MediaStream] = []
    @State var didHandlePlaybackEnded: Bool = false
    @State var kernelStats = DKRuntimeStats()
    @State var autoHideBox = PlayerAutoHideBox()
    @State var mouseMonitor: Any? = nil
    @State var keyMonitor: Any? = nil
    @State var lastRecordedPosition: Double = -10
    @State var activePlaybackGeneration: Int = 0
    @State var displayDownloadSpeedMBs: Double = 0.0
    @State private var bottomControlBarHeight: CGFloat = 96
    @State var activeTurboHandle: TurboStreamByteHandle? = nil
    @State var playbackNetworkPriorityToken: UUID? = nil
    @State var activeSecondarySubtitleSelection: PlayerSubtitleSelection = .off
    @State var secondaryLocalSubtitleName: String? = nil
    @State var explicitSubtitleOff: Bool = false
    @State var kernelChapters: [PlaybackChapterItem] = []
    @State var healthPolicy = PlaybackHealthPolicy()
    @State var seekGeneration: Int = 0
    @State var lastSeekCommitUptime: TimeInterval = 0
    @State var lastSeekCommitTarget: Double = 0
    @State var skipBannerLabel: String? = nil
    @State var skipBannerTargetSec: Double = 0
    @State var skipBannerIsOutro: Bool = false
    @State var didAutoSkipIntroForCurrentItem: Bool = false
    @State var didAutoSkipOutroForCurrentItem: Bool = false
    @State var finishedItemPendingCleanup: (itemId: String, mediaSourceId: String)? = nil
    @State var prefetchedNextEpisodeResource: (itemId: String, resource: ResolvedPlaybackResource)? = nil
    @State var prefetchedNextEpisodeInFlightId: String? = nil
    @State var subtitleStyleRevision: Int = 0
    @State var isAdjustingSubtitleLayout: Bool = false
    @State var tracksDrawerSection: TracksDrawerSection = .tracks
    @State var isAutoAligningSubtitle: Bool = false
    @State var lastAutoAlignSummary: String? = nil
    @State var lastSubtitleAlignUndo: SubtitleAlignUndoState? = nil
    @State var secondarySubtitleTimeScale: Double = 1.0
    @State var isSecondaryAlignedToPrimary: Bool = false
    @StateObject var companionBox = DonbyPlayerCompanionBox()


    // Use `.default` RunLoop mode so timers automatically pause during macOS NSMenu `.eventTracking`,
    // preventing 0.25s body re-evaluations from flickering open subtitle/audio/speed dropdown menus.
    private let progressTimer = Timer.publish(every: 0.25, on: .main, in: .default).autoconnect()
    private let embySyncTimer = Timer.publish(every: 10.0, on: .main, in: .default).autoconnect()


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
                },
                onRenderDiagnostic: { msg in
                    DonbyLogger.shared.log(msg, level: .info, subsystem: "Render")
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

            if let companion = companionBox.companion {
                companion.makeVideoOverlay(
                    isEnabled: appState.enableDanmaku,
                    isPlaying: isPlaying && hasRenderedFirstFrame && !isWaitingForSeekOrBuffer,
                    playbackRate: Double(playbackSpeed),
                    timeProvider: {
                        (autoHideBox.liveCurrentTime, autoHideBox.lastObservedPosUptime > 0 ? autoHideBox.lastObservedPosUptime : ProcessInfo.processInfo.systemUptime)
                    }
                )
            }

            if isOpeningMedia || (!hasRenderedFirstFrame && openingErrorMessage == nil) {
                PlayerLoadingOverlayView {
                    exitPlayer()
                }
            } else if isWaitingForSeekOrBuffer && openingErrorMessage == nil {
                PlayerBufferingOverlayView(
                    displayDownloadSpeedMBs: displayDownloadSpeedMBs,
                    bottomPadding: showControls ? (bottomControlBarHeight + 18) : 34
                )
            }

            if let err = openingErrorMessage {
                PlayerErrorOverlayView(
                    errorMessage: err,
                    onRetry: { startNativeKernelPlayback(startSeconds: autoHideBox.liveCurrentTime) },
                    onSwitchLine: { appState.linePickerServer = session.server },
                    onShowLogs: { showLogSheet = true },
                    onExit: { exitPlayer() }
                )
            }

            if showControls || isOpeningMedia || openingErrorMessage != nil {
                VStack {
                    topOSDBar
                        .onContinuousHover { _ in showControlsAndResetTimer() }
                    Spacer()
                    if showControls && !isOpeningMedia && openingErrorMessage == nil {
                        if let bannerTitle = skipBannerLabel {
                            PlayerSkipBannerView(
                                title: bannerTitle,
                                isOutro: skipBannerIsOutro,
                                onTap: {
                                    if skipBannerIsOutro,
                                       let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
                                       session.episodesQueue.indices.contains(idx + 1) {
                                        switchToEpisode(session.episodesQueue[idx + 1])
                                    } else {
                                        seekTo(skipBannerTargetSec)
                                    }
                                    skipBannerLabel = nil
                                }
                            )
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
                .preferredColorScheme(appState.colorScheme)
                .tint(appState.accentColor)
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
                let hasSheet = showLogSheet || appState.showLogViewer || appState.serverEditorRequest != nil || appState.linePickerServer != nil
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
        .onAppear {
            configureAndBindCompanionIfNeeded()
        }
        .task(id: "\(currentItem.id)|\(appState.enableDanmaku)|\(hasRenderedFirstFrame)") {
            configureAndBindCompanionIfNeeded()
            await companionBox.companion?.onMediaOrFirstFrameChanged(
                item: currentItem,
                mediaSource: currentResource.mediaSource,
                enableDanmaku: appState.enableDanmaku,
                hasRenderedFirstFrame: hasRenderedFirstFrame
            )
        }
        .modifier(
            PlayerCompanionSheetsModifier(
                box: companionBox,
                currentItem: currentItem,
                currentMediaSource: currentResource.mediaSource
            )
        )
        .onReceive(progressTimer) { _ in
            handleProgressTimerTick()
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
                prefetchAheadChunks: Self.resolvedTurboPrefetchChunks(
                    prefetchSeconds: appState.turboPrefetchSeconds,
                    bitrateBps: currentResource.mediaSource.bitrate.map(Int64.init)
                )
            )
        }
        .onReceive(embySyncTimer) { _ in
            handleEmbySyncTimerTick()
        }
        .environment(\.colorScheme, .dark)
    }

    func syncVisiblePlaybackStateFromBox() {
        if abs(currentTime - autoHideBox.liveCurrentTime) > 0.05 {
            currentTime = autoHideBox.liveCurrentTime
        }
        if abs(bufferedAheadSeconds - autoHideBox.liveBufferedAheadSeconds) > 0.25 {
            bufferedAheadSeconds = autoHideBox.liveBufferedAheadSeconds
        }
        if currentResource.isLocalOrOfflineMedia {
            if displayDownloadSpeedMBs != 0.0 {
                displayDownloadSpeedMBs = 0.0
            }
        } else if let turboHandle = activeTurboHandle {
            let turboSpeed = turboHandle.currentWireSpeedMBs
            if abs(displayDownloadSpeedMBs - turboSpeed) > 0.05 || (turboSpeed < 0.01 && displayDownloadSpeedMBs > 0) {
                displayDownloadSpeedMBs = turboSpeed
            }
        }
    }

    func showControlsAndResetTimer() {
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

    func adjustVolume(delta: Float) {
        let newVol = max(0, min(1.0, volume + delta))
        volume = newVol
        isMuted = (newVol == 0)
        if let handle = playerHandle {
            dk_player_set_volume(handle, newVol, isMuted)
        }
        appState.showToast("音量: \(Int(newVol * 100))%", icon: newVol == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        showControlsAndResetTimer()
    }
}

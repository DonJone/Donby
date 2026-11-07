import SwiftUI
import Combine
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

public enum PlayerDrawerTab: String, CaseIterable, Identifiable {
    case playlist = "播放列表"
    case tracks = "音轨与字幕"
    case mediaInfo = "流媒体信息"
    public var id: String { rawValue }
}

public struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    public let session: ActivePlaybackSession

    @State private var playerHandle: OpaquePointer? = nil
    @State private var currentItem: EmbyItem
    @State private var currentResource: DonbyCore.ResolvedPlaybackResource
    @State private var isPlaying: Bool = true
    @State private var currentTime: Double = 0
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
    @State private var systemClockString: String = ""
    @State private var kernelStats = DKRuntimeStats()
    @State private var autoHideTask: Task<Void, Never>? = nil
    @State private var mouseMonitor: Any? = nil
    @State private var keyMonitor: Any? = nil
    @State private var lastRecordedPosition: Double = -10
    @State private var lastMouseMoveTimestamp: TimeInterval = 0
    @State private var activePlaybackGeneration: Int = 0

    private let progressTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let embySyncTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

    public init(session: ActivePlaybackSession) {
        self.session = session
        self._currentItem = State(initialValue: session.item)
        self._currentResource = State(initialValue: session.resource)
        self._selectedAudioIdx = State(initialValue: session.selectedAudioIndex)
        self._selectedSubIdx = State(initialValue: session.selectedSubtitleIndex)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // C++ / Metal Native Engine Video Surface
            DKMetalVideoView(playerHandle: playerHandle)
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

            if showControls {
                VStack {
                    topOSDBar
                        .onContinuousHover { _ in showControlsAndResetTimer() }
                    Spacer()
                    bottomControlBar
                        .onContinuousHover { _ in showControlsAndResetTimer() }
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

            if isOpeningMedia {
                ZStack {
                    Color.black.opacity(0.85)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(appState.accentColor)
                        Text("正在解析视频流与配置硬件解码...")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(currentResource.routeNote.isEmpty ? currentItem.name : "\(currentItem.name) · \(currentResource.routeNote)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 36).padding(.vertical, 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
                }
                .transition(.opacity)
            }

            if let err = openingErrorMessage {
                ZStack {
                    Color.black.opacity(0.9)
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
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .transition(.opacity)
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
        .onAppear {
            playbackSpeed = Float(appState.defaultPlaySpeed)
            updateClock()
            startNativeKernelPlayback(startSeconds: session.startPositionSeconds)
            showControlsAndResetTimer()

            // Setup global window monitors for mouse activity and keyboard shortcuts
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { event in
                let now = ProcessInfo.processInfo.systemUptime
                if event.type != .mouseMoved || now - lastMouseMoveTimestamp > 0.08 {
                    lastMouseMoveTimestamp = now
                    showControlsAndResetTimer()
                }
                return event
            }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            currentTime = dk_player_get_position(handle)
            let dur = dk_player_get_duration(handle)
            if dur > 0 { duration = dur }
            else if currentItem.durationSeconds > 0 { duration = currentItem.durationSeconds }
            dk_player_get_stats(handle, &kernelStats)

            // Update watch history periodically (every 5s) to avoid UI frame drops
            if abs(currentTime - lastRecordedPosition) >= 5.0 {
                lastRecordedPosition = currentTime
                appState.recordWatch(
                    title: currentItem.name,
                    subtitle: currentItem.isEpisode ? currentItem.episodeCodeString : currentItem.resolutionBadge,
                    posterKey: nil,
                    posterURL: EmbyClient.shared.imageURL(server: session.server, item: currentItem, kind: .primary, maxWidth: 320)?.absoluteString,
                    position: currentTime,
                    duration: duration,
                    sourceType: currentResource.isDirectStream ? "原画直链" : "Emby",
                    streamURLString: currentResource.streamURL.absoluteString,
                    embyItemId: currentItem.id,
                    resolutionTag: kernelStats.is_hw_accelerated ? "HW 4K" : "4K UHD"
                )
            }
        }
        .onReceive(embySyncTimer) { _ in
            guard !session.server.host.isEmpty && !session.server.accessToken.isEmpty else { return }
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

    private var topOSDBar: some View {
        HStack(spacing: 14) {
            Button { exitPlayer() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text("退出播放").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial).clipShape(Capsule())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(currentItem.isEpisode ? "\(currentItem.seriesName ?? "") · \(currentItem.episodeCodeString ?? "") \(currentItem.name)" : currentItem.name)
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)

                    Text(kernelStats.is_hw_accelerated ? "VideoToolbox HW" : "CPU SW")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(appState.accentColor).clipShape(RoundedRectangle(cornerRadius: 4))

                    if kernelStats.is_dolby_vision {
                        Text("Dolby Vision")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.purple).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(playerStreamMetaSubtitle)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                appState.linePickerServer = session.server
            } label: {
                HStack(spacing: 6) {
                    RouteSwitchVectorIcon(size: 12, color: appState.accentColor)
                    Text(session.server.activeLineName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    LatencyBadgeView(latencyMs: session.server.activeLineLatencyMs, isPinging: appState.isPingingLines)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("切换当前播放线路")

            Text(systemClockString)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.black.opacity(0.4)).clipShape(Capsule())
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 24)
        .background(
            ZStack {
                Color.black.opacity(0.8)
                LinearGradient(colors: [Color.black.opacity(0.8), Color.clear], startPoint: .top, endPoint: .bottom)
            }
        )
    }

    private func getControlBarStyle() -> ControlBarPositionStyle {
        appState.controlBarStyle
    }

    private var bottomControlBar: some View {
        let isFloat = (getControlBarStyle() == .float)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(formatTime(isScrubbing ? scrubTime : currentTime))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 64, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : currentTime },
                        set: { newVal in isScrubbing = true; scrubTime = newVal }
                    ),
                    in: 0...max(1, duration),
                    onEditingChanged: { editing in
                        if !editing { seekTo(scrubTime); isScrubbing = false }
                    }
                )
                .tint(appState.accentColor)

                Button { showRemainingTime.toggle() } label: {
                    Text(showRemainingTime ? "-\(formatTime(max(0, duration - currentTime)))" : formatTime(duration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 68, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 18) {
                HStack(spacing: 10) {
                    Button {
                        isMuted.toggle()
                        if let handle = playerHandle {
                            dk_player_set_volume(handle, volume, isMuted)
                        }
                    } label: {
                        Image(systemName: isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Slider(
                        value: Binding(
                            get: { isMuted ? 0 : volume },
                            set: { v in
                                volume = v
                                isMuted = (v == 0)
                                if let handle = playerHandle { dk_player_set_volume(handle, v, isMuted) }
                            }
                        ),
                        in: 0...1.0
                    )
                    .frame(width: 84)
                    .tint(.white)

                    Button {
                        seekRelative(Double(appState.opSeconds))
                        appState.showToast("跳过片头 +\(appState.opSeconds)秒", icon: "forward.end.alt.fill")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.zigzag.right").font(.system(size: 11))
                            Text("跳过片头").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.white.opacity(0.12)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 20) {
                    Button { playAdjacentEpisode(offset: -1) } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.episodesQueue.count > 1 ? .white : .white.opacity(0.35))
                    }
                    .buttonStyle(.plain).disabled(session.episodesQueue.count <= 1)

                    Button { seekRelative(-10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button { togglePlayPause() } label: {
                        ZStack {
                            Circle().fill(appState.accentColor).frame(width: 44, height: 44)
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 1.5)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { seekRelative(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button { playAdjacentEpisode(offset: 1) } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.episodesQueue.count > 1 ? .white : .white.opacity(0.35))
                    }
                    .buttonStyle(.plain).disabled(session.episodesQueue.count <= 1)
                }

                Spacer()

                HStack(spacing: 12) {
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { spd in
                            Button(String(format: "%.2gx 倍速", spd)) {
                                playbackSpeed = Float(spd)
                                if let handle = playerHandle { dk_player_set_rate(handle, playbackSpeed) }
                            }
                        }
                    } label: {
                        Text(String(format: "%.2gx", playbackSpeed))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.white.opacity(0.14)).clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton).frame(width: 56)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { activeDrawer = (activeDrawer == .tracks) ? nil : .tracks }
                    } label: {
                        Image(systemName: "captions.bubble").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(activeDrawer == .tracks ? appState.accentColor : .white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { activeDrawer = (activeDrawer == .playlist) ? nil : .playlist }
                    } label: {
                        Image(systemName: "list.bullet.rectangle.fill").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(activeDrawer == .playlist ? appState.accentColor : .white)
                    }
                    .buttonStyle(.plain)

                    Button { toggleFullScreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(maxWidth: isFloat ? 860 : .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: isFloat ? 22 : 0, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: isFloat ? 22 : 0, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: isFloat ? 0.8 : 0))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .padding(.horizontal, isFloat ? 32 : 0)
        .padding(.bottom, isFloat ? 24 : 0)
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
                        Text("音频轨道").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        ForEach(currentItem.audioStreams) { stream in
                            let isSel = selectedAudioIdx == stream.index
                            Button {
                                selectedAudioIdx = stream.index
                                if let handle = playerHandle, let idx = stream.index {
                                    dk_player_select_track(handle, 1, Int32(idx))
                                    appState.showToast("已切换音轨: \(stream.readableLabel)", icon: "speaker.wave.2.fill")
                                }
                            } label: {
                                HStack {
                                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle").foregroundStyle(isSel ? appState.accentColor : .secondary)
                                    Text(stream.readableLabel).font(.system(size: 12)).foregroundStyle(.white)
                                    Spacer()
                                }
                                .padding(9).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }

                        Text("字幕轨道").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
                        Button {
                            selectedSubIdx = nil
                            if let handle = playerHandle {
                                dk_player_select_track(handle, 2, -1)
                                appState.showToast("已关闭字幕", icon: "captions.bubble")
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedSubIdx == nil ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedSubIdx == nil ? appState.accentColor : .secondary)
                                Text("关闭字幕").font(.system(size: 12)).foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(9).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        ForEach(currentItem.subtitleStreams) { stream in
                            let isSel = selectedSubIdx == stream.index
                            Button {
                                selectedSubIdx = stream.index
                                if let handle = playerHandle, let idx = stream.index {
                                    dk_player_select_track(handle, 2, Int32(idx))
                                    appState.showToast("已切换字幕: \(stream.readableLabel)", icon: "captions.bubble.fill")
                                }
                            } label: {
                                HStack {
                                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle").foregroundStyle(isSel ? appState.accentColor : .secondary)
                                    Text(stream.readableLabel).font(.system(size: 12)).foregroundStyle(.white)
                                    Spacer()
                                }
                                .padding(9).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                case .mediaInfo:
                    VStack(alignment: .leading, spacing: 10) {
                        osdInfoRow("解码方式", kernelStats.is_hw_accelerated ? "Apple VideoToolbox 硬件解码" : "CPU 软件解码")
                        osdInfoRow("动态范围", kernelStats.is_dolby_vision ? "Dolby Vision" : (kernelStats.is_hdr ? "HDR10" : "SDR"))
                        osdInfoRow("流预读缓存", "\(kernelStats.cached_bytes / 1024 / 1024) MB")
                        osdInfoRow("分辨率", "\(kernelStats.width) × \(kernelStats.height)")
                        osdInfoRow("帧率", String(format: "%.3f fps", kernelStats.fps))
                        osdInfoRow("视频编码", withUnsafePointer(to: &kernelStats.video_codec) { ptr in
                            ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                        })
                        osdInfoRow("音频编码", withUnsafePointer(to: &kernelStats.audio_codec) { ptr in
                            ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                        })
                        osdInfoRow("播放线路", session.server.activeLineName)

                        Divider().opacity(0.2).padding(.vertical, 4)

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
        .padding(18).frame(width: 320).frame(maxHeight: .infinity).background(.ultraThinMaterial)
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
                    if activeDrawer == nil && !isScrubbing {
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

        let urlStr = currentResource.streamURL.absoluteString
        let headersStr = currentResource.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let hwDecode = appState.enableHardwareDecode
        let speed = playbackSpeed
        let vol = volume
        let muted = isMuted
        let audioIdx = selectedAudioIdx
        let subIdx = selectedSubIdx

        DonbyLogger.shared.log("启动原生播放内核 (URL: \(urlStr))", level: .info, subsystem: "Player")

        Task.detached(priority: .userInitiated) {
            let handle = dk_player_create()
            let ret = dk_player_open(handle, urlStr, headersStr, startSeconds, hwDecode)
            let addr = UInt(bitPattern: handle)

            await MainActor.run {
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

                if let aIdx = audioIdx, aIdx >= 0 {
                    dk_player_select_track(validHandle, 1, Int32(aIdx))
                }
                if let sIdx = subIdx, sIdx >= 0 {
                    dk_player_select_track(validHandle, 2, Int32(sIdx))
                }
                self.isPlaying = true
                DonbyLogger.shared.log("原生播放器配置就绪，画面启动渲染", level: .info, subsystem: "Player")
            }
        }

        guard !session.server.host.isEmpty && !session.server.accessToken.isEmpty else { return }
        Task {
            await EmbyClient.shared.reportPlaybackStart(
                server: session.server,
                itemId: currentItem.id,
                mediaSourceId: currentResource.mediaSource.id,
                playSessionId: currentResource.playSessionId,
                positionSeconds: startSeconds
            )
        }
    }

    private func stopNativeKernel() {
        activePlaybackGeneration &+= 1
        guard let handle = playerHandle else { return }
        self.playerHandle = nil
        Task.detached(priority: .userInitiated) {
            dk_player_close(handle)
            dk_player_destroy(handle)
        }
    }

    private func togglePlayPause() {
        guard let handle = playerHandle else { return }
        if isPlaying {
            dk_player_pause(handle)
            isPlaying = false
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
        currentTime = seconds
        if let handle = playerHandle {
            dk_player_seek(handle, seconds, true)
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

    private func switchToEpisode(_ nextEp: EmbyItem) {
        Task {
            if let res = try? await EmbyClient.shared.resolvePlaybackResource(
                server: session.server,
                item: nextEp,
                audioStreamIndex: selectedAudioIdx,
                subtitleStreamIndex: selectedSubIdx
            ) {
                currentItem = nextEp
                currentResource = res
                startNativeKernelPlayback(startSeconds: nextEp.resumePositionSeconds)
            }
        }
    }

    private func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    private func exitPlayer() {
        autoHideTask?.cancel()
        if let mm = mouseMonitor { NSEvent.removeMonitor(mm); mouseMonitor = nil }
        if let km = keyMonitor { NSEvent.removeMonitor(km); keyMonitor = nil }

        appState.recordWatch(
            title: currentItem.name,
            subtitle: currentItem.isEpisode ? currentItem.episodeCodeString : currentItem.resolutionBadge,
            posterKey: nil,
            posterURL: EmbyClient.shared.imageURL(server: session.server, item: currentItem, kind: .primary, maxWidth: 320)?.absoluteString,
            position: currentTime,
            duration: duration,
            sourceType: currentResource.isDirectStream ? "原画直链" : "Emby",
            streamURLString: currentResource.streamURL.absoluteString,
            embyItemId: currentItem.id,
            resolutionTag: kernelStats.is_hw_accelerated ? "HW 4K" : "4K UHD"
        )
        appState.flushWatchHistory()

        if !session.server.host.isEmpty && !session.server.accessToken.isEmpty {
            let srv = session.server
            let cId = currentItem.id
            let msId = currentResource.mediaSource.id
            let psId = currentResource.playSessionId
            let pos = currentTime
            Task {
                await EmbyClient.shared.reportPlaybackStopped(
                    server: srv,
                    itemId: cId,
                    mediaSourceId: msId,
                    playSessionId: psId,
                    positionSeconds: pos
                )
            }
        }

        stopNativeKernel()
        appState.activePlayback = nil
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

        let vCodec = withUnsafePointer(to: &kernelStats.video_codec) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
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
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        systemClockString = f.string(from: Date())
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

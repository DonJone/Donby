import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
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

private enum PlayerSubtitleSelection: Equatable {
    case off
    case embedded(avStreamIndex: Int)
    case remoteExternal(url: URL)
    case localExternal(url: URL)
}

private struct PlayerAudioTrackOption: Identifiable, Equatable {
    var id: String { "audio-\(avStreamIndex)" }
    let avStreamIndex: Int
    let embyIndex: Int?
    let label: String
}

private struct PlayerSubtitleTrackOption: Identifiable, Equatable {
    let id: String
    let selection: PlayerSubtitleSelection
    let embyIndex: Int?
    let label: String
    let badge: String?
    let externalItem: SubtitleResourceItem?
}

/// Sleek mini volume slider with white track and circular thumb
private struct MiniVolumeSlider: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool
    let onChange: (Float) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let ratio = CGFloat(isMuted ? 0 : max(0, min(1, volume)))
            let filledW = w * ratio
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 3.5)

                Capsule()
                    .fill(Color.white)
                    .frame(width: max(3.5, filledW), height: 3.5)

                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: min(max(0, filledW - 5), w - 10))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let r = Float(max(0.0, min(1.0, val.location.x / w)))
                        volume = r
                        isMuted = (r == 0)
                        onChange(r)
                    }
            )
        }
        .frame(width: 55, height: 16)
    }
}

private struct PlayerCircleButton<Content: View>: View {
    let tooltip: String
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(isHovered ? 0.95 : 0.65), lineWidth: 1.25)
                    .background(Circle().fill(isHovered ? Color.white.opacity(0.18) : Color.clear))
                content()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered = $0 }
    }
}

private struct PlayerCircleMenu<Content: View, MenuItems: View>: View {
    let tooltip: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let menuItems: () -> MenuItems
    @State private var isHovered = false

    var body: some View {
        Menu {
            menuItems()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(isHovered ? 0.95 : 0.65), lineWidth: 1.25)
                    .background(Circle().fill(isHovered ? Color.white.opacity(0.18) : Color.clear))
                content()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .help(tooltip)
        .onHover { isHovered = $0 }
    }
}

/// Custom Liquid Glass video scrubber with real-time ahead-of-playhead buffered progress indicator
private struct PlayerTimelineScrubberView: View {
    let currentTime: Double
    let bufferedAheadSeconds: Double
    let duration: Double
    let accentColor: Color
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: Double
    let onCommitSeek: (Double) -> Void

    @State private var isHovered: Bool = false

    private var safeDuration: Double { max(1.0, duration) }
    private var displayedTime: Double { isScrubbing ? scrubTime : currentTime }
    private var playedRatio: CGFloat {
        CGFloat(max(0.0, min(1.0, displayedTime / safeDuration)))
    }
    private var bufferedRatio: CGFloat {
        let target = max(displayedTime, currentTime + max(0.0, bufferedAheadSeconds))
        return CGFloat(max(Double(playedRatio), min(1.0, target / safeDuration)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1.0, geo.size.width)
            let trackHeight: CGFloat = (isHovered || isScrubbing) ? 5.0 : 3.5
            let knobSize: CGFloat = (isHovered || isScrubbing) ? 14.0 : 12.0
            let playedW = width * playedRatio
            let bufferedW = width * bufferedRatio

            ZStack(alignment: .leading) {
                // Unbuffered background track
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: width, height: trackHeight)

                // Cached / Buffered progress indicator ahead of playhead
                if bufferedW > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.38))
                        .frame(width: min(width, bufferedW), height: trackHeight)
                        .animation(.linear(duration: 0.20), value: bufferedRatio)
                }

                // Played progress segment
                if playedW > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: min(width, max(trackHeight, playedW)), height: trackHeight)
                }

                // Circular playhead thumb
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(0, playedW - knobSize * 0.5), max(0, width - knobSize)))
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isHovered = hovering
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = max(0.0, min(1.0, Double(value.location.x / width)))
                        isScrubbing = true
                        scrubTime = ratio * safeDuration
                    }
                    .onEnded { value in
                        let ratio = max(0.0, min(1.0, Double(value.location.x / width)))
                        let target = ratio * safeDuration
                        scrubTime = target
                        isScrubbing = false
                        onCommitSeek(target)
                    }
            )
        }
        .frame(height: 20)
    }
}

public struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    public let session: ActivePlaybackSession

    @State private var playerHandle: OpaquePointer? = nil
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
    @State private var displayDownloadSpeedMBs: Double = 20.2
    @State private var lastSpeedMeasurementTime: TimeInterval = 0
    @State private var lastMeasuredBytes: Int64 = 0

    private let progressTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
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
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.black.opacity(0.68))
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                        }
                    )
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
            bufferedAheadSeconds = dk_player_get_buffered_duration(handle)
            let dur = dk_player_get_duration(handle)
            if dur > 0 { duration = dur }
            else if currentItem.durationSeconds > 0 { duration = currentItem.durationSeconds }
            dk_player_get_stats(handle, &kernelStats)

            let pState = dk_player_get_state(handle)
            if pState == DK_STATE_ENDED && !didHandlePlaybackEnded {
                didHandlePlaybackEnded = true
                isPlaying = false
                if let idx = session.episodesQueue.firstIndex(where: { $0.id == currentItem.id }),
                   session.episodesQueue.indices.contains(idx + 1) {
                    let nextEp = session.episodesQueue[idx + 1]
                    appState.showToast("正在自动连播下一集: \(nextEp.name)", icon: "forward.end.fill")
                    switchToEpisode(nextEp)
                    return
                }
            }

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
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.55))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
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
                Text(String(format: "%.1f MB/s", max(0.1, displayDownloadSpeedMBs)))
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
        let vCodec = withUnsafePointer(to: &kernelStats.video_codec) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
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

    private var specBitrateString: String {
        if kernelStats.video_bitrate_mbps > 0.05 {
            return String(format: "%.1fmbps", kernelStats.video_bitrate_mbps)
        }
        if let br = currentItem.primaryVideoStream?.bitRate, br > 0 {
            return String(format: "%.1fmbps", Double(br) / 1_000_000.0)
        }
        return "18.3mbps"
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
                playerSpecBadge(text: specBitrateString)
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
        Button("加载本地字幕文件 (.srt / .ass)...") {
            promptLocalExternalSubtitleFile()
        }
        Button("打开字幕管理面板...") {
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
            Text("码率: \(specBitrateString)")
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
        Section("快捷操作") {
            Button("跳过片头 (+\(appState.opSeconds)s)") {
                seekRelative(Double(appState.opSeconds))
                appState.showToast("跳过片头 +\(appState.opSeconds)秒", icon: "forward.end.alt.fill")
            }
            Button("跳过片尾 (-90s)") {
                seekRelative(-90)
                appState.showToast("快退片尾 -90秒", icon: "backward.end.alt.fill")
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
        guard let view = DKMetalLayerView.activeInstance,
              let image = view.captureSnapshotImage() else {
            appState.showToast("截图失败：未捕获到视频画面", icon: "camera.fill", isError: true)
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])

        let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        let donbyDir = picturesURL.appendingPathComponent("Donby", isDirectory: true)
        try? FileManager.default.createDirectory(at: donbyDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let safeTitle = currentItem.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let fileURL = donbyDir.appendingPathComponent("\(safeTitle)_\(timestamp).png")

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }

        appState.showToast("已截图并保存至照片与剪贴板", icon: "camera.fill")
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
                externalItem: nil
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
                externalItem: ext
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
                externalItem: nil
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
                            promptLocalExternalSubtitleFile()
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
                    }

                case .mediaInfo:
                    VStack(alignment: .leading, spacing: 10) {
                        osdInfoRow("解码方式", kernelStats.is_hw_accelerated ? "Apple VideoToolbox 硬件解码" : "CPU 软件解码")
                        osdInfoRow("动态范围", kernelStats.is_dolby_vision ? "Dolby Vision" : (kernelStats.is_hdr ? "HDR10" : "SDR"))
                        osdInfoRow("超前缓冲时长", String(format: "+%.1f 秒", bufferedAheadSeconds))
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
        didHandlePlaybackEnded = false
        bufferedAheadSeconds = 0
        localExternalSubtitleName = nil

        let urlStr = currentResource.streamURL.absoluteString
        let headersStr = currentResource.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let hwDecode = appState.enableHardwareDecode
        let speed = playbackSpeed
        let vol = volume
        let muted = isMuted
        let audioIdx = selectedAudioIdx
        let subIdx = selectedSubIdx
        let hasEmbyStreamCatalog = !(currentResource.mediaSource.mediaStreams ?? []).isEmpty

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

                let discovered = Self.queryKernelTracks(handle: validHandle)
                self.kernelAudioTracks = discovered.audio
                self.kernelSubtitleTracks = discovered.subtitles

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

                // Resolve initial subtitle track (respecting explicit "Off", external URLs, or embedded ordinal)
                let subOpts = self.resolvedSubtitleOptions
                if let requestedEmbySub = subIdx, requestedEmbySub >= 0 {
                    if let matchedOpt = subOpts.first(where: { $0.embyIndex == requestedEmbySub })
                        ?? subOpts.first(where: {
                            if case .embedded(let avIdx) = $0.selection { return avIdx == requestedEmbySub }
                            return false
                        }) {
                        self.applySubtitleOptionOnStartup(matchedOpt, handle: validHandle, defaultSelectedAV: discovered.selectedSubIndex)
                    } else if let autoSub = discovered.selectedSubIndex {
                        self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                    }
                } else if hasEmbyStreamCatalog {
                    // User explicitly chose "关闭字幕" (nil) on an Emby item
                    self.activeSubtitleSelection = .off
                    if discovered.selectedSubIndex != nil {
                        dk_player_select_track(validHandle, 2, -1)
                    }
                } else if let autoSub = discovered.selectedSubIndex {
                    // Direct URL / local file without pre-playback selector: keep default subtitle
                    self.activeSubtitleSelection = .embedded(avStreamIndex: autoSub)
                } else {
                    self.activeSubtitleSelection = .off
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
        if dk_player_get_state(handle) == DK_STATE_ENDED {
            didHandlePlaybackEnded = false
            currentTime = 0
            dk_player_seek(handle, 0, true)
            dk_player_play(handle)
            isPlaying = true
            return
        }
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
        didHandlePlaybackEnded = false
        currentTime = seconds
        if let handle = playerHandle {
            dk_player_seek(handle, seconds, true)
        }
    }

    private static func queryKernelTracks(handle: OpaquePointer) -> (
        audio: [MediaStream],
        subtitles: [MediaStream],
        selectedAudioIndex: Int?,
        selectedSubIndex: Int?
    ) {
        func readString<T>(_ tuple: T, maxLen: Int) -> String {
            withUnsafePointer(to: tuple) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { String(cString: $0) }
            }
        }

        var audios: [MediaStream] = []
        var selAudio: Int? = nil
        let aCount = dk_player_get_track_count(handle, 1)
        for ord in 0..<aCount {
            var info = DKTrackInfo()
            guard dk_player_get_track_info(handle, 1, ord, &info) else { continue }
            let idx = Int(info.stream_index)
            let codec = readString(info.codec, maxLen: 32)
            let lang = readString(info.language, maxLen: 32)
            let title = readString(info.title, maxLen: 128)
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
            let codec = readString(info.codec, maxLen: 32)
                .replacingOccurrences(of: "hdmv_pgs_subtitle", with: "PGS")
                .replacingOccurrences(of: "subrip", with: "SRT")
            let lang = readString(info.language, maxLen: 32)
            let title = readString(info.title, maxLen: 128)
            if info.is_selected { selSub = idx }
            subs.append(MediaStream(
                index: idx,
                type: "Subtitle",
                codec: codec.isEmpty ? nil : codec,
                language: lang.isEmpty ? nil : lang,
                title: title.isEmpty ? nil : title,
                isDefault: info.is_default
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

    private func disableSubtitles(showFeedback: Bool) {
        selectedSubIdx = nil
        activeSubtitleSelection = .off
        localExternalSubtitleName = nil
        if let handle = playerHandle {
            dk_player_select_track(handle, 2, -1)
            if showFeedback {
                appState.showToast("已关闭字幕", icon: "captions.bubble")
            }
        }
    }

    private func applySubtitleOptionOnStartup(_ option: PlayerSubtitleTrackOption, handle: OpaquePointer, defaultSelectedAV: Int?) {
        switch option.selection {
        case .off:
            activeSubtitleSelection = .off
            dk_player_select_track(handle, 2, -1)
        case .embedded(let avIdx):
            activeSubtitleSelection = .embedded(avStreamIndex: avIdx)
            if defaultSelectedAV != avIdx {
                dk_player_select_track(handle, 2, Int32(avIdx))
            }
        case .remoteExternal:
            if let ext = option.externalItem {
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: true)
            }
        case .localExternal:
            break
        }
    }

    private func selectSubtitleOption(_ option: PlayerSubtitleTrackOption) {
        selectedSubIdx = option.embyIndex
        switch option.selection {
        case .off:
            disableSubtitles(showFeedback: true)
        case .embedded(let avIdx):
            localExternalSubtitleName = nil
            activeSubtitleSelection = .embedded(avStreamIndex: avIdx)
            if let handle = playerHandle {
                dk_player_select_track(handle, 2, Int32(avIdx))
                appState.showToast("已切换字幕: \(option.label)", icon: "captions.bubble.fill")
            }
        case .remoteExternal:
            if let ext = option.externalItem {
                localExternalSubtitleName = nil
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: false)
            }
        case .localExternal:
            break
        }
    }

    private func loadRemoteExternalSubtitle(item: SubtitleResourceItem, embyStreamIndex: Int?, silentToast: Bool) {
        selectedSubIdx = embyStreamIndex
        activeSubtitleSelection = .remoteExternal(url: item.url)
        let headers = currentResource.headers
        let url = item.url
        let label = item.name
        Task.detached(priority: .userInitiated) {
            var req = URLRequest(url: url, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .utf16)
                      ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) else {
                await MainActor.run {
                    appState.showToast("下载外挂字幕失败", icon: "exclamationmark.triangle.fill", isError: true)
                }
                return
            }
            let ext = url.pathExtension.lowercased()
            let isAss = (ext == "ass" || ext == "ssa" || text.contains("[Script Info]"))
            await MainActor.run {
                if let handle = self.playerHandle {
                    dk_player_load_external_subtitle(handle, text, isAss)
                    if !silentToast {
                        self.appState.showToast("已加载外挂字幕: \(label)", icon: "captions.bubble.fill")
                    }
                }
            }
        }
    }

    private func promptLocalExternalSubtitleFile() {
        let panel = NSOpenPanel()
        panel.title = "选择外挂字幕文件 (.srt / .ass / .ssa / .vtt)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        for ext in ["srt", "ass", "ssa", "vtt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .utf16)
                      ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) else {
                appState.showToast("读取字幕文件失败", icon: "exclamationmark.triangle.fill", isError: true)
                return
            }
            let ext = url.pathExtension.lowercased()
            let isAss = (ext == "ass" || ext == "ssa" || text.contains("[Script Info]"))
            if let handle = playerHandle {
                selectedSubIdx = nil
                localExternalSubtitleName = url.lastPathComponent
                activeSubtitleSelection = .localExternal(url: url)
                dk_player_load_external_subtitle(handle, text, isAss)
                appState.showToast("已加载本地字幕: \(url.lastPathComponent)", icon: "captions.bubble.fill")
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

    private func switchToEpisode(_ nextEp: EmbyItem) {
        Task {
            if let res = try? await EmbyClient.shared.resolvePlaybackResource(
                server: session.server,
                item: nextEp,
                preferredPreset: appState.preferredVersionPreset,
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

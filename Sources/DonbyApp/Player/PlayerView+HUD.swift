import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

extension PlayerView {
    var topBarTitleString: String {
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

    var topOSDBar: some View {
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

            HStack(spacing: 10) {
                Spacer()
                if let companion = companionBox.companion {
                    companion.makeTopBarControls(activeDrawer: $activeDrawer)
                }

                if !currentResource.isLocalOrOfflineMedia {
                    PlayerTopSpeedView(telemetry: telemetry)
                }
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
        let vCodec = Self.cString(from: telemetry.kernelStats.video_codec)
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
        if telemetry.kernelStats.is_dolby_vision { return "DOVI" }
        if telemetry.kernelStats.is_hdr { return "HDR" }
        return "SDR"
    }

    private var specResolutionString: String {
        let w = telemetry.kernelStats.width > 0 ? telemetry.kernelStats.width : Int32(currentItem.primaryVideoStream?.width ?? 0)
        let h = telemetry.kernelStats.height > 0 ? telemetry.kernelStats.height : Int32(currentItem.primaryVideoStream?.height ?? 0)
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
        let fps = telemetry.kernelStats.fps > 0 ? telemetry.kernelStats.fps : 24.0
        return "\(Int(fps.rounded()))FPS"
    }

    private var specBitrateString: String? {
        if telemetry.kernelStats.video_bitrate_mbps > 0.05 {
            return String(format: "%.1fmbps", telemetry.kernelStats.video_bitrate_mbps)
        }
        if let br = currentItem.primaryVideoStream?.bitRate, br > 0 {
            return String(format: "%.1fmbps", Double(br) / 1_000_000.0)
        }
        return nil
    }

    var bottomControlBar: some View {
        PlayerBottomControlBarView(
            telemetry: telemetry,
            currentItem: currentItem,
            episodesCount: session.episodesQueue.count,
            isPlaying: isPlaying,
            isScrubbing: $isScrubbing,
            scrubTime: $scrubTime,
            showRemainingTime: $showRemainingTime,
            volume: $volume,
            isMuted: $isMuted,
            accentColor: drawerSelectedAccentTint(),
            onAdjacentEpisode: { playAdjacentEpisode(offset: $0) },
            onSeekRelative: { seekRelative($0) },
            onTogglePlayPause: { togglePlayPause() },
            onCommitSeek: { seekTo($0) },
            onToggleMute: {
                isMuted.toggle()
                if let handle = playerHandle {
                    dk_player_set_volume(handle, volume, isMuted)
                }
            },
            onVolumeChanged: { v in
                if let handle = playerHandle {
                    dk_player_set_volume(handle, v, isMuted)
                }
            },
            formatTime: { formatTime($0) },
            audioMenu: { AnyView(audioMenuContent) },
            subtitleMenu: { AnyView(subtitleMenuContent) },
            decoderMenu: { AnyView(decoderMenuContent) },
            speedMenu: { AnyView(speedMenuContent) },
            moreMenu: { AnyView(moreMenuContent) }
        )
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
            Text("解码: \(telemetry.kernelStats.is_hw_accelerated ? "硬件解码" : "软件解码")")
            Text("动态范围: \(telemetry.kernelStats.is_dolby_vision ? "Dolby Vision" : (telemetry.kernelStats.is_hdr ? "HDR10" : "SDR"))")
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
                startNativeKernelPlayback(startSeconds: telemetry.currentTime)
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
                companionBox.companion?.onLocalRateChanged(rate: spd, isPlaying: isPlaying, livePos: autoHideBox.liveCurrentTime)
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
            Button("设当前位置为本季片头结束 (\(formatTime(telemetry.currentTime)))") {
                appState.updateSeasonSkipPreference(serverId: session.server.id, item: currentItem) { pref in
                    pref.introSeconds = telemetry.currentTime
                    pref.hasUserMarkedIntro = true
                }
                appState.showToast("已记忆本季片头长度：\(formatTime(telemetry.currentTime))", icon: "checkmark.circle.fill")
            }
            Button("设当前位置为本季片尾开始 (剩余 \(formatTime(max(0, telemetry.duration - telemetry.currentTime))))") {
                let tailLen = max(0, telemetry.duration - telemetry.currentTime)
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
            if let companion = companionBox.companion {
                companion.makeContextMenuItems(activeDrawer: $activeDrawer)
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
}

private struct PlayerTopSpeedView: View {
    @ObservedObject var telemetry: PlayerHUDTelemetry

    var body: some View {
        Text(String(format: "%.1f MB/s", max(0.0, telemetry.displayDownloadSpeedMBs)))
            .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
    }
}

private struct PlayerSpecBadgeHostView: View {
    @ObservedObject var telemetry: PlayerHUDTelemetry
    let currentItem: EmbyItem

    var body: some View {
        let stats = telemetry.kernelStats
        HStack(spacing: 6) {
            badge(stats.is_hw_accelerated ? "HW" : "SW")
            badge(videoCodecString(stats: stats))
            badge(stats.is_dolby_vision ? "DOVI" : (stats.is_hdr ? "HDR" : "SDR"))
            badge(resolutionString(stats: stats))
            badge("\(Int((stats.fps > 0 ? stats.fps : 24.0).rounded()))FPS")
            if let br = bitrateString(stats: stats) {
                badge(br)
            }
        }
    }

    private func badge(_ text: String) -> some View {
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

    private func videoCodecString(stats: DKRuntimeStats) -> String {
        let vCodec = PlayerView.cString(from: stats.video_codec)
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

    private func resolutionString(stats: DKRuntimeStats) -> String {
        let w = stats.width > 0 ? stats.width : Int32(currentItem.primaryVideoStream?.width ?? 0)
        let h = stats.height > 0 ? stats.height : Int32(currentItem.primaryVideoStream?.height ?? 0)
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

    private func bitrateString(stats: DKRuntimeStats) -> String? {
        if stats.video_bitrate_mbps > 0.05 {
            return String(format: "%.1fmbps", stats.video_bitrate_mbps)
        }
        if let br = currentItem.primaryVideoStream?.bitRate, br > 0 {
            return String(format: "%.1fmbps", Double(br) / 1_000_000.0)
        }
        return nil
    }
}

private struct PlayerBottomControlBarView: View {
    @ObservedObject var telemetry: PlayerHUDTelemetry
    let currentItem: EmbyItem
    let episodesCount: Int
    let isPlaying: Bool
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: Double
    @Binding var showRemainingTime: Bool
    @Binding var volume: Float
    @Binding var isMuted: Bool
    let accentColor: Color
    let onAdjacentEpisode: (Int) -> Void
    let onSeekRelative: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onCommitSeek: (Double) -> Void
    let onToggleMute: () -> Void
    let onVolumeChanged: (Float) -> Void
    let formatTime: (Double) -> String
    let audioMenu: () -> AnyView
    let subtitleMenu: () -> AnyView
    let decoderMenu: () -> AnyView
    let speedMenu: () -> AnyView
    let moreMenu: () -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlayerSpecBadgeHostView(telemetry: telemetry, currentItem: currentItem)
                .padding(.leading, 24)
                .padding(.bottom, 8)

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    PlayerConsoleIconButton(
                        systemImage: "backward.end.fill",
                        fontSize: 13.5,
                        isDisabled: episodesCount <= 1,
                        tooltip: "上一集"
                    ) {
                        onAdjacentEpisode(-1)
                    }

                    PlayerConsoleIconButton(
                        systemImage: "gobackward.10",
                        fontSize: 14.5,
                        tooltip: "快退 10 秒"
                    ) {
                        onSeekRelative(-10)
                    }

                    PlayerConsoleIconButton(
                        systemImage: isPlaying ? "pause.fill" : "play.fill",
                        fontSize: 15,
                        fontWeight: .bold,
                        size: 34,
                        prominent: true,
                        tooltip: isPlaying ? "暂停 (空格)" : "播放 (空格)"
                    ) {
                        onTogglePlayPause()
                    }

                    PlayerConsoleIconButton(
                        systemImage: "goforward.10",
                        fontSize: 14.5,
                        tooltip: "快进 10 秒"
                    ) {
                        onSeekRelative(10)
                    }

                    PlayerConsoleIconButton(
                        systemImage: "forward.end.fill",
                        fontSize: 13.5,
                        isDisabled: episodesCount <= 1,
                        tooltip: "下一集"
                    ) {
                        onAdjacentEpisode(1)
                    }

                    Text(formatTime(isScrubbing ? scrubTime : telemetry.currentTime))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(minWidth: 46, alignment: .leading)
                        .padding(.leading, 4)
                }

                PlayerTimelineScrubberView(
                    currentTime: telemetry.currentTime,
                    bufferedAheadSeconds: telemetry.bufferedAheadSeconds,
                    duration: telemetry.duration,
                    accentColor: accentColor,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    onCommitSeek: onCommitSeek
                )

                HStack(spacing: 8) {
                    Button { showRemainingTime.toggle() } label: {
                        Text(showRemainingTime ? "-\(formatTime(max(0, telemetry.duration - telemetry.currentTime)))" : formatTime(telemetry.duration))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(minWidth: 48, minHeight: 28, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("切换显示总时长 / 剩余时长")

                    PlayerConsoleIconButton(
                        systemImage: isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        fontSize: 13.5,
                        tooltip: isMuted ? "取消静音" : "静音"
                    ) {
                        onToggleMute()
                    }

                    MiniVolumeSlider(volume: $volume, isMuted: $isMuted) { v in
                        onVolumeChanged(v)
                    }
                    .padding(.trailing, 4)

                    PlayerCircleMenu(tooltip: "音频轨道") {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .semibold))
                    } menuItems: {
                        audioMenu()
                    }

                    PlayerCircleMenu(tooltip: "字幕选择") {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 12.5, weight: .semibold))
                    } menuItems: {
                        subtitleMenu()
                    }

                    PlayerCircleMenu(tooltip: "解码与显示信息") {
                        Text("D")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    } menuItems: {
                        decoderMenu()
                    }

                    PlayerCircleMenu(tooltip: "播放速度") {
                        Image(systemName: "speedometer")
                            .font(.system(size: 13, weight: .semibold))
                    } menuItems: {
                        speedMenu()
                    }

                    PlayerCircleMenu(tooltip: "更多选项") {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                    } menuItems: {
                        moreMenu()
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
}

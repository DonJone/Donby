import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

extension PlayerView {
    private func drawerGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        PlayerDrawerGlassCard(content: content)
    }

    private func drawerRowBackground(isSelected: Bool) -> some View {
        PlayerDrawerRowBackground(
            isSelected: isSelected,
            isMonochromeTheme: appState.isMonochromeTheme,
            accentColor: appState.accentColor
        )
    }

    func drawerSelectedAccentTint() -> Color {
        appState.isMonochromeTheme ? .white : appState.accentColor
    }

    func drawerDelayStepButton(_ label: String, action: @escaping () -> Void) -> some View {
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

    func drawerSegmentedPill<T: Hashable & Identifiable>(
        options: [T],
        selection: T,
        title: @escaping (T) -> String,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        PlayerDrawerSegmentedPill(options: options, selection: selection, title: title, onSelect: onSelect)
    }

    private var availableDrawerTabs: [PlayerDrawerTab] {
        if companionBox.companion?.showsCompanionDrawerTab == true {
            return PlayerDrawerTab.allCases
        }
        return [.playlist, .tracks, .mediaInfo]
    }

    func rightDrawerPanel(tab: PlayerDrawerTab) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Liquid Glass Drawer Header
            HStack(spacing: 8) {
                drawerSegmentedPill(
                    options: availableDrawerTabs,
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
                            PlayerSubtitleStyleDrawerView(
                                appState: appState,
                                isAdjustingSubtitleLayout: $isAdjustingSubtitleLayout,
                                hasActivePrimary: activeSubtitleSelection != .off,
                                hasActiveSecondary: activeSecondarySubtitleSelection != .off,
                                hasPlayerHandle: playerHandle != nil,
                                isAutoAligningSubtitle: isAutoAligningSubtitle,
                                lastAutoAlignSummary: lastAutoAlignSummary,
                                lastSubtitleAlignUndo: lastSubtitleAlignUndo,
                                secondarySubtitleTimeScale: secondarySubtitleTimeScale,
                                isSecondaryAlignedToPrimary: isSecondaryAlignedToPrimary,
                                accentTint: drawerSelectedAccentTint(),
                                onAutoAlignAudio: { runAutoAlignAudioToSubtitle() },
                                onAutoAlignDual: { runAutoAlignDualSubtitles() },
                                onUndoAlign: { undoLastSubtitleAlignment() },
                                onResetScale: { resetSecondarySubtitleTimeScale() },
                                drawerDelayStepButton: { label, action in
                                    AnyView(drawerDelayStepButton(label, action: action))
                                }
                            )
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

                case .watchParty:
                    watchPartyDrawerContent
                }
            }
        }
        .padding(16)
        .frame(width: 324)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.92))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
            }
            .opacity(isAdjustingSubtitleLayout ? 0.14 : 1.0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(isAdjustingSubtitleLayout ? 0.0 : 0.42), radius: 22, x: -4, y: 8)
        .opacity(isAdjustingSubtitleLayout ? 0.42 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {}
        .padding(.vertical, 14)
        .padding(.trailing, 14)
    }

    func osdInfoRow(_ key: String, _ val: String) -> some View {
        HStack {
            Text(key).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(val).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

struct PlayerDrawerSegmentedPill<T: Hashable & Identifiable>: View {
    let options: [T]
    let selection: T
    let title: (T) -> String
    let onSelect: (T) -> Void

    var body: some View {
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
}

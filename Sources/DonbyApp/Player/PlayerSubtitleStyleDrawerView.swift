import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

/// Non-observable box holding preview-throttling and debounced commit tasks so
/// 120Hz slider drags never trigger redundant SwiftUI updates or UserDefaults writes.
private final class SubtitleDrawerSliderBox {
    var lastPreviewUptime: TimeInterval = 0
    var lastAppliedPreview: SubtitleStyleConfiguration? = nil
    var pendingPreviewTask: Task<Void, Never>? = nil
    var pendingCommitTask: Task<Void, Never>? = nil
}

struct PlayerSubtitleStyleDrawerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var alignmentCoordinator = SubtitleAlignmentCoordinator.shared
    @Binding var isAdjustingSubtitleLayout: Bool
    let hasActivePrimary: Bool
    let hasActiveSecondary: Bool
    let hasPlayerHandle: Bool
    let isAutoAligningSubtitle: Bool
    let lastAutoAlignSummary: String?
    let lastSubtitleAlignUndo: SubtitleAlignUndoState?
    let secondarySubtitleTimeScale: Double
    let isSecondaryAlignedToPrimary: Bool
    let accentTint: Color
    let onAutoAlignAudio: () -> Void
    let onAutoAlignDual: () -> Void
    let onUndoAlign: () -> Void
    let onResetScale: () -> Void
    let onLivePreviewStyle: ((SubtitleStyleConfiguration) -> Void)?
    let drawerDelayStepButton: (String, @escaping () -> Void) -> AnyView

    @State private var showMoreSubtitleOptions: Bool = false
    @State private var draftScale: Double? = nil
    @State private var draftVerticalPos: Double? = nil
    @State private var draftSecondaryScale: Double? = nil
    @State private var draftDualGapPx: Double? = nil
    @State private var draftBorderWidth: Double? = nil
    @State private var sliderBox = SubtitleDrawerSliderBox()

    private var activeAlignmentMode: SubtitleAlignmentMode {
        isAutoAligningSubtitle ? alignmentCoordinator.mode : .none
    }

    private var activeScale: Double {
        draftScale ?? appState.subtitleStyle.scale
    }

    private var activeVerticalPos: Double {
        draftVerticalPos ?? appState.subtitleStyle.verticalPositionPercent
    }

    private var activeSecondaryScale: Double {
        draftSecondaryScale ?? appState.subtitleStyle.secondaryScale
    }

    private var activeDualGapPx: Double {
        draftDualGapPx ?? appState.subtitleStyle.dualSubtitleGapPx
    }

    private var activeBorderWidth: Double {
        draftBorderWidth ?? appState.subtitleStyle.borderWidth
    }

    private func makeDraftStyle(base: SubtitleStyleConfiguration) -> SubtitleStyleConfiguration {
        var preview = base
        if let s = draftScale { preview.scale = s }
        if let v = draftVerticalPos { preview.verticalPositionPercent = v }
        if let sec = draftSecondaryScale { preview.secondaryScale = sec }
        if let gap = draftDualGapPx { preview.dualSubtitleGapPx = gap }
        if let border = draftBorderWidth { preview.borderWidth = border }
        return preview
    }

    private func scheduleLivePreview(_ preview: SubtitleStyleConfiguration, immediate: Bool = false) {
        guard onLivePreviewStyle != nil else { return }
        if preview == sliderBox.lastAppliedPreview { return }
        let now = ProcessInfo.processInfo.systemUptime
        if immediate || (now - sliderBox.lastPreviewUptime >= 0.033 && sliderBox.pendingPreviewTask == nil) {
            sliderBox.pendingPreviewTask?.cancel()
            sliderBox.pendingPreviewTask = nil
            sliderBox.lastPreviewUptime = now
            sliderBox.lastAppliedPreview = preview
            onLivePreviewStyle?(preview)
            return
        }
        sliderBox.pendingPreviewTask?.cancel()
        sliderBox.pendingPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            sliderBox.pendingPreviewTask = nil
            let latest = makeDraftStyle(base: appState.subtitleStyle)
            guard latest != sliderBox.lastAppliedPreview else { return }
            sliderBox.lastPreviewUptime = ProcessInfo.processInfo.systemUptime
            sliderBox.lastAppliedPreview = latest
            onLivePreviewStyle?(latest)
        }
    }

    private func scheduleDebouncedCommit() {
        sliderBox.pendingCommitTask?.cancel()
        sliderBox.pendingCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            sliderBox.pendingCommitTask = nil
            commitPendingDrafts()
        }
    }

    private func commitPendingDrafts() {
        sliderBox.pendingCommitTask?.cancel()
        sliderBox.pendingCommitTask = nil
        sliderBox.pendingPreviewTask?.cancel()
        sliderBox.pendingPreviewTask = nil
        let hasDraft = draftScale != nil
            || draftVerticalPos != nil
            || draftSecondaryScale != nil
            || draftDualGapPx != nil
            || draftBorderWidth != nil
        guard hasDraft else { return }
        let updated = makeDraftStyle(base: appState.subtitleStyle)
        draftScale = nil
        draftVerticalPos = nil
        draftSecondaryScale = nil
        draftDualGapPx = nil
        draftBorderWidth = nil
        if updated != appState.subtitleStyle {
            appState.subtitleStyle = updated
        }
    }

    private func clearAllDraftsAndTasks() {
        sliderBox.pendingPreviewTask?.cancel()
        sliderBox.pendingPreviewTask = nil
        sliderBox.pendingCommitTask?.cancel()
        sliderBox.pendingCommitTask = nil
        sliderBox.lastAppliedPreview = nil
        draftScale = nil
        draftVerticalPos = nil
        draftSecondaryScale = nil
        draftDualGapPx = nil
        draftBorderWidth = nil
    }

    private func draftSliderBinding(
        current: @escaping () -> Double,
        assignDraft: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: current,
            set: { newVal in
                sliderBox.pendingCommitTask?.cancel()
                sliderBox.pendingCommitTask = nil
                assignDraft(newVal)
                scheduleLivePreview(makeDraftStyle(base: appState.subtitleStyle))
            }
        )
    }

    private func handleSliderEditingChanged(_ editing: Bool, affectsLayout: Bool) {
        if affectsLayout {
            withAnimation(.easeInOut(duration: 0.15)) { isAdjustingSubtitleLayout = editing }
        }
        if editing {
            sliderBox.pendingCommitTask?.cancel()
            sliderBox.pendingCommitTask = nil
        } else {
            scheduleLivePreview(makeDraftStyle(base: appState.subtitleStyle), immediate: true)
            scheduleDebouncedCommit()
        }
    }

    private var scaleBinding: Binding<Double> {
        draftSliderBinding(
            current: { activeScale },
            assignDraft: { draftScale = $0 }
        )
    }

    private var verticalPosBinding: Binding<Double> {
        draftSliderBinding(
            current: { activeVerticalPos },
            assignDraft: { draftVerticalPos = $0 }
        )
    }

    private var secondaryScaleBinding: Binding<Double> {
        draftSliderBinding(
            current: { activeSecondaryScale },
            assignDraft: { draftSecondaryScale = $0 }
        )
    }

    private var dualGapPxBinding: Binding<Double> {
        draftSliderBinding(
            current: { activeDualGapPx },
            assignDraft: { draftDualGapPx = $0 }
        )
    }

    private var borderWidthBinding: Binding<Double> {
        draftSliderBinding(
            current: { activeBorderWidth },
            assignDraft: { draftBorderWidth = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        // 样式与对齐 — Liquid Glass card stack
        PlayerDrawerGlassCard {
            Label("智能对齐与延迟", systemImage: "waveform.badge.magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))

            HStack(spacing: 7) {
                let audioAlignDisabled = (!hasActivePrimary || isAutoAligningSubtitle || !hasPlayerHandle)
                Button {
                    onAutoAlignAudio()
                } label: {
                    HStack(spacing: 5) {
                        if activeAlignmentMode == .audioToSubtitle {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("字音对齐")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(audioAlignDisabled ? 0.48 : 0.96))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(audioAlignDisabled ? 0.06 : 0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(audioAlignDisabled ? 0.08 : 0.24), lineWidth: 0.7)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(audioAlignDisabled)
                .help("以音轨为基准，通过 Silero VAD 自动校准字幕时间轴")

                let dualAlignDisabled = (!hasActivePrimary || !hasActiveSecondary || isAutoAligningSubtitle || !hasPlayerHandle)
                Button {
                    onAutoAlignDual()
                } label: {
                    HStack(spacing: 5) {
                        if activeAlignmentMode == .dualSubtitles {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text("双字对齐")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(dualAlignDisabled ? 0.48 : 0.96))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(dualAlignDisabled ? 0.06 : 0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(dualAlignDisabled ? 0.08 : 0.24), lineWidth: 0.7)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(dualAlignDisabled)
                .help("对齐主/副字幕偏移及 23.976/25fps 帧率漂移（自动校验音轨基准）")

                if isAutoAligningSubtitle {
                    Button {
                        alignmentCoordinator.cancel()
                        appState.showToast("已取消字幕对齐", icon: "xmark.circle")
                    } label: {
                        Text("取消")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(accentTint)
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
                } else if lastSubtitleAlignUndo != nil {
                    Button {
                        onUndoAlign()
                    } label: {
                        Text("撤销")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(accentTint)
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
                            onResetScale()
                        } label: {
                            Text("重置速率")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(accentTint)
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
                Text(PlayerView.formatSubtitleDelay(appState.subtitleStyle.primaryDelaySeconds))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                drawerDelayStepButton("-0.5s") { appState.subtitleStyle.primaryDelaySeconds = max(-120, appState.subtitleStyle.primaryDelaySeconds - 0.5) }
                drawerDelayStepButton("0") { appState.subtitleStyle.primaryDelaySeconds = 0 }
                drawerDelayStepButton("+0.5s") { appState.subtitleStyle.primaryDelaySeconds = min(120, appState.subtitleStyle.primaryDelaySeconds + 0.5) }
            }

            if hasActiveSecondary {
                HStack(spacing: 5) {
                    Text("副延迟")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.80))
                    Text(PlayerView.formatSubtitleDelay(appState.subtitleStyle.secondaryDelaySeconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer()
                    drawerDelayStepButton("-0.5s") { appState.subtitleStyle.secondaryDelaySeconds = max(-120, appState.subtitleStyle.secondaryDelaySeconds - 0.5) }
                    drawerDelayStepButton("0") { appState.subtitleStyle.secondaryDelaySeconds = 0 }
                    drawerDelayStepButton("+0.5s") { appState.subtitleStyle.secondaryDelaySeconds = min(120, appState.subtitleStyle.secondaryDelaySeconds + 0.5) }
                }
            }
        }

        PlayerDrawerGlassCard {
            HStack {
                Label("基础样式", systemImage: "textformat.size")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Button {
                    clearAllDraftsAndTasks()
                    let prevDelay1 = appState.subtitleStyle.primaryDelaySeconds
                    let prevDelay2 = appState.subtitleStyle.secondaryDelaySeconds
                    var fresh = SubtitleStyleConfiguration()
                    fresh.primaryDelaySeconds = prevDelay1
                    fresh.secondaryDelaySeconds = prevDelay2
                    appState.subtitleStyle = fresh
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentTint)
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
                    Text(String(format: "%.2fx", activeScale))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                    if abs(activeScale - 1.0) > 0.01 {
                        Button {
                            draftScale = nil
                            appState.subtitleStyle.scale = 1.0
                        } label: {
                            Text("重置")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(accentTint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                DonbySlider(
                    value: scaleBinding,
                    in: 0.6...1.8,
                    step: 0.05,
                    isLightMode: false,
                    accentColor: accentTint,
                    onEditingChanged: { editing in
                        handleSliderEditingChanged(editing, affectsLayout: true)
                    }
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("位置").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(Int(activeVerticalPos))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                    if abs(activeVerticalPos - 92.0) > 0.5 {
                        Button {
                            draftVerticalPos = nil
                            appState.subtitleStyle.verticalPositionPercent = 92.0
                        } label: {
                            Text("重置")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(accentTint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                DonbySlider(
                    value: verticalPosBinding,
                    in: 60...100,
                    step: 1,
                    isLightMode: false,
                    accentColor: accentTint,
                    onEditingChanged: { editing in
                        handleSliderEditingChanged(editing, affectsLayout: true)
                    }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("简繁转换")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                PlayerDrawerSegmentedPill(
                    options: SubtitleTextTransform.allCases,
                    selection: appState.subtitleStyle.transform,
                    title: { $0.shortTitle },
                    onSelect: { appState.subtitleStyle.transform = $0 }
                )
            }
        }

        PlayerDrawerGlassCard {
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
                            Text(String(format: "外语副行比例 %.2fx", activeSecondaryScale))
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                            Spacer()
                            if abs(activeSecondaryScale - 0.60) > 0.01 {
                                Button {
                                    draftSecondaryScale = nil
                                    appState.subtitleStyle.secondaryScale = 0.60
                                } label: {
                                    Text("重置")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(accentTint)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        DonbySlider(
                            value: secondaryScaleBinding,
                            in: 0.45...0.90,
                            step: 0.02,
                            isLightMode: false,
                            accentColor: accentTint,
                            onEditingChanged: { editing in
                                handleSliderEditingChanged(editing, affectsLayout: true)
                            }
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "双语行间距 %.0f px", activeDualGapPx))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                        DonbySlider(
                            value: dualGapPxBinding,
                            in: 2...20,
                            step: 1,
                            isLightMode: false,
                            accentColor: accentTint,
                            onEditingChanged: { editing in
                                handleSliderEditingChanged(editing, affectsLayout: true)
                            }
                        )
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
                        Text(String(format: "描边宽度 %.1f", activeBorderWidth))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                        DonbySlider(
                            value: borderWidthBinding,
                            in: 0...6,
                            step: 0.25,
                            isLightMode: false,
                            accentColor: accentTint,
                            onEditingChanged: { editing in
                                handleSliderEditingChanged(editing, affectsLayout: false)
                            }
                        )
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
                .toggleStyle(
                    DonbySwitchToggleStyle(
                        isLightMode: false,
                        accentColor: accentTint,
                        accentTextColor: appState.isMonochromeTheme ? .black : .white,
                        compact: true
                    )
                )
                .padding(.top, 4)
            }
        }
        }
        .onDisappear {
            commitPendingDrafts()
        }
    }
}

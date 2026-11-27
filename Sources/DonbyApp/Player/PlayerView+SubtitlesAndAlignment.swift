import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork
import DonbyKernelC

enum SubtitleAlignmentMode: Equatable {
    case none
    case audioToSubtitle
    case dualSubtitles
}

@MainActor
final class SubtitleAlignmentCoordinator: ObservableObject {
    static let shared = SubtitleAlignmentCoordinator()
    @Published private(set) var mode: SubtitleAlignmentMode = .none
    private(set) var activeTaskID: UUID? = nil
    private var activeTask: Task<Void, Never>? = nil
    private var onCancelResetState: (() -> Void)? = nil

    func begin(
        mode: SubtitleAlignmentMode,
        onCancelResetState: @escaping () -> Void,
        taskFactory: (UUID) -> Task<Void, Never>
    ) {
        activeTask?.cancel()
        let taskID = UUID()
        self.mode = mode
        self.activeTaskID = taskID
        self.onCancelResetState = onCancelResetState
        self.activeTask = taskFactory(taskID)
    }

    func clear(taskID: UUID) {
        guard activeTaskID == taskID else { return }
        activeTask = nil
        activeTaskID = nil
        mode = .none
        onCancelResetState = nil
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = nil
        mode = .none
        let reset = onCancelResetState
        onCancelResetState = nil
        reset?()
    }
}

extension PlayerView {
    func resolvedDualAnchorMode() -> Int32 {
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

    nonisolated static func makeKernelSubtitleStyleConfig(
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

    func applyKernelSubtitleStyle(styleOverride: SubtitleStyleConfiguration? = nil) {
        guard let handle = playerHandle else { return }
        var cfg = Self.makeKernelSubtitleStyleConfig(styleOverride ?? appState.subtitleStyle, anchorMode: resolvedDualAnchorMode())
        dk_player_set_subtitle_style(handle, &cfg)
        NotificationCenter.default.post(
            name: Notification.Name("DonbyMetalRequestPausedSubtitleRedraw"),
            object: nil,
            userInfo: ["handle": UInt(bitPattern: handle)]
        )
    }

    func cancelActiveSubtitleAlignment(showToast: Bool = false) {
        guard SubtitleAlignmentCoordinator.shared.mode != .none || isAutoAligningSubtitle else { return }
        SubtitleAlignmentCoordinator.shared.cancel()
        if isAutoAligningSubtitle {
            isAutoAligningSubtitle = false
        }
        if showToast {
            appState.showToast("已取消字幕对齐", icon: "xmark.circle")
        }
    }

    func loadRemoteExternalSubtitle(
        item: SubtitleResourceItem,
        embyStreamIndex: Int?,
        silentToast: Bool,
        asSecondary: Bool = false
    ) {
        cancelActiveSubtitleAlignment(showToast: false)
        let expectedSelection: PlayerSubtitleSelection = .remoteExternal(url: item.url)
        if asSecondary {
            activeSecondarySubtitleSelection = expectedSelection
        } else {
            selectedSubIdx = embyStreamIndex
            activeSubtitleSelection = expectedSelection
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
                    let stillSelected = asSecondary
                        ? (self.activeSecondarySubtitleSelection == expectedSelection)
                        : (self.activeSubtitleSelection == expectedSelection)
                    guard self.activePlaybackGeneration == expectedGeneration, stillSelected else { return }
                    if asSecondary {
                        self.activeSecondarySubtitleSelection = .off
                    } else {
                        self.activeSubtitleSelection = .off
                        self.selectedSubIdx = nil
                    }
                    if !silentToast {
                        self.appState.showToast("下载外挂字幕失败", icon: "exclamationmark.triangle.fill", isError: true)
                    }
                }
                return
            }
            let text = decoded.text
            let isAss = (ext == "ass" || ext == "ssa" || text.contains("[Script Info]"))
            await MainActor.run {
                let stillSelected = asSecondary
                    ? (self.activeSecondarySubtitleSelection == expectedSelection)
                    : (self.activeSubtitleSelection == expectedSelection)
                guard self.activePlaybackGeneration == expectedGeneration, stillSelected else { return }
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

    func promptLocalExternalSubtitleFile(asSecondary: Bool = false) {
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
        let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            self.loadLocalExternalSubtitleURL(url, asSecondary: asSecondary, silentToast: false, persist: true)
        }
        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: hostWindow, completionHandler: handleSelection)
        } else {
            panel.begin(completionHandler: handleSelection)
        }
    }

    func loadLocalExternalSubtitleURL(
        _ url: URL,
        asSecondary: Bool,
        silentToast: Bool,
        persist: Bool
    ) {
        cancelActiveSubtitleAlignment(showToast: false)
        let expectedSelection: PlayerSubtitleSelection = .localExternal(url: url)
        let expectedGeneration = activePlaybackGeneration
        if asSecondary {
            secondaryLocalSubtitleName = url.lastPathComponent
            activeSecondarySubtitleSelection = expectedSelection
        } else {
            explicitSubtitleOff = false
            selectedSubIdx = nil
            localExternalSubtitleName = url.lastPathComponent
            activeSubtitleSelection = expectedSelection
        }
        let ext = url.pathExtension.lowercased()
        Task.detached(priority: .userInitiated) {
            let decoded = (try? Data(contentsOf: url)).flatMap {
                SubtitleTextDecoder.decode(data: $0, fileExtension: ext)
            }
            await MainActor.run {
                let stillSelected = asSecondary
                    ? (self.activeSecondarySubtitleSelection == expectedSelection)
                    : (self.activeSubtitleSelection == expectedSelection)
                guard self.activePlaybackGeneration == expectedGeneration, stillSelected else { return }
                guard let decoded else {
                    if asSecondary {
                        self.secondaryLocalSubtitleName = nil
                        self.activeSecondarySubtitleSelection = .off
                    } else {
                        self.localExternalSubtitleName = nil
                        self.activeSubtitleSelection = .off
                    }
                    if !silentToast {
                        self.appState.showToast("读取字幕文件失败", icon: "exclamationmark.triangle.fill", isError: true)
                    }
                    return
                }
                let text = decoded.text
                let isAss = (ext == "ass" || ext == "ssa" || text.contains("[Script Info]"))
                guard let handle = self.playerHandle else { return }
                if asSecondary {
                    self.secondarySubtitleTimeScale = 1.0
                    self.isSecondaryAlignedToPrimary = false
                    dk_player_load_secondary_external_subtitle(handle, text, isAss)
                } else {
                    dk_player_load_external_subtitle(handle, text, isAss)
                }
                self.applyKernelSubtitleStyle()
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
                        self.appState.recordSecondarySubtitleChoice(serverId: self.session.server.id, item: self.currentItem, preference: pref, updateGlobal: false)
                    } else {
                        self.appState.recordPrimarySubtitleChoice(serverId: self.session.server.id, item: self.currentItem, preference: pref, updateGlobal: false)
                    }
                }
                if !silentToast {
                    let tag = asSecondary ? "已加载本地副字幕" : "已加载本地字幕"
                    self.appState.showToast("\(tag): \(url.lastPathComponent) (\(decoded.encoding.rawValue))", icon: "captions.bubble.fill")
                }
            }
        }
    }

    static func formatSubtitleDelay(_ seconds: Double) -> String {
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

    func runAutoAlignAudioToSubtitle() {
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
        let expectedPrimary = activeSubtitleSelection
        let expectedSecondary = activeSecondarySubtitleSelection
        let curPrimaryDelay = appState.subtitleStyle.primaryDelaySeconds
        let curSecondaryDelay = appState.subtitleStyle.secondaryDelaySeconds
        let curSecScale = secondarySubtitleTimeScale
        let prevAligned = isSecondaryAlignedToPrimary
        isAutoAligningSubtitle = true

        SubtitleAlignmentCoordinator.shared.begin(
            mode: .audioToSubtitle,
            onCancelResetState: { self.isAutoAligningSubtitle = false }
        ) { taskID in
            Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard SubtitleAlignmentCoordinator.shared.activeTaskID == taskID else { return }
                        SubtitleAlignmentCoordinator.shared.clear(taskID: taskID)
                        self.isAutoAligningSubtitle = false
                        guard !Task.isCancelled,
                              self.activePlaybackGeneration == generation,
                              self.activeSubtitleSelection == expectedPrimary,
                              self.activeSecondarySubtitleSelection == expectedSecondary,
                              let currentHandle = self.playerHandle else { return }
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
                } catch is CancellationError {
                    await MainActor.run {
                        guard SubtitleAlignmentCoordinator.shared.activeTaskID == taskID else { return }
                        SubtitleAlignmentCoordinator.shared.clear(taskID: taskID)
                        self.isAutoAligningSubtitle = false
                    }
                } catch {
                    await MainActor.run {
                        guard SubtitleAlignmentCoordinator.shared.activeTaskID == taskID else { return }
                        SubtitleAlignmentCoordinator.shared.clear(taskID: taskID)
                        self.isAutoAligningSubtitle = false
                        guard self.activePlaybackGeneration == generation else { return }
                        DonbyLogger.shared.log("字音对齐异常: \(error.localizedDescription)", level: .error, subsystem: "SubtitleAlign")
                        self.appState.showToast(error.localizedDescription, icon: "exclamationmark.triangle.fill", isError: true)
                    }
                }
            }
        }
    }

    func runAutoAlignDualSubtitles() {
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
        let expectedPrimary = activeSubtitleSelection
        let expectedSecondary = activeSecondarySubtitleSelection
        let curPrimaryDelay = appState.subtitleStyle.primaryDelaySeconds
        let curSecondaryDelay = appState.subtitleStyle.secondaryDelaySeconds
        let curSecScale = secondarySubtitleTimeScale
        let prevAligned = isSecondaryAlignedToPrimary
        isAutoAligningSubtitle = true

        SubtitleAlignmentCoordinator.shared.begin(
            mode: .dualSubtitles,
            onCancelResetState: { self.isAutoAligningSubtitle = false }
        ) { taskID in
            Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard SubtitleAlignmentCoordinator.shared.activeTaskID == taskID else { return }
                        SubtitleAlignmentCoordinator.shared.clear(taskID: taskID)
                        self.isAutoAligningSubtitle = false
                    }
                    return
                }
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
                    guard SubtitleAlignmentCoordinator.shared.activeTaskID == taskID else { return }
                    SubtitleAlignmentCoordinator.shared.clear(taskID: taskID)
                    self.isAutoAligningSubtitle = false
                    guard !Task.isCancelled,
                          self.activePlaybackGeneration == generation,
                          self.activeSubtitleSelection == expectedPrimary,
                          self.activeSecondarySubtitleSelection == expectedSecondary,
                          let currentHandle = self.playerHandle else { return }
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
    }

    func undoLastSubtitleAlignment() {
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

    func resetSecondarySubtitleTimeScale() {
        secondarySubtitleTimeScale = 1.0
        if let handle = playerHandle {
            dk_player_set_secondary_subtitle_time_scale(handle, 1.0)
            applyKernelSubtitleStyle()
        }
        lastAutoAlignSummary = "副字幕速率已重置为 1.0000x"
        appState.showToast("副字幕速率已重置为 1.0x", icon: "arrow.counterclockwise")
    }
}

#if canImport(DonbyUHDModule)
import SwiftUI
import AppKit
import DonbyCore
import DonbyUHDModule

// MARK: - Watch Party Join & Create Sheets

public struct UHDWatchPartyJoinSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    @State private var rawInvite: String = ""
    @State private var isJoining: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("加入同看")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("输入 8 位邀请码或粘贴分享链接")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Spacer()
                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("8 位邀请码或链接", text: $rawInvite)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .donbyFlatTextField(isLight: appState.isLightMode)
                    .onSubmit { Task { await joinNow() } }

                Button {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        rawInvite = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("粘贴")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await joinNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isJoining { ProgressView().controlSize(.small) }
                        Text("加入")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(UHDWatchPartyInviteParser.extractInviteCode(from: rawInvite) == nil || isJoining)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func joinNow() async {
        guard !isJoining else { return }
        errorMessage = nil
        isJoining = true
        defer { isJoining = false }
        do {
            try await UHDModuleManager.shared.joinAndStartWatchParty(server: server, rawInvite: rawInvite, appState: appState)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct UHDWatchPartyCreateSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig
    public let item: EmbyItem
    public let preferredSourceId: String?

    @State private var maxMembers: Int = 4
    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig, item: EmbyItem, preferredSourceId: String?) {
        self.server = server
        self.item = item
        self.preferredSourceId = preferredSourceId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("创建同看")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(item.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }
                Spacer()
                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("人数上限")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        if maxMembers > 2 { maxMembers -= 1 }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(maxMembers <= 2)

                    Text("\(maxMembers) 人")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .frame(minWidth: 42)

                    Button {
                        if maxMembers < 10 { maxMembers += 1 }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .donbyLiquidGlassCapsule()
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(maxMembers >= 10)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await createNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text("创建房间")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func createNow() async {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await UHDModuleManager.shared.createAndStartWatchParty(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId,
                maxMembers: maxMembers,
                appState: appState
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Zero-Stutter Native CALayer Danmu Overlay & Picker

/// Immutable reference container so holding thousands of danmu comments on PlayerView
/// never triggers O(N) SwiftUI Equatable array diffing on HUD updates.
public final class UHDDanmuTrack: @unchecked Sendable {
    private static var nextRevision: UInt64 = 1

    public let revision: UInt64
    public let title: String
    public let comments: [UHDDanmuComment]

    public init(title: String, comments: [UHDDanmuComment]) {
        self.revision = Self.nextRevision
        Self.nextRevision &+= 1
        self.title = title
        self.comments = comments
    }
}

public struct UHDDanmuLiveOverlay: NSViewRepresentable {
    public let track: UHDDanmuTrack?
    public let isEnabled: Bool
    public let isPlaying: Bool
    public let playbackRate: Double
    public let opacity: Double
    public let timeProvider: () -> (baseTime: Double, baseUptime: TimeInterval)

    public init(
        track: UHDDanmuTrack?,
        isEnabled: Bool,
        isPlaying: Bool,
        playbackRate: Double,
        opacity: Double = 0.88,
        timeProvider: @escaping () -> (baseTime: Double, baseUptime: TimeInterval)
    ) {
        self.track = track
        self.isEnabled = isEnabled
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.opacity = opacity
        self.timeProvider = timeProvider
    }

    public func makeNSView(context: Context) -> DanmuSpriteHostView {
        let view = DanmuSpriteHostView()
        view.configure(
            track: track,
            isEnabled: isEnabled,
            isPlaying: isPlaying,
            playbackRate: playbackRate,
            opacity: opacity,
            timeProvider: timeProvider
        )
        return view
    }

    public func updateNSView(_ nsView: DanmuSpriteHostView, context: Context) {
        nsView.configure(
            track: track,
            isEnabled: isEnabled,
            isPlaying: isPlaying,
            playbackRate: playbackRate,
            opacity: opacity,
            timeProvider: timeProvider
        )
    }

    public static func dismantleNSView(_ nsView: DanmuSpriteHostView, coordinator: ()) {
        nsView.shutdown()
    }
}

/// Hardware-composited CoreAnimation `CATextLayer` Danmu renderer:
/// - Zero main-thread `CGContext` bitmap allocations: uses a pre-allocated pool of reusable `CATextLayer`s.
/// - Zero 60fps main-thread position polling: hands off scrolling trajectories via `CABasicAnimation(keyPath: "position.x")`
///   directly to the macOS WindowServer GPU compositor process (120Hz ProMotion, ~0% app CPU).
/// - Uses a lightweight 4Hz (250ms) scheduler and lane collision avoidance so high-volume shows never stutter.
public final class DanmuSpriteHostView: NSView {
    private struct ActiveSprite {
        let layer: CATextLayer
        let lane: Int
        let isStatic: Bool
        let isBottom: Bool
        let startTime: Double
        let duration: Double
        let width: CGFloat
        let height: CGFloat
    }

    private var track: UHDDanmuTrack?
    private var trackRevision: UInt64 = 0
    private var isDanmuEnabled: Bool = false
    private var isPlaying: Bool = false
    private var isLayerPaused: Bool = false
    private var playbackRate: Double = 1.0
    private var danmuOpacity: Double = 0.88
    private var timeProvider: (() -> (baseTime: Double, baseUptime: TimeInterval))?

    private var timer: Timer?
    private var nextIndex: Int = 0
    private var lastObservedTime: Double = -1
    private var activeSprites: [ActiveSprite] = []
    private var recycledLayers: [CATextLayer] = []
    private let maxConcurrentSprites: Int = 36

    private static let danmuFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
    private static let measureAttrs: [NSAttributedString.Key: Any] = [.font: danmuFont]
    private static let laneHeight: CGFloat = 30
    private static let topMargin: CGFloat = 46
    private static let scrollDuration: Double = 9.0
    private static let staticDuration: Double = 4.2

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public func configure(
        track: UHDDanmuTrack?,
        isEnabled: Bool,
        isPlaying: Bool,
        playbackRate: Double,
        opacity: Double,
        timeProvider: @escaping () -> (baseTime: Double, baseUptime: TimeInterval)
    ) {
        let newRev = track?.revision ?? 0
        let trackChanged = (newRev != trackRevision)
        self.track = track
        self.trackRevision = newRev
        self.isDanmuEnabled = isEnabled
        self.isPlaying = isPlaying
        self.playbackRate = max(0.25, playbackRate)
        self.danmuOpacity = opacity
        self.timeProvider = timeProvider

        if !isEnabled || track == nil || (track?.comments.isEmpty ?? true) {
            stopTimer()
            clearAllSprites()
            isHidden = true
            return
        }

        isHidden = false
        if trackChanged {
            clearAllSprites()
            lastObservedTime = -1
        }

        if isPlaying {
            resumeHostLayerIfNeeded()
            startTimerIfNeeded()
        } else {
            pauseHostLayerIfNeeded()
            stopTimer()
        }
    }

    public func shutdown() {
        stopTimer()
        clearAllSprites()
        recycledLayers.removeAll()
    }

    private func pauseHostLayerIfNeeded() {
        guard !isLayerPaused, let hostLayer = layer else { return }
        let pausedTime = hostLayer.convertTime(CACurrentMediaTime(), from: nil)
        hostLayer.speed = 0.0
        hostLayer.timeOffset = pausedTime
        isLayerPaused = true
    }

    private func resumeHostLayerIfNeeded() {
        guard let hostLayer = layer else { return }
        if isLayerPaused {
            let pausedTime = hostLayer.timeOffset
            hostLayer.speed = 1.0
            hostLayer.timeOffset = 0.0
            hostLayer.beginTime = 0.0
            let timeSincePause = hostLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            hostLayer.beginTime = timeSincePause
            isLayerPaused = false
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // 5Hz scheduler (200ms) is sufficient because WindowServer GPU animates position.x continuously at 120Hz
        let t = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func dequeueLayer() -> CATextLayer {
        if let reused = recycledLayers.popLast() {
            reused.removeAllAnimations()
            return reused
        }
        let l = CATextLayer()
        l.font = Self.danmuFont
        l.fontSize = 19
        l.alignmentMode = .left
        l.isWrapped = false
        l.truncationMode = .none
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.88
        l.shadowRadius = 1.6
        l.shadowOffset = CGSize(width: 1.0, height: 1.0)
        return l
    }

    private func recycleLayer(_ l: CATextLayer) {
        l.removeAllAnimations()
        l.removeFromSuperlayer()
        if recycledLayers.count < maxConcurrentSprites {
            recycledLayers.append(l)
        }
    }

    private func clearAllSprites() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in activeSprites {
            recycleLayer(s.layer)
        }
        CATransaction.commit()
        activeSprites.removeAll(keepingCapacity: true)
    }

    private func currentPlaybackTime() -> Double {
        guard let provider = timeProvider else { return 0 }
        let sample = provider()
        let dt = isPlaying ? max(0, min(1.5, ProcessInfo.processInfo.systemUptime - sample.baseUptime)) : 0
        return sample.baseTime + dt * playbackRate
    }

    private func lowerBound(comments: [UHDDanmuComment], time: Double) -> Int {
        var lo = 0
        var hi = comments.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if comments[mid].timeSeconds < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    private func tick() {
        guard isDanmuEnabled, isPlaying, let comments = track?.comments, !comments.isEmpty else {
            return
        }
        let width = bounds.width
        let height = bounds.height
        guard width > 40, height > 40, let hostLayer = layer else { return }

        let now = currentPlaybackTime()

        // Detect seek or initial positioning -> O(log N) jump
        if lastObservedTime < 0 || now < lastObservedTime - 0.25 || (now - lastObservedTime) > 1.8 {
            clearAllSprites()
            nextIndex = lowerBound(comments: comments, time: max(0, now - 0.15))
        }
        lastObservedTime = now

        let maxScrollLanes = max(4, min(10, Int((height * 0.48) / Self.laneHeight)))
        let scale = window?.backingScaleFactor ?? 2.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Prune expired sprites
        var writeIdx = 0
        for i in 0..<activeSprites.count {
            let sprite = activeSprites[i]
            let age = now - sprite.startTime
            if age > sprite.duration {
                recycleLayer(sprite.layer)
                continue
            }
            activeSprites[writeIdx] = sprite
            writeIdx += 1
        }
        if writeIdx < activeSprites.count {
            activeSprites.removeSubrange(writeIdx..<activeSprites.count)
        }

        // 2. Spawn newly arrived comments within the 200ms lookahead window using GPU CABasicAnimation
        var spawnedThisTick = 0
        let maxSpawnPerTick = 6

        while nextIndex < comments.count && comments[nextIndex].timeSeconds <= now + 0.22 {
            let c = comments[nextIndex]
            nextIndex += 1

            let age = now - c.timeSeconds
            let isStatic = (c.mode == 4 || c.mode == 5)
            let baseLife = isStatic ? Self.staticDuration : Self.scrollDuration
            let effectiveLife = baseLife / max(0.5, min(2.0, playbackRate))
            guard age >= -0.25 && age <= 0.6 else { continue }
            guard activeSprites.count < maxConcurrentSprites, spawnedThisTick < maxSpawnPerTick else { continue }

            let chosenLane: Int?
            if isStatic {
                let isBottom = (c.mode == 4)
                var occupied = Set<Int>()
                for s in activeSprites where s.isStatic && s.isBottom == isBottom {
                    occupied.insert(s.lane)
                }
                chosenLane = (0..<4).first(where: { !occupied.contains($0) })
            } else {
                var laneRightmostEdge = [CGFloat](repeating: -.greatestFiniteMagnitude, count: maxScrollLanes)
                for s in activeSprites where !s.isStatic && s.lane < maxScrollLanes {
                    let sAge = max(0, now - s.startTime)
                    let sProg = CGFloat(min(1.0, sAge / max(0.1, s.duration)))
                    let leftX = width - sProg * (width + s.width + 28)
                    let rightEdge = leftX + s.width
                    if rightEdge > laneRightmostEdge[s.lane] {
                        laneRightmostEdge[s.lane] = rightEdge
                    }
                }
                chosenLane = (0..<maxScrollLanes).first(where: { laneRightmostEdge[$0] < width - 32 })
            }

            guard let lane = chosenLane else { continue }

            let measured = (c.text as NSString).size(withAttributes: Self.measureAttrs)
            let itemSize = CGSize(width: ceil(measured.width) + 6, height: ceil(measured.height) + 4)
            guard itemSize.width > 2, itemSize.height > 2 else { continue }

            let r = CGFloat((c.colorRGB >> 16) & 0xFF) / 255.0
            let g = CGFloat((c.colorRGB >> 8) & 0xFF) / 255.0
            let b = CGFloat(c.colorRGB & 0xFF) / 255.0

            let textLayer = dequeueLayer()
            textLayer.contentsScale = scale
            textLayer.string = c.text
            textLayer.foregroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0).cgColor
            textLayer.bounds = CGRect(origin: .zero, size: itemSize)
            textLayer.opacity = Float(danmuOpacity)

            if isStatic {
                let isBottom = (c.mode == 4)
                let y: CGFloat = isBottom
                    ? max(Self.topMargin, height - 116 - CGFloat(lane) * Self.laneHeight)
                    : Self.topMargin + CGFloat(lane) * Self.laneHeight
                textLayer.position = CGPoint(x: width * 0.5, y: y + itemSize.height * 0.5)
            } else {
                let startX = width + itemSize.width * 0.5
                let endX = -itemSize.width * 0.5 - 28
                let y = Self.topMargin + CGFloat(lane) * Self.laneHeight + itemSize.height * 0.5
                textLayer.position = CGPoint(x: endX, y: y)

                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = startX
                anim.toValue = endX
                anim.duration = effectiveLife
                anim.timingFunction = CAMediaTimingFunction(name: .linear)
                anim.isRemovedOnCompletion = false
                anim.fillMode = .both
                textLayer.add(anim, forKey: "danmuScroll")
            }

            hostLayer.addSublayer(textLayer)
            activeSprites.append(
                ActiveSprite(
                    layer: textLayer,
                    lane: lane,
                    isStatic: isStatic,
                    isBottom: c.mode == 4,
                    startTime: now,
                    duration: effectiveLife,
                    width: itemSize.width,
                    height: itemSize.height
                )
            )
            spawnedThisTick += 1
        }

        CATransaction.commit()
    }
}

public struct UHDDanmuPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig
    public let initialKeyword: String
    public let onSelectEpisode: (String, Int, [UHDDanmuComment]) -> Void

    @State private var keyword: String
    @State private var animes: [UHDDanmuAnimeMatch] = []
    @State private var selectedAnime: UHDDanmuAnimeMatch? = nil
    @State private var episodes: [UHDDanmuEpisodeOption] = []
    @State private var isSearching: Bool = false
    @State private var isLoadingComments: Bool = false
    @State private var errorMessage: String? = nil

    public init(
        server: EmbyServerConfig,
        initialKeyword: String,
        onSelectEpisode: @escaping (String, Int, [UHDDanmuComment]) -> Void
    ) {
        self.server = server
        self.initialKeyword = initialKeyword
        self.onSelectEpisode = onSelectEpisode
        self._keyword = State(initialValue: initialKeyword)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("匹配弹幕")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                TextField("搜索名称", text: $keyword)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .donbyFlatTextField(isLight: false)
                    .onSubmit { Task { await runSearch() } }
                Button {
                    Task { await runSearch() }
                } label: {
                    Text("搜索")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("剧目 (\(animes.count))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(animes) { anime in
                                let isSel = selectedAnime?.animeId == anime.animeId
                                Button {
                                    selectedAnime = anime
                                    Task { await loadEpisodes(animeId: anime.animeId) }
                                } label: {
                                    HStack {
                                        Text(anime.animeTitle)
                                            .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(isSel ? Color.white.opacity(0.18) : Color.white.opacity(0.05)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 250)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("分集 (\(episodes.count))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(episodes) { ep in
                                Button {
                                    Task { await pickEpisode(ep) }
                                } label: {
                                    HStack {
                                        Text(ep.episodeTitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Spacer()
                                        if isLoadingComments {
                                            ProgressView().controlSize(.mini)
                                        }
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoadingComments)
                            }
                        }
                    }
                    .frame(height: 250)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(red: 0.09, green: 0.095, blue: 0.115))
        .preferredColorScheme(.dark)
        .task {
            if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await runSearch()
            }
        }
    }

    private func runSearch() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await UHDDanmuClient.shared.searchAnime(server: server, keyword: keyword)
            animes = found
            if let first = found.first {
                selectedAnime = first
                await loadEpisodes(animeId: first.animeId)
            } else {
                episodes = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEpisodes(animeId: Int) async {
        errorMessage = nil
        do {
            episodes = try await UHDDanmuClient.shared.fetchBangumiEpisodes(server: server, animeId: animeId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickEpisode(_ ep: UHDDanmuEpisodeOption) async {
        isLoadingComments = true
        errorMessage = nil
        defer { isLoadingComments = false }
        do {
            let list = try await UHDDanmuClient.shared.fetchComments(server: server, commentId: ep.episodeId)
            let label = [selectedAnime?.animeTitle, ep.episodeTitle].compactMap { $0 }.joined(separator: " · ")
            onSelectEpisode(label, ep.episodeId, list)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Reactive Watch Party HUD Subviews

public struct WatchPartyTopStatusPill: View {
    @ObservedObject public var session: UHDWatchPartySession
    public let onTap: () -> Void

    public init(session: UHDWatchPartySession, onTap: @escaping () -> Void) {
        self.session = session
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.connectionState == .connected ? Color.green : Color.orange)
                    .frame(width: 6.5, height: 6.5)
                Text("同看 \(session.snapshot?.members.count ?? 1)/\(session.snapshot?.maxMembers ?? 4)")
                    .font(.system(size: 11.5, weight: .semibold))
                if let inv = session.inviteCode, !inv.isEmpty {
                    Text(UHDLoginCodeNormalizer.formattedDisplay(inv))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("同看房间")
    }
}

public struct WatchPartyActiveRoomDrawerView: View {
    @ObservedObject public var session: UHDWatchPartySession
    public let accentColor: Color
    public let onCopyToast: (String, String) -> Void
    public let onLeave: () -> Void
    public let onEnd: () -> Void

    public init(
        session: UHDWatchPartySession,
        accentColor: Color,
        onCopyToast: @escaping (String, String) -> Void,
        onLeave: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.session = session
        self.accentColor = accentColor
        self.onCopyToast = onCopyToast
        self.onLeave = onLeave
        self.onEnd = onEnd
    }

    public var body: some View {
        let snap = session.snapshot
        VStack(alignment: .leading, spacing: 10) {
            card {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.connectionState == .connected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(snap?.localizedPhase ?? "连接中...")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text(session.isHost ? "房主" : "成员")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(session.isHost ? accentColor.opacity(0.65) : Color.white.opacity(0.14)))
                }

                if let invite = session.inviteCode, !invite.isEmpty {
                    HStack(spacing: 8) {
                        Text(UHDLoginCodeNormalizer.formattedDisplay(invite))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(invite, forType: .string)
                            onCopyToast("已复制邀请码 \(invite)", "doc.on.doc.fill")
                        } label: {
                            Text("复制邀请码")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            let link = "\(session.server.mainLineURL)/stream/play?invite=\(invite)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            onCopyToast("已复制邀请链接", "link")
                        } label: {
                            Text("复制链接")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if session.isHost, let snap {
                    Divider().opacity(0.20)
                    HStack {
                        Text(snap.locked ? "已锁定" : "开放加入")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer()
                        Button {
                            let targetLock = !snap.locked
                            Task {
                                try? await UHDWatchPartyClient.shared.setLocked(server: session.server, roomId: session.roomId, locked: targetLock)
                            }
                        } label: {
                            Text(snap.locked ? "解锁" : "锁定")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(snap.locked ? Color.orange.opacity(0.45) : Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let members = snap?.members {
                card {
                    Text("成员 (\(members.count)/\(snap?.maxMembers ?? 10))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))

                    ForEach(members) { m in
                        let memberIsHost = (m.userId == snap?.hostId)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(m.online ? Color.green : Color.gray)
                                .frame(width: 6.5, height: 6.5)
                            Text(m.name)
                                .font(.system(size: 12, weight: memberIsHost ? .bold : .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if memberIsHost {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.yellow)
                            }
                            Spacer()
                            Text(m.localizedStatus)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.62))

                            if session.isHost && !memberIsHost {
                                Menu {
                                    Button("移交房主") {
                                        Task { try? await UHDWatchPartyClient.shared.transferHost(server: session.server, roomId: session.roomId, userId: m.userId) }
                                    }
                                    Button("移出房间", role: .destructive) {
                                        Task { try? await UHDWatchPartyClient.shared.kickMember(server: session.server, roomId: session.roomId, userId: m.userId) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Circle())
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .menuIndicator(.hidden)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: onLeave) {
                    Text("退出房间")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                if session.isHost {
                    Button(action: onEnd) {
                        Text("结束房间")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.16)))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.65))
    }
}
#endif

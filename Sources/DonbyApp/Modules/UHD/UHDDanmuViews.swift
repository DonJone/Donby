#if canImport(DonbyUHDModule)
import SwiftUI
import AppKit
import DonbyCore
import DonbyUHDModule

// MARK: - Watch Party Join & Create Sheets

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

#endif

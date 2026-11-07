import SwiftUI
import Combine
import AppKit
import DonbyCore
import DonbyNetwork

/// Captures macOS two-finger trackpad horizontal swipes over its host bounds without
/// intercepting vertical scrolling or button hit-testing.
private struct TrackpadHorizontalSwipeDetector: NSViewRepresentable {
    let onSwipeNext: () -> Void
    let onSwipePrev: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipeNext: onSwipeNext, onSwipePrev: onSwipePrev)
    }

    func makeNSView(context: Context) -> AnchorNSView {
        let view = AnchorNSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: AnchorNSView, context: Context) {
        context.coordinator.onSwipeNext = onSwipeNext
        context.coordinator.onSwipePrev = onSwipePrev
    }

    static func dismantleNSView(_ nsView: AnchorNSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var onSwipeNext: () -> Void
        var onSwipePrev: () -> Void
        private weak var anchorView: NSView?
        private var monitor: Any?
        private var accumulatedDeltaX: CGFloat = 0
        private var didFireForCurrentSwipe: Bool = false
        private var lastDiscreteTriggerTime: TimeInterval = 0

        init(onSwipeNext: @escaping () -> Void, onSwipePrev: @escaping () -> Void) {
            self.onSwipeNext = onSwipeNext
            self.onSwipePrev = onSwipePrev
        }

        func attach(to view: NSView) {
            detach()
            self.anchorView = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self else { return event }
                return self.handleScrollWheel(event)
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard let view = anchorView,
                  let win = view.window,
                  event.window === win,
                  win.isVisible else {
                return event
            }

            let localPt = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(localPt) else {
                return event
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // Reset state at gesture start / completion
            if event.phase == .began {
                accumulatedDeltaX = 0
                didFireForCurrentSwipe = false
            } else if event.phase == .ended || event.phase == .cancelled {
                accumulatedDeltaX = 0
                didFireForCurrentSwipe = false
            }

            // Let vertical page scrolling pass through untouched
            guard abs(dx) > abs(dy) * 1.15, abs(dx) > 0.4 else {
                return event
            }

            // Ignore post-lift trackpad inertia so one flick advances exactly one poster
            if !event.momentumPhase.isEmpty {
                return nil
            }

            if event.hasPreciseScrollingDeltas {
                guard !didFireForCurrentSwipe else { return nil }
                // Normalize finger motion: swiping two fingers LEFT advances to next poster
                let fingerDeltaX = event.isDirectionInvertedFromDevice ? dx : -dx
                accumulatedDeltaX += fingerDeltaX
                let threshold: CGFloat = 28.0
                if accumulatedDeltaX <= -threshold {
                    didFireForCurrentSwipe = true
                    accumulatedDeltaX = 0
                    DispatchQueue.main.async { self.onSwipeNext() }
                } else if accumulatedDeltaX >= threshold {
                    didFireForCurrentSwipe = true
                    accumulatedDeltaX = 0
                    DispatchQueue.main.async { self.onSwipePrev() }
                }
                return nil
            } else {
                // Discrete horizontal scroll wheel / tilt wheel with cooldown
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastDiscreteTriggerTime > 0.35 else { return nil }
                lastDiscreteTriggerTime = now
                if dx < 0 {
                    DispatchQueue.main.async { self.onSwipeNext() }
                } else {
                    DispatchQueue.main.async { self.onSwipePrev() }
                }
                return nil
            }
        }

        deinit {
            detach()
        }
    }
}

public struct MainCarouselView: View {
    @EnvironmentObject private var appState: AppState
    public let items: [EmbyItem]
    public let onPlay: (EmbyItem) -> Void
    public let onSelectDetail: (EmbyItem) -> Void

    @State private var currentIndex: Int = 0
    @State private var isHovering: Bool = false
    @State private var slideDirection: Int = 1
    @State private var lastManualInteraction: Date = .distantPast

    private let timer = Timer.publish(every: 6.0, on: .main, in: .common).autoconnect()

    public init(
        items: [EmbyItem],
        onPlay: @escaping (EmbyItem) -> Void,
        onSelectDetail: @escaping (EmbyItem) -> Void
    ) {
        self.items = items
        self.onPlay = onPlay
        self.onSelectDetail = onSelectDetail
    }

    private var currentItem: EmbyItem? {
        guard !items.isEmpty else { return nil }
        let safeIdx = max(0, min(currentIndex, items.count - 1))
        return items[safeIdx]
    }

    private func stepSlide(_ delta: Int) {
        guard items.count > 1 else { return }
        slideDirection = delta >= 0 ? 1 : -1
        lastManualInteraction = Date()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            currentIndex = (currentIndex + delta + items.count) % items.count
        }
    }

    public var body: some View {
        if let item = currentItem {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(
                    server: appState.activeServer,
                    item: item,
                    kind: .backdrop,
                    maxWidth: 1600
                )
                .id(item.id)
                .frame(maxWidth: .infinity)
                .frame(height: 365)
                .clipped()
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: CGFloat(slideDirection) * 28)),
                        removal: .opacity
                    )
                )

                LinearGradient(
                    colors: [Color.black.opacity(0.86), Color.black.opacity(0.42), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.34), Color.black.opacity(0.90)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        if let res = item.resolutionBadge {
                            Text(res)
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(appState.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let audioTag = item.audioSummaryTag {
                            Text(audioTag)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let rating = item.communityRating, rating > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                                Text(String(format: "%.1f", rating))
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.black.opacity(0.45)).clipShape(Capsule())
                        }
                        if let year = item.productionYear {
                            Text(String(year)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                        }
                        if let genres = item.genres, !genres.isEmpty {
                            Text(genres.prefix(2).joined(separator: " · "))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let tagline = item.taglines?.first, !tagline.isEmpty {
                            Text(tagline).font(.system(size: 13, weight: .semibold)).foregroundStyle(appState.accentColor).lineLimit(1)
                        }
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(2)
                            .frame(maxWidth: 580, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        LiquidGlassCapsuleButton(
                            title: item.resumePositionSeconds > 0 ? "继续播放" : "立即播放",
                            systemImage: "play.fill",
                            tint: appState.accentColor,
                            horizontalPadding: 24,
                            verticalPadding: 11,
                            fontSize: 14
                        ) {
                            onPlay(item)
                        }

                        LiquidGlassCapsuleButton(
                            title: "详情",
                            systemImage: "info.circle.fill",
                            tint: nil,
                            horizontalPadding: 20,
                            verticalPadding: 11,
                            fontSize: 14
                        ) {
                            onSelectDetail(item)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .padding(.trailing, 160) // reserve room for indicators
            }
            .frame(height: 365)
            .background(
                TrackpadHorizontalSwipeDetector(
                    onSwipeNext: { stepSlide(1) },
                    onSwipePrev: { stepSlide(-1) }
                )
            )
            .gesture(
                DragGesture(minimumDistance: 28)
                    .onEnded { val in
                        guard abs(val.translation.width) > abs(val.translation.height) else { return }
                        if val.translation.width < -32 {
                            stepSlide(1)
                        } else if val.translation.width > 32 {
                            stepSlide(-1)
                        }
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if isHovering && items.count > 1 {
                    HStack {
                        LiquidGlassCircleButton(
                            systemImage: "chevron.left",
                            size: 36,
                            tooltip: "上一部 (支持触控板双指左右滑动)"
                        ) {
                            stepSlide(-1)
                        }
                        Spacer()
                        LiquidGlassCircleButton(
                            systemImage: "chevron.right",
                            size: 36,
                            tooltip: "下一部 (支持触控板双指左右滑动)"
                        ) {
                            stepSlide(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                }
            }
            .overlay(
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, _ in
                        Capsule()
                            .fill(idx == currentIndex ? appState.accentColor : Color.white.opacity(0.34))
                            .frame(width: idx == currentIndex ? 22 : 7, height: 7)
                            .onTapGesture {
                                slideDirection = idx >= currentIndex ? 1 : -1
                                lastManualInteraction = Date()
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { currentIndex = idx }
                            }
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(DonbyLiquidGlassCapsuleSurface(tint: nil, isHovered: false))
                .padding(.trailing, 24)
                .padding(.bottom, 24),
                alignment: .bottomTrailing
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.08), Color.white.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .onHover { h in withAnimation(.easeInOut(duration: 0.2)) { isHovering = h } }
            .onReceive(timer) { _ in
                guard !isHovering && items.count > 1 && Date().timeIntervalSince(lastManualInteraction) > 5.0 else { return }
                slideDirection = 1
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { currentIndex = (currentIndex + 1) % items.count }
            }
        }
    }
}

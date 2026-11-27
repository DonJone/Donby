import SwiftUI
import Combine
import AppKit
import DonbyCore
import DonbyNetwork

/// Hosts `MainCarouselView` inside `NativeEmbyHomeView` and intercepts two-finger trackpad
/// horizontal swipes directly via AppKit's responder chain (`scrollWheel(with:)`) while
/// forwarding vertical scrolling cleanly to the enclosing `NonDraggableScrollView`.
final class CarouselHostingView: NSHostingView<AnyView> {
    private enum ScrollAxis {
        case undecided
        case horizontal
        case vertical
    }

    var onHorizontalSwipe: ((Int) -> Void)?

    private var activeGestureAxis: ScrollAxis = .undecided
    private var momentumAxis: ScrollAxis = .undecided
    private var accumulatedAbsX: CGFloat = 0
    private var accumulatedAbsY: CGFloat = 0
    private var accumulatedDeltaX: CGFloat = 0
    private var didFireForCurrentSwipe: Bool = false
    private var lastCooldownTriggerTime: TimeInterval = 0
    private var pendingBeganEvent: NSEvent?

    private func resetActiveTracking() {
        activeGestureAxis = .undecided
        accumulatedAbsX = 0
        accumulatedAbsY = 0
        accumulatedDeltaX = 0
        didFireForCurrentSwipe = false
        pendingBeganEvent = nil
    }

    private func handleHorizontalDelta(_ event: NSEvent) {
        guard !didFireForCurrentSwipe else { return }
        let dx = event.scrollingDeltaX
        // Normalize finger motion: swiping two fingers LEFT advances to next poster (+1)
        let fingerDeltaX = event.isDirectionInvertedFromDevice ? dx : -dx
        accumulatedDeltaX += fingerDeltaX
        let threshold: CGFloat = 14.0
        if accumulatedDeltaX <= -threshold {
            didFireForCurrentSwipe = true
            accumulatedDeltaX = 0
            onHorizontalSwipe?(1)
        } else if accumulatedDeltaX >= threshold {
            didFireForCurrentSwipe = true
            accumulatedDeltaX = 0
            onHorizontalSwipe?(-1)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let absX = abs(event.scrollingDeltaX)
        let absY = abs(event.scrollingDeltaY)

        // Phaseless scroll events (discrete mouse wheel or smooth-scroll utilities)
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            if absY >= absX {
                nextResponder?.scrollWheel(with: event)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastCooldownTriggerTime > 0.35 else { return }
            if event.hasPreciseScrollingDeltas {
                let fingerDeltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                accumulatedDeltaX += fingerDeltaX
                if accumulatedDeltaX <= -14.0 {
                    lastCooldownTriggerTime = now
                    accumulatedDeltaX = 0
                    onHorizontalSwipe?(1)
                } else if accumulatedDeltaX >= 14.0 {
                    lastCooldownTriggerTime = now
                    accumulatedDeltaX = 0
                    onHorizontalSwipe?(-1)
                }
            } else if absX > 0.5 {
                lastCooldownTriggerTime = now
                onHorizontalSwipe?(event.scrollingDeltaX < 0 ? 1 : -1)
            }
            return
        }

        // Post-lift trackpad inertia: swallow horizontal inertia so one flick advances one poster
        if !event.momentumPhase.isEmpty {
            let targetAxis: ScrollAxis = momentumAxis != .undecided
                ? momentumAxis
                : (absX > absY ? .horizontal : .vertical)
            if targetAxis == .vertical {
                nextResponder?.scrollWheel(with: event)
            }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                momentumAxis = .undecided
            }
            return
        }

        switch event.phase {
        case .mayBegin:
            resetActiveTracking()
            momentumAxis = .undecided
            nextResponder?.scrollWheel(with: event)

        case .began:
            resetActiveTracking()
            momentumAxis = .undecided
            accumulatedAbsX = absX
            accumulatedAbsY = absY
            if max(accumulatedAbsX, accumulatedAbsY) >= 1.5 {
                let locked: ScrollAxis = accumulatedAbsX >= accumulatedAbsY ? .horizontal : .vertical
                activeGestureAxis = locked
                momentumAxis = locked
                if locked == .horizontal {
                    handleHorizontalDelta(event)
                } else {
                    nextResponder?.scrollWheel(with: event)
                }
            } else {
                pendingBeganEvent = event
            }

        case .changed, .stationary:
            if activeGestureAxis == .undecided {
                accumulatedAbsX += absX
                accumulatedAbsY += absY
                guard max(accumulatedAbsX, accumulatedAbsY) >= 1.5 else { return }
                let locked: ScrollAxis = accumulatedAbsX >= accumulatedAbsY ? .horizontal : .vertical
                activeGestureAxis = locked
                momentumAxis = locked
                if locked == .vertical, let began = pendingBeganEvent {
                    pendingBeganEvent = nil
                    nextResponder?.scrollWheel(with: began)
                } else {
                    pendingBeganEvent = nil
                }
            }
            if activeGestureAxis == .horizontal {
                handleHorizontalDelta(event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }

        case .ended, .cancelled:
            let axis = activeGestureAxis
            let began = pendingBeganEvent
            resetActiveTracking()
            if axis != .horizontal {
                if let began {
                    nextResponder?.scrollWheel(with: began)
                }
                nextResponder?.scrollWheel(with: event)
            }

        default:
            if activeGestureAxis == .horizontal {
                handleHorizontalDelta(event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        }
    }
}

public struct MainCarouselView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject public var stateBox: CarouselStateBox
    public var swipePublisher: AnyPublisher<Int, Never>? = nil
    public let onPlay: (EmbyItem) -> Void
    public let onSelectDetail: (EmbyItem) -> Void

    @State private var displayedItems: [EmbyItem] = []
    @State private var pendingReorderedItems: [EmbyItem]? = nil
    @State private var currentItemId: String? = nil
    @State private var currentIndex: Int = 0
    @State private var hoverBox = HoverStateBox()
    @State private var slideDirection: Int = 1
    @State private var lastManualInteraction: Date = .distantPast

    private final class HoverStateBox {
        var isHovering: Bool = false
    }

    public init(
        stateBox: CarouselStateBox,
        swipePublisher: AnyPublisher<Int, Never>? = nil,
        onPlay: @escaping (EmbyItem) -> Void,
        onSelectDetail: @escaping (EmbyItem) -> Void
    ) {
        self.stateBox = stateBox
        self.swipePublisher = swipePublisher
        self.onPlay = onPlay
        self.onSelectDetail = onSelectDetail
    }

    private var currentItem: EmbyItem? {
        guard !displayedItems.isEmpty else { return nil }
        let safeIdx = max(0, min(currentIndex, displayedItems.count - 1))
        return displayedItems[safeIdx]
    }

    private func syncDisplayedItems(_ newItems: [EmbyItem], forceImmediate: Bool = false) {
        if !forceImmediate && !displayedItems.isEmpty && Date().timeIntervalSince(lastManualInteraction) < 6.0 {
            pendingReorderedItems = newItems
            return
        }
        pendingReorderedItems = nil
        let targetId = currentItemId ?? currentItem?.id
        displayedItems = newItems
        if let targetId, let preservedIdx = newItems.firstIndex(where: { $0.id == targetId }) {
            currentIndex = preservedIdx
            currentItemId = targetId
        } else {
            let clamped = newItems.isEmpty ? 0 : max(0, min(currentIndex, newItems.count - 1))
            currentIndex = clamped
            currentItemId = newItems.isEmpty ? nil : newItems[clamped].id
        }
    }

    private func stepSlide(_ delta: Int) {
        guard displayedItems.count > 1 else { return }
        slideDirection = delta >= 0 ? 1 : -1
        lastManualInteraction = Date()
        let nextIdx = (currentIndex + delta + displayedItems.count) % displayedItems.count
        currentItemId = displayedItems[nextIdx].id
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            currentIndex = nextIdx
        }
    }

    public var body: some View {
        Group {
            if let item = currentItem {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.16),
                            Color(red: 0.06, green: 0.07, blue: 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    MediaArtworkView(
                        server: appState.activeServer,
                        item: item,
                        kind: .backdrop,
                        maxWidth: 2200,
                        alignment: .top
                    )
                    .id(item.id)
                    .frame(maxWidth: .infinity)
                    .frame(height: stateBox.height)
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

                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 8) {
                            if let audioTag = item.audioSummaryTag {
                                Text(audioTag)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.16))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
                                Text(tagline).font(.system(size: 13, weight: .semibold)).foregroundStyle(appState.overlayAccentColor).lineLimit(1)
                            }
                        }

                        CarouselHeroRatingsView(
                            ratingsStore: appState.ratingsStore,
                            item: item
                        )

                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(2)
                                .frame(maxWidth: 580, alignment: .leading)
                        }

                        DonbyGlassContainer(spacing: 12) {
                            HStack(spacing: 12) {
                                LiquidGlassCapsuleButton(
                                    title: item.resumePositionSeconds > 0 ? "继续播放" : "立即播放",
                                    systemImage: "play.fill",
                                    tint: appState.isMonochromeTheme ? Color.white : appState.accentColor,
                                    textColorOverride: appState.isMonochromeTheme ? Color(red: 0.10, green: 0.10, blue: 0.12) : appState.accentTextColor,
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
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                    .padding(.trailing, 160) // reserve room for indicators
                }
                .frame(height: stateBox.height)
                .onReceive(swipePublisher ?? Empty<Int, Never>().eraseToAnyPublisher()) { delta in
                    stepSlide(delta)
                }
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
                .overlay(
                    HStack(spacing: 7.5) {
                        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { idx, dotItem in
                            Circle()
                                .fill(idx == currentIndex ? Color.white : Color.white.opacity(0.36))
                                .frame(width: 7, height: 7)
                                .contentShape(Circle())
                                .onTapGesture {
                                    slideDirection = idx >= currentIndex ? 1 : -1
                                    lastManualInteraction = Date()
                                    currentItemId = dotItem.id
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { currentIndex = idx }
                                }
                        }
                    }
                    .padding(.trailing, 26)
                    .padding(.bottom, 26),
                    alignment: .bottomTrailing
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.06),
                            lineWidth: 0.65
                        )
                )
                .onHover { hoverBox.isHovering = $0 }
                .task(id: "\(item.id)|\(appState.mdblistAPIKey)") {
                    _ = await appState.ensureMultiPlatformRating(for: item, server: appState.activeServer)
                }
                .task(id: "\(appState.activeServer?.activeBaseURL ?? "")|\(currentIndex)|\(displayedItems.count)") {
                    guard displayedItems.count > 1 else { return }
                    let nextIdx = (currentIndex + 1) % displayedItems.count
                    let nextItem = displayedItems[nextIdx]
                    let server = appState.activeServer
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    _ = await MediaArtworkView.loadOrFetchCGImage(
                        server: server,
                        item: nextItem,
                        kind: .backdrop,
                        maxWidth: 1600,
                        priority: .low
                    )
                }
            }
        }
        .preferredColorScheme(stateBox.isLightMode ? .light : .dark)
        .onAppear {
            syncDisplayedItems(stateBox.items, forceImmediate: true)
        }
        .onChange(of: stateBox.items) { newItems in
            syncDisplayedItems(newItems)
        }
        .task(id: "\(appState.currentDetailItem != nil)|\(appState.activePlayback != nil)|\(appState.selectedLibrary != nil)|\(displayedItems.count)") {
            guard appState.currentDetailItem == nil,
                  appState.activePlayback == nil,
                  appState.selectedLibrary == nil,
                  displayedItems.count > 1 else {
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { break }
                if let pending = pendingReorderedItems,
                   Date().timeIntervalSince(lastManualInteraction) > 5.0 {
                    syncDisplayedItems(pending, forceImmediate: true)
                }
                guard appState.currentDetailItem == nil,
                      appState.activePlayback == nil,
                      appState.selectedLibrary == nil,
                      !stateBox.isScrolling,
                      !hoverBox.isHovering,
                      displayedItems.count > 1,
                      Date().timeIntervalSince(lastManualInteraction) > 5.0 else {
                    continue
                }
                slideDirection = 1
                let nextIdx = (currentIndex + 1) % displayedItems.count
                currentItemId = displayedItems[nextIdx].id
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    currentIndex = nextIdx
                }
            }
        }
    }
}

private struct CarouselHeroRatingsView: View {
    @ObservedObject var ratingsStore: DonbyRatingsStore
    let item: EmbyItem

    var body: some View {
        HeroRatingBadgesRow(
            item: item,
            ratings: ratingsStore.multiPlatformRatingsByItemId[item.id],
            isLightSurface: false,
            fontSize: 13.5,
            iconHeight: 17
        )
    }
}

import SwiftUI
import AppKit
import QuartzCore
import DonbyCore
import DonbyNetwork

private final class FixedShelfFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let cv = collectionView else { return false }
        return abs(newBounds.height - cv.bounds.height) > 0.5
    }
}

@MainActor
final class HomeCarouselPauseState {
    var isScrolling: Bool = false
}

public struct HomeShelfSection: Equatable {
    public enum Kind: Equatable {
        case library
        case landscape
        case poster
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let items: [EmbyItem]
    public let library: EmbyItem?
    public let countsByLibrary: [String: Int]

    public init(
        id: String,
        title: String,
        kind: Kind,
        items: [EmbyItem],
        library: EmbyItem? = nil,
        countsByLibrary: [String: Int] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.items = items
        self.library = library
        self.countsByLibrary = countsByLibrary
    }
}

@MainActor
private final class NativeHomeShelfView: FlippedLayerHostView, NSCollectionViewDataSource, NSCollectionViewPrefetching, NativeCardActionDelegate {
    let sectionId: String
    let kind: HomeShelfSection.Kind

    private let titleLayer: CATextLayer = {
        let layer = CATextLayer()
        layer.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        layer.fontSize = 17
        layer.contentsScale = 2.0
        layer.truncationMode = .end
        layer.isWrapped = false
        layer.alignmentMode = .left
        layer.isOpaque = false
        return layer
    }()

    private let moreButton = NSButton(frame: .zero)
    private let horizontalScrollView = HorizontalShelfScrollView(frame: .zero)
    private let collectionView = InteractiveCollectionView(frame: .zero)

    private var items: [EmbyItem] = []
    private var countsByLibrary: [String: Int] = [:]
    private var library: EmbyItem?
    private var cardAppearance: DonbyCardAppearance?
    private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]

    private var lastTitle: String?
    private var lastIsLightMode: Bool?
    private(set) var isViewportActive: Bool = false

    var onSelectItem: ((EmbyItem) -> Void)?
    var onPlayItem: ((EmbyItem) -> Void)?
    var onOpenLibrary: ((EmbyItem) -> Void)?

    static func totalHeight(for kind: HomeShelfSection.Kind) -> CGFloat {
        switch kind {
        case .library: return 22 + 8 + 128
        case .landscape: return 22 + 8 + 198
        case .poster: return 22 + 8 + 285
        }
    }

    init(sectionId: String, kind: HomeShelfSection.Kind, canHover: @escaping () -> Bool) {
        self.sectionId = sectionId
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true

        layer?.addSublayer(titleLayer)

        moreButton.isBordered = false
        moreButton.bezelStyle = .inline
        moreButton.target = self
        moreButton.action = #selector(handleMoreTapped)
        moreButton.isHidden = true
        addSubview(moreButton)

        horizontalScrollView.drawsBackground = false
        horizontalScrollView.hasVerticalScroller = false
        horizontalScrollView.hasHorizontalScroller = false
        horizontalScrollView.autohidesScrollers = true
        horizontalScrollView.scrollerStyle = .overlay
        horizontalScrollView.horizontalScroller?.isHidden = true
        horizontalScrollView.horizontalScroller?.alphaValue = 0

        let layout = FixedShelfFlowLayout()
        layout.scrollDirection = .horizontal
        layout.sectionInset = NSEdgeInsets(top: 8, left: 24, bottom: 8, right: 24)
        switch kind {
        case .library:
            layout.itemSize = NativeLibraryCollectionItem.itemSize
            layout.minimumLineSpacing = 14
            layout.minimumInteritemSpacing = 14
        case .landscape:
            layout.itemSize = NativeLandscapeCollectionItem.itemSize
            layout.minimumLineSpacing = 16
            layout.minimumInteritemSpacing = 16
        case .poster:
            layout.itemSize = NSSize(width: 152, height: 269)
            layout.minimumLineSpacing = 15
            layout.minimumInteritemSpacing = 15
        }

        collectionView.collectionViewLayout = layout
        switch kind {
        case .library:
            collectionView.register(NativeLibraryCollectionItem.self, forItemWithIdentifier: NativeLibraryCollectionItem.identifier)
        case .landscape:
            collectionView.register(NativeLandscapeCollectionItem.self, forItemWithIdentifier: NativeLandscapeCollectionItem.identifier)
        case .poster:
            collectionView.register(NativePosterCollectionItem.self, forItemWithIdentifier: NativePosterCollectionItem.identifier)
        }
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.canHover = canHover
        collectionView.dataSource = self
        collectionView.prefetchDataSource = self

        horizontalScrollView.documentView = collectionView
        addSubview(horizontalScrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for (_, task) in prefetchTasks {
            task.cancel()
        }
    }

    func clearHover() {
        collectionView.clearHover()
    }

    func setViewportActive(_ active: Bool) {
        guard isViewportActive != active else { return }
        isViewportActive = active
        guard active else { return }
        for visibleItem in collectionView.visibleItems() {
            switch visibleItem {
            case let cell as NativeLibraryCollectionItem:
                cell.startPendingArtworkLoadIfNeeded()
            case let cell as NativeLandscapeCollectionItem:
                cell.startPendingArtworkLoadIfNeeded()
            case let cell as NativePosterCollectionItem:
                cell.startPendingArtworkLoadIfNeeded()
            default:
                break
            }
        }
    }

    @objc private func handleMoreTapped() {
        if let library {
            onOpenLibrary?(library)
        }
    }

    func configure(
        section: HomeShelfSection,
        appearance: DonbyCardAppearance,
        onSelectItem: @escaping (EmbyItem) -> Void,
        onPlayItem: @escaping (EmbyItem) -> Void,
        onOpenLibrary: @escaping (EmbyItem) -> Void
    ) {
        self.onSelectItem = onSelectItem
        self.onPlayItem = onPlayItem
        self.onOpenLibrary = onOpenLibrary

        let themeChanged = (lastIsLightMode != appearance.isLightMode)
        let itemsChanged = (self.items != section.items)
        let countsChanged = (self.countsByLibrary != section.countsByLibrary)
        let appearanceChanged = (self.cardAppearance != appearance)

        self.library = section.library
        self.cardAppearance = appearance

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if themeChanged {
            lastIsLightMode = appearance.isLightMode
            let canvasNS = NativeCardLayerCache.canvasNSColor(isLight: appearance.isLightMode)
            layer?.backgroundColor = canvasNS.cgColor
            collectionView.backgroundColors = [canvasNS]
            titleLayer.foregroundColor = NativeCardLayerCache.primaryTextCGColor(isLight: appearance.isLightMode)
            updateMoreButtonStyle(isLight: appearance.isLightMode)
        }
        if lastTitle != section.title {
            lastTitle = section.title
            titleLayer.string = section.title
        }
        moreButton.isHidden = (section.library == nil)
        CATransaction.commit()

        if itemsChanged || countsChanged || appearanceChanged {
            for (_, task) in prefetchTasks {
                task.cancel()
            }
            prefetchTasks.removeAll()
            self.items = section.items
            self.countsByLibrary = section.countsByLibrary
            collectionView.reloadData()
        }
    }

    private func updateMoreButtonStyle(isLight: Bool) {
        let color = isLight ? NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1.0) : NSColor(white: 0.60, alpha: 1.0)
        let titleAttr = NSMutableAttributedString(
            string: "更多 ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: color
            ]
        )
        if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            attachment.bounds = CGRect(x: 0, y: -1, width: chevron.size.width, height: chevron.size.height)
            titleAttr.append(NSAttributedString(attachment: attachment))
        }
        moreButton.attributedTitle = titleAttr
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.frame = CGRect(x: 24, y: 0, width: max(120, width - 110), height: 22)
        CATransaction.commit()
        moreButton.frame = NSRect(x: max(24, width - 24 - 56), y: 0, width: 56, height: 22)
        horizontalScrollView.frame = NSRect(x: 0, y: 30, width: width, height: max(0, height - 30))
    }

    // MARK: - NativeCardActionDelegate
    func cardDidSelect(_ item: EmbyItem) {
        if kind == .library {
            onOpenLibrary?(item)
        } else {
            onSelectItem?(item)
        }
    }

    func cardDidPlay(_ item: EmbyItem) {
        onPlayItem?(item)
    }

    // MARK: - NSCollectionViewDataSource
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = items[indexPath.item]
        switch kind {
        case .library:
            let cell = collectionView.makeItem(
                withIdentifier: NativeLibraryCollectionItem.identifier,
                for: indexPath
            ) as! NativeLibraryCollectionItem
            if let cardAppearance {
                cell.configure(library: item, itemCount: countsByLibrary[item.id], appearance: cardAppearance, allowAsyncLoad: isViewportActive)
            }
            cell.actionDelegate = self
            return cell
        case .landscape:
            let cell = collectionView.makeItem(
                withIdentifier: NativeLandscapeCollectionItem.identifier,
                for: indexPath
            ) as! NativeLandscapeCollectionItem
            if let cardAppearance {
                cell.configure(item: item, appearance: cardAppearance, allowAsyncLoad: isViewportActive)
            }
            cell.actionDelegate = self
            return cell
        case .poster:
            let cell = collectionView.makeItem(
                withIdentifier: NativePosterCollectionItem.identifier,
                for: indexPath
            ) as! NativePosterCollectionItem
            if let cardAppearance {
                cell.configure(item: item, cardWidth: 152, appearance: cardAppearance, allowAsyncLoad: isViewportActive)
            }
            cell.actionDelegate = self
            return cell
        }
    }

    // MARK: - NSCollectionViewPrefetching
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard isViewportActive else { return }
        let server = cardAppearance?.server
        for indexPath in indexPaths {
            if prefetchTasks.count >= 12 { break }
            guard indexPath.item >= 0, indexPath.item < items.count, prefetchTasks[indexPath] == nil else { continue }
            let item = items[indexPath.item]
            let targetKind: EmbyImageKind
            let targetWidth: Int
            switch kind {
            case .library:
                targetKind = (item.backdropImageTags?.isEmpty == false) ? .backdrop : .primary
                targetWidth = 440
            case .landscape:
                targetKind = .thumb
                targetWidth = 500
            case .poster:
                targetKind = .primary
                targetWidth = 360
            }
            if MediaArtworkView.cachedCGImageInMemory(item: item, kind: targetKind, maxWidth: targetWidth) != nil {
                continue
            }
            prefetchTasks[indexPath] = Task(priority: .utility) { [weak self] in
                await Self.runPrefetch(server: server, item: item, kind: targetKind, maxWidth: targetWidth)
                guard !Task.isCancelled else { return }
                _ = self?.prefetchTasks.removeValue(forKey: indexPath)
            }
        }
    }

    private nonisolated static func runPrefetch(
        server: EmbyServerConfig?,
        item: EmbyItem,
        kind: EmbyImageKind,
        maxWidth: Int
    ) async {
        if Task.isCancelled { return }
        _ = await MediaArtworkView.loadOrFetchCGImage(server: server, item: item, kind: kind, maxWidth: maxWidth, priority: .low)
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            prefetchTasks[indexPath]?.cancel()
            prefetchTasks.removeValue(forKey: indexPath)
        }
    }
}

public struct NativeEmbyHomeView: NSViewRepresentable {
    public let carouselItems: [EmbyItem]
    public let showCarousel: Bool
    public let shelves: [HomeShelfSection]
    public let appearance: DonbyCardAppearance
    public let appState: AppState
    public let onSelectItem: (EmbyItem) -> Void
    public let onPlayItem: (EmbyItem) -> Void
    public let onOpenLibrary: (EmbyItem) -> Void

    public init(
        carouselItems: [EmbyItem],
        showCarousel: Bool,
        shelves: [HomeShelfSection],
        appearance: DonbyCardAppearance,
        appState: AppState,
        onSelectItem: @escaping (EmbyItem) -> Void,
        onPlayItem: @escaping (EmbyItem) -> Void,
        onOpenLibrary: @escaping (EmbyItem) -> Void
    ) {
        self.carouselItems = carouselItems
        self.showCarousel = showCarousel
        self.shelves = shelves
        self.appearance = appearance
        self.appState = appState
        self.onSelectItem = onSelectItem
        self.onPlayItem = onPlayItem
        self.onOpenLibrary = onOpenLibrary
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            appState: appState,
            onSelectItem: onSelectItem,
            onPlayItem: onPlayItem,
            onOpenLibrary: onOpenLibrary
        )
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NonDraggableScrollView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
        scrollView.drawsBackground = true
        let canvasNS = NativeCardLayerCache.canvasNSColor(isLight: appearance.isLightMode)
        scrollView.backgroundColor = canvasNS
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = canvasNS
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true

        let documentView = FlippedLayerHostView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NativeCardLayerCache.canvasNSColor(isLight: appearance.isLightMode).cgColor
        scrollView.documentView = documentView

        scrollView.onWidthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.layoutDocument(width: width)
        }

        context.coordinator.attach(scrollView: scrollView, documentView: documentView)
        context.coordinator.update(
            carouselItems: carouselItems,
            showCarousel: showCarousel,
            shelves: shelves,
            appearance: appearance
        )
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onSelectItem = onSelectItem
        context.coordinator.onPlayItem = onPlayItem
        context.coordinator.onOpenLibrary = onOpenLibrary
        context.coordinator.update(
            carouselItems: carouselItems,
            showCarousel: showCarousel,
            shelves: shelves,
            appearance: appearance
        )
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    public final class Coordinator: NSObject {
        private let appState: AppState
        var onSelectItem: (EmbyItem) -> Void
        var onPlayItem: (EmbyItem) -> Void
        var onOpenLibrary: (EmbyItem) -> Void

        private weak var scrollView: NSScrollView?
        private weak var documentView: FlippedLayerHostView?
        private var carouselHostingView: NSHostingView<AnyView>?
        private var shelfViewsById: [String: NativeHomeShelfView] = [:]
        private var orderedShelfViews: [NativeHomeShelfView] = []

        private var lastCarouselItems: [EmbyItem] = []
        private var lastShowCarousel: Bool = false
        private var lastShelves: [HomeShelfSection] = []
        private var lastAppearance: DonbyCardAppearance?
        private var currentWidth: CGFloat = 960
        private var currentCarouselHeight: CGFloat = 365

        private static func resolvedCarouselHeight(forWidth width: CGFloat) -> CGFloat {
            let bannerWidth = max(200, width - 48)
            return min(max(365, (bannerWidth * 0.36).rounded()), 540)
        }

        private var observers: [NSObjectProtocol] = []
        private var hoverGate: ScrollHoverGate?
        private let carouselPauseState = HomeCarouselPauseState()

        init(
            appState: AppState,
            onSelectItem: @escaping (EmbyItem) -> Void,
            onPlayItem: @escaping (EmbyItem) -> Void,
            onOpenLibrary: @escaping (EmbyItem) -> Void
        ) {
            self.appState = appState
            self.onSelectItem = onSelectItem
            self.onPlayItem = onPlayItem
            self.onOpenLibrary = onOpenLibrary
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(scrollView: NSScrollView, documentView: FlippedLayerHostView) {
            self.scrollView = scrollView
            self.documentView = documentView
            let gate = ScrollHoverGate(
                onScrollBegan: { [weak self] in
                    guard let self else { return }
                    self.carouselPauseState.isScrolling = true
                    for shelf in self.orderedShelfViews {
                        shelf.clearHover()
                    }
                },
                onScrollEnded: { [weak self] in
                    self?.carouselPauseState.isScrolling = false
                }
            )
            self.hoverGate = gate

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.carouselPauseState.isScrolling = true
                    self?.hoverGate?.markScrollingActivity()
                }
            })
            observers.append(nc.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.carouselPauseState.isScrolling = true
                    self?.hoverGate?.markScrollingActivity()
                }
            })
            observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.carouselPauseState.isScrolling = false
                    self?.hoverGate?.scheduleIdleEvaluation()
                }
            })
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hoverGate?.markScrollingActivity()
                    self?.carouselPauseState.isScrolling = self?.hoverGate?.isActivelyScrolling ?? false
                    self?.updateShelfViewportVisibility()
                }
            })
        }

        func update(
            carouselItems: [EmbyItem],
            showCarousel: Bool,
            shelves: [HomeShelfSection],
            appearance: DonbyCardAppearance
        ) {
            let themeChanged = (lastAppearance?.isLightMode != appearance.isLightMode)
            let carouselChanged = (lastShowCarousel != showCarousel) || (lastCarouselItems != carouselItems) || (lastAppearance != appearance)
            let shelvesChanged = (lastShelves != shelves) || (lastAppearance != appearance)

            if !themeChanged && !carouselChanged && !shelvesChanged {
                return
            }

            lastCarouselItems = carouselItems
            lastShowCarousel = showCarousel
            lastShelves = shelves
            lastAppearance = appearance

            if themeChanged, let scrollView, let documentView {
                let canvasNS = NativeCardLayerCache.canvasNSColor(isLight: appearance.isLightMode)
                scrollView.backgroundColor = canvasNS
                scrollView.contentView.backgroundColor = canvasNS
                documentView.layer?.backgroundColor = canvasNS.cgColor
            }

            if carouselChanged {
                updateCarousel(items: carouselItems, visible: showCarousel, appearance: appearance)
            }

            if shelvesChanged {
                updateShelves(shelves, appearance: appearance)
            }

            let width = max(400, scrollView?.contentView.bounds.width ?? currentWidth)
            layoutDocument(width: width)
        }

        private func updateCarousel(items: [EmbyItem], visible: Bool, appearance: DonbyCardAppearance) {
            guard let documentView else { return }
            let shouldShow = visible && !items.isEmpty
            if !shouldShow {
                carouselHostingView?.removeFromSuperview()
                carouselHostingView = nil
                return
            }

            let carouselHeight = Self.resolvedCarouselHeight(forWidth: max(400, scrollView?.contentView.bounds.width ?? currentWidth))
            currentCarouselHeight = carouselHeight
            let carouselRoot = AnyView(
                MainCarouselView(
                    items: items,
                    height: carouselHeight,
                    isScrollPaused: { [weak pauseState = carouselPauseState] in pauseState?.isScrolling ?? false },
                    onPlay: { [weak self] item in self?.onPlayItem(item) },
                    onSelectDetail: { [weak self] item in self?.onSelectItem(item) }
                )
                .environmentObject(appState)
                .preferredColorScheme(appearance.isLightMode ? .light : .dark)
            )

            if let existing = carouselHostingView {
                existing.rootView = carouselRoot
            } else {
                let hosting = NSHostingView(rootView: carouselRoot)
                hosting.sizingOptions = []
                hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
                documentView.addSubview(hosting)
                carouselHostingView = hosting
            }
        }

        private func updateShelves(_ shelves: [HomeShelfSection], appearance: DonbyCardAppearance) {
            guard let documentView else { return }
            let newIds = Set(shelves.map(\.id))
            for (shelfId, view) in shelfViewsById where !newIds.contains(shelfId) {
                view.removeFromSuperview()
                shelfViewsById.removeValue(forKey: shelfId)
            }

            var ordered: [NativeHomeShelfView] = []
            ordered.reserveCapacity(shelves.count)

            for section in shelves {
                let shelfView: NativeHomeShelfView
                if let existing = shelfViewsById[section.id], existing.kind == section.kind {
                    shelfView = existing
                } else {
                    shelfViewsById[section.id]?.removeFromSuperview()
                    let created = NativeHomeShelfView(
                        sectionId: section.id,
                        kind: section.kind,
                        canHover: { [weak self] in self?.hoverGate?.canHover ?? true }
                    )
                    documentView.addSubview(created)
                    shelfViewsById[section.id] = created
                    shelfView = created
                }
                shelfView.configure(
                    section: section,
                    appearance: appearance,
                    onSelectItem: { [weak self] item in self?.onSelectItem(item) },
                    onPlayItem: { [weak self] item in self?.onPlayItem(item) },
                    onOpenLibrary: { [weak self] lib in self?.onOpenLibrary(lib) }
                )
                ordered.append(shelfView)
            }
            orderedShelfViews = ordered
        }

        func layoutDocument(width: CGFloat) {
            guard let documentView else { return }
            let resolvedWidth = max(400, width)
            currentWidth = resolvedWidth

            var cursorY: CGFloat = 12
            if let carousel = carouselHostingView {
                let targetCarouselHeight = Self.resolvedCarouselHeight(forWidth: resolvedWidth)
                if abs(targetCarouselHeight - currentCarouselHeight) > 1.0, let appearance = lastAppearance {
                    updateCarousel(items: lastCarouselItems, visible: lastShowCarousel, appearance: appearance)
                }
                carousel.frame = NSRect(x: 24, y: cursorY, width: max(200, resolvedWidth - 48), height: targetCarouselHeight)
                cursorY += targetCarouselHeight
                if !orderedShelfViews.isEmpty {
                    cursorY += 22
                }
            }

            for (index, shelfView) in orderedShelfViews.enumerated() {
                let shelfHeight = NativeHomeShelfView.totalHeight(for: shelfView.kind)
                shelfView.frame = NSRect(x: 0, y: cursorY, width: resolvedWidth, height: shelfHeight)
                cursorY += shelfHeight
                if index < orderedShelfViews.count - 1 {
                    cursorY += 22
                }
            }
            cursorY += 36

            let minHeight = scrollView?.contentView.bounds.height ?? 680
            let targetFrame = NSRect(x: 0, y: 0, width: resolvedWidth, height: max(cursorY, minHeight))
            if abs(documentView.frame.width - targetFrame.width) > 0.5 || abs(documentView.frame.height - targetFrame.height) > 0.5 {
                documentView.frame = targetFrame
            }
            updateShelfViewportVisibility()
        }

        private func updateShelfViewportVisibility() {
            guard let sv = scrollView else { return }
            let visible = sv.contentView.bounds
            let activeBounds = visible.width > 0 && visible.height > 0
                ? visible.insetBy(dx: 0, dy: -180)
                : NSRect(x: 0, y: 0, width: max(400, currentWidth), height: 900)
            for shelfView in orderedShelfViews {
                let inRange = shelfView.frame.intersects(activeBounds)
                if inRange {
                    shelfView.setViewportActive(true)
                }
            }
        }
    }
}

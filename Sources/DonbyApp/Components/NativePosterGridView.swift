import SwiftUI
import AppKit
import QuartzCore
import DonbyCore
import DonbyNetwork

private final class PosterGridFooterView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PosterGridFooterView")
    override var isFlipped: Bool { true }

    private let spinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在加载更多…")
    private let loadMoreButton = NSButton(title: "", target: nil, action: nil)
    private var onLoadMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        loadingLabel.font = NSFont.systemFont(ofSize: 12)
        loadingLabel.alignment = .center

        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.isBordered = false
        loadMoreButton.wantsLayer = true
        loadMoreButton.layer?.cornerRadius = 14
        loadMoreButton.layer?.cornerCurve = .continuous
        loadMoreButton.layer?.borderWidth = 0.6
        loadMoreButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        loadMoreButton.target = self
        loadMoreButton.action = #selector(handleLoadMore)

        addSubview(spinner)
        addSubview(loadingLabel)
        addSubview(loadMoreButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleLoadMore() {
        onLoadMore?()
    }

    func configure(
        isLoadingMore: Bool,
        hasMore: Bool,
        loadedCount: Int,
        totalCount: Int,
        isLightMode: Bool,
        onLoadMore: @escaping () -> Void
    ) {
        self.onLoadMore = onLoadMore
        let secondaryColor = isLightMode ? NSColor(red: 0.42, green: 0.42, blue: 0.46, alpha: 1) : NSColor(white: 0.60, alpha: 1)
        let primaryColor = isLightMode ? NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1) : NSColor.white

        if isLoadingMore {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            loadingLabel.isHidden = false
            loadingLabel.textColor = secondaryColor
            loadMoreButton.isHidden = true
        } else if hasMore {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            loadingLabel.isHidden = true
            loadMoreButton.isHidden = false
            let title = "加载更多 (\(loadedCount)/\(totalCount))"
            loadMoreButton.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: primaryColor
                ]
            )
            loadMoreButton.layer?.backgroundColor = (isLightMode
                ? NSColor.white.withAlphaComponent(0.85)
                : NSColor(red: 0.09, green: 0.095, blue: 0.11, alpha: 1.0)).cgColor
            loadMoreButton.layer?.borderColor = (isLightMode
                ? NSColor.black.withAlphaComponent(0.08)
                : NSColor.white.withAlphaComponent(0.08)).cgColor
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            loadingLabel.isHidden = true
            loadMoreButton.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        spinner.frame = NSRect(x: w * 0.5 - 58, y: (h - 16) * 0.5, width: 16, height: 16)
        loadingLabel.frame = NSRect(x: w * 0.5 - 36, y: (h - 16) * 0.5, width: 110, height: 16)
        let btnW: CGFloat = 176
        let btnH: CGFloat = 28
        loadMoreButton.frame = NSRect(x: (w - btnW) * 0.5, y: (h - btnH) * 0.5, width: btnW, height: btnH)
    }
}

private final class FixedPosterGridFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let cv = collectionView else { return false }
        return abs(newBounds.width - cv.bounds.width) > 0.5
    }
}

public struct NativePosterGridView: NSViewRepresentable {
    public let items: [EmbyItem]
    public let itemsRevision: Int
    public let totalCount: Int
    public let hasMoreItems: Bool
    public let isLoadingMore: Bool
    public let appearance: DonbyCardAppearance
    public let onSelect: (EmbyItem) -> Void
    public let onPlay: (EmbyItem) -> Void
    public let onLoadMore: () -> Void

    public init(
        items: [EmbyItem],
        itemsRevision: Int = 0,
        totalCount: Int,
        hasMoreItems: Bool,
        isLoadingMore: Bool,
        appearance: DonbyCardAppearance,
        onSelect: @escaping (EmbyItem) -> Void,
        onPlay: @escaping (EmbyItem) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.items = items
        self.itemsRevision = itemsRevision
        self.totalCount = totalCount
        self.hasMoreItems = hasMoreItems
        self.isLoadingMore = isLoadingMore
        self.appearance = appearance
        self.onSelect = onSelect
        self.onPlay = onPlay
        self.onLoadMore = onLoadMore
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onPlay: onPlay, onLoadMore: onLoadMore)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let canvasNS = NativeCardLayerCache.canvasNSColor(isLight: appearance.isLightMode)
        let scrollView = NonDraggableScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true

        let layout = FixedPosterGridFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 12, left: 24, bottom: 20, right: 24)
        layout.itemSize = NSSize(width: 152, height: 269)

        let collectionView = InteractiveCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [canvasNS]
        collectionView.register(
            NativePosterCollectionItem.self,
            forItemWithIdentifier: NativePosterCollectionItem.identifier
        )
        collectionView.register(
            PosterGridFooterView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
            withIdentifier: PosterGridFooterView.identifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.delegate = context.coordinator

        scrollView.documentView = collectionView
        scrollView.onWidthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.updateLayoutWidth(width)
        }

        context.coordinator.attach(scrollView: scrollView, collectionView: collectionView)
        context.coordinator.updateData(
            items: items,
            itemsRevision: itemsRevision,
            totalCount: totalCount,
            hasMoreItems: hasMoreItems,
            isLoadingMore: isLoadingMore,
            appearance: appearance
        )
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onPlay = onPlay
        context.coordinator.onLoadMore = onLoadMore
        if let cv = nsView.documentView as? NSCollectionView,
           context.coordinator.appearance?.isLightMode != appearance.isLightMode {
            let canvasNS = NativeCardLayerCache.canvasNSColor(isLight: appearance.isLightMode)
            cv.backgroundColors = [canvasNS]
        }
        context.coordinator.updateData(
            items: items,
            itemsRevision: itemsRevision,
            totalCount: totalCount,
            hasMoreItems: hasMoreItems,
            isLoadingMore: isLoadingMore,
            appearance: appearance
        )
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    public final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewPrefetching, NSCollectionViewDelegateFlowLayout, NativeCardActionDelegate {
        var onSelect: (EmbyItem) -> Void
        var onPlay: (EmbyItem) -> Void
        var onLoadMore: () -> Void

        private(set) var items: [EmbyItem] = []
        private(set) var itemsRevision: Int = -1
        private(set) var totalCount: Int = 0
        private(set) var hasMoreItems: Bool = false
        private(set) var isLoadingMore: Bool = false
        private(set) var appearance: DonbyCardAppearance?
        private(set) var currentCardWidth: CGFloat = 152

        private weak var scrollView: NSScrollView?
        private weak var collectionView: InteractiveCollectionView?
        private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]
        private var prewarmTextTask: Task<Void, Never>?
        private var observers: [NSObjectProtocol] = []
        private var hoverGate: ScrollHoverGate?
        private var lastPaginationRequestCount: Int = -1

        init(
            onSelect: @escaping (EmbyItem) -> Void,
            onPlay: @escaping (EmbyItem) -> Void,
            onLoadMore: @escaping () -> Void
        ) {
            self.onSelect = onSelect
            self.onPlay = onPlay
            self.onLoadMore = onLoadMore
        }

        deinit {
            for (_, task) in prefetchTasks { task.cancel() }
            prewarmTextTask?.cancel()
            for obs in observers { NotificationCenter.default.removeObserver(obs) }
        }

        func attach(scrollView: NSScrollView, collectionView: InteractiveCollectionView) {
            self.scrollView = scrollView
            self.collectionView = collectionView
            let gate = ScrollHoverGate { [weak self] in
                self?.collectionView?.clearHover()
            }
            self.hoverGate = gate
            collectionView.canHover = { [weak self] in
                self?.hoverGate?.canHover ?? true
            }

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverGate?.markScrollingActivity() }
            })
            observers.append(nc.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverGate?.markScrollingActivity() }
            })
            observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverGate?.scheduleIdleEvaluation() }
            })
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hoverGate?.markScrollingActivity()
                    self?.checkPaginationTriggerFromScroll()
                }
            })
        }

        private func checkPaginationTriggerFromScroll() {
            guard hasMoreItems, !isLoadingMore, lastPaginationRequestCount != items.count,
                  let sv = scrollView, let doc = sv.documentView else { return }
            let visibleMaxY = sv.contentView.bounds.maxY
            if doc.bounds.height > 0 && visibleMaxY >= doc.bounds.height - 480 {
                lastPaginationRequestCount = items.count
                onLoadMore()
            }
        }

        func updateLayoutWidth(_ width: CGFloat) {
            guard let cv = collectionView, let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let available = max(160.0, width - 48.0)
            let spacing: CGFloat = 16.0
            let cols = max(1, Int((available + spacing) / (156.0 + spacing)))
            let newCardW = min(176.0, max(152.0, floor((available - CGFloat(cols - 1) * spacing) / CGFloat(cols))))
            let newCardH = round(newCardW * 1.5) + 41.0
            let newSize = NSSize(width: newCardW, height: newCardH)
            if abs(layout.itemSize.width - newSize.width) > 0.5 || abs(layout.itemSize.height - newSize.height) > 0.5 {
                currentCardWidth = newCardW
                layout.itemSize = newSize
                layout.invalidateLayout()
                scheduleTextPrewarm(from: 0, count: min(72, items.count))
            }
        }

        func updateData(
            items newItems: [EmbyItem],
            itemsRevision newRevision: Int,
            totalCount: Int,
            hasMoreItems: Bool,
            isLoadingMore: Bool,
            appearance: DonbyCardAppearance
        ) {
            let oldItems = self.items
            let oldAppearance = self.appearance
            let oldRevision = self.itemsRevision
            let footerChanged = (self.hasMoreItems != hasMoreItems) || (self.isLoadingMore != isLoadingMore) || (self.totalCount != totalCount)

            self.totalCount = totalCount
            self.hasMoreItems = hasMoreItems
            self.isLoadingMore = isLoadingMore
            self.appearance = appearance

            if !isLoadingMore && newItems.count != oldItems.count {
                lastPaginationRequestCount = -1
            }

            guard let cv = collectionView else {
                self.items = newItems
                self.itemsRevision = newRevision
                return
            }

            if let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout {
                let footerH: CGFloat = (hasMoreItems || isLoadingMore) ? 56 : 12
                if abs(layout.footerReferenceSize.height - footerH) > 0.5 {
                    layout.footerReferenceSize = NSSize(width: max(200, cv.bounds.width), height: footerH)
                }
            }

            if oldItems.isEmpty && newItems.isEmpty {
                self.items = newItems
                self.itemsRevision = newRevision
                return
            }

            // Fast path: pure append (pagination) with unchanged appearance
            let isPureAppend: Bool = {
                guard oldAppearance == appearance,
                      !oldItems.isEmpty,
                      newItems.count > oldItems.count else { return false }
                for i in 0..<oldItems.count {
                    if oldItems[i].id != newItems[i].id { return false }
                }
                return true
            }()

            if isPureAppend {
                let prevCount = oldItems.count
                self.items = newItems
                self.itemsRevision = newRevision
                let inserted = Set((oldItems.count..<newItems.count).map { IndexPath(item: $0, section: 0) })
                cv.insertItems(at: inserted)
                refreshFooter()
                scheduleTextPrewarm(from: prevCount, count: min(72, newItems.count - prevCount))
                return
            }

            self.itemsRevision = newRevision

            // Fast path: unchanged revision & count and identical appearance -> skip deep 2400-item equality
            if newRevision > 0 && oldRevision == newRevision && oldItems.count == newItems.count && oldAppearance == appearance {
                if footerChanged {
                    refreshFooter()
                }
                return
            }

            // Fast path: identical IDs & content and identical appearance -> footer-only update
            if oldAppearance == appearance && oldItems == newItems {
                if footerChanged {
                    refreshFooter()
                }
                return
            }

            for (_, task) in prefetchTasks { task.cancel() }
            prefetchTasks.removeAll()
            self.items = newItems
            cv.reloadData()
            if oldItems.first?.id != newItems.first?.id, let sv = scrollView {
                sv.contentView.scroll(to: .zero)
                sv.reflectScrolledClipView(sv.contentView)
            }
            scheduleTextPrewarm(from: 0, count: min(72, newItems.count))
        }

        private func scheduleTextPrewarm(from start: Int, count: Int) {
            guard count > 0, start < items.count else { return }
            let end = min(items.count, start + count)
            let slice = Array(items[start..<end])
            let cardWidth = currentCardWidth
            let isLight = appearance?.isLightMode ?? false
            prewarmTextTask?.cancel()
            prewarmTextTask = Task.detached(priority: .utility) {
                for item in slice {
                    if Task.isCancelled { return }
                    let subtitleText = item.displaySubtitle.isEmpty ? (item.isSeries ? "剧集" : "电影") : item.displaySubtitle
                    _ = CardTextBitmapCache.shared.renderOrCached(
                        title: item.name,
                        subtitle: subtitleText,
                        width: cardWidth,
                        isLightMode: isLight
                    )
                }
            }
        }

        private func refreshFooter() {
            guard let cv = collectionView,
                  let footer = cv.supplementaryView(
                    forElementKind: NSCollectionView.elementKindSectionFooter,
                    at: IndexPath(item: 0, section: 0)
                  ) as? PosterGridFooterView else { return }
            footer.configure(
                isLoadingMore: isLoadingMore,
                hasMore: hasMoreItems,
                loadedCount: items.count,
                totalCount: totalCount,
                isLightMode: appearance?.isLightMode ?? false,
                onLoadMore: onLoadMore
            )
        }

        func cardDidSelect(_ item: EmbyItem) {
            onSelect(item)
        }

        func cardDidPlay(_ item: EmbyItem) {
            onPlay(item)
        }

        // MARK: - NSCollectionViewDataSource
        public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(
                withIdentifier: NativePosterCollectionItem.identifier,
                for: indexPath
            ) as! NativePosterCollectionItem

            let item = items[indexPath.item]
            if let appearance {
                cell.configure(
                    item: item,
                    cardWidth: currentCardWidth,
                    appearance: appearance,
                    allowAsyncLoad: true,
                    deferTextRenderIfScrolling: hoverGate?.isActivelyScrolling ?? false
                )
            }
            cell.actionDelegate = self

            if hasMoreItems, !isLoadingMore,
               lastPaginationRequestCount != items.count,
               indexPath.item >= max(0, items.count - 18) {
                lastPaginationRequestCount = items.count
                DispatchQueue.main.async { [weak self] in
                    self?.onLoadMore()
                }
            }

            return cell
        }

        public func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let footer = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: PosterGridFooterView.identifier,
                for: indexPath
            ) as! PosterGridFooterView
            footer.configure(
                isLoadingMore: isLoadingMore,
                hasMore: hasMoreItems,
                loadedCount: items.count,
                totalCount: totalCount,
                isLightMode: appearance?.isLightMode ?? false,
                onLoadMore: onLoadMore
            )
            return footer
        }

        // MARK: - NSCollectionViewPrefetching
        public func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let server = appearance?.server
            let cardWidth = currentCardWidth
            let isLightMode = appearance?.isLightMode ?? false
            for ip in indexPaths {
                if prefetchTasks.count >= 24 { break }
                guard ip.item >= 0, ip.item < items.count, prefetchTasks[ip] == nil else { continue }
                let item = items[ip.item]
                let subtitleText = item.displaySubtitle.isEmpty ? (item.isSeries ? "剧集" : "电影") : item.displaySubtitle
                let needsText = CardTextBitmapCache.shared.cached(
                    title: item.name,
                    subtitle: subtitleText,
                    width: cardWidth,
                    isLightMode: isLightMode
                ) == nil
                let needsImage = MediaArtworkView.cachedCGImageInMemory(item: item, kind: .primary, maxWidth: 360) == nil
                if !needsImage && !needsText {
                    continue
                }
                prefetchTasks[ip] = Task(priority: .utility) { [weak self] in
                    await Self.runPrefetch(
                        server: server,
                        item: item,
                        subtitle: subtitleText,
                        cardWidth: cardWidth,
                        isLightMode: isLightMode,
                        needsText: needsText,
                        needsImage: needsImage
                    )
                    guard !Task.isCancelled else { return }
                    _ = self?.prefetchTasks.removeValue(forKey: ip)
                }
            }
        }

        private nonisolated static func runPrefetch(
            server: EmbyServerConfig?,
            item: EmbyItem,
            subtitle: String,
            cardWidth: CGFloat,
            isLightMode: Bool,
            needsText: Bool,
            needsImage: Bool
        ) async {
            if needsText && !Task.isCancelled {
                _ = CardTextBitmapCache.shared.renderOrCached(title: item.name, subtitle: subtitle, width: cardWidth, isLightMode: isLightMode)
            }
            if needsImage && !Task.isCancelled {
                _ = await MediaArtworkView.loadOrFetchCGImage(server: server, item: item, kind: .primary, maxWidth: 360, priority: .low)
            }
        }

        public func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for ip in indexPaths {
                prefetchTasks[ip]?.cancel()
                prefetchTasks.removeValue(forKey: ip)
            }
        }
    }
}

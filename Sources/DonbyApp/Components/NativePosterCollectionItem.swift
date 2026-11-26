import SwiftUI
import AppKit
import QuartzCore
import DonbyCore
import DonbyNetwork

// MARK: - Pure CALayer Poster Cell
final class NativePosterCollectionItem: NSCollectionViewItem, HoverableCollectionItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativePosterCollectionItem")

    private let cardContainerLayer = CALayer()
    private let placeholderIconLayer = CALayer()
    private let posterLayer = CALayer()
    private let gradientLayer = CALayer()
    private let hoverDimLayer = CALayer()
    private let playLayer = CALayer()

    private let resBadgeLayer = CALayer()
    private let unplayedBadgeLayer = CALayer()
    private let playedIconLayer = CALayer()
    private let ratingPillLayer = CALayer()
    private let downloadedBadgeLayer = CALayer()
    private let favoriteIconLayer = CALayer()
    private let progressTrack = CALayer()
    private let progressFill = CALayer()

    private let textBlockLayer = CALayer()

    private var currentItem: EmbyItem?
    private var currentAppearance: DonbyCardAppearance?
    private var currentCardWidth: CGFloat = 152
    private var loadTask: Task<Void, Never>?
    private var isHovered = false

    private var lastTitle: String?
    private var lastSubtitle: String?
    private var lastTextWidth: CGFloat = 0
    private var lastIsLightMode: Bool?
    private var lastLaidOutWidth: CGFloat = -1
    private var needsCardLayout = true
    private var pendingTextKey: String?

    weak var actionDelegate: (any NativeCardActionDelegate)?

    override func loadView() {
        let root = LayerOnlyCellRootView(frame: NSRect(x: 0, y: 0, width: 152, height: 269))
        root.wantsLayer = true
        root.autoresizingMask = []
        root.autoresizesSubviews = false

        cardContainerLayer.cornerRadius = 10
        cardContainerLayer.cornerCurve = .continuous
        cardContainerLayer.masksToBounds = true
        cardContainerLayer.isOpaque = true
        cardContainerLayer.borderWidth = 0.65
        cardContainerLayer.borderColor = NativeCardLayerCache.defaultPosterBorderCGColor
        cardContainerLayer.backgroundColor = NativeCardLayerCache.cardPlaceholderCGColor(isLight: false)

        placeholderIconLayer.contents = NativeCardLayerCache.filmPlaceholderImage(isLight: false)
        placeholderIconLayer.contentsScale = 2.0
        placeholderIconLayer.contentsGravity = .center
        placeholderIconLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(placeholderIconLayer)

        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.contentsScale = 2.0
        posterLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(posterLayer)

        gradientLayer.contents = NativeCardLayerCache.posterBottomGradient
        gradientLayer.contentsGravity = .resize
        cardContainerLayer.addSublayer(gradientLayer)

        hoverDimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        hoverDimLayer.isHidden = true
        hoverDimLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(hoverDimLayer)

        cardContainerLayer.addSublayer(resBadgeLayer)
        cardContainerLayer.addSublayer(unplayedBadgeLayer)
        cardContainerLayer.addSublayer(playedIconLayer)
        cardContainerLayer.addSublayer(ratingPillLayer)
        cardContainerLayer.addSublayer(downloadedBadgeLayer)
        cardContainerLayer.addSublayer(favoriteIconLayer)

        progressTrack.cornerRadius = 1.5
        progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        progressFill.cornerRadius = 1.5
        progressTrack.addSublayer(progressFill)
        cardContainerLayer.addSublayer(progressTrack)

        playLayer.contents = NativeCardLayerCache.playCircleImage(diameter: 40, iconSize: 15)
        playLayer.contentsScale = 2.0
        playLayer.contentsGravity = .resize
        playLayer.isHidden = true
        cardContainerLayer.addSublayer(playLayer)

        textBlockLayer.isOpaque = true
        textBlockLayer.backgroundColor = NativeCardLayerCache.canvasDarkCG
        textBlockLayer.contentsScale = 2.0
        textBlockLayer.contentsGravity = .resize
        textBlockLayer.actions = NativeCardLayerCache.noImplicitActions

        root.layer?.addSublayer(cardContainerLayer)
        root.layer?.addSublayer(textBlockLayer)
        self.view = root
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let boundsWidth = view.bounds.width
        if boundsWidth > 0 && abs(boundsWidth - currentCardWidth) > 0.5 {
            currentCardWidth = boundsWidth
            needsCardLayout = true
        }
        let width = currentCardWidth > 0 ? currentCardWidth : boundsWidth
        if needsCardLayout || abs(lastLaidOutWidth - width) > 0.5 {
            layoutCardElements()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        currentItem = nil
        pendingTextKey = nil
        setHovered(false)
    }

    deinit {
        loadTask?.cancel()
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        let borderCG = currentAppearance.map { NativeCardLayerCache.srgbColorInfo(for: $0.accentColor).hoverBorderCG }
            ?? NSColor.white.withAlphaComponent(0.35).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hovered {
            cardContainerLayer.borderWidth = 1.5
            cardContainerLayer.borderColor = borderCG
            hoverDimLayer.isHidden = false
            playLayer.isHidden = true
        } else {
            cardContainerLayer.borderWidth = 0.65
            cardContainerLayer.borderColor = NativeCardLayerCache.defaultPosterBorderCGColor
            hoverDimLayer.isHidden = true
            playLayer.isHidden = true
        }
        CATransaction.commit()
    }

    func hitTestHoverPoint(_ pointInItemView: NSPoint) -> Bool {
        cardContainerLayer.frame.contains(pointInItemView)
    }

    func handleClick(at pointInItemView: NSPoint) {
        guard let currentItem else { return }
        actionDelegate?.cardDidSelect(currentItem)
    }

    func configure(
        item: EmbyItem,
        cardWidth: CGFloat,
        appearance: DonbyCardAppearance,
        allowAsyncLoad: Bool = true,
        deferTextRenderIfScrolling: Bool = false
    ) {
        let sameIdentity = (currentItem == item && currentAppearance == appearance && abs(currentCardWidth - cardWidth) < 0.5)
        if sameIdentity {
            if allowAsyncLoad && posterLayer.contents == nil && loadTask == nil {
                startPosterLoad(item: item, server: appearance.server)
            }
            return
        }
        let sameImageSource = (currentItem?.id == item.id && currentAppearance?.server?.activeBaseURL == appearance.server?.activeBaseURL)
        currentItem = item
        currentAppearance = appearance
        let widthChanged = abs(currentCardWidth - cardWidth) > 0.5
        currentCardWidth = cardWidth
        if widthChanged {
            needsCardLayout = true
        }

        let accentInfo = NativeCardLayerCache.srgbColorInfo(for: appearance.accentColor)
        let accentTextInfo = NativeCardLayerCache.srgbColorInfo(for: appearance.accentTextColor)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if lastIsLightMode != appearance.isLightMode {
            cardContainerLayer.backgroundColor = NativeCardLayerCache.cardPlaceholderCGColor(isLight: appearance.isLightMode)
            placeholderIconLayer.contents = NativeCardLayerCache.filmPlaceholderImage(isLight: appearance.isLightMode)
            textBlockLayer.backgroundColor = NativeCardLayerCache.canvasCGColor(isLight: appearance.isLightMode)
        }

        let subtitleText = item.displaySubtitle.isEmpty ? (item.isSeries ? "剧集" : "电影") : item.displaySubtitle
        if lastTitle != item.name || lastSubtitle != subtitleText || abs(lastTextWidth - cardWidth) > 0.5 || textBlockLayer.contents == nil || lastIsLightMode != appearance.isLightMode {
            lastTitle = item.name
            lastSubtitle = subtitleText
            lastTextWidth = cardWidth
            if let cachedText = CardTextBitmapCache.shared.cached(
                title: item.name,
                subtitle: subtitleText,
                width: cardWidth,
                isLightMode: appearance.isLightMode
            ) {
                pendingTextKey = nil
                textBlockLayer.contents = cachedText
            } else if deferTextRenderIfScrolling {
                let reqKey = CardTextBitmapCache.shared.cacheKey(
                    title: item.name,
                    subtitle: subtitleText,
                    width: cardWidth,
                    isLightMode: appearance.isLightMode
                )
                pendingTextKey = reqKey
                textBlockLayer.contents = nil
                let targetId = item.id
                CardTextBitmapCache.shared.renderAsync(
                    title: item.name,
                    subtitle: subtitleText,
                    width: cardWidth,
                    isLightMode: appearance.isLightMode
                ) { [weak self] cg in
                    guard let self,
                          self.currentItem?.id == targetId,
                          self.pendingTextKey == reqKey,
                          let cg else { return }
                    self.pendingTextKey = nil
                    self.textBlockLayer.contents = cg
                }
            } else {
                pendingTextKey = nil
                textBlockLayer.contents = CardTextBitmapCache.shared.renderOrCached(
                    title: item.name,
                    subtitle: subtitleText,
                    width: cardWidth,
                    isLightMode: appearance.isLightMode
                )
            }
        }
        lastIsLightMode = appearance.isLightMode

        resBadgeLayer.isHidden = true

        if let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            configureBadgeLayer(
                unplayedBadgeLayer,
                with: NativeCardLayerCache.unplayedBadgeImage(
                    count: unplayed,
                    accentColor: accentInfo.ns,
                    textColor: accentTextInfo.ns,
                    accentKey: accentInfo.key,
                    textKey: accentTextInfo.key
                )
            )
            unplayedBadgeLayer.isHidden = false
            playedIconLayer.isHidden = true
        } else if item.userData?.played == true {
            unplayedBadgeLayer.isHidden = true
            configureBadgeLayer(playedIconLayer, with: NativeCardLayerCache.playedCheckImage(accentColor: accentInfo.ns, colorKey: accentInfo.key))
            playedIconLayer.isHidden = false
        } else {
            unplayedBadgeLayer.isHidden = true
            playedIconLayer.isHidden = true
        }

        if appearance.showRatingBadge, let rating = item.communityRating, rating > 0 {
            configureBadgeLayer(ratingPillLayer, with: NativeCardLayerCache.ratingPillImage(ratingText: NativeCardLayerCache.formatRatingTenths(rating)))
            ratingPillLayer.isHidden = false
        } else {
            ratingPillLayer.isHidden = true
        }

        if item.userData?.isFavorite == true {
            let heartColor = appearance.isMonochromeTheme ? NSColor.white : accentInfo.ns
            let heartKey = appearance.isMonochromeTheme ? "mono_white" : accentInfo.key
            configureBadgeLayer(
                favoriteIconLayer,
                with: NativeCardLayerCache.favoriteHeartImage(accentColor: heartColor, colorKey: heartKey)
            )
            favoriteIconLayer.isHidden = false
        } else {
            favoriteIconLayer.isHidden = true
        }

        if let dlText = appearance.downloadStatusIndex.badgeText(for: item) {
            let isDone = appearance.downloadStatusIndex.isItemDownloaded(item)
            configureBadgeLayer(
                downloadedBadgeLayer,
                with: NativeCardLayerCache.downloadedBadgeImage(
                    text: dlText,
                    isCompleted: isDone,
                    accentColor: accentInfo.ns,
                    accentKey: accentInfo.key
                )
            )
            downloadedBadgeLayer.isHidden = false
        } else {
            downloadedBadgeLayer.isHidden = true
        }
        needsCardLayout = true

        let progress = item.progressFraction
        if progress > 0 && progress < 0.99 {
            progressTrack.isHidden = false
            progressFill.backgroundColor = appearance.isMonochromeTheme ? NSColor.white.cgColor : accentInfo.cg
        } else {
            progressTrack.isHidden = true
        }

        CATransaction.commit()
        layoutCardElements()

        if sameImageSource {
            if allowAsyncLoad && posterLayer.contents == nil && loadTask == nil {
                if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: item, kind: .primary, maxWidth: 360) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    posterLayer.contents = cachedCG
                    posterLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
                    placeholderIconLayer.isHidden = true
                    CATransaction.commit()
                } else {
                    startPosterLoad(item: item, server: appearance.server)
                }
            }
            return
        }

        loadTask?.cancel()
        loadTask = nil

        if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: item, kind: .primary, maxWidth: 360) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            posterLayer.contents = cachedCG
            posterLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
            placeholderIconLayer.isHidden = true
            CATransaction.commit()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.contents = nil
        posterLayer.isOpaque = false
        placeholderIconLayer.isHidden = false
        CATransaction.commit()

        if allowAsyncLoad {
            startPosterLoad(item: item, server: appearance.server)
        }
    }

    func startPendingArtworkLoadIfNeeded() {
        guard let currentItem, posterLayer.contents == nil, loadTask == nil else { return }
        if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: currentItem, kind: .primary, maxWidth: 360) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            posterLayer.contents = cachedCG
            posterLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
            placeholderIconLayer.isHidden = true
            CATransaction.commit()
            return
        }
        startPosterLoad(item: currentItem, server: currentAppearance?.server)
    }

    private func startPosterLoad(item: EmbyItem, server: EmbyServerConfig?) {
        let targetId = item.id
        loadTask = Task { @MainActor [weak self] in
            let cgImage = await MediaArtworkView.loadOrFetchCGImage(server: server, item: item, kind: .primary, maxWidth: 360, priority: .high)
            guard let self, !Task.isCancelled, self.currentItem?.id == targetId, let cgImage else { return }
            self.posterLayer.contents = cgImage
            self.posterLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cgImage)
            self.placeholderIconLayer.isHidden = true
        }
    }

    private func layoutCardElements() {
        let width = currentCardWidth > 0 ? currentCardWidth : view.bounds.width
        let posterHeight = round(width * 1.5)
        lastLaidOutWidth = width
        needsCardLayout = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        cardContainerLayer.frame = CGRect(x: 0, y: 0, width: width, height: posterHeight)
        posterLayer.frame = cardContainerLayer.bounds
        placeholderIconLayer.frame = cardContainerLayer.bounds
        gradientLayer.frame = CGRect(x: 0, y: posterHeight * 0.5, width: width, height: posterHeight * 0.5)
        hoverDimLayer.frame = cardContainerLayer.bounds

        if !resBadgeLayer.isHidden, let cg = resBadgeLayer.contents as! CGImage? {
            let badgeW = min(CGFloat(cg.width) * 0.5, max(20, width - 36))
            let badgeH = CGFloat(cg.height) * 0.5
            resBadgeLayer.frame = CGRect(x: 7, y: 7, width: badgeW, height: badgeH)
        }
        if !unplayedBadgeLayer.isHidden, let cg = unplayedBadgeLayer.contents as! CGImage? {
            let badgeW = CGFloat(cg.width) * 0.5
            let badgeH = CGFloat(cg.height) * 0.5
            unplayedBadgeLayer.frame = CGRect(x: width - 7 - badgeW, y: 7, width: badgeW, height: badgeH)
        }
        if !playedIconLayer.isHidden {
            playedIconLayer.frame = CGRect(x: width - 7 - 18, y: 7, width: 18, height: 18)
        }

        let hasProgress = !progressTrack.isHidden
        let bottomInset: CGFloat = hasProgress ? 14 : 7
        if hasProgress {
            let trackW = width - 14
            progressTrack.frame = CGRect(x: 7, y: posterHeight - 10, width: trackW, height: 3)
            let fraction = CGFloat(max(0.0, min(1.0, currentItem?.progressFraction ?? 0.0)))
            progressFill.frame = CGRect(x: 0, y: 0, width: trackW * fraction, height: 3)
        }

        var dlStartX: CGFloat = 7
        if !ratingPillLayer.isHidden, let cg = ratingPillLayer.contents as! CGImage? {
            let pillW = CGFloat(cg.width) * 0.5
            let pillH = CGFloat(cg.height) * 0.5
            ratingPillLayer.frame = CGRect(x: 7, y: posterHeight - bottomInset - pillH, width: pillW, height: pillH)
            dlStartX = 7 + pillW + 4
        }
        if !downloadedBadgeLayer.isHidden, let cg = downloadedBadgeLayer.contents as! CGImage? {
            let dlW = CGFloat(cg.width) * 0.5
            let dlH = CGFloat(cg.height) * 0.5
            downloadedBadgeLayer.frame = CGRect(x: dlStartX, y: posterHeight - bottomInset - dlH, width: dlW, height: dlH)
        }
        if !favoriteIconLayer.isHidden {
            favoriteIconLayer.frame = CGRect(x: width - 7 - 14, y: posterHeight - bottomInset - 14, width: 14, height: 14)
        }

        playLayer.frame = CGRect(x: (width - 40) * 0.5, y: (posterHeight - 40) * 0.5, width: 40, height: 40)
        textBlockLayer.frame = CGRect(x: 0, y: posterHeight + 6.0, width: width, height: 35.0)

        CATransaction.commit()
    }
}

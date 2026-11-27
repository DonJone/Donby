import SwiftUI
import AppKit
import QuartzCore
import DonbyCore
import DonbyNetwork

private func createTextLayer(font: NSFont, fontSize: CGFloat) -> CATextLayer {
    let layer = CATextLayer()
    layer.font = font
    layer.fontSize = fontSize
    layer.contentsScale = 2.0
    layer.truncationMode = .end
    layer.isWrapped = false
    layer.alignmentMode = .left
    layer.isOpaque = false
    return layer
}

// MARK: - Pure CALayer Landscape Cell
final class NativeLandscapeCollectionItem: NSCollectionViewItem, HoverableCollectionItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativeLandscapeCollectionItem")
    static let itemSize = NSSize(width: 248, height: 180)
    private static let thumbHeight: CGFloat = 140

    private let cardContainerLayer = CALayer()
    private let placeholderIconLayer = CALayer()
    private let artworkLayer = CALayer()
    private let gradientLayer = CALayer()
    private let hoverDimLayer = CALayer()
    private let playLayer = CALayer()

    private let topLeftBadgeLayer = CALayer()
    private let downloadedBadgeLayer = CALayer()
    private let runtimeBadgeLayer = CALayer()
    private let progressTrack = CALayer()
    private let progressFill = CALayer()

    private let textBlockLayer = CALayer()
    private let infoIconLayer = CALayer()

    private var currentItem: EmbyItem?
    private var currentAppearance: DonbyCardAppearance?
    private var loadTask: Task<Void, Never>?
    private var isHovered = false

    private var lastTitle: String?
    private var lastSubtitle: String?
    private var lastIsLightMode: Bool?

    weak var actionDelegate: (any NativeCardActionDelegate)?

    override func loadView() {
        let root = LayerOnlyCellRootView(frame: NSRect(origin: .zero, size: Self.itemSize))
        root.wantsLayer = true
        root.autoresizingMask = []
        root.autoresizesSubviews = false

        cardContainerLayer.frame = CGRect(x: 0, y: 0, width: Self.itemSize.width, height: Self.thumbHeight)
        cardContainerLayer.cornerRadius = 10
        cardContainerLayer.cornerCurve = .continuous
        cardContainerLayer.masksToBounds = true
        cardContainerLayer.isOpaque = true
        cardContainerLayer.borderWidth = 0.65
        cardContainerLayer.borderColor = NativeCardLayerCache.defaultPosterBorderCGColor
        cardContainerLayer.backgroundColor = NativeCardLayerCache.cardPlaceholderCGColor(isLight: false)

        placeholderIconLayer.frame = cardContainerLayer.bounds
        placeholderIconLayer.contents = NativeCardLayerCache.filmPlaceholderImage(isLight: false)
        placeholderIconLayer.contentsScale = 2.0
        placeholderIconLayer.contentsGravity = .center
        placeholderIconLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(placeholderIconLayer)

        artworkLayer.frame = cardContainerLayer.bounds
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.contentsScale = 2.0
        artworkLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(artworkLayer)

        gradientLayer.frame = cardContainerLayer.bounds
        gradientLayer.contents = NativeCardLayerCache.landscapeGradient
        gradientLayer.contentsGravity = .resize
        cardContainerLayer.addSublayer(gradientLayer)

        hoverDimLayer.frame = cardContainerLayer.bounds
        hoverDimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        hoverDimLayer.isHidden = true
        hoverDimLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(hoverDimLayer)

        cardContainerLayer.addSublayer(topLeftBadgeLayer)
        cardContainerLayer.addSublayer(downloadedBadgeLayer)
        cardContainerLayer.addSublayer(runtimeBadgeLayer)

        progressTrack.frame = CGRect(x: 8, y: Self.thumbHeight - 11.5, width: Self.itemSize.width - 16, height: 3.5)
        progressTrack.cornerRadius = 1.75
        progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        progressFill.cornerRadius = 1.75
        progressTrack.addSublayer(progressFill)
        cardContainerLayer.addSublayer(progressTrack)

        playLayer.frame = CGRect(
            x: (Self.itemSize.width - 36) * 0.5,
            y: (Self.thumbHeight - 36) * 0.5,
            width: 36,
            height: 36
        )
        playLayer.contents = NativeCardLayerCache.playCircleImage(diameter: 36, iconSize: 13)
        playLayer.contentsScale = 2.0
        playLayer.contentsGravity = .resize
        playLayer.isHidden = true
        cardContainerLayer.addSublayer(playLayer)

        let textWidth = Self.itemSize.width - 28
        textBlockLayer.isOpaque = true
        textBlockLayer.backgroundColor = NativeCardLayerCache.canvasDarkCG
        textBlockLayer.contentsScale = 2.0
        textBlockLayer.contentsGravity = .resize
        textBlockLayer.actions = NativeCardLayerCache.noImplicitActions
        textBlockLayer.frame = CGRect(x: 0, y: Self.thumbHeight + 5.5, width: textWidth, height: 35.0)

        infoIconLayer.frame = CGRect(x: Self.itemSize.width - 22, y: Self.thumbHeight + 11, width: 22, height: 22)
        infoIconLayer.contentsScale = 2.0
        infoIconLayer.contentsGravity = .center

        root.layer?.addSublayer(cardContainerLayer)
        root.layer?.addSublayer(textBlockLayer)
        root.layer?.addSublayer(infoIconLayer)
        self.view = root
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        currentItem = nil
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

    func configure(item: EmbyItem, appearance: DonbyCardAppearance, allowAsyncLoad: Bool = true) {
        let sameIdentity = (currentItem == item && currentAppearance == appearance)
        if sameIdentity {
            if allowAsyncLoad && artworkLayer.contents == nil && loadTask == nil {
                startThumbLoad(item: item, server: appearance.server)
            }
            return
        }
        let sameImageSource = (currentItem?.id == item.id && currentAppearance?.server?.activeBaseURL == appearance.server?.activeBaseURL)
        currentItem = item
        currentAppearance = appearance

        let accentInfo = NativeCardLayerCache.srgbColorInfo(for: appearance.accentColor)
        let cardWidth = Self.itemSize.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if lastIsLightMode != appearance.isLightMode {
            cardContainerLayer.backgroundColor = NativeCardLayerCache.cardPlaceholderCGColor(isLight: appearance.isLightMode)
            placeholderIconLayer.contents = NativeCardLayerCache.filmPlaceholderImage(isLight: appearance.isLightMode)
            infoIconLayer.contents = NativeCardLayerCache.infoIconImage(isLight: appearance.isLightMode)
            textBlockLayer.backgroundColor = NativeCardLayerCache.canvasCGColor(isLight: appearance.isLightMode)
        }

        let title = item.isEpisode ? (item.seriesName ?? item.name) : item.name
        let subtitle = item.isEpisode ? item.name : item.displaySubtitle
        if lastTitle != title || lastSubtitle != subtitle || textBlockLayer.contents == nil || lastIsLightMode != appearance.isLightMode {
            lastTitle = title
            lastSubtitle = subtitle
            textBlockLayer.contents = CardTextBitmapCache.shared.renderOrCached(
                title: title,
                subtitle: subtitle,
                width: Self.itemSize.width - 28,
                isLightMode: appearance.isLightMode
            )
        }
        lastIsLightMode = appearance.isLightMode

        var dlX: CGFloat = 7
        if let epCode = item.episodeCodeString {
            let cg = NativeCardLayerCache.resolutionBadgeImage(text: epCode, monospaced: true)
            configureBadgeLayer(topLeftBadgeLayer, with: cg)
            if let cg {
                let bw = CGFloat(cg.width) * 0.5
                topLeftBadgeLayer.frame = CGRect(x: 7, y: 7, width: bw, height: CGFloat(cg.height) * 0.5)
                dlX = 7 + bw + 5
            }
            topLeftBadgeLayer.isHidden = false
        } else {
            topLeftBadgeLayer.isHidden = true
        }

        if let dlText = appearance.downloadStatusIndex.badgeText(for: item) {
            let isDone = appearance.downloadStatusIndex.isItemDownloaded(item)
            let cg = NativeCardLayerCache.downloadedBadgeImage(
                text: dlText,
                isCompleted: isDone,
                accentColor: accentInfo.ns,
                accentKey: accentInfo.key
            )
            configureBadgeLayer(downloadedBadgeLayer, with: cg)
            if let cg {
                downloadedBadgeLayer.frame = CGRect(x: dlX, y: 7, width: CGFloat(cg.width) * 0.5, height: CGFloat(cg.height) * 0.5)
            }
            downloadedBadgeLayer.isHidden = false
        } else {
            downloadedBadgeLayer.isHidden = true
        }

        if let runtime = item.runtimeMinutesString,
           let cg = NativeCardLayerCache.runtimeBadgeImage(text: runtime) {
            configureBadgeLayer(runtimeBadgeLayer, with: cg)
            let badgeW = CGFloat(cg.width) * 0.5
            runtimeBadgeLayer.frame = CGRect(x: cardWidth - 7 - badgeW, y: 7, width: badgeW, height: CGFloat(cg.height) * 0.5)
            runtimeBadgeLayer.isHidden = false
        } else {
            runtimeBadgeLayer.isHidden = true
        }

        let progress = item.progressFraction
        if progress > 0 {
            progressTrack.isHidden = false
            progressFill.backgroundColor = appearance.isMonochromeTheme ? NSColor.white.cgColor : accentInfo.cg
            let trackW = cardWidth - 16
            progressFill.frame = CGRect(x: 0, y: 0, width: trackW * CGFloat(min(1.0, progress)), height: 3.5)
        } else {
            progressTrack.isHidden = true
        }

        CATransaction.commit()

        if sameImageSource {
            if allowAsyncLoad && artworkLayer.contents == nil && loadTask == nil {
                if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: item, kind: .thumb, maxWidth: 500) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    artworkLayer.contents = cachedCG
                    artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
                    placeholderIconLayer.isHidden = true
                    CATransaction.commit()
                } else {
                    startThumbLoad(item: item, server: appearance.server)
                }
            }
            return
        }

        loadTask?.cancel()
        loadTask = nil

        if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: item, kind: .thumb, maxWidth: 500) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artworkLayer.contents = cachedCG
            artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
            placeholderIconLayer.isHidden = true
            CATransaction.commit()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = nil
        artworkLayer.isOpaque = false
        placeholderIconLayer.isHidden = false
        CATransaction.commit()

        if allowAsyncLoad {
            startThumbLoad(item: item, server: appearance.server)
        }
    }

    func startPendingArtworkLoadIfNeeded() {
        guard let currentItem, artworkLayer.contents == nil, loadTask == nil else { return }
        if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: currentItem, kind: .thumb, maxWidth: 500) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artworkLayer.contents = cachedCG
            artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
            placeholderIconLayer.isHidden = true
            CATransaction.commit()
            return
        }
        startThumbLoad(item: currentItem, server: currentAppearance?.server)
    }

    private func startThumbLoad(item: EmbyItem, server: EmbyServerConfig?) {
        let targetId = item.id
        loadTask = Task { @MainActor [weak self] in
            let cgImage = await MediaArtworkView.loadOrFetchCGImage(server: server, item: item, kind: .thumb, maxWidth: 500, priority: .high)
            guard let self, !Task.isCancelled, self.currentItem?.id == targetId else { return }
            self.loadTask = nil
            guard let cgImage else { return }
            self.artworkLayer.contents = cgImage
            self.artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cgImage)
            self.placeholderIconLayer.isHidden = true
        }
    }
}

// MARK: - Pure CALayer Library Cell
final class NativeLibraryCollectionItem: NSCollectionViewItem, HoverableCollectionItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativeLibraryCollectionItem")
    static let itemSize = NSSize(width: 205, height: 112)

    private let cardContainerLayer = CALayer()
    private let placeholderIconLayer = CALayer()
    private let artworkLayer = CALayer()
    private let gradientLayer = CALayer()
    private let countBadgeLayer = CALayer()
    private let titleLayer = createTextLayer(font: NSFont.systemFont(ofSize: 14.5, weight: .bold), fontSize: 14.5)

    private var currentLibrary: EmbyItem?
    private var currentAppearance: DonbyCardAppearance?
    private var lastItemCount: Int?
    private var lastIsLightMode: Bool?
    private var loadTask: Task<Void, Never>?
    private var isHovered = false
    private var lastTitle: String?

    weak var actionDelegate: (any NativeCardActionDelegate)?

    override func loadView() {
        let root = LayerOnlyCellRootView(frame: NSRect(origin: .zero, size: Self.itemSize))
        root.wantsLayer = true
        root.autoresizingMask = []
        root.autoresizesSubviews = false

        cardContainerLayer.frame = CGRect(origin: .zero, size: Self.itemSize)
        cardContainerLayer.cornerRadius = 12
        cardContainerLayer.cornerCurve = .continuous
        cardContainerLayer.masksToBounds = true
        cardContainerLayer.isOpaque = true
        cardContainerLayer.borderWidth = 0.65
        cardContainerLayer.borderColor = NativeCardLayerCache.defaultLibraryBorderDarkCGColor
        cardContainerLayer.backgroundColor = NativeCardLayerCache.cardPlaceholderCGColor(isLight: false)

        placeholderIconLayer.frame = cardContainerLayer.bounds
        placeholderIconLayer.contents = NativeCardLayerCache.filmPlaceholderImage(isLight: false)
        placeholderIconLayer.contentsScale = 2.0
        placeholderIconLayer.contentsGravity = .center
        placeholderIconLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(placeholderIconLayer)

        artworkLayer.frame = cardContainerLayer.bounds
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.contentsScale = 2.0
        artworkLayer.actions = NativeCardLayerCache.noImplicitActions
        cardContainerLayer.addSublayer(artworkLayer)

        gradientLayer.frame = cardContainerLayer.bounds
        gradientLayer.contents = NativeCardLayerCache.libraryGradient
        gradientLayer.contentsGravity = .resize
        cardContainerLayer.addSublayer(gradientLayer)

        cardContainerLayer.addSublayer(countBadgeLayer)

        titleLayer.isOpaque = false
        titleLayer.backgroundColor = nil
        titleLayer.foregroundColor = NSColor.white.cgColor
        titleLayer.frame = CGRect(x: 11, y: Self.itemSize.height - 30, width: Self.itemSize.width - 22, height: 19)
        cardContainerLayer.addSublayer(titleLayer)

        root.layer?.addSublayer(cardContainerLayer)
        self.view = root
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        currentLibrary = nil
        setHovered(false)
    }

    deinit {
        loadTask?.cancel()
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        let isLight = currentAppearance?.isLightMode ?? false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hovered {
            cardContainerLayer.borderWidth = 1.5
            cardContainerLayer.borderColor = NativeCardLayerCache.hoverLibraryBorderCGColor
        } else {
            cardContainerLayer.borderWidth = 0.65
            cardContainerLayer.borderColor = isLight ? NativeCardLayerCache.defaultLibraryBorderLightCGColor : NativeCardLayerCache.defaultLibraryBorderDarkCGColor
        }
        CATransaction.commit()
    }

    func hitTestHoverPoint(_ pointInItemView: NSPoint) -> Bool {
        cardContainerLayer.frame.contains(pointInItemView)
    }

    func handleClick(at pointInItemView: NSPoint) {
        guard let currentLibrary else { return }
        actionDelegate?.cardDidSelect(currentLibrary)
    }

    func configure(library: EmbyItem, itemCount: Int?, appearance: DonbyCardAppearance, allowAsyncLoad: Bool = true) {
        let artworkKind: EmbyImageKind = (library.backdropImageTags?.isEmpty == false) ? .backdrop : .primary
        let resolvedCount = itemCount ?? library.childCount
        let sameIdentity = (currentLibrary == library && currentAppearance == appearance && lastItemCount == resolvedCount)
        if sameIdentity {
            if allowAsyncLoad && artworkLayer.contents == nil && loadTask == nil {
                startLibraryArtworkLoad(library: library, artworkKind: artworkKind, server: appearance.server)
            }
            return
        }
        let sameImageSource = (currentLibrary?.id == library.id && currentAppearance?.server?.activeBaseURL == appearance.server?.activeBaseURL)
        currentLibrary = library
        currentAppearance = appearance
        lastItemCount = resolvedCount

        let hidesOverlay = appearance.hidesLibraryTextOverlay

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if !isHovered {
            cardContainerLayer.borderColor = appearance.isLightMode
                ? NativeCardLayerCache.defaultLibraryBorderLightCGColor
                : NativeCardLayerCache.defaultLibraryBorderDarkCGColor
        }
        if lastIsLightMode != appearance.isLightMode {
            lastIsLightMode = appearance.isLightMode
            placeholderIconLayer.contents = NativeCardLayerCache.filmPlaceholderImage(isLight: appearance.isLightMode)
        }
        cardContainerLayer.backgroundColor = NativeCardLayerCache.cardPlaceholderCGColor(isLight: appearance.isLightMode)
        gradientLayer.isHidden = hidesOverlay
        titleLayer.isHidden = hidesOverlay
        if !hidesOverlay, lastTitle != library.name {
            lastTitle = library.name
            titleLayer.string = library.name
        }

        if let count = resolvedCount, count > 0,
           let cg = NativeCardLayerCache.libraryCountBadgeImage(countText: String(count)) {
            configureBadgeLayer(countBadgeLayer, with: cg)
            let badgeW = CGFloat(cg.width) * 0.5
            countBadgeLayer.frame = CGRect(x: Self.itemSize.width - 11 - badgeW, y: 11, width: badgeW, height: CGFloat(cg.height) * 0.5)
            countBadgeLayer.isHidden = false
        } else {
            countBadgeLayer.isHidden = true
        }

        CATransaction.commit()

        if sameImageSource {
            if allowAsyncLoad && artworkLayer.contents == nil && loadTask == nil {
                if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: library, kind: artworkKind, maxWidth: 440) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    artworkLayer.contents = cachedCG
                    artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
                    placeholderIconLayer.isHidden = true
                    CATransaction.commit()
                } else {
                    startLibraryArtworkLoad(library: library, artworkKind: artworkKind, server: appearance.server)
                }
            }
            return
        }

        loadTask?.cancel()
        loadTask = nil

        if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: library, kind: artworkKind, maxWidth: 440) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artworkLayer.contents = cachedCG
            artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
            placeholderIconLayer.isHidden = true
            CATransaction.commit()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = nil
        artworkLayer.isOpaque = false
        placeholderIconLayer.isHidden = false
        CATransaction.commit()

        if allowAsyncLoad {
            startLibraryArtworkLoad(library: library, artworkKind: artworkKind, server: appearance.server)
        }
    }

    func startPendingArtworkLoadIfNeeded() {
        guard let currentLibrary, artworkLayer.contents == nil, loadTask == nil else { return }
        let artworkKind: EmbyImageKind = (currentLibrary.backdropImageTags?.isEmpty == false) ? .backdrop : .primary
        if let cachedCG = MediaArtworkView.cachedCGImageInMemory(item: currentLibrary, kind: artworkKind, maxWidth: 440) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artworkLayer.contents = cachedCG
            artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cachedCG)
            placeholderIconLayer.isHidden = true
            CATransaction.commit()
            return
        }
        startLibraryArtworkLoad(library: currentLibrary, artworkKind: artworkKind, server: currentAppearance?.server)
    }

    private func startLibraryArtworkLoad(library: EmbyItem, artworkKind: EmbyImageKind, server: EmbyServerConfig?) {
        let targetId = library.id
        loadTask = Task { @MainActor [weak self] in
            let cgImage = await MediaArtworkView.loadOrFetchCGImage(server: server, item: library, kind: artworkKind, maxWidth: 440, priority: .veryHigh)
            guard let self, !Task.isCancelled, self.currentLibrary?.id == targetId else { return }
            self.loadTask = nil
            guard let cgImage else { return }
            self.artworkLayer.contents = cgImage
            self.artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cgImage)
            self.placeholderIconLayer.isHidden = true
        }
    }
}

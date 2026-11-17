import SwiftUI
import AppKit
import QuartzCore
import CoreText
import DonbyCore
import DonbyNetwork

class FlippedLayerHostView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

class LayerOnlyCellRootView: FlippedLayerHostView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class NonDraggableScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
    var onWidthChanged: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        if abs(width - lastWidth) > 1.0, width > 0 {
            lastWidth = width
            onWidthChanged?(width)
        }
    }
}

final class HorizontalShelfScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

@MainActor
protocol HoverableCollectionItem: NSCollectionViewItem {
    func setHovered(_ hovered: Bool)
    func hitTestHoverPoint(_ pointInItemView: NSPoint) -> Bool
    func handleClick(at pointInItemView: NSPoint)
}

final class InteractiveCollectionView: NSCollectionView {
    override var mouseDownCanMoveWindow: Bool { false }

    var canHover: (() -> Bool)?
    private var hoverTrackingArea: NSTrackingArea?
    private weak var activeHoveredItem: (any HoverableCollectionItem)?
    private var mouseDownPoint: NSPoint?
    private weak var mouseDownItem: (any HoverableCollectionItem)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    func clearHover() {
        activeHoveredItem?.setHovered(false)
        activeHoveredItem = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard canHover?() ?? true else {
            clearHover()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point),
              let cell = item(at: indexPath) as? any HoverableCollectionItem else {
            clearHover()
            return
        }
        let localPoint = cell.view.convert(point, from: self)
        guard cell.hitTestHoverPoint(localPoint) else {
            clearHover()
            return
        }
        if activeHoveredItem !== cell {
            activeHoveredItem?.setHovered(false)
            cell.setHovered(true)
            activeHoveredItem = cell
        }
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           let cell = item(at: indexPath) as? any HoverableCollectionItem {
            mouseDownPoint = point
            mouseDownItem = cell
            return
        }
        mouseDownPoint = nil
        mouseDownItem = nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let downPoint = mouseDownPoint, let targetCell = mouseDownItem else {
            super.mouseUp(with: event)
            return
        }
        mouseDownPoint = nil
        mouseDownItem = nil
        guard targetCell.view.superview != nil else { return }
        let upPoint = convert(event.locationInWindow, from: nil)
        guard hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 6 else { return }
        let localPoint = targetCell.view.convert(upPoint, from: self)
        targetCell.handleClick(at: localPoint)
    }
}

@MainActor
final class ScrollHoverGate {
    private(set) var isActivelyScrolling = false
    private var lastScrollActivityTime: CFTimeInterval = 0
    private var hasPendingIdleCheck = false
    private let idleDelay: TimeInterval
    private let onScrollBegan: () -> Void
    private let onScrollEnded: (() -> Void)?

    init(
        idleDelay: TimeInterval = 0.14,
        onScrollBegan: @escaping () -> Void,
        onScrollEnded: (() -> Void)? = nil
    ) {
        self.idleDelay = idleDelay
        self.onScrollBegan = onScrollBegan
        self.onScrollEnded = onScrollEnded
    }

    var canHover: Bool {
        !isActivelyScrolling && (CACurrentMediaTime() - lastScrollActivityTime >= idleDelay)
    }

    func markScrollingActivity() {
        lastScrollActivityTime = CACurrentMediaTime()
        if !isActivelyScrolling {
            isActivelyScrolling = true
            ScrollActivityTracker.setScrolling(true)
            onScrollBegan()
        }
        scheduleIdleEvaluation()
    }

    func scheduleIdleEvaluation() {
        guard !hasPendingIdleCheck else { return }
        hasPendingIdleCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay + 0.01) { [weak self] in
            self?.evaluateIdle()
        }
    }

    private func evaluateIdle() {
        hasPendingIdleCheck = false
        let elapsed = CACurrentMediaTime() - lastScrollActivityTime
        if elapsed < idleDelay - 0.005 {
            hasPendingIdleCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (idleDelay - elapsed) + 0.01) { [weak self] in
                self?.evaluateIdle()
            }
        } else {
            isActivelyScrolling = false
            ScrollActivityTracker.setScrolling(false)
            onScrollEnded?()
        }
    }
}

@MainActor
protocol NativeCardActionDelegate: AnyObject {
    func cardDidSelect(_ item: EmbyItem)
    func cardDidPlay(_ item: EmbyItem)
}

@MainActor
enum NativeCardLayerCache {
    struct SRGBColorInfo {
        let ns: NSColor
        let cg: CGColor
        let hoverBorderCG: CGColor
        let key: String
    }

    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static var pillCache: [String: CGImage] = [:]
    private static var iconCache: [String: CGImage] = [:]
    private static var srgbColorCache: [Color: SRGBColorInfo] = [:]

    static let noImplicitActions: [String: CAAction] = [
        "contents": NSNull(),
        "hidden": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "backgroundColor": NSNull(),
        "borderColor": NSNull(),
        "borderWidth": NSNull(),
        "opacity": NSNull()
    ]

    static let defaultPosterBorderCGColor: CGColor = NSColor.white.withAlphaComponent(0.06).cgColor
    static let defaultLibraryBorderDarkCGColor: CGColor = NSColor.white.withAlphaComponent(0.08).cgColor
    static let defaultLibraryBorderLightCGColor: CGColor = NSColor.black.withAlphaComponent(0.06).cgColor
    static let hoverLibraryBorderCGColor: CGColor = NSColor.white.withAlphaComponent(0.50).cgColor
    private static let canvasDarkNS = NSColor(srgbRed: 0.043, green: 0.046, blue: 0.056, alpha: 1.0)
    private static let canvasLightNS = NSColor(srgbRed: 0.945, green: 0.948, blue: 0.960, alpha: 1.0)
    static let canvasDarkCG = canvasDarkNS.cgColor
    static let canvasLightCG = canvasLightNS.cgColor
    private static let placeholderDarkCG = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0).cgColor
    private static let placeholderLightCG = NSColor(srgbRed: 0.916, green: 0.922, blue: 0.942, alpha: 1.0).cgColor
    private static let primaryTextDarkCG = NSColor.white.cgColor
    private static let primaryTextLightCG = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0).cgColor
    private static let secondaryTextDarkCG = NSColor(white: 0.60, alpha: 1.0).cgColor
    private static let secondaryTextLightCG = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1.0).cgColor

    private static let resFont = NSFont.systemFont(ofSize: 9.5, weight: .heavy)
    private static let resMonoFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    private static let runtimeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let unplayedFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    private static let ratingFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    private static let libCountFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private static let darkBadgeBg = NSColor.black.withAlphaComponent(0.68)
    private static let runtimeBadgeBg = NSColor.black.withAlphaComponent(0.55)
    private static let ratingBadgeBg = NSColor.black.withAlphaComponent(0.62)
    private static let runtimeBadgeText = NSColor.white.withAlphaComponent(0.88)
    private static let libCountText = NSColor.white.withAlphaComponent(0.90)
    private static var symbolCGCache: [String: CGImage] = [:]

    static func canvasNSColor(isLight: Bool) -> NSColor {
        isLight ? canvasLightNS : canvasDarkNS
    }

    static func canvasCGColor(isLight: Bool) -> CGColor {
        isLight ? canvasLightCG : canvasDarkCG
    }

    static func cardPlaceholderCGColor(isLight: Bool) -> CGColor {
        isLight ? placeholderLightCG : placeholderDarkCG
    }

    static func primaryTextCGColor(isLight: Bool) -> CGColor {
        isLight ? primaryTextLightCG : primaryTextDarkCG
    }

    static func formatRatingTenths(_ rating: Double) -> String {
        let tenths = max(0, Int((rating * 10.0).rounded()))
        return "\(tenths / 10).\(tenths % 10)"
    }

    static func secondaryTextCGColor(isLight: Bool) -> CGColor {
        isLight ? secondaryTextLightCG : secondaryTextDarkCG
    }

    static func srgbColorInfo(for color: Color) -> SRGBColorInfo {
        if let cached = srgbColorCache[color] {
            return cached
        }
        let converted = NSColor(color)
        let srgb = converted.usingColorSpace(.sRGB) ?? converted
        let key = String(
            format: "%02x%02x%02x%02x",
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255)),
            Int(round(srgb.alphaComponent * 255))
        )
        let info = SRGBColorInfo(
            ns: srgb,
            cg: srgb.cgColor,
            hoverBorderCG: srgb.withAlphaComponent(0.88).cgColor,
            key: key
        )
        if srgbColorCache.count > 64 {
            srgbColorCache.removeAll(keepingCapacity: true)
        }
        srgbColorCache[color] = info
        return info
    }

    static func srgbNSColor(_ color: Color) -> NSColor {
        srgbColorInfo(for: color).ns
    }

    static func colorKey(_ nsColor: NSColor) -> String {
        let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return String(
            format: "%02x%02x%02x%02x",
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255)),
            Int(round(srgb.alphaComponent * 255))
        )
    }

    static func isOpaqueCGImage(_ image: CGImage) -> Bool {
        image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast || image.alphaInfo == .none
    }

    private static func renderCGImage(
        widthPt: CGFloat,
        heightPt: CGFloat,
        scale: CGFloat = 2.0,
        isOpaque: Bool = false,
        draw: (CGContext, CGRect) -> Void
    ) -> CGImage? {
        let pixelW = max(1, Int(ceil(widthPt * scale)))
        let pixelH = max(1, Int(ceil(heightPt * scale)))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | (isOpaque ? CGImageAlphaInfo.noneSkipFirst.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue)

        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ArtworkImageCache.shared.activeDisplayColorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        let prevGC = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx, CGRect(x: 0, y: 0, width: widthPt, height: heightPt))
        NSGraphicsContext.current = prevGC
        return ctx.makeImage()
    }

    private static func renderGradientImage(
        topColor: NSColor,
        bottomColor: NSColor,
        startLocation: CGFloat = 0.0
    ) -> CGImage? {
        renderCGImage(widthPt: 2, heightPt: 128, scale: 1.0) { ctx, rect in
            let colors: [CGColor]
            let locations: [CGFloat]
            if startLocation > 0.001 {
                colors = [topColor.cgColor, topColor.cgColor, bottomColor.cgColor]
                locations = [0.0, startLocation, 1.0]
            } else {
                colors = [topColor.cgColor, bottomColor.cgColor]
                locations = [0.0, 1.0]
            }
            guard let gradient = CGGradient(colorsSpace: srgbSpace, colors: colors as CFArray, locations: locations) else { return }
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: 0, y: rect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    static let posterBottomGradient: CGImage? = renderGradientImage(
        topColor: NSColor.black.withAlphaComponent(0.0),
        bottomColor: NSColor.black.withAlphaComponent(0.62)
    )

    static let landscapeGradient: CGImage? = renderGradientImage(
        topColor: NSColor.black.withAlphaComponent(0.0),
        bottomColor: NSColor.black.withAlphaComponent(0.76)
    )

    static let libraryGradient: CGImage? = renderGradientImage(
        topColor: NSColor.black.withAlphaComponent(0.10),
        bottomColor: NSColor.black.withAlphaComponent(0.78)
    )

    private static func drawTintedSymbol(
        name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        in targetRect: CGRect,
        ctx: CGContext? = nil
    ) {
        let cacheKey = "\(name)|\(pointSize)|\(weight.rawValue)|\(colorKey(color))"
        if let cachedCG = symbolCGCache[cacheKey], let cgCtx = ctx ?? NSGraphicsContext.current?.cgContext {
            let symW = CGFloat(cachedCG.width) * 0.5
            let symH = CGFloat(cachedCG.height) * 0.5
            let scale = min(targetRect.width / symW, targetRect.height / symH)
            let drawWidth = symW * scale
            let drawHeight = symH * scale
            let drawRect = CGRect(
                x: targetRect.midX - drawWidth * 0.5,
                y: targetRect.midY - drawHeight * 0.5,
                width: drawWidth,
                height: drawHeight
            )
            cgCtx.draw(cachedCG, in: drawRect)
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return
        }
        let symbolSize = symbol.size
        guard symbolSize.width > 0, symbolSize.height > 0 else { return }
        let rendered = renderCGImage(widthPt: symbolSize.width, heightPt: symbolSize.height) { _, r in
            symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        if let rendered {
            symbolCGCache[cacheKey] = rendered
        }
        let scale = min(targetRect.width / symbolSize.width, targetRect.height / symbolSize.height)
        let drawWidth = symbolSize.width * scale
        let drawHeight = symbolSize.height * scale
        let drawRect = CGRect(
            x: targetRect.midX - drawWidth * 0.5,
            y: targetRect.midY - drawHeight * 0.5,
            width: drawWidth,
            height: drawHeight
        )
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    private static let filmPlaceholderDarkImage: CGImage? = renderCGImage(widthPt: 28, heightPt: 28) { _, rect in
        drawTintedSymbol(
            name: "film",
            pointSize: 22,
            weight: .light,
            color: NSColor.white.withAlphaComponent(0.25),
            in: rect
        )
    }

    private static let filmPlaceholderLightImage: CGImage? = renderCGImage(widthPt: 28, heightPt: 28) { _, rect in
        drawTintedSymbol(
            name: "film",
            pointSize: 22,
            weight: .light,
            color: NSColor.black.withAlphaComponent(0.18),
            in: rect
        )
    }

    static func filmPlaceholderImage(isLight: Bool) -> CGImage? {
        isLight ? filmPlaceholderLightImage : filmPlaceholderDarkImage
    }

    static let favoriteHeartImage: CGImage? = renderCGImage(widthPt: 14, heightPt: 14) { _, rect in
        drawTintedSymbol(
            name: "heart.fill",
            pointSize: 10.5,
            weight: .bold,
            color: NSColor.systemPink,
            in: rect
        )
    }

    static func infoIconImage(isLight: Bool) -> CGImage? {
        let key = "info|\(isLight ? 1 : 0)"
        if let cached = iconCache[key] { return cached }
        let color = isLight ? NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1.0) : NSColor(white: 0.60, alpha: 1.0)
        let image = renderCGImage(widthPt: 22, heightPt: 22) { _, rect in
            drawTintedSymbol(name: "info.circle", pointSize: 13.5, weight: .regular, color: color, in: rect.insetBy(dx: 3, dy: 3))
        }
        if let image { iconCache[key] = image }
        return image
    }

    static func playCircleImage(diameter: CGFloat, iconSize: CGFloat) -> CGImage? {
        let key = "play|\(Int(diameter))|\(Int(iconSize))"
        if let cached = iconCache[key] { return cached }
        let image = renderCGImage(widthPt: diameter, heightPt: diameter) { ctx, rect in
            let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            ctx.fillEllipse(in: insetRect)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokeEllipse(in: insetRect)
            let iconRect = CGRect(
                x: rect.midX - iconSize * 0.5 + 1.0,
                y: rect.midY - iconSize * 0.5,
                width: iconSize,
                height: iconSize
            )
            drawTintedSymbol(name: "play.fill", pointSize: iconSize, weight: .bold, color: .white, in: iconRect)
        }
        if let image { iconCache[key] = image }
        return image
    }

    static func playedCheckImage(accentColor: NSColor, colorKey overrideKey: String? = nil) -> CGImage? {
        let key = "played|\(overrideKey ?? colorKey(accentColor))"
        if let cached = iconCache[key] { return cached }
        let image = renderCGImage(widthPt: 16, heightPt: 16) { ctx, rect in
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
            drawTintedSymbol(name: "checkmark.circle.fill", pointSize: 12.5, weight: .bold, color: accentColor, in: rect)
        }
        if let image { iconCache[key] = image }
        return image
    }

    private static func cachedPillImage(
        cacheKey: String,
        text: String,
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        cornerRadius: CGFloat?,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        minWidth: CGFloat = 0,
        leadingSymbol: String? = nil,
        symbolPointSize: CGFloat = 0,
        symbolColor: NSColor? = nil
    ) -> CGImage? {
        if let cached = pillCache[cacheKey] {
            return cached
        }
        if pillCache.count > 384 {
            pillCache.removeAll(keepingCapacity: true)
        }

        let attr = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        let textSize = attr.size()
        let hasSymbol = leadingSymbol != nil
        let symbolBox: CGFloat = hasSymbol ? max(10, symbolPointSize + 1.5) : 0
        let symbolGap: CGFloat = hasSymbol ? 3.0 : 0
        let pillWidth = max(minWidth, ceil(textSize.width) + horizontalPadding * 2 + symbolBox + symbolGap)
        let pillHeight = ceil(max(textSize.height, symbolBox)) + verticalPadding * 2

        let image = renderCGImage(widthPt: pillWidth, heightPt: pillHeight) { ctx, rect in
            let resolvedRadius = cornerRadius ?? (rect.height * 0.5)
            let path = CGPath(roundedRect: rect, cornerWidth: resolvedRadius, cornerHeight: resolvedRadius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(backgroundColor.cgColor)
            ctx.fillPath()

            var textX = horizontalPadding
            if let leadingSymbol {
                let symRect = CGRect(
                    x: horizontalPadding,
                    y: (rect.height - symbolBox) * 0.5,
                    width: symbolBox,
                    height: symbolBox
                )
                drawTintedSymbol(
                    name: leadingSymbol,
                    pointSize: symbolPointSize,
                    weight: .bold,
                    color: symbolColor ?? textColor,
                    in: symRect,
                    ctx: ctx
                )
                textX += symbolBox + symbolGap
            } else if minWidth > 0 {
                textX = max(horizontalPadding, (rect.width - textSize.width) * 0.5)
            }

            let textPoint = CGPoint(x: textX, y: (rect.height - textSize.height) * 0.5)
            attr.draw(at: textPoint)
        }

        if let image {
            pillCache[cacheKey] = image
        }
        return image
    }

    static func resolutionBadgeImage(text: String, monospaced: Bool = false) -> CGImage? {
        let key = "res|\(monospaced ? 1 : 0)|\(text)"
        if let cached = pillCache[key] { return cached }
        let font = monospaced ? resMonoFont : resFont
        return cachedPillImage(
            cacheKey: key,
            text: text,
            font: font,
            textColor: .white,
            backgroundColor: darkBadgeBg,
            cornerRadius: 4,
            horizontalPadding: 5.5,
            verticalPadding: 2.0
        )
    }

    static func runtimeBadgeImage(text: String) -> CGImage? {
        let key = "rt|\(text)"
        if let cached = pillCache[key] { return cached }
        return cachedPillImage(
            cacheKey: key,
            text: text,
            font: runtimeFont,
            textColor: runtimeBadgeText,
            backgroundColor: runtimeBadgeBg,
            cornerRadius: nil,
            horizontalPadding: 6.0,
            verticalPadding: 2.0
        )
    }

    static func unplayedBadgeImage(
        count: Int,
        accentColor: NSColor,
        textColor: NSColor,
        accentKey: String? = nil,
        textKey: String? = nil
    ) -> CGImage? {
        let key = "unplayed|\(count)|\(accentKey ?? colorKey(accentColor))|\(textKey ?? colorKey(textColor))"
        if let cached = pillCache[key] { return cached }
        return cachedPillImage(
            cacheKey: key,
            text: "\(count)",
            font: unplayedFont,
            textColor: textColor,
            backgroundColor: accentColor,
            cornerRadius: nil,
            horizontalPadding: 6.0,
            verticalPadding: 2.0,
            minWidth: 20.0
        )
    }

    static func ratingPillImage(ratingText: String) -> CGImage? {
        let key = "rating|\(ratingText)"
        if let cached = pillCache[key] { return cached }
        return cachedPillImage(
            cacheKey: key,
            text: ratingText,
            font: ratingFont,
            textColor: .white,
            backgroundColor: ratingBadgeBg,
            cornerRadius: nil,
            horizontalPadding: 5.5,
            verticalPadding: 2.0,
            leadingSymbol: "star.fill",
            symbolPointSize: 8.5,
            symbolColor: .systemYellow
        )
    }

    static func libraryCountBadgeImage(countText: String) -> CGImage? {
        let key = "libcnt|\(countText)"
        if let cached = pillCache[key] { return cached }
        return cachedPillImage(
            cacheKey: key,
            text: countText,
            font: libCountFont,
            textColor: libCountText,
            backgroundColor: runtimeBadgeBg,
            cornerRadius: nil,
            horizontalPadding: 7.0,
            verticalPadding: 2.5
        )
    }
}

final class CardTextBitmapCache: @unchecked Sendable {
    static let shared = CardTextBitmapCache()
    private let cache = NSCache<NSString, CGImage>()
    private let colorSpaceLock = NSLock()
    private var lastColorSpaceICC: Data?
    private let renderQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.don.CardTextRender"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 4
        return q
    }()
    private let titleFont: CTFont = NSFont.systemFont(ofSize: 12.5, weight: .medium) as CTFont
    private let subtitleFont: CTFont = NSFont.systemFont(ofSize: 11, weight: .regular) as CTFont
    private let canvasDarkCG = NSColor(srgbRed: 0.043, green: 0.046, blue: 0.056, alpha: 1.0).cgColor
    private let canvasLightCG = NSColor(srgbRed: 0.945, green: 0.948, blue: 0.960, alpha: 1.0).cgColor
    private let primaryDarkCG = NSColor.white.cgColor
    private let primaryLightCG = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0).cgColor
    private let secondaryDarkCG = NSColor(white: 0.60, alpha: 1.0).cgColor
    private let secondaryLightCG = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1.0).cgColor

    private init() {
        cache.countLimit = 2800
        cache.totalCostLimit = 140 * 1024 * 1024
        lastColorSpaceICC = ArtworkImageCache.shared.activeDisplayColorSpace.copyICCData() as Data?
    }

    private func activeDisplayColorSpace() -> CGColorSpace {
        let cs = ArtworkImageCache.shared.activeDisplayColorSpace
        let icc = cs.copyICCData() as Data?
        colorSpaceLock.lock()
        let changed = (icc != lastColorSpaceICC)
        if changed {
            lastColorSpaceICC = icc
        }
        colorSpaceLock.unlock()
        if changed {
            cache.removeAllObjects()
        }
        return cs
    }

    func cached(title: String, subtitle: String, width: CGFloat, isLightMode: Bool) -> CGImage? {
        let bucketW = max(60, Int(round(width)))
        let key = "\(isLightMode ? 1 : 0)|\(bucketW)|\(title)\u{1F}\(subtitle)" as NSString
        return cache.object(forKey: key)
    }

    func cacheKey(title: String, subtitle: String, width: CGFloat, isLightMode: Bool) -> String {
        let bucketW = max(60, Int(round(width)))
        return "\(isLightMode ? 1 : 0)|\(bucketW)|\(title)\u{1F}\(subtitle)"
    }

    func renderAsync(
        title: String,
        subtitle: String,
        width: CGFloat,
        isLightMode: Bool,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        if let hit = cached(title: title, subtitle: subtitle, width: width, isLightMode: isLightMode) {
            Task { @MainActor in completion(hit) }
            return
        }
        renderQueue.addOperation { [weak self] in
            let cg = self?.renderOrCached(title: title, subtitle: subtitle, width: width, isLightMode: isLightMode)
            Task { @MainActor in
                completion(cg)
            }
        }
    }

    @discardableResult
    func renderOrCached(title: String, subtitle: String, width: CGFloat, isLightMode: Bool) -> CGImage? {
        let bucketW = max(60, Int(round(width)))
        let key = "\(isLightMode ? 1 : 0)|\(bucketW)|\(title)\u{1F}\(subtitle)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }

        let wPt = CGFloat(bucketW)
        let hPt: CGFloat = 35.0
        let scale: CGFloat = 2.0
        let pixelW = Int(ceil(wPt * scale))
        let pixelH = Int(ceil(hPt * scale))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: activeDisplayColorSpace(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(isLightMode ? canvasLightCG : canvasDarkCG)
        ctx.fill(CGRect(x: 0, y: 0, width: wPt, height: hPt))
        ctx.textMatrix = .identity

        let primaryColor = isLightMode ? primaryLightCG : primaryDarkCG
        let secondaryColor = isLightMode ? secondaryLightCG : secondaryDarkCG

        drawSingleTruncatedLine(
            text: title,
            font: titleFont,
            color: primaryColor,
            maxWidth: wPt,
            baselineY: hPt - 13.5,
            in: ctx
        )
        if !subtitle.isEmpty {
            drawSingleTruncatedLine(
                text: subtitle,
                font: subtitleFont,
                color: secondaryColor,
                maxWidth: wPt,
                baselineY: 4.5,
                in: ctx
            )
        }

        guard let cg = ctx.makeImage() else { return nil }
        cache.setObject(cg, forKey: key, cost: cg.bytesPerRow * cg.height)
        return cg
    }

    private func drawSingleTruncatedLine(
        text: String,
        font: CTFont,
        color: CGColor,
        maxWidth: CGFloat,
        baselineY: CGFloat,
        in ctx: CGContext
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let drawLine: CTLine
        if lineWidth > Double(maxWidth) {
            let ellipsisAttr = CFAttributedStringCreate(nil, "…" as CFString, attrs as CFDictionary)!
            let ellipsisLine = CTLineCreateWithAttributedString(ellipsisAttr)
            drawLine = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsisLine) ?? line
        } else {
            drawLine = line
        }
        ctx.textPosition = CGPoint(x: 0, y: baselineY)
        CTLineDraw(drawLine, ctx)
    }
}

private func configureBadgeLayer(_ layer: CALayer, with image: CGImage?) {
    layer.contentsScale = 2.0
    layer.contentsGravity = .resize
    layer.contents = image
}

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
            ?? NSColor.controlAccentColor.withAlphaComponent(0.88).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hovered {
            cardContainerLayer.borderWidth = 1.5
            cardContainerLayer.borderColor = borderCG
            hoverDimLayer.isHidden = false
            playLayer.isHidden = false
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
        if isHovered && !playLayer.isHidden && playLayer.frame.contains(pointInItemView) {
            actionDelegate?.cardDidPlay(currentItem)
        } else {
            actionDelegate?.cardDidSelect(currentItem)
        }
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

        if appearance.showResolutionBadge, let res = item.resolutionBadge {
            configureBadgeLayer(resBadgeLayer, with: NativeCardLayerCache.resolutionBadgeImage(text: res))
            resBadgeLayer.isHidden = false
        } else {
            resBadgeLayer.isHidden = true
        }

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
            configureBadgeLayer(favoriteIconLayer, with: NativeCardLayerCache.favoriteHeartImage)
            favoriteIconLayer.isHidden = false
        } else {
            favoriteIconLayer.isHidden = true
        }

        let progress = item.progressFraction
        if progress > 0 && progress < 0.99 {
            progressTrack.isHidden = false
            progressFill.backgroundColor = accentInfo.cg
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
            playedIconLayer.frame = CGRect(x: width - 7 - 16, y: 7, width: 16, height: 16)
        }

        let hasProgress = !progressTrack.isHidden
        let bottomInset: CGFloat = hasProgress ? 14 : 7
        if hasProgress {
            let trackW = width - 14
            progressTrack.frame = CGRect(x: 7, y: posterHeight - 10, width: trackW, height: 3)
            let fraction = CGFloat(max(0.0, min(1.0, currentItem?.progressFraction ?? 0.0)))
            progressFill.frame = CGRect(x: 0, y: 0, width: trackW * fraction, height: 3)
        }

        if !ratingPillLayer.isHidden, let cg = ratingPillLayer.contents as! CGImage? {
            let pillW = CGFloat(cg.width) * 0.5
            let pillH = CGFloat(cg.height) * 0.5
            ratingPillLayer.frame = CGRect(x: 7, y: posterHeight - bottomInset - pillH, width: pillW, height: pillH)
        }
        if !favoriteIconLayer.isHidden {
            favoriteIconLayer.frame = CGRect(x: width - 7 - 14, y: posterHeight - bottomInset - 14, width: 14, height: 14)
        }

        playLayer.frame = CGRect(x: (width - 40) * 0.5, y: (posterHeight - 40) * 0.5, width: 40, height: 40)
        textBlockLayer.frame = CGRect(x: 0, y: posterHeight + 6.0, width: width, height: 35.0)

        CATransaction.commit()
    }
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
            ?? NSColor.controlAccentColor.withAlphaComponent(0.88).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hovered {
            cardContainerLayer.borderWidth = 1.5
            cardContainerLayer.borderColor = borderCG
            hoverDimLayer.isHidden = false
            playLayer.isHidden = false
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
        let infoHitRect = CGRect(x: Self.itemSize.width - 30, y: Self.thumbHeight + 2, width: 30, height: 38)
        if infoHitRect.contains(pointInItemView) {
            actionDelegate?.cardDidSelect(currentItem)
        } else if cardContainerLayer.frame.contains(pointInItemView) {
            actionDelegate?.cardDidPlay(currentItem)
        } else {
            actionDelegate?.cardDidSelect(currentItem)
        }
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

        if let epCode = item.episodeCodeString {
            let cg = NativeCardLayerCache.resolutionBadgeImage(text: epCode, monospaced: true)
            configureBadgeLayer(topLeftBadgeLayer, with: cg)
            if let cg {
                topLeftBadgeLayer.frame = CGRect(x: 7, y: 7, width: CGFloat(cg.width) * 0.5, height: CGFloat(cg.height) * 0.5)
            }
            topLeftBadgeLayer.isHidden = false
        } else if let res = item.resolutionBadge {
            let cg = NativeCardLayerCache.resolutionBadgeImage(text: res)
            configureBadgeLayer(topLeftBadgeLayer, with: cg)
            if let cg {
                topLeftBadgeLayer.frame = CGRect(x: 7, y: 7, width: CGFloat(cg.width) * 0.5, height: CGFloat(cg.height) * 0.5)
            }
            topLeftBadgeLayer.isHidden = false
        } else {
            topLeftBadgeLayer.isHidden = true
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
            progressFill.backgroundColor = accentInfo.cg
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
            guard let self, !Task.isCancelled, self.currentItem?.id == targetId, let cgImage else { return }
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
            guard let self, !Task.isCancelled, self.currentLibrary?.id == targetId, let cgImage else { return }
            self.artworkLayer.contents = cgImage
            self.artworkLayer.isOpaque = NativeCardLayerCache.isOpaqueCGImage(cgImage)
            self.placeholderIconLayer.isHidden = true
        }
    }
}

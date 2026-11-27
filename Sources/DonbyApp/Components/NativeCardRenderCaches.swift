import SwiftUI
import AppKit
import QuartzCore
import CoreText
import DonbyCore
import DonbyNetwork

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
            if symbolCGCache.count >= 256 {
                symbolCGCache.removeAll(keepingCapacity: true)
            }
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

    private static func storeIcon(_ image: CGImage, forKey key: String) {
        if iconCache.count >= 256 {
            iconCache.removeAll(keepingCapacity: true)
        }
        iconCache[key] = image
    }

    static func favoriteHeartImage(accentColor: NSColor, colorKey overrideKey: String? = nil) -> CGImage? {
        let key = "fav_heart|\(overrideKey ?? colorKey(accentColor))"
        if let cached = iconCache[key] { return cached }
        let image = renderCGImage(widthPt: 14, heightPt: 14) { _, rect in
            drawTintedSymbol(
                name: "heart.fill",
                pointSize: 10.5,
                weight: .bold,
                color: accentColor,
                in: rect
            )
        }
        if let image { storeIcon(image, forKey: key) }
        return image
    }

    static func infoIconImage(isLight: Bool) -> CGImage? {
        let key = "info|\(isLight ? 1 : 0)"
        if let cached = iconCache[key] { return cached }
        let color = isLight ? NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1.0) : NSColor(white: 0.60, alpha: 1.0)
        let image = renderCGImage(widthPt: 22, heightPt: 22) { _, rect in
            drawTintedSymbol(name: "info.circle", pointSize: 13.5, weight: .regular, color: color, in: rect.insetBy(dx: 3, dy: 3))
        }
        if let image { storeIcon(image, forKey: key) }
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
        if let image { storeIcon(image, forKey: key) }
        return image
    }

    static func playedCheckImage(accentColor: NSColor, colorKey overrideKey: String? = nil) -> CGImage? {
        let key = "played_glass_v2"
        if let cached = iconCache[key] { return cached }
        let image = renderCGImage(widthPt: 18, heightPt: 18) { ctx, rect in
            let circleRect = rect.insetBy(dx: 0.75, dy: 0.75)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.64).cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokeEllipse(in: circleRect)
            drawTintedSymbol(
                name: "checkmark",
                pointSize: 9.0,
                weight: .bold,
                color: NSColor.white.withAlphaComponent(0.95),
                in: rect.insetBy(dx: 4.2, dy: 4.2),
                ctx: ctx
            )
        }
        if let image { storeIcon(image, forKey: key) }
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
        symbolColor: NSColor? = nil,
        borderColor: NSColor? = nil,
        borderWidth: CGFloat = 0.65
    ) -> CGImage? {
        if let cached = pillCache[cacheKey] {
            return cached
        }
        if pillCache.count >= 512 {
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

            if let borderColor {
                let strokeRect = rect.insetBy(dx: borderWidth * 0.5, dy: borderWidth * 0.5)
                let strokeRadius = cornerRadius ?? (strokeRect.height * 0.5)
                let strokePath = CGPath(roundedRect: strokeRect, cornerWidth: strokeRadius, cornerHeight: strokeRadius, transform: nil)
                ctx.addPath(strokePath)
                ctx.setStrokeColor(borderColor.cgColor)
                ctx.setLineWidth(borderWidth)
                ctx.strokePath()
            }

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
        let key = "rating_v2|\(ratingText)"
        if let cached = pillCache[key] { return cached }
        return cachedPillImage(
            cacheKey: key,
            text: ratingText,
            font: ratingFont,
            textColor: .white,
            backgroundColor: ratingBadgeBg,
            cornerRadius: nil,
            horizontalPadding: 6.5,
            verticalPadding: 2.0
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

    static func downloadedBadgeImage(text: String, isCompleted: Bool, accentColor: NSColor, accentKey: String? = nil) -> CGImage? {
        let key = "dl_glass_v3|\(text)|\(isCompleted ? "done" : (accentKey ?? colorKey(accentColor)))"
        if let cached = pillCache[key] { return cached }
        let bg = NSColor.black.withAlphaComponent(0.64)
        let border = isCompleted
            ? NSColor.white.withAlphaComponent(0.22)
            : accentColor.withAlphaComponent(0.45)
        let symColor = isCompleted
            ? NSColor.white.withAlphaComponent(0.95)
            : accentColor
        return cachedPillImage(
            cacheKey: key,
            text: text,
            font: runtimeFont,
            textColor: NSColor.white.withAlphaComponent(0.95),
            backgroundColor: bg,
            cornerRadius: nil,
            horizontalPadding: 6.5,
            verticalPadding: 2.0,
            leadingSymbol: isCompleted ? "checkmark" : "arrow.down",
            symbolPointSize: 8.5,
            symbolColor: symColor,
            borderColor: border
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

func configureBadgeLayer(_ layer: CALayer, with image: CGImage?) {
    layer.contentsScale = 2.0
    layer.contentsGravity = .resize
    layer.contents = image
}

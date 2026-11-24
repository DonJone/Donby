import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

/// Static weighted top-edge color-extension backdrop rendered behind DetailView's transparent ScrollView.
/// Matches the exact color space, horizontal `.scaledToFill()` visible slice, and saturation/contrast of the hero poster.
public struct HeroTopEdgeBackdropView: View {
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public var viewportAspect: CGFloat = 16.0 / 9.0

    @State private var synthesizedStrip: CGImage? = nil

    public init(server: EmbyServerConfig?, item: EmbyItem, viewportAspect: CGFloat = 16.0 / 9.0) {
        self.server = server
        self.item = item
        self.viewportAspect = viewportAspect
    }

    private static let stripCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 48
        return c
    }()

    private var quantizedAspectBucket: Int {
        Int((max(0.5, min(4.0, viewportAspect)) * 20.0).rounded())
    }

    private var stripCacheKey: String {
        "hero_top_edge_v3|\(server?.activeBaseURL ?? "")|\(item.id)|\(quantizedAspectBucket)"
    }

    public var body: some View {
        Group {
            if let strip = synthesizedStrip ?? Self.stripCache.object(forKey: stripCacheKey as NSString) {
                Image(decorative: strip, scale: 1.0)
                    .resizable()
                    .interpolation(.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .saturation(1.10)
                    .contrast(1.04)
            } else {
                Color.clear
            }
        }
        .task(id: stripCacheKey) {
            let key = stripCacheKey
            let aspect = viewportAspect
            if let cached = Self.stripCache.object(forKey: key as NSString) {
                self.synthesizedStrip = cached
                return
            }
            // Prefer the exact UHD backdrop already in memory for 100% identical gamut & pixels
            let backdrop: CGImage?
            if let memUHD = MediaArtworkView.cachedCGImageInMemory(item: item, kind: .backdrop, maxWidth: 3840) {
                backdrop = memUHD
            } else {
                backdrop = await MediaArtworkView.loadOrFetchCGImage(
                    server: server,
                    item: item,
                    kind: .backdrop,
                    maxWidth: 3840,
                    priority: .normal
                )
            }
            guard let backdrop, !Task.isCancelled else { return }

            let strip: CGImage? = await Task.detached(priority: .userInitiated) {
                Self.buildWeightedTopStrip(from: backdrop, viewportAspect: aspect)
            }.value
            guard !Task.isCancelled, let strip else { return }
            Self.stripCache.setObject(strip, forKey: key as NSString)
            await MainActor.run {
                self.synthesizedStrip = strip
            }
        }
    }

    nonisolated private static func buildWeightedTopStrip(from cgImage: CGImage, viewportAspect: CGFloat) -> CGImage? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW >= 8, srcH >= 8 else { return nil }

        // Match exact horizontal crop that `.scaledToFill()` with `.top` alignment shows in the hero container
        let imgAspect = CGFloat(srcW) / CGFloat(srcH)
        let cropX: Int
        let visibleW: Int
        if viewportAspect > 0.2 && viewportAspect < imgAspect {
            let frac = viewportAspect / imgAspect
            visibleW = max(8, Int((CGFloat(srcW) * frac).rounded()))
            cropX = max(0, (srcW - visibleW) / 2)
        } else {
            cropX = 0
            visibleW = srcW
        }

        let sampleRows = min(4, srcH)
        guard let topCrop = cgImage.cropping(to: CGRect(x: cropX, y: 0, width: visibleW, height: sampleRows)) else {
            return nil
        }

        let sampleW = min(1024, visibleW)
        // Preserve the source image's exact display color space (Display P3 / sRGB) so colors never wash out
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        var band = [UInt8](repeating: 0, count: sampleW * sampleRows * 4)
        guard let ctx = CGContext(
            data: &band,
            width: sampleW,
            height: sampleRows,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(topCrop, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleRows))

        let outPixels = HeroTopEdgeSynthesizer.synthesizeWeightedStrip(
            topBandRGBA: band,
            width: sampleW,
            rows: sampleRows,
            outputHeight: 1
        )
        guard outPixels.count == sampleW * 4 else { return nil }
        let providerData = Data(outPixels) as CFData
        guard let provider = CGDataProvider(data: providerData) else { return nil }
        return CGImage(
            width: sampleW,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: sampleW * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

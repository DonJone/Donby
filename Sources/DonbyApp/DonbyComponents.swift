import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import DonbyCore
import DonbyNetwork

// MARK: - Native Artwork & Local Poster Cache
public final class ArtworkImageCache: @unchecked Sendable {
    public static let shared = ArtworkImageCache()
    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskQueue = DispatchQueue(label: "com.don.ArtworkDiskCache", qos: .utility)
    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL

    private init() {
        memoryCache.countLimit = 800
        memoryCache.totalCostLimit = 200 * 1024 * 1024 // 200 MB

        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.don.Donby/ArtworkCache", isDirectory: true)
        self.cacheDirectoryURL = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }

    private func diskFileName(for key: String) -> String {
        let hash = key.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
        let cleanPrefix = String(key.filter { $0.isLetter || $0.isNumber }.prefix(24))
        return "\(cleanPrefix)_\(abs(hash)).img"
    }

    /// Decodes and downsamples compressed image data in the background using hardware-accelerated ImageIO.
    public func decodeThumbnail(from data: Data, maxPixelSize: Int = 500) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any]
        if maxPixelSize >= 2400 {
            options = [
                kCGImageSourceShouldCacheImmediately: true
            ]
        } else {
            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
        }
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }

    /// Instantaneous O(1) in-memory lookup. Completely safe to call on Main Thread in body or computed properties.
    public func imageFromMemory(for key: String) -> NSImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// Asynchronous disk lookup that never blocks the Main Thread or scroll animations.
    public func imageFromDiskAsync(for key: String, maxPixelSize: Int = 500) async -> NSImage? {
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(diskFileName(for: key))
        return await withCheckedContinuation { continuation in
            diskQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                guard let data = try? Data(contentsOf: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                if let thumb = self.decodeThumbnail(from: data, maxPixelSize: maxPixelSize) {
                    self.memoryCache.setObject(thumb, forKey: key as NSString, cost: data.count / 4)
                    continuation.resume(returning: thumb)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func image(for key: String) -> NSImage? {
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        // Restrict synchronous disk I/O to background threads so main-thread UI never blocks
        if !Thread.isMainThread {
            let fileURL = cacheDirectoryURL.appendingPathComponent(diskFileName(for: key))
            if let data = try? Data(contentsOf: fileURL),
               let img = NSImage(data: data) {
                memoryCache.setObject(img, forKey: key as NSString, cost: data.count)
                return img
            }
        }
        return nil
    }

    public func store(_ image: NSImage, for key: String, aliases: [String] = []) {
        memoryCache.setObject(image, forKey: key as NSString)
        for alias in aliases where !alias.isEmpty {
            memoryCache.setObject(image, forKey: alias as NSString)
        }
        diskQueue.async { [cacheDirectoryURL] in
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
                return
            }
            let fileURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: key))
            try? data.write(to: fileURL, options: .atomic)
            for alias in aliases where !alias.isEmpty {
                let aliasURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: alias))
                try? data.write(to: aliasURL, options: .atomic)
            }
        }
    }

    @discardableResult
    public func storeRawData(_ data: Data, for key: String, maxPixelSize: Int = 500, aliases: [String] = []) -> NSImage? {
        let decoded = decodeThumbnail(from: data, maxPixelSize: maxPixelSize) ?? NSImage(data: data)
        if let decoded {
            memoryCache.setObject(decoded, forKey: key as NSString, cost: data.count / 4)
            for alias in aliases where !alias.isEmpty {
                memoryCache.setObject(decoded, forKey: alias as NSString, cost: data.count / 4)
            }
        }
        diskQueue.async { [cacheDirectoryURL] in
            let fileURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: key))
            try? data.write(to: fileURL, options: .atomic)
            for alias in aliases where !alias.isEmpty {
                let aliasURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: alias))
                if !FileManager.default.fileExists(atPath: aliasURL.path) {
                    try? FileManager.default.linkItem(at: fileURL, to: aliasURL)
                }
            }
        }
        return decoded
    }

    public func systemAsset(_ name: String) -> NSImage? {
        let key = "asset_\(name)"
        if let cached = image(for: key) { return cached }
        if let img = NSImage(named: name) {
            store(img, for: key)
            return img
        }
        return nil
    }

    public func localPoster(_ key: String) -> NSImage? {
        return nil
    }

    public func aliasKeys(_ aliases: [String], to canonicalKey: String) {
        if let img = image(for: canonicalKey) {
            for alias in aliases where !alias.isEmpty {
                memoryCache.setObject(img, forKey: alias as NSString)
            }
            diskQueue.async { [cacheDirectoryURL] in
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
                    return
                }
                for alias in aliases where !alias.isEmpty {
                    let aliasURL = cacheDirectoryURL.appendingPathComponent(self.diskFileName(for: alias))
                    try? data.write(to: aliasURL, options: .atomic)
                }
            }
        }
    }
}

// MARK: - Concurrency-Controlled Artwork Downloader
public final class ArtworkDownloadManager: @unchecked Sendable {
    public static let shared = ArtworkDownloadManager()
    private let semaphore = DispatchSemaphore(value: 6)
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    public func download(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
        defer { semaphore.signal() }
        try Task.checkCancellation()
        return try await session.data(for: request)
    }
}

// MARK: - Independent Modern Brand Marks & Server Type Icons
public struct ServerIconView: View {
    public let server: EmbyServerConfig
    public var size: CGFloat = 30

    public init(server: EmbyServerConfig, size: CGFloat = 30) {
        self.server = server
        self.size = size
    }

    public var body: some View {
        if server.usesUHDLogo {
            UHDNowVectorLogo(size: size)
        } else {
            switch server.type {
            case .emby:
                EmbyVectorMark(size: size)
            case .jellyfin:
                JellyfinVectorMark(size: size)
            case .plex:
                PlexVectorMark(size: size)
            case .feiniu:
                FeiniuVectorMark(size: size)
            case .webdav, .smb:
                StorageVectorMark(size: size, isSmb: server.type == .smb)
            }
        }
    }
}

/// Pure code Emby green emerald mark
public struct EmbyVectorMark: View {
    public var size: CGFloat = 30
    public init(size: CGFloat = 30) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.24, blue: 0.15), Color(red: 0.04, green: 0.13, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(Color(red: 0.20, green: 0.84, blue: 0.40).opacity(0.35), lineWidth: 0.8)
                )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                var diamond = Path()
                diamond.move(to: CGPoint(x: w * 0.50, y: h * 0.16))
                diamond.addLine(to: CGPoint(x: w * 0.84, y: h * 0.50))
                diamond.addLine(to: CGPoint(x: w * 0.50, y: h * 0.84))
                diamond.addLine(to: CGPoint(x: w * 0.16, y: h * 0.50))
                diamond.closeSubpath()
                context.fill(
                    diamond,
                    with: .linearGradient(
                        Gradient(colors: [Color(red: 0.32, green: 0.90, blue: 0.50), Color(red: 0.11, green: 0.68, blue: 0.33)]),
                        startPoint: CGPoint(x: w * 0.2, y: h * 0.2),
                        endPoint: CGPoint(x: w * 0.8, y: h * 0.8)
                    )
                )
                var play = Path()
                play.move(to: CGPoint(x: w * 0.41, y: h * 0.35))
                play.addLine(to: CGPoint(x: w * 0.66, y: h * 0.50))
                play.addLine(to: CGPoint(x: w * 0.41, y: h * 0.65))
                play.closeSubpath()
                context.fill(play, with: .color(.white))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Pure code Jellyfin purple fluid mark
public struct JellyfinVectorMark: View {
    public var size: CGFloat = 30
    public init(size: CGFloat = 30) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.08, blue: 0.26), Color(red: 0.09, green: 0.04, blue: 0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.8)
                )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                var outer = Path()
                outer.move(to: CGPoint(x: w * 0.50, y: h * 0.20))
                outer.addQuadCurve(to: CGPoint(x: w * 0.80, y: h * 0.74), control: CGPoint(x: w * 0.84, y: h * 0.54))
                outer.addQuadCurve(to: CGPoint(x: w * 0.20, y: h * 0.74), control: CGPoint(x: w * 0.50, y: h * 0.84))
                outer.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.20), control: CGPoint(x: w * 0.16, y: h * 0.54))
                context.stroke(
                    outer,
                    with: .linearGradient(
                        Gradient(colors: [Color(red: 0.72, green: 0.42, blue: 1.0), Color(red: 0.24, green: 0.68, blue: 0.98)]),
                        startPoint: CGPoint(x: w * 0.25, y: h * 0.2),
                        endPoint: CGPoint(x: w * 0.75, y: h * 0.8)
                    ),
                    style: StrokeStyle(lineWidth: w * 0.10, lineCap: .round, lineJoin: .round)
                )
                var inner = Path()
                inner.move(to: CGPoint(x: w * 0.50, y: h * 0.41))
                inner.addLine(to: CGPoint(x: w * 0.63, y: h * 0.64))
                inner.addLine(to: CGPoint(x: w * 0.37, y: h * 0.64))
                inner.closeSubpath()
                context.fill(
                    inner,
                    with: .linearGradient(
                        Gradient(colors: [Color(red: 0.66, green: 0.44, blue: 1.0), Color(red: 0.28, green: 0.72, blue: 1.0)]),
                        startPoint: CGPoint(x: w * 0.5, y: h * 0.4),
                        endPoint: CGPoint(x: w * 0.5, y: h * 0.65)
                    )
                )
            }
        }
        .frame(width: size, height: size)
    }
}

/// Pure code Plex amber chevron mark
public struct PlexVectorMark: View {
    public var size: CGFloat = 30
    public init(size: CGFloat = 30) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.22, green: 0.18, blue: 0.06), Color(red: 0.12, green: 0.09, blue: 0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
                )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                var chevron = Path()
                chevron.move(to: CGPoint(x: w * 0.34, y: h * 0.22))
                chevron.addLine(to: CGPoint(x: w * 0.54, y: h * 0.22))
                chevron.addLine(to: CGPoint(x: w * 0.72, y: h * 0.50))
                chevron.addLine(to: CGPoint(x: w * 0.54, y: h * 0.78))
                chevron.addLine(to: CGPoint(x: w * 0.34, y: h * 0.78))
                chevron.addLine(to: CGPoint(x: w * 0.52, y: h * 0.50))
                chevron.closeSubpath()
                context.fill(
                    chevron,
                    with: .linearGradient(
                        Gradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.18), Color(red: 0.92, green: 0.52, blue: 0.06)]),
                        startPoint: CGPoint(x: w * 0.5, y: h * 0.2),
                        endPoint: CGPoint(x: w * 0.5, y: h * 0.8)
                    )
                )
            }
        }
        .frame(width: size, height: size)
    }
}

/// Pure code Feiniu (fnOS) cyan tech mark
public struct FeiniuVectorMark: View {
    public var size: CGFloat = 30
    public init(size: CGFloat = 30) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.18, blue: 0.25), Color(red: 0.03, green: 0.10, blue: 0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 0.8)
                )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                var ring = Path()
                ring.addArc(center: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.27, startAngle: .degrees(35), endAngle: .degrees(325), clockwise: false)
                context.stroke(
                    ring,
                    with: .linearGradient(
                        Gradient(colors: [Color(red: 0.34, green: 0.88, blue: 1.0), Color(red: 0.12, green: 0.54, blue: 0.94)]),
                        startPoint: CGPoint(x: w * 0.2, y: h * 0.2),
                        endPoint: CGPoint(x: w * 0.8, y: h * 0.8)
                    ),
                    style: StrokeStyle(lineWidth: w * 0.11, lineCap: .round)
                )
                var play = Path()
                play.move(to: CGPoint(x: w * 0.44, y: h * 0.37))
                play.addLine(to: CGPoint(x: w * 0.67, y: h * 0.50))
                play.addLine(to: CGPoint(x: w * 0.44, y: h * 0.63))
                play.closeSubpath()
                context.fill(play, with: .color(.white))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Pure code Storage (WebDAV / SMB) mark
public struct StorageVectorMark: View {
    public var size: CGFloat = 30
    public var isSmb: Bool = false
    public init(size: CGFloat = 30, isSmb: Bool = false) { self.size = size; self.isSmb = isSmb }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.15, green: 0.16, blue: 0.20), Color(red: 0.09, green: 0.10, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let r1 = CGRect(x: w * 0.22, y: h * 0.25, width: w * 0.56, height: h * 0.20)
                let r2 = CGRect(x: w * 0.22, y: h * 0.55, width: w * 0.56, height: h * 0.20)
                context.fill(Path(roundedRect: r1, cornerRadius: w * 0.06), with: .color(Color(red: 0.70, green: 0.80, blue: 0.96)))
                context.fill(Path(roundedRect: r2, cornerRadius: w * 0.06), with: .color(Color(red: 0.50, green: 0.64, blue: 0.88)))
                let dot1 = CGRect(x: w * 0.64, y: h * 0.31, width: w * 0.08, height: h * 0.08)
                let dot2 = CGRect(x: w * 0.64, y: h * 0.61, width: w * 0.08, height: h * 0.08)
                context.fill(Path(ellipseIn: dot1), with: .color(Color(red: 0.12, green: 0.88, blue: 0.45)))
                context.fill(Path(ellipseIn: dot2), with: .color(isSmb ? Color.cyan : Color(red: 0.12, green: 0.88, blue: 0.45)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Custom Donby Brand App Emblem (`D + Play Prism`) matching AppIcon.icns
/// Space Black Liquid Glass chassis + concentric optical ring + Liquid Glass `D` + solid white `▶`
public struct DonbyAppLogoView: View {
    public var size: CGFloat = 58
    public init(size: CGFloat = 58) { self.size = size }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.980, green: 0.983, blue: 0.990),
                            Color(red: 0.925, green: 0.932, blue: 0.945)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.90),
                                    Color(red: 0.80, green: 0.82, blue: 0.86).opacity(0.25),
                                    Color(red: 0.72, green: 0.75, blue: 0.80).opacity(0.50)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1, size * 0.018)
                        )
                )
                .shadow(color: Color.black.opacity(0.18), radius: size * 0.10, y: size * 0.04)

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let scale = w / 824.0
                let xOffset = 16.0 * scale
                let rOut = 48.0 * scale
                let rIn = 14.0 * scale

                let totalH = h * 0.62
                let strokeW = w * 0.118
                let dRadius = totalH * 0.5 - strokeW * 0.5
                let dLeft = (w * 0.50 + xOffset) - w * 0.230
                let dArcCenterX = (w * 0.50 + xOffset) - w * 0.040

                let openAngle = 0.28 * Double.pi

                let rOuterArc = dRadius + strokeW * 0.5
                let rInnerArc = dRadius - strokeW * 0.5
                let capRadius = strokeW * 0.5

                let topTermX = dArcCenterX + dRadius * cos(openAngle)
                let topTermY = h * 0.50 - dRadius * sin(openAngle)
                let btmTermX = dArcCenterX + dRadius * cos(openAngle)
                let btmTermY = h * 0.50 + dRadius * sin(openAngle)

                var path = Path()

                let topOuterX = dArcCenterX + rOuterArc * cos(openAngle)
                let topOuterY = h * 0.50 - rOuterArc * sin(openAngle)

                // Outer boundary
                path.move(to: CGPoint(x: topOuterX, y: topOuterY))
                path.addArc(
                    center: CGPoint(x: dArcCenterX, y: h * 0.50),
                    radius: rOuterArc,
                    startAngle: .radians(-openAngle),
                    endAngle: .radians(-0.5 * .pi),
                    clockwise: true
                )

                let outerLeftX = dLeft - strokeW * 0.5
                let outerTopY = h * 0.50 - dRadius - strokeW * 0.5
                let outerBtmY = h * 0.50 + dRadius + strokeW * 0.5

                path.addArc(
                    tangent1End: CGPoint(x: outerLeftX, y: outerTopY),
                    tangent2End: CGPoint(x: outerLeftX, y: h * 0.50),
                    radius: rOut
                )
                path.addArc(
                    tangent1End: CGPoint(x: outerLeftX, y: outerBtmY),
                    tangent2End: CGPoint(x: dArcCenterX, y: outerBtmY),
                    radius: rOut
                )
                path.addLine(to: CGPoint(x: dArcCenterX, y: outerBtmY))
                path.addArc(
                    center: CGPoint(x: dArcCenterX, y: h * 0.50),
                    radius: rOuterArc,
                    startAngle: .radians(0.5 * .pi),
                    endAngle: .radians(openAngle),
                    clockwise: true
                )

                // Bottom end cap
                path.addArc(
                    center: CGPoint(x: btmTermX, y: btmTermY),
                    radius: capRadius,
                    startAngle: .radians(openAngle),
                    endAngle: .radians(openAngle + .pi),
                    clockwise: true
                )

                // Inner boundary
                path.addArc(
                    center: CGPoint(x: dArcCenterX, y: h * 0.50),
                    radius: rInnerArc,
                    startAngle: .radians(openAngle),
                    endAngle: .radians(0.5 * .pi),
                    clockwise: false
                )

                let innerLeftX = dLeft + strokeW * 0.5
                let innerBtmY = h * 0.50 + dRadius - strokeW * 0.5
                let innerTopY = h * 0.50 - dRadius + strokeW * 0.5

                path.addArc(
                    tangent1End: CGPoint(x: innerLeftX, y: innerBtmY),
                    tangent2End: CGPoint(x: innerLeftX, y: h * 0.50),
                    radius: rIn
                )
                path.addArc(
                    tangent1End: CGPoint(x: innerLeftX, y: innerTopY),
                    tangent2End: CGPoint(x: dArcCenterX, y: innerTopY),
                    radius: rIn
                )
                path.addLine(to: CGPoint(x: dArcCenterX, y: innerTopY))
                path.addArc(
                    center: CGPoint(x: dArcCenterX, y: h * 0.50),
                    radius: rInnerArc,
                    startAngle: .radians(-0.5 * .pi),
                    endAngle: .radians(-openAngle),
                    clockwise: false
                )

                // Top end cap
                path.addArc(
                    center: CGPoint(x: topTermX, y: topTermY),
                    radius: capRadius,
                    startAngle: .radians(-openAngle + .pi),
                    endAngle: .radians(-openAngle),
                    clockwise: true
                )

                path.closeSubpath()

                let triLeftX = dLeft + strokeW * 1.35
                let triRightX = (w * 0.50 + xOffset) + w * 0.290
                let triHalfH = totalH * 0.35
                let triCorner = w * 0.042

                let p1 = CGPoint(x: triLeftX, y: h * 0.50 - triHalfH)
                let p2 = CGPoint(x: triRightX, y: h * 0.50)
                let p3 = CGPoint(x: triLeftX, y: h * 0.50 + triHalfH)

                var playPath = Path()
                let mid12 = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
                playPath.move(to: mid12)
                playPath.addArc(tangent1End: p2, tangent2End: p3, radius: triCorner)
                playPath.addArc(tangent1End: p3, tangent2End: p1, radius: triCorner)
                playPath.addArc(tangent1End: p1, tangent2End: p2, radius: triCorner)
                playPath.closeSubpath()

                var emblem = Path()
                emblem.addPath(path)
                emblem.addPath(playPath)

                // Fill solid deep obsidian velvet
                context.fill(
                    emblem,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.075, green: 0.080, blue: 0.090),
                            Color(red: 0.015, green: 0.016, blue: 0.018),
                            Color.black
                        ]),
                        startPoint: CGPoint(x: w * 0.50, y: h * 0.18),
                        endPoint: CGPoint(x: w * 0.50, y: h * 0.82)
                    )
                )

                // Top chamfer bevel specular highlight
                context.stroke(
                    emblem,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.85),
                            Color(red: 0.50, green: 0.52, blue: 0.58).opacity(0.30),
                            Color.clear
                        ]),
                        startPoint: CGPoint(x: w * 0.25, y: h * 0.18),
                        endPoint: CGPoint(x: w * 0.75, y: h * 0.82)
                    ),
                    lineWidth: max(0.8, w * 0.012)
                )
            }
        }
        .frame(width: size, height: size)
    }
}

/// Official UHDNow brand logo directly referenced from https://www.uhdnow.com/
/// Automatically adapts to Light Mode (tactile obsidian U) and Dark Mode (luminous platinum U)
public struct UHDNowVectorLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    public var size: CGFloat = 30
    public var isLight: Bool? = nil

    public init(size: CGFloat = 30, isLight: Bool? = nil) {
        self.size = size
        self.isLight = isLight
    }

    private var effectiveIsLight: Bool {
        if let isLight = isLight { return isLight }
        if let mode = AppState.sharedInstance?.appearanceMode {
            switch mode {
            case .light: return true
            case .dark: return false
            case .auto: return colorScheme == .light
            }
        }
        return colorScheme == .light
    }

    private static var cachedDayImage: NSImage? = {
        let possibleUrls = [
            Bundle.main.url(forResource: "uhdnow_day", withExtension: "png"),
            Bundle.main.url(forResource: "uhdnow_official_day", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("uhdnow_day.png")
        ]
        for url in possibleUrls {
            if let url = url, let img = NSImage(contentsOf: url) {
                return img
            }
        }
        let fallbackPaths = [
            "Resources/uhdnow_day.png",
            "../Resources/uhdnow_day.png",
            "Donby.app/Contents/Resources/uhdnow_day.png"
        ]
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }()

    private static var cachedNightImage: NSImage? = {
        let possibleUrls = [
            Bundle.main.url(forResource: "uhdnow_night", withExtension: "png"),
            Bundle.main.url(forResource: "uhdnow_official_night", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("uhdnow_night.png")
        ]
        for url in possibleUrls {
            if let url = url, let img = NSImage(contentsOf: url) {
                return img
            }
        }
        let fallbackPaths = [
            "Resources/uhdnow_night.png",
            "../Resources/uhdnow_night.png",
            "Donby.app/Contents/Resources/uhdnow_night.png"
        ]
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }()

    public var body: some View {
        let isLight = effectiveIsLight
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    isLight
                    ? LinearGradient(
                        colors: [Color.white, Color(red: 0.93, green: 0.94, blue: 0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [Color(red: 0.12, green: 0.14, blue: 0.19), Color(red: 0.07, green: 0.08, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(
                            isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.12),
                            lineWidth: max(0.8, size * 0.02)
                        )
                )

            if let img = (isLight ? Self.cachedDayImage : Self.cachedNightImage) ?? Self.cachedNightImage ?? Self.cachedDayImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.10)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Modern Polished Toolbar Action Buttons (Fixes Broken Native Menu Bezel & Chevrons)
/// Custom vector icon for "切换线路" (dual-route directional node switch)
public struct RouteSwitchVectorIcon: View {
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 15, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.35, w * 0.105)
            let nodeR = max(1.6, w * 0.115)

            let topY = h * 0.31
            let node1 = CGRect(x: w * 0.12 - nodeR, y: topY - nodeR, width: nodeR * 2, height: nodeR * 2)
            context.fill(Path(ellipseIn: node1), with: .color(color))

            var topLine = Path()
            topLine.move(to: CGPoint(x: w * 0.24, y: topY))
            topLine.addLine(to: CGPoint(x: w * 0.84, y: topY))
            topLine.move(to: CGPoint(x: w * 0.67, y: topY - h * 0.15))
            topLine.addLine(to: CGPoint(x: w * 0.86, y: topY))
            topLine.addLine(to: CGPoint(x: w * 0.67, y: topY + h * 0.15))
            context.stroke(topLine, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            let botY = h * 0.69
            let node2 = CGRect(x: w * 0.88 - nodeR, y: botY - nodeR, width: nodeR * 2, height: nodeR * 2)
            context.fill(Path(ellipseIn: node2), with: .color(color))

            var botLine = Path()
            botLine.move(to: CGPoint(x: w * 0.76, y: botY))
            botLine.addLine(to: CGPoint(x: w * 0.16, y: botY))
            botLine.move(to: CGPoint(x: w * 0.33, y: botY - h * 0.15))
            botLine.addLine(to: CGPoint(x: w * 0.14, y: botY))
            botLine.addLine(to: CGPoint(x: w * 0.33, y: botY + h * 0.15))
            context.stroke(botLine, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Custom vector icon for "刷新" (twin-arc sync arrows with exact center rotation)
public struct RefreshVectorIcon: View {
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)
    public var isSpinning: Bool = false

    public init(size: CGFloat = 15, color: Color = Color(white: 0.90), isSpinning: Bool = false) {
        self.size = size
        self.color = color
        self.isSpinning = isSpinning
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let c = CGPoint(x: w * 0.5, y: h * 0.5)
            let r = w * 0.34
            let lw = max(1.35, w * 0.105)

            var arc1 = Path()
            arc1.addArc(center: c, radius: r, startAngle: .degrees(-145), endAngle: .degrees(-18), clockwise: false)
            context.stroke(arc1, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))

            let tip1 = CGPoint(x: c.x + r * cos(-.pi * 18 / 180), y: c.y + r * sin(-.pi * 18 / 180))
            var head1 = Path()
            head1.move(to: CGPoint(x: tip1.x - w * 0.17, y: tip1.y - h * 0.04))
            head1.addLine(to: tip1)
            head1.addLine(to: CGPoint(x: tip1.x + w * 0.02, y: tip1.y - h * 0.18))
            context.stroke(head1, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            var arc2 = Path()
            arc2.addArc(center: c, radius: r, startAngle: .degrees(35), endAngle: .degrees(162), clockwise: false)
            context.stroke(arc2, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))

            let tip2 = CGPoint(x: c.x + r * cos(.pi * 162 / 180), y: c.y + r * sin(.pi * 162 / 180))
            var head2 = Path()
            head2.move(to: CGPoint(x: tip2.x + w * 0.17, y: tip2.y + h * 0.04))
            head2.addLine(to: tip2)
            head2.addLine(to: CGPoint(x: tip2.x - w * 0.02, y: tip2.y + h * 0.18))
            context.stroke(head2, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(isSpinning ? 360 : 0))
        .animation(isSpinning ? .linear(duration: 0.78).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: isSpinning)
    }
}

/// Custom 3-dot more icon (centered without any NSPopUpButton disclosure chevron)
public struct MoreDotsVectorIcon: View {
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 15, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let r = max(1.3, w * 0.095)
            for xf in [0.23, 0.50, 0.77] {
                let rect = CGRect(x: w * xf - r, y: h * 0.5 - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Custom geometric Plus icon
public struct PlusVectorIcon: View {
    public var size: CGFloat = 14
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 14, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.5, w * 0.12)
            var p = Path()
            p.move(to: CGPoint(x: w * 0.5, y: h * 0.16))
            p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.84))
            p.move(to: CGPoint(x: w * 0.16, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.84, y: h * 0.5))
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Pure SwiftUI Toolbar Button accepting any custom vector icon content (0 native bezel, 0 Menu chevron)
public struct ToolbarVectorButton<Icon: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public var tooltip: String = ""
    public var isActive: Bool = false
    public let action: () -> Void
    @ViewBuilder public let icon: (Bool) -> Icon

    @State private var isHovered: Bool = false

    public init(
        tooltip: String = "",
        isActive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping (Bool) -> Icon
    ) {
        self.tooltip = tooltip
        self.isActive = isActive
        self.action = action
        self.icon = icon
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                icon(isHovered)
            }
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(colorScheme == .light ? Color.white : Color(white: 0.16))
                    .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.22), radius: (isHovered || isActive) ? 4 : 2, y: 1)
            )
            .overlay(
                Circle()
                    .strokeBorder(colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

public struct ToolbarCircleActionButton: View {
    public let systemName: String
    public var isRotating: Bool = false
    public var tooltip: String? = nil
    public var action: () -> Void

    @State private var isHovered: Bool = false

    public init(systemName: String, isRotating: Bool = false, tooltip: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.isRotating = isRotating
        self.tooltip = tooltip
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered ? .white : Color(white: 0.88))
                    .rotationEffect(Angle(degrees: isRotating ? 360 : 0))
                    .animation(isRotating ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRotating)
            }
            .frame(width: 32, height: 32)
            .donbyLiquidGlassCapsule(tint: nil, interactive: true, isHovered: isHovered)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? "")
    }
}

public struct DonbyToolbarCapsuleModifier: ViewModifier {
    public var width: CGFloat
    public init(width: CGFloat = 34) {
        self.width = width
    }
    public func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: width, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.16, blue: 0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
    }
}

public extension View {
    func donbyToolbarMenuCapsule(width: CGFloat = 34) -> some View {
        modifier(DonbyToolbarCapsuleModifier(width: width))
    }
}
public struct DonbyToolbarCircleView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let systemName: String
    public var showChevron: Bool = false

    public init(systemName: String, showChevron: Bool = false) {
        self.systemName = systemName
        self.showChevron = showChevron
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(colorScheme == .light ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(white: 0.90))
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(colorScheme == .light ? Color(red: 0.40, green: 0.40, blue: 0.44) : Color(white: 0.65))
            }
        }
        .frame(width: showChevron ? 42 : 32, height: 32)
        .background(
            Capsule()
                .fill(colorScheme == .light ? Color.white : Color(white: 0.16))
                .shadow(color: Color.black.opacity(colorScheme == .light ? 0.05 : 0.22), radius: 2, y: 1)
        )
        .overlay(
            Capsule()
                .strokeBorder(colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }
}

public struct DonbySearchPillField: View {
    @Environment(\.colorScheme) private var colorScheme
    public let placeholder: String
    @Binding public var text: String
    public var width: CGFloat = 260
    public var onSubmit: (() -> Void)? = nil

    public init(
        placeholder: String = "搜索",
        text: Binding<String>,
        width: CGFloat = 260,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.width = width
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.56))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(colorScheme == .light ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                .onSubmit {
                    onSubmit?()
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: min(128, width), idealWidth: width, maxWidth: width)
        .frame(height: 34)
        .donbyLiquidGlassCapsule(tint: nil, interactive: false, isHovered: false)
    }
}

// MARK: - High-Resolution Media Artwork View (Real Bundled Posters + Live Emby Server Artwork)
public struct MediaArtworkView: View {
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public var kind: EmbyImageKind = .primary
    public var maxWidth: Int = 600

    @State private var loadedImage: NSImage? = nil

    public init(
        server: EmbyServerConfig?,
        item: EmbyItem,
        kind: EmbyImageKind = .primary,
        maxWidth: Int = 600
    ) {
        self.server = server
        self.item = item
        self.kind = kind
        self.maxWidth = maxWidth
    }

    private var localPosterKey: String? {
        item.providerIds?["localPoster"]
    }

    private var remoteURL: URL? {
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return EmbyClient.shared.imageURL(server: server, item: item, kind: kind, maxWidth: maxWidth)
    }

    private var candidateURLs: [URL] {
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var urls: [URL] = []
        if kind == .backdrop {
            // For backdrops, prioritize series fanart for episodes before low-res thumbnails
            if item.isEpisode {
                if let sId = item.seriesId,
                   let sBackdrop = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .backdrop, maxWidth: maxWidth) {
                    urls.append(sBackdrop)
                }
                if let pId = item.parentBackdropItemId,
                   let pBackdrop = EmbyClient.shared.imageURL(server: server, itemId: pId, kind: .backdrop, maxWidth: maxWidth),
                   !urls.contains(pBackdrop) {
                    urls.append(pBackdrop)
                }
            }
            if let primary = EmbyClient.shared.imageURL(server: server, item: item, kind: .backdrop, maxWidth: maxWidth), !urls.contains(primary) {
                urls.append(primary)
            }
            if let direct = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .backdrop, maxWidth: maxWidth), !urls.contains(direct) {
                urls.append(direct)
            }
            if item.isEpisode {
                if let thumb = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .thumb, maxWidth: maxWidth), !urls.contains(thumb) {
                    urls.append(thumb)
                }
            }
            return urls
        }

        // Prioritize tagged primary URL first because it is CDN-cached and fastest on UHDNow/Emby
        if let primary = EmbyClient.shared.imageURL(server: server, item: item, kind: kind, maxWidth: maxWidth) {
            urls.append(primary)
        }
        if let direct = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: kind, maxWidth: maxWidth), !urls.contains(direct) {
            urls.append(direct)
        }
        if item.isEpisode {
            if let thumb = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .thumb, maxWidth: maxWidth), !urls.contains(thumb) {
                urls.append(thumb)
            }
            if let sId = item.seriesId {
                if let sBackdrop = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .backdrop, maxWidth: maxWidth), !urls.contains(sBackdrop) {
                    urls.append(sBackdrop)
                }
                if let sPrimary = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .primary, maxWidth: maxWidth), !urls.contains(sPrimary) {
                    urls.append(sPrimary)
                }
            }
        }
        return urls
    }

    public var body: some View {
        ZStack {
            if let img = resolvedImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    Color(red: 0.88, green: 0.89, blue: 0.92).opacity(0.35)
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.black.opacity(0.18))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(server?.activeBaseURL ?? "")|\(item.id)|\(kind.rawValue)") {
            if let key = localPosterKey, let localImg = ArtworkImageCache.shared.localPoster(key) {
                if self.loadedImage == nil { self.loadedImage = localImg }
                return
            }
            if resolvedImage != nil {
                return
            }
            let primaryKey = "item_\(item.id)_\(kind.rawValue)"
            let targetPixelSize: Int
            if kind == .backdrop {
                targetPixelSize = max(maxWidth * 2, 2880) // Full Retina/4K resolution for hero backdrop
            } else if maxWidth > 0 {
                targetPixelSize = min(maxWidth * 2, 1200)
            } else {
                targetPixelSize = 600
            }

            // 1. Fast background disk check with hardware downsampling
            let checkKeys: [String]
            if kind == .backdrop {
                if item.isEpisode, let sId = item.seriesId {
                    checkKeys = [primaryKey, "series_\(sId)_backdrop"]
                } else {
                    checkKeys = [primaryKey]
                }
            } else {
                checkKeys = [primaryKey, item.id]
            }

            for key in checkKeys {
                if Task.isCancelled { return }
                if let diskImg = await ArtworkImageCache.shared.imageFromDiskAsync(for: key, maxPixelSize: targetPixelSize) {
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.loadedImage = diskImg
                        }
                    }
                    return
                }
            }

            guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let urls = candidateURLs
            for url in urls {
                if Task.isCancelled { return }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req)
                    if Task.isCancelled { return }
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       data.count > 128 {
                        var aliases = [url.absoluteString]
                        if kind == .backdrop {
                            if item.isEpisode, let sId = item.seriesId {
                                aliases.append("series_\(sId)_backdrop")
                            }
                        } else {
                            aliases.append(contentsOf: [self.item.id, "item_\(self.item.id)"])
                        }
                        if let decoded = ArtworkImageCache.shared.storeRawData(
                            data,
                            for: primaryKey,
                            maxPixelSize: targetPixelSize,
                            aliases: aliases
                        ) {
                            if !Task.isCancelled {
                                await MainActor.run {
                                    self.loadedImage = decoded
                                }
                            }
                            return
                        }
                    }
                } catch {
                    continue
                }
            }
        }
    }

    private var resolvedImage: NSImage? {
        if let loadedImage { return loadedImage }
        if let key = localPosterKey {
            if let local = ArtworkImageCache.shared.localPoster(key) { return local }
        }
        // Fast O(1) direct memory lookup (instant, zero candidate URLs allocations)
        let primaryKey = "item_\(item.id)_\(kind.rawValue)"
        if let cached = ArtworkImageCache.shared.imageFromMemory(for: primaryKey) { return cached }
        if kind == .backdrop, item.isEpisode, let sId = item.seriesId {
            if let sCached = ArtworkImageCache.shared.imageFromMemory(for: "series_\(sId)_backdrop") { return sCached }
        }
        if kind != .backdrop {
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: item.id) { return cached }
        }
        return nil
    }
}

// MARK: - High-Performance Fractional Progress Bar (Zero GeometryReader Layout Invalidation)
public struct FractionalProgressBar: View {
    public var fraction: Double
    public var color: Color
    public var height: CGFloat = 3.0

    public init(fraction: Double, color: Color, height: CGFloat = 3.0) {
        self.fraction = fraction
        self.color = color
        self.height = height
    }

    public var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .overlay(
                Capsule()
                    .fill(color)
                    .scaleEffect(x: CGFloat(max(0.0, min(1.0, fraction))), y: 1.0, anchor: .leading)
            )
            .frame(height: height)
    }
}

// MARK: - Native Poster Card
public struct PosterCardView: View {
    @EnvironmentObject private var appState: AppState
    public let item: EmbyItem
    public var width: CGFloat? = nil
    public var onSelect: () -> Void
    public var onPlay: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    private var targetWidth: CGFloat { width ?? 152 }
    private var targetHeight: CGFloat { targetWidth * 1.5 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                MediaArtworkView(server: appState.activeServer, item: item, kind: .primary, maxWidth: 420)
                    .frame(width: targetWidth, height: targetHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack {
                    HStack(alignment: .top, spacing: 4) {
                        if appState.showResolutionBadge, let resBadge = item.resolutionBadge {
                            Text(resBadge)
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.68))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        Spacer()

                        if let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
                            Text("\(unplayed)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(appState.accentColor)
                                .clipShape(Capsule())
                        } else if item.userData?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(appState.accentColor)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                    }
                    .padding(7)

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if appState.showRatingBadge, let rating = item.communityRating, rating > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.yellow)
                                    Text(String(format: "%.1f", rating))
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.62))
                                .clipShape(Capsule())
                            }

                            Spacer()

                            if item.userData?.isFavorite == true {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.pink)
                            }
                        }

                        if item.progressFraction > 0 && item.progressFraction < 0.99 {
                            FractionalProgressBar(fraction: item.progressFraction, color: appState.accentColor, height: 3)
                        }
                    }
                    .padding(7)
                }

                if isHovered, let onPlay {
                    Color.black.opacity(0.22)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button(action: onPlay) {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 40, height: 40)
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: targetWidth, height: targetHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? appState.accentColor.opacity(0.85) : Color.white.opacity(0.06),
                        lineWidth: isHovered ? 1.5 : 0.65
                    )
            )
            .shadow(
                color: isHovered ? Color.black.opacity(0.30) : Color.clear,
                radius: isHovered ? 6 : 0,
                y: isHovered ? 3 : 0
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .lineLimit(1)

                Text(item.displaySubtitle.isEmpty ? (item.isSeries ? "剧集" : "电影") : item.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .lineLimit(1)
            }
            .frame(width: targetWidth, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }
}

// MARK: - Native Landscape Card
public struct LandscapeCardView: View {
    @EnvironmentObject private var appState: AppState
    public let item: EmbyItem
    public var width: CGFloat = 248
    public var subtitleOverride: String? = nil
    public var onPlay: () -> Void
    public var onDetail: () -> Void

    @State private var isHovered: Bool = false
    private var height: CGFloat { width * 9.0 / 16.0 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                MediaArtworkView(server: appState.activeServer, item: item, kind: .thumb, maxWidth: 560)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.76)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack {
                    HStack {
                        if let epCode = item.episodeCodeString {
                            Text(epCode)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if let res = item.resolutionBadge {
                            Text(res)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                        if let runtime = item.runtimeMinutesString {
                            Text(runtime)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(7)

                    Spacer()

                    if item.progressFraction > 0 {
                        FractionalProgressBar(fraction: item.progressFraction, color: appState.accentColor, height: 3.5)
                            .padding(8)
                    }
                }

                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75))
                        .frame(width: 36, height: 36)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
                .opacity(isHovered ? 1.0 : 0.0)
                .scaleEffect(isHovered ? 1.0 : 0.88)
                .animation(.easeOut(duration: 0.18), value: isHovered)
            }
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? appState.accentColor.opacity(0.85) : Color.white.opacity(0.06),
                        lineWidth: isHovered ? 1.5 : 0.65
                    )
            )
            .shadow(
                color: isHovered ? Color.black.opacity(0.30) : Color.clear,
                radius: isHovered ? 6 : 0,
                y: isHovered ? 3 : 0
            )
            .onTapGesture { onPlay() }

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isEpisode ? (item.seriesName ?? item.name) : item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)

                    Text(subtitleOverride ?? (item.isEpisode ? item.name : item.displaySubtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("查看作品详情")
            }
            .frame(width: width)
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Native Library Card
public struct LibraryCardView: View {
    @EnvironmentObject private var appState: AppState
    public let library: EmbyItem
    public let itemCount: Int?
    public let action: () -> Void

    @State private var isHovered: Bool = false

    private var hidesTextOverlay: Bool {
        appState.activeServer?.usesUHDLogo == true
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(server: appState.activeServer, item: library, kind: .backdrop, maxWidth: 440)
                    .frame(width: 205, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if !hidesTextOverlay {
                    LinearGradient(
                        colors: [.black.opacity(0.10), .black.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        if let count = itemCount ?? library.childCount, count > 0 {
                            Text(String(count))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                        }
                    }

                    Spacer()

                    if !hidesTextOverlay {
                        Text(library.name)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .padding(11)
            }
            .frame(width: 205, height: 112)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.white.opacity(0.40) : (appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08)),
                        lineWidth: isHovered ? 1.2 : 0.65
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.22 : (appState.isLightMode ? 0.04 : 0.12)),
                radius: isHovered ? 8 : 4,
                y: isHovered ? 4 : 2
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Native 3D Module Card
public struct DonbyModuleCardView: View {
    public let title: String
    public let subtitle: String
    public let assetName: String
    public let glowColor: Color
    public let isSelected: Bool
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.145, green: 0.149, blue: 0.165))

                RadialGradient(
                    colors: [glowColor.opacity(0.28), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 115
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading) {
                    HStack(alignment: .top) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        if let img = ArtworkImageCache.shared.systemAsset(assetName) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(glowColor)
                        }
                    }

                    Spacer()

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.56))
                }
                .padding(16)
            }
            .frame(width: 224, height: 124)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color(red: 0.16, green: 0.49, blue: 0.96) : (isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.05)),
                        lineWidth: isSelected ? 1.6 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Latency Pill Badge
public struct LatencyBadgeView: View {
    public let latencyMs: Int?
    public var isPinging: Bool = false

    public init(latencyMs: Int?, isPinging: Bool = false) {
        self.latencyMs = latencyMs
        self.isPinging = isPinging
    }

    private var badgeColor: Color {
        if isPinging && latencyMs == nil { return Color(red: 0.25, green: 0.68, blue: 1.0) }
        guard let ms = latencyMs else { return .secondary }
        if ms < 100 { return Color(red: 0.20, green: 0.84, blue: 0.34) }
        if ms < 260 { return Color(red: 0.24, green: 0.74, blue: 0.98) }
        if ms < 500 { return .orange }
        return Color(red: 0.98, green: 0.36, blue: 0.32)
    }

    public var body: some View {
        EmptyView()
    }
}

// MARK: - Native Toast Banner
public struct ToastBannerView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let toast: ToastMessage

    private static let classicRed = Color(
        red: ThemeColorPalette.appleMusicRedRGB.r,
        green: ThemeColorPalette.appleMusicRedRGB.g,
        blue: ThemeColorPalette.appleMusicRedRGB.b
    )

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.isError ? Self.classicRed : Color(red: 0.22, green: 0.86, blue: 0.36))

            Text(toast.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colorScheme == .light ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(DonbyLiquidGlassCapsuleSurface(tint: nil, isHovered: false))
        .clipShape(Capsule())
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(0.12) : Color.black.opacity(0.42),
            radius: colorScheme == .light ? 10 : 14,
            y: colorScheme == .light ? 4 : 6
        )
    }
}

// MARK: - Apple Liquid Glass Design System (Authentic Multi-Layer Optical Refraction)

public enum DonbyGlassPalette {
    /// Deep Space Black cinema canvas
    public static let canvasBlack = Color(red: 0.043, green: 0.046, blue: 0.056)
    /// SenPlayer-inspired Light Mode canvas
    public static let canvasLight = Color(red: 0.945, green: 0.948, blue: 0.960)
    public static let smokedBacking = Color(red: 0.020, green: 0.024, blue: 0.036)

    public static func canvas(isLight: Bool) -> Color {
        isLight ? canvasLight : canvasBlack
    }

    public static func sidebar(isLight: Bool) -> Color {
        isLight ? Color(red: 0.92, green: 0.925, blue: 0.94) : Color(red: 0.075, green: 0.080, blue: 0.095)
    }

    public static func cardBackground(isLight: Bool) -> Color {
        isLight ? Color.white.opacity(0.85) : Color(red: 0.09, green: 0.095, blue: 0.11)
    }

    public static func primaryText(isLight: Bool) -> Color {
        isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : Color.white
    }

    public static func secondaryText(isLight: Bool) -> Color {
        isLight ? Color(red: 0.42, green: 0.42, blue: 0.46) : Color(white: 0.60)
    }

    public static func tertiaryText(isLight: Bool) -> Color {
        isLight ? Color(red: 0.58, green: 0.58, blue: 0.62) : Color(white: 0.42)
    }

    public static func separator(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }
}

/// Optical Visual Effect View for sidebar translucency and desktop-bleed
public struct DonbyVisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .sidebar
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    public init(material: NSVisualEffectView.Material = .sidebar, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

public struct DonbyBackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var alpha: CGFloat = 0.45

    public init(material: NSVisualEffectView.Material = .hudWindow, alpha: CGFloat = 0.45) {
        self.material = material
        self.alpha = alpha
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .withinWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.alphaValue = alpha
        return v
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.alphaValue = alpha
    }
}

/// Groups nearby Liquid Glass controls into a shared WindowServer refraction & batching field on macOS 26+
public struct DonbyGlassContainer<Content: View>: View {
    public var spacing: CGFloat
    @ViewBuilder public var content: () -> Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

private struct DonbyLiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color?
    let interactive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        let isLight = (colorScheme == .light)
        content
            .background(
                ZStack {
                    if let tint {
                        Capsule(style: .continuous)
                            .fill(tint)
                    } else if isLight {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isHovered ? 0.94 : 0.88))
                    } else {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isHovered ? 0.14 : 0.08))
                    }
                }
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        tint != nil ? Color.white.opacity(0.18) : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(isHovered ? 0.16 : 0.10)),
                        lineWidth: 0.65
                    )
            )
            .shadow(
                color: tint != nil
                    ? tint!.opacity(isHovered ? 0.35 : 0.20)
                    : (isLight ? Color.black.opacity(isHovered ? 0.08 : 0.04) : Color.black.opacity(isHovered ? 0.25 : 0.15)),
                radius: isHovered ? 5 : 2.5,
                y: isHovered ? 2 : 1
            )
    }
}

private struct DonbyLiquidGlassRectModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        let isLight = (colorScheme == .light)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    if let tint {
                        shape.fill(tint)
                    } else if isLight {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.white.opacity(isHovered ? 0.94 : 0.88))
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.white.opacity(isHovered ? 0.14 : 0.08))
                    }
                }
                .clipShape(shape)
            )
            .overlay(
                shape.strokeBorder(
                    tint != nil ? Color.white.opacity(0.18) : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(isHovered ? 0.16 : 0.10)),
                    lineWidth: 0.65
                )
            )
            .shadow(
                color: tint != nil
                    ? tint!.opacity(isHovered ? 0.35 : 0.20)
                    : (isLight ? Color.black.opacity(isHovered ? 0.08 : 0.04) : Color.black.opacity(isHovered ? 0.25 : 0.15)),
                radius: isHovered ? 5 : 2.5,
                y: isHovered ? 2 : 1
            )
    }
}

public extension View {
    func donbyLiquidGlassCapsule(tint: Color? = nil, interactive: Bool = false, isHovered: Bool = false) -> some View {
        modifier(DonbyLiquidGlassCapsuleModifier(tint: tint, interactive: interactive, isHovered: isHovered))
    }

    func donbyLiquidGlassRect(cornerRadius: CGFloat = 15, tint: Color? = nil, interactive: Bool = false, isHovered: Bool = false) -> some View {
        modifier(DonbyLiquidGlassRectModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive, isHovered: isHovered))
    }
}

public struct DonbyLiquidGlassRoundedSurface: View {
    public var cornerRadius: CGFloat = 14
    public var tint: Color? = nil
    public var isHovered: Bool = false

    public init(cornerRadius: CGFloat = 14, tint: Color? = nil, isHovered: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.isHovered = isHovered
    }

    public var body: some View {
        Color.clear
            .donbyLiquidGlassRect(cornerRadius: cornerRadius, tint: tint, interactive: false, isHovered: isHovered)
    }
}

public struct DonbyLiquidGlassCapsuleSurface: View {
    public var tint: Color? = nil
    public var isHovered: Bool = false

    public init(tint: Color? = nil, isHovered: Bool = false) {
        self.tint = tint
        self.isHovered = isHovered
    }

    public var body: some View {
        Color.clear
            .donbyLiquidGlassCapsule(tint: tint, interactive: false, isHovered: isHovered)
    }
}

public struct LiquidGlassCapsuleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    public let title: String
    public let systemImage: String
    public var tint: Color? = nil
    public var progressFraction: Double = 0
    public var horizontalPadding: CGFloat = 22
    public var verticalPadding: CGFloat = 10.5
    public var fontSize: CGFloat = 14
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        title: String,
        systemImage: String,
        tint: Color? = nil,
        progressFraction: Double = 0,
        horizontalPadding: CGFloat = 22,
        verticalPadding: CGFloat = 10.5,
        fontSize: CGFloat = 14,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.progressFraction = progressFraction
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.fontSize = fontSize
        self.action = action
    }

    private var textColor: Color {
        if tint != nil {
            return .white
        }
        return Color(red: 0.10, green: 0.10, blue: 0.12)
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if let tint {
                    Capsule(style: .continuous).fill(tint)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(isHovered ? 1.0 : 0.95))

                            if progressFraction > 0 {
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.08))
                                    .frame(width: geo.size.width * min(1.0, max(0.0, progressFraction)))
                            }
                        }
                    }
                    .clipShape(Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.65)
                    )
                    .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0.13), radius: isHovered ? 8 : 5, y: 3)
                }

                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: fontSize - 0.5, weight: .bold))
                    Text(title)
                        .font(.system(size: fontSize, weight: .bold))
                }
                .foregroundStyle(textColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
            .fixedSize()
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

public struct LiquidGlassCircleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    public let systemImage: String
    public var iconColor: Color? = nil
    public var size: CGFloat = 38
    public var tooltip: String = ""
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        systemImage: String,
        iconColor: Color? = nil,
        size: CGFloat = 38,
        tooltip: String = "",
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.size = size
        self.tooltip = tooltip
        self.action = action
    }

    private var effectiveIconColor: Color {
        if let iconColor { return iconColor }
        return Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovered ? 1.0 : 0.95))
                    .shadow(color: Color.black.opacity(isHovered ? 0.20 : 0.11), radius: isHovered ? 6 : 4, y: 2)

                Circle()
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.65)

                Image(systemName: systemImage)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(effectiveIconColor)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

/// Sculpted Liquid Glass circular Menu button with unified physical optics matching LiquidGlassCircleButton
public struct LiquidGlassCircleMenu<MenuItems: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public let systemImage: String
    public var iconColor: Color? = nil
    public var size: CGFloat = 38
    public var tooltip: String = ""
    @ViewBuilder public let menuContent: () -> MenuItems

    @State private var isHovered: Bool = false

    public init(
        systemImage: String,
        iconColor: Color? = nil,
        size: CGFloat = 38,
        tooltip: String = "",
        @ViewBuilder menuContent: @escaping () -> MenuItems
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.size = size
        self.tooltip = tooltip
        self.menuContent = menuContent
    }

    private var effectiveIconColor: Color {
        if let iconColor { return iconColor }
        return Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    public var body: some View {
        ZStack {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovered ? 1.0 : 0.95))
                    .shadow(color: Color.black.opacity(isHovered ? 0.20 : 0.11), radius: isHovered ? 6 : 4, y: 2)

                Circle()
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.65)

                Image(systemName: systemImage)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(effectiveIconColor)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)

            // Transparent Menu trigger on top to open menu with zero layout offset
            Menu {
                menuContent()
            } label: {
                Color.white.opacity(0.0001)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

/// Sculpted Liquid Glass selector card (`资源版本` / `音轨选择` / `主字幕`) replacing stock grey NSPopUpButton
public struct LiquidGlassSelectorCard<MenuItems: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public let title: String
    public let icon: String
    public let valueText: String
    public var badgeText: String? = nil
    public let accentColor: Color
    @ViewBuilder public let menuItems: () -> MenuItems

    @State private var isHovered: Bool = false

    public init(
        title: String,
        icon: String,
        valueText: String,
        badgeText: String? = nil,
        accentColor: Color,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.title = title
        self.icon = icon
        self.valueText = valueText
        self.badgeText = badgeText
        self.accentColor = accentColor
        self.menuItems = menuItems
    }

    public var body: some View {
        Menu {
            menuItems()
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [accentColor.opacity(0.32), accentColor.opacity(0.10)],
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: 26
                            )
                        )
                        .overlay(
                            Circle().strokeBorder(accentColor.opacity(0.50), lineWidth: 0.75)
                        )
                        .frame(width: 33, height: 33)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(colorScheme == .light ? Color(red: 0.44, green: 0.44, blue: 0.48) : Color.white.opacity(0.66))
                        if let badgeText, !badgeText.isEmpty {
                            Text(badgeText)
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background(accentColor.opacity(0.82))
                                .clipShape(Capsule())
                        }
                    }

                    Text(valueText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colorScheme == .light ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(colorScheme == .light ? Color(red: 0.40, green: 0.40, blue: 0.44) : Color.white.opacity(isHovered ? 0.92 : 0.58))
                    .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .donbyLiquidGlassRect(cornerRadius: 15, tint: nil, interactive: true, isHovered: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

public struct PersonAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let server: EmbyServerConfig?
    public let person: EmbyPerson
    public var width: CGFloat = 78
    public var height: CGFloat = 100
    public var size: CGFloat = 70
    public var accentColor: Color = Color(
        red: ThemeColorPalette.appleMusicRedRGB.r,
        green: ThemeColorPalette.appleMusicRedRGB.g,
        blue: ThemeColorPalette.appleMusicRedRGB.b
    )

    @State private var avatarImage: NSImage? = nil

    public init(
        server: EmbyServerConfig?,
        person: EmbyPerson,
        width: CGFloat = 78,
        height: CGFloat = 100,
        size: CGFloat = 70,
        accentColor: Color = Color(
            red: ThemeColorPalette.appleMusicRedRGB.r,
            green: ThemeColorPalette.appleMusicRedRGB.g,
            blue: ThemeColorPalette.appleMusicRedRGB.b
        )
    ) {
        self.server = server
        self.person = person
        self.width = width
        self.height = height
        self.size = size
        self.accentColor = accentColor
    }

    private var cacheKey: String {
        "\(server?.activeBaseURL ?? "local")|person|\(person.id)|\(person.name)|\(person.primaryImageTag ?? "")"
    }

    public var body: some View {
        let isLight = (colorScheme == .light)
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        ZStack {
            if let img = avatarImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height, alignment: .top)
                    .clipShape(shape)
            } else {
                if isLight {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.90, green: 0.91, blue: 0.93), Color(red: 0.85, green: 0.86, blue: 0.89)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(person.name.prefix(1)))
                        .font(.system(size: min(width, height) * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.40, green: 0.40, blue: 0.45))
                } else {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.34), Color(red: 0.16, green: 0.17, blue: 0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(person.name.prefix(1)))
                        .font(.system(size: min(width, height) * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isLight ? 0.85 : 0.46),
                            Color.white.opacity(isLight ? 0.30 : 0.10),
                            (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.24))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.65
                )
        )
        .shadow(color: Color.black.opacity(isLight ? 0.08 : 0.32), radius: isLight ? 5 : 8, y: isLight ? 2.5 : 4)
        .task(id: cacheKey) {
            if let cached = ArtworkImageCache.shared.image(for: cacheKey) {
                self.avatarImage = cached
                return
            }
            guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let candidates = EmbyClient.shared.personImageURLs(server: server, person: person, maxWidth: Int(size * 3.5))
            for url in candidates {
                if Task.isCancelled { return }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse,
                       (200...299).contains(http.statusCode),
                       data.count > 128,
                       let img = NSImage(data: data),
                       img.size.width > 1 {
                        ArtworkImageCache.shared.store(img, for: cacheKey)
                        self.avatarImage = img
                        return
                    }
                } catch {
                    continue
                }
            }
        }
    }
}


// MARK: - Watch Record Poster & Video Frame Thumbnail View
public struct RecordArtworkThumbnailView: View {
    @EnvironmentObject private var appState: AppState
    public let record: WatchRecordItem
    public let server: EmbyServerConfig?
    public var width: CGFloat = 78
    public var height: CGFloat = 114

    @State private var thumbnail: NSImage? = nil

    public init(record: WatchRecordItem, server: EmbyServerConfig?, width: CGFloat = 78, height: CGFloat = 114) {
        self.record = record
        self.server = server
        self.width = width
        self.height = height
    }

    private var cacheKey: String {
        "record_thumb_\(record.id)_\(record.posterURL ?? "")"
    }

    public var body: some View {
        ZStack {
            if let img = resolvedThumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                (appState.isLightMode ? Color(red: 0.91, green: 0.92, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.14))
                    .frame(width: width, height: height)

                VStack(spacing: 5) {
                    Image(systemName: (record.sourceType == "Local" || record.sourceType == "本地文件") ? "play.rectangle.fill" : "film")
                        .font(.system(size: 22))
                        .foregroundStyle(appState.isLightMode ? Color.black.opacity(0.28) : Color.white.opacity(0.35))
                    Text(record.sourceType)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(appState.isLightMode ? Color.black.opacity(0.40) : Color.white.opacity(0.40))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.65)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 5, y: 2)
        .task(id: "\(record.id)|\(record.posterURL ?? "")") {
            await loadThumbnail()
        }
    }

    private var resolvedThumbnail: NSImage? {
        if let thumbnail { return thumbnail }
        if let cached = ArtworkImageCache.shared.image(for: cacheKey) {
            return cached
        }
        if let urlStr = record.posterURL, let cached = ArtworkImageCache.shared.image(for: urlStr) {
            return cached
        }
        if let embyId = record.embyItemId {
            for alias in ["item_\(embyId)_Primary", "item_\(embyId)_Thumb", "item_\(embyId)", embyId, "emby_\(embyId)"] {
                if let cached = ArtworkImageCache.shared.image(for: alias) {
                    return cached
                }
            }
        }
        if let stream = record.streamURLString, let cached = ArtworkImageCache.shared.image(for: "local_frame_\(stream)") {
            return cached
        }
        return nil
    }

    private func loadThumbnail() async {
        if let cached = resolvedThumbnail {
            self.thumbnail = cached
            return
        }

        // 1. Try remote posterURL string
        if let urlStr = record.posterURL, let url = URL(string: urlStr) {
            if let img = await fetchImage(url: url) {
                var aliases = [cacheKey, "record_\(record.id)"]
                if let embyId = record.embyItemId {
                    aliases.append(contentsOf: ["item_\(embyId)", "item_\(embyId)_Primary", embyId])
                }
                ArtworkImageCache.shared.store(img, for: cacheKey, aliases: aliases)
                self.thumbnail = img
                return
            }
        }

        // 2. Try Emby item ID with server
        if let itemId = record.embyItemId, let server, !server.host.isEmpty {
            if let url = EmbyClient.shared.imageURL(server: server, itemId: itemId, kind: .primary, maxWidth: 300) {
                if let img = await fetchImage(url: url) {
                    ArtworkImageCache.shared.store(img, for: cacheKey, aliases: ["item_\(itemId)", "item_\(itemId)_Primary", itemId])
                    self.thumbnail = img
                    return
                }
            }
        }

        // 3. Try local video file frame extraction via AVAssetImageGenerator
        if let streamStr = record.streamURLString {
            let fileURL: URL? = {
                if let u = URL(string: streamStr), u.isFileURL { return u }
                if streamStr.hasPrefix("/") && FileManager.default.fileExists(atPath: streamStr) {
                    return URL(fileURLWithPath: streamStr)
                }
                return nil
            }()
            if let fileURL, let img = await extractLocalThumbnail(fileURL: fileURL) {
                ArtworkImageCache.shared.store(img, for: cacheKey, aliases: ["local_frame_\(streamStr)"])
                self.thumbnail = img
                return
            }
        }
    }

    private func fetchImage(url: URL) async -> NSImage? {
        if let cached = ArtworkImageCache.shared.image(for: url.absoluteString) {
            return cached
        }
        do {
            let req = server.map { EmbyClient.shared.makeImageRequest(url: url, server: $0) } ?? URLRequest(url: url)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let img = NSImage(data: data) {
                ArtworkImageCache.shared.store(img, for: url.absoluteString)
                return img
            }
        } catch {}
        return nil
    }

    private func extractLocalThumbnail(fileURL: URL) async -> NSImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 480)
        let pos = max(1.0, min(record.positionSeconds, 120.0))
        let time = CMTime(seconds: pos, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}

// MARK: - ClearLogo with Fallback Typography Header
public struct ClearLogoHeaderView: View {
    public let server: EmbyServerConfig?
    public let item: EmbyItem
    public let isLightMode: Bool
    public let showTitle: String
    public let subtitle: String

    @State private var logoImage: NSImage? = nil

    public init(
        server: EmbyServerConfig?,
        item: EmbyItem,
        isLightMode: Bool,
        showTitle: String,
        subtitle: String
    ) {
        self.server = server
        self.item = item
        self.isLightMode = isLightMode
        self.showTitle = showTitle
        self.subtitle = subtitle
    }

    private var candidateLogoURLs: [URL] {
        guard let server, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var urls: [URL] = []
        if item.isEpisode {
            if let sId = item.seriesId,
               let sLogo = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .logo, maxWidth: 800) {
                urls.append(sLogo)
            }
            if let direct = EmbyClient.shared.imageURL(server: server, item: item, kind: .logo, maxWidth: 800), !urls.contains(direct) {
                urls.append(direct)
            }
            if let directId = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .logo, maxWidth: 800), !urls.contains(directId) {
                urls.append(directId)
            }
        } else {
            if let direct = EmbyClient.shared.imageURL(server: server, item: item, kind: .logo, maxWidth: 800) {
                urls.append(direct)
            }
            if let directId = EmbyClient.shared.imageURL(server: server, itemId: item.id, kind: .logo, maxWidth: 800), !urls.contains(directId) {
                urls.append(directId)
            }
            if let sId = item.seriesId,
               let sLogo = EmbyClient.shared.imageURL(server: server, itemId: sId, kind: .logo, maxWidth: 800), !urls.contains(sLogo) {
                urls.append(sLogo)
            }
        }
        return urls
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = logoImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 380, maxHeight: 78, alignment: .leading)
                    .shadow(color: Color.black.opacity(isLightMode ? 0.14 : 0.45), radius: 4, y: 2)
            } else {
                Text(showTitle)
                    .font(.system(size: item.isEpisode ? 32 : 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                    .shadow(color: isLightMode ? Color.white.opacity(0.85) : Color.black.opacity(0.50), radius: 3, y: 1)
                    .lineLimit(2)
            }

            if !subtitle.isEmpty && subtitle != showTitle {
                Text(subtitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    .lineLimit(1)
            }
        }
        .task(id: "\(server?.activeBaseURL ?? "")|\(item.id)|\(item.seriesId ?? "")") {
            let primaryTargetId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
            let cacheKey = "logo_\(primaryTargetId)"
            if let cached = ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                self.logoImage = cached
                return
            }
            if let disk = await ArtworkImageCache.shared.imageFromDiskAsync(for: cacheKey, maxPixelSize: 800) {
                await MainActor.run {
                    self.logoImage = disk
                }
                return
            }

            guard let server else { return }
            for url in candidateLogoURLs {
                if Task.isCancelled { return }
                do {
                    let req = EmbyClient.shared.makeImageRequest(url: url, server: server)
                    let (data, resp) = try await ArtworkDownloadManager.shared.download(for: req)
                    if Task.isCancelled { return }
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       data.count > 100,
                       let decoded = ArtworkImageCache.shared.storeRawData(data, for: cacheKey, maxPixelSize: 800) {
                        await MainActor.run {
                            self.logoImage = decoded
                        }
                        return
                    }
                } catch {
                    continue
                }
            }
        }
    }
}

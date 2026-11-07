import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

// MARK: - Native Artwork & Local Poster Cache
@MainActor
public final class ArtworkImageCache {
    public static let shared = ArtworkImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    public func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    public func store(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
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
public struct DonbyAppLogoView: View {
    public var size: CGFloat = 58
    public init(size: CGFloat = 58) { self.size = size }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.115, blue: 0.13),
                            Color(red: 0.03, green: 0.032, blue: 0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color(red: 0.85, green: 0.88, blue: 0.94).opacity(0.26), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1, size * 0.018)
                        )
                )
                .shadow(color: .black.opacity(0.48), radius: size * 0.12, y: size * 0.05)

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let strokeW = w * 0.115

                var dPath = Path()
                dPath.move(to: CGPoint(x: w * 0.56, y: h * 0.27))
                dPath.addQuadCurve(to: CGPoint(x: w * 0.44, y: h * 0.23), control: CGPoint(x: w * 0.51, y: h * 0.23))
                dPath.addLine(to: CGPoint(x: w * 0.27, y: h * 0.23))
                dPath.addLine(to: CGPoint(x: w * 0.27, y: h * 0.77))
                dPath.addLine(to: CGPoint(x: w * 0.44, y: h * 0.77))
                dPath.addQuadCurve(to: CGPoint(x: w * 0.56, y: h * 0.73), control: CGPoint(x: w * 0.51, y: h * 0.77))

                context.stroke(
                    dPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.88, green: 0.91, blue: 0.96),
                            Color(red: 0.56, green: 0.60, blue: 0.68),
                            Color(red: 0.32, green: 0.36, blue: 0.43)
                        ]),
                        startPoint: CGPoint(x: w * 0.25, y: h * 0.2),
                        endPoint: CGPoint(x: w * 0.60, y: h * 0.8)
                    ),
                    style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
                )

                var play = Path()
                play.move(to: CGPoint(x: w * 0.45, y: h * 0.32))
                play.addLine(to: CGPoint(x: w * 0.78, y: h * 0.50))
                play.addLine(to: CGPoint(x: w * 0.45, y: h * 0.68))
                play.closeSubpath()

                context.fill(
                    play,
                    with: .linearGradient(
                        Gradient(colors: [.white, Color(red: 0.78, green: 0.82, blue: 0.88)]),
                        startPoint: CGPoint(x: w * 0.45, y: h * 0.32),
                        endPoint: CGPoint(x: w * 0.78, y: h * 0.68)
                    )
                )
            }
        }
        .frame(width: size, height: size)
    }
}

/// Renders modern luminous UHDNow mark with electric cyan-blue glow
public struct UHDNowVectorLogo: View {
    public var size: CGFloat = 30

    public init(size: CGFloat = 30) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Subtle frosted squircle chip
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.12, green: 0.16, blue: 0.24), Color(red: 0.07, green: 0.09, blue: 0.14)],
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
                let strokeW = w * 0.18

                // Draw modern luminous U-channel
                var uPath = Path()
                let leftX = w * 0.26
                let rightX = w * 0.74
                let topY = h * 0.22
                let midRightY = h * 0.52
                let arcCenter = CGPoint(x: (leftX + rightX) / 2.0, y: h * 0.52)
                let radius = (rightX - leftX) / 2.0

                uPath.move(to: CGPoint(x: leftX, y: topY))
                uPath.addLine(to: CGPoint(x: leftX, y: arcCenter.y))
                uPath.addArc(
                    center: arcCenter,
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(0),
                    clockwise: true
                )
                uPath.addLine(to: CGPoint(x: rightX, y: midRightY))

                context.stroke(
                    uPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.32, green: 0.82, blue: 1.0),
                            Color(red: 0.16, green: 0.52, blue: 0.98),
                            Color(red: 0.38, green: 0.32, blue: 0.96)
                        ]),
                        startPoint: CGPoint(x: leftX, y: topY),
                        endPoint: CGPoint(x: rightX, y: h * 0.82)
                    ),
                    style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
                )

                // Draw glowing play prism ▶
                var playPath = Path()
                let triLeft = w * 0.53
                let triRight = w * 0.84
                let triTop = h * 0.18
                let triBottom = h * 0.48
                let triMidY = (triTop + triBottom) / 2.0

                playPath.move(to: CGPoint(x: triLeft, y: triTop))
                playPath.addLine(to: CGPoint(x: triRight, y: triMidY))
                playPath.addLine(to: CGPoint(x: triLeft, y: triBottom))
                playPath.closeSubpath()

                context.fill(
                    playPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white,
                            Color(red: 0.72, green: 0.90, blue: 1.0)
                        ]),
                        startPoint: CGPoint(x: triLeft, y: triTop),
                        endPoint: CGPoint(x: triRight, y: triMidY)
                    )
                )
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
                Circle()
                    .fill(isHovered || isActive ? Color.white.opacity(0.13) : Color(red: 0.16, green: 0.16, blue: 0.18))
                    .frame(width: 34, height: 34)
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered || isActive ? 0.28 : 0.16),
                                Color.white.opacity(isHovered || isActive ? 0.10 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                    .frame(width: 34, height: 34)
                icon(isHovered)
            }
            .frame(width: 34, height: 34)
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
                Circle()
                    .fill(isHovered ? Color.white.opacity(0.12) : Color(red: 0.16, green: 0.16, blue: 0.18))
                    .frame(width: 32, height: 32)
                Circle()
                    .strokeBorder(
                        isHovered ? Color.white.opacity(0.24) : Color.white.opacity(0.08),
                        lineWidth: 0.8
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered ? .white : Color(white: 0.88))
                    .rotationEffect(Angle(degrees: isRotating ? 360 : 0))
                    .animation(isRotating ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRotating)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? "")
    }
}

public struct SenToolbarCapsuleModifier: ViewModifier {
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
    func senToolbarMenuCapsule(width: CGFloat = 34) -> some View {
        modifier(SenToolbarCapsuleModifier(width: width))
    }
}
public struct SenToolbarCircleView: View {
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
                .foregroundStyle(Color(white: 0.86))
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(white: 0.65))
            }
        }
        .frame(width: showChevron ? 42 : 36, height: 34)
        .background(
            Capsule()
                .fill(Color(red: 0.17, green: 0.17, blue: 0.19))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
    }
}

public struct SenSearchPillField: View {
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
                .foregroundStyle(.white)
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
        .background(
            Capsule()
                .fill(Color(red: 0.17, green: 0.17, blue: 0.19))
        )
        .overlay(
            Capsule()
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

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = resolvedImage {
                    if kind == .primary || img.size.width >= img.size.height * 1.02 {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        // Fallback Widescreen Composition when only a portrait poster exists
                        ZStack(alignment: .center) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .blur(radius: 22)
                                .scaleEffect(1.18)
                                .overlay(Color.black.opacity(0.24))
                                .clipped()

                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(height: geo.size.height)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    }
                } else {
                    Color(red: 0.14, green: 0.15, blue: 0.17)
                }
            }
        }
        .task(id: remoteURL?.absoluteString ?? item.id) {
            if let key = localPosterKey, let localImg = ArtworkImageCache.shared.localPoster(key) {
                self.loadedImage = localImg
                return
            }
            guard let url = remoteURL else { return }
            if let cached = ArtworkImageCache.shared.image(for: url.absoluteString) {
                self.loadedImage = cached
                return
            }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let img = NSImage(data: data) {
                    ArtworkImageCache.shared.store(img, for: url.absoluteString)
                    self.loadedImage = img
                }
            } catch {}
        }
    }

    private var resolvedImage: NSImage? {
        if let loadedImage { return loadedImage }
        if let key = localPosterKey {
            return ArtworkImageCache.shared.localPoster(key)
        }
        return nil
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
                            GeometryReader { barGeo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.28))
                                    Capsule()
                                        .fill(appState.accentColor)
                                        .frame(width: barGeo.size.width * item.progressFraction)
                                }
                            }
                            .frame(height: 3)
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
                        isHovered ? appState.accentColor.opacity(0.85) : Color.white.opacity(0.08),
                        lineWidth: isHovered ? 1.5 : 0.6
                    )
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isHovered)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)

                Text(item.displaySubtitle.isEmpty ? (item.isSeries ? "剧集" : "电影") : item.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
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
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.28))
                                Capsule()
                                    .fill(appState.accentColor)
                                    .frame(width: geo.size.width * item.progressFraction)
                            }
                        }
                        .frame(height: 3.5)
                        .padding(8)
                    }
                }

                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 36, height: 36)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                .opacity(isHovered ? 1.0 : 0.72)
            }
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? appState.accentColor.opacity(0.85) : Color.white.opacity(0.08),
                        lineWidth: isHovered ? 1.4 : 0.6
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onTapGesture { onPlay() }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isEpisode ? (item.seriesName ?? item.name) : item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color(white: 0.92))
                        .lineLimit(1)

                    Text(subtitleOverride ?? (item.isEpisode ? item.name : item.displaySubtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(white: 0.55))
                }
                .buttonStyle(.plain)
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

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(server: appState.activeServer, item: library, kind: .backdrop, maxWidth: 440)
                    .frame(width: 205, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                LinearGradient(
                    colors: [.black.opacity(0.10), .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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

                    Text(library.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(11)
            }
            .frame(width: 205, height: 112)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovered ? appState.accentColor.opacity(0.85) : Color.white.opacity(0.10),
                        lineWidth: isHovered ? 1.5 : 0.7
                    )
            )
            .scaleEffect(isHovered ? 1.025 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Native 3D Module Card
public struct SenModuleCardView: View {
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
        HStack(spacing: 4.5) {
            if isPinging && latencyMs == nil {
                RefreshVectorIcon(size: 9.5, color: badgeColor, isSpinning: true)
            } else {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 5.5, height: 5.5)
            }
            if let ms = latencyMs {
                Text("\(ms) ms")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badgeColor)
            } else if isPinging {
                Text("测速中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(badgeColor)
            } else {
                Text("待测速")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Native Toast Banner
public struct ToastBannerView: View {
    public let toast: ToastMessage

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.isError ? Color.red : Color(red: 0.20, green: 0.84, blue: 0.29))

            Text(toast.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(red: 0.18, green: 0.18, blue: 0.20))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }
}

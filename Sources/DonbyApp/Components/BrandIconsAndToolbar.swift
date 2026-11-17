import SwiftUI
import DonbyCore

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

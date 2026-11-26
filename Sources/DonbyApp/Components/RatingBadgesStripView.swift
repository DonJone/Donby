import SwiftUI
import DonbyCore

/// Multi-platform rating badges strip displayed on Home (`MainCarouselView`) and Detail (`DetailView`) hero posters.
/// Renders crisp pure-vector platform emblems paired with tabular score typography across up to 7 sources:
/// TMDB, IMDb, Rotten Tomatoes Critics, Rotten Tomatoes Audience, Letterboxd, Trakt, and Metacritic.
public struct HeroRatingBadgesRow: View {
    public let item: EmbyItem
    public let ratings: MultiPlatformRatings?
    public var isLightSurface: Bool = false
    public var fontSize: CGFloat = 13.5
    public var iconHeight: CGFloat = 17

    public init(
        item: EmbyItem,
        ratings: MultiPlatformRatings?,
        isLightSurface: Bool = false,
        fontSize: CGFloat = 13.5,
        iconHeight: CGFloat = 17
    ) {
        self.item = item
        self.ratings = ratings
        self.isLightSurface = isLightSurface
        self.fontSize = fontSize
        self.iconHeight = iconHeight
    }

    private var badges: [MultiPlatformRatings.RatingBadgeItem] {
        MultiPlatformRatings.displayBadges(for: item, external: ratings)
    }

    public var body: some View {
        let items = badges
        if !items.isEmpty {
            RatingBadgesFlowLayout(horizontalSpacing: 13, verticalSpacing: 6) {
                ForEach(items) { badge in
                    HStack(spacing: 5) {
                        RatingPlatformEmblemView(
                            platform: badge.platform,
                            isPositive: badge.isPositive,
                            height: iconHeight,
                            isLightSurface: isLightSurface
                        )
                        Text(badge.formattedValue)
                            .font(.system(size: fontSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(
                                isLightSurface
                                    ? DonbyGlassPalette.primaryText(isLight: true)
                                    : Color.white.opacity(0.95)
                            )
                            .shadow(
                                color: isLightSurface ? .clear : Color.black.opacity(0.42),
                                radius: 2,
                                x: 0,
                                y: 1
                            )
                    }
                    .fixedSize()
                    .help(badge.tooltip)
                }
            }
            .animation(.easeOut(duration: 0.22), value: items)
        }
    }
}

// MARK: - Single-Line-Preferred Wrapping Flow Layout

private struct RatingBadgesFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 13
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + horizontalSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                if rowWidth > 0 { rowWidth += horizontalSpacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX + 0.5 {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y + (max(rowHeight, size.height) - size.height) * 0.5),
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Platform Emblem Dispatcher

private struct RatingPlatformEmblemView: View {
    let platform: MultiPlatformRatings.RatingPlatform
    let isPositive: Bool
    let height: CGFloat
    let isLightSurface: Bool

    var body: some View {
        switch platform {
        case .tmdb:
            TMDBStackedBadgeIcon(height: height)
        case .imdb:
            IMDbBadgeIcon(height: height)
        case .rottenTomatoesCritics:
            RottenTomatoesCriticsIcon(isFresh: isPositive, size: height + 1)
        case .rottenTomatoesAudience:
            RottenTomatoesAudienceIcon(isFresh: isPositive, size: height + 1, isLightSurface: isLightSurface)
        case .letterboxd:
            LetterboxdBadgeIcon(size: height + 1)
        case .trakt:
            TraktBadgeIcon(size: height + 1)
        case .metacritic:
            MetacriticBadgeIcon(size: height + 1)
        }
    }
}

// MARK: - 1. TMDB Stacked Cyan-Teal Logo

private struct TMDBStackedBadgeIcon: View {
    let height: CGFloat

    private let gradient = LinearGradient(
        colors: [
            Color(red: 0.56, green: 0.81, blue: 0.63),
            Color(red: 0.16, green: 0.77, blue: 0.78),
            Color(red: 0.01, green: 0.71, blue: 0.89)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        let scale = height / 17.0
        VStack(alignment: .leading, spacing: 0.6 * scale) {
            HStack(spacing: 1.8 * scale) {
                Text("THE")
                    .font(.system(size: 5.2 * scale, weight: .black, design: .rounded))
                    .tracking(0.3 * scale)
                Capsule()
                    .frame(width: 9.5 * scale, height: 4.1 * scale)
            }
            .frame(height: 5.2 * scale)

            HStack(spacing: 0.5 * scale) {
                Text("M")
                    .font(.system(size: 5.2 * scale, weight: .black, design: .rounded))
                Capsule()
                    .frame(width: 5.2 * scale, height: 4.1 * scale)
                Text("VIE")
                    .font(.system(size: 5.2 * scale, weight: .black, design: .rounded))
                    .tracking(0.2 * scale)
            }
            .frame(height: 5.2 * scale)

            HStack(spacing: 1.8 * scale) {
                Capsule()
                    .frame(width: 12.2 * scale, height: 4.1 * scale)
                Text("DB")
                    .font(.system(size: 5.2 * scale, weight: .black, design: .rounded))
                    .tracking(0.2 * scale)
            }
            .frame(height: 5.2 * scale)
        }
        .foregroundStyle(gradient)
        .frame(height: height)
        .accessibilityLabel("TMDB")
    }
}

// MARK: - 2. IMDb Golden Rounded Badge

private struct IMDbBadgeIcon: View {
    let height: CGFloat

    var body: some View {
        let width = height * 1.88
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.21, style: .continuous)
                .fill(Color(red: 0.96, green: 0.77, blue: 0.09))
            Text("IMDb")
                .font(.system(size: height * 0.68, weight: .black, design: .default))
                .tracking(-0.3)
                .scaleEffect(x: 0.86, y: 1.04)
                .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.10))
        }
        .frame(width: width, height: height)
        .accessibilityLabel("IMDb")
    }
}

// MARK: - 3. Rotten Tomatoes Critics (Fresh Tomato / Rotten Splat)

private struct RottenTomatoesCriticsIcon: View {
    let isFresh: Bool
    let size: CGFloat

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height

            if isFresh {
                // Plump vibrant red tomato silhouette
                var bodyPath = Path()
                bodyPath.move(to: CGPoint(x: w * 0.50, y: h * 0.24))
                bodyPath.addCurve(
                    to: CGPoint(x: w * 0.93, y: h * 0.56),
                    control1: CGPoint(x: w * 0.78, y: h * 0.18),
                    control2: CGPoint(x: w * 0.96, y: h * 0.34)
                )
                bodyPath.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.94),
                    control1: CGPoint(x: w * 0.90, y: h * 0.82),
                    control2: CGPoint(x: w * 0.72, y: h * 0.96)
                )
                bodyPath.addCurve(
                    to: CGPoint(x: w * 0.07, y: h * 0.56),
                    control1: CGPoint(x: w * 0.28, y: h * 0.96),
                    control2: CGPoint(x: w * 0.10, y: h * 0.82)
                )
                bodyPath.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.24),
                    control1: CGPoint(x: w * 0.04, y: h * 0.34),
                    control2: CGPoint(x: w * 0.22, y: h * 0.18)
                )
                bodyPath.closeSubpath()

                context.fill(
                    bodyPath,
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 1.00, green: 0.30, blue: 0.11),
                            Color(red: 0.95, green: 0.17, blue: 0.04),
                            Color(red: 0.82, green: 0.10, blue: 0.03)
                        ]),
                        center: CGPoint(x: w * 0.36, y: h * 0.42),
                        startRadius: w * 0.05,
                        endRadius: w * 0.56
                    )
                )

                // Green star calyx & short stem
                var calyx = Path()
                calyx.move(to: CGPoint(x: w * 0.46, y: h * 0.06))
                calyx.addLine(to: CGPoint(x: w * 0.53, y: h * 0.19))
                calyx.addLine(to: CGPoint(x: w * 0.72, y: h * 0.15))
                calyx.addLine(to: CGPoint(x: w * 0.58, y: h * 0.26))
                calyx.addLine(to: CGPoint(x: w * 0.67, y: h * 0.36))
                calyx.addLine(to: CGPoint(x: w * 0.49, y: h * 0.29))
                calyx.addLine(to: CGPoint(x: w * 0.34, y: h * 0.39))
                calyx.addLine(to: CGPoint(x: w * 0.38, y: h * 0.27))
                calyx.addLine(to: CGPoint(x: w * 0.23, y: h * 0.25))
                calyx.addLine(to: CGPoint(x: w * 0.40, y: h * 0.19))
                calyx.closeSubpath()
                context.fill(calyx, with: .color(Color(red: 0.09, green: 0.72, blue: 0.26)))
            } else {
                // Classic green rotten splat
                let cx = w * 0.5
                let cy = h * 0.52
                var splat = Path()
                let lobes = 7
                for i in 0..<(lobes * 2) {
                    let angle = (Double(i) / Double(lobes * 2)) * .pi * 2.0 - .pi / 2.0
                    let r = (i % 2 == 0) ? (w * 0.43) : (w * 0.22)
                    let pt = CGPoint(x: cx + CGFloat(cos(angle)) * r, y: cy + CGFloat(sin(angle)) * r)
                    if i == 0 { splat.move(to: pt) } else { splat.addLine(to: pt) }
                }
                splat.closeSubpath()
                context.fill(splat, with: .color(Color(red: 0.31, green: 0.74, blue: 0.27)))

                let drop1 = Path(ellipseIn: CGRect(x: w * 0.78, y: h * 0.14, width: w * 0.14, height: h * 0.14))
                let drop2 = Path(ellipseIn: CGRect(x: w * 0.10, y: h * 0.76, width: w * 0.12, height: h * 0.12))
                context.fill(drop1, with: .color(Color(red: 0.31, green: 0.74, blue: 0.27)))
                context.fill(drop2, with: .color(Color(red: 0.31, green: 0.74, blue: 0.27)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Rotten Tomatoes Critics")
    }
}

// MARK: - 4. Rotten Tomatoes Audience (Popcorn Bucket)

private struct RottenTomatoesAudienceIcon: View {
    let isFresh: Bool
    let size: CGFloat
    let isLightSurface: Bool

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height

            let primaryStripe = isFresh
                ? Color(red: 0.88, green: 0.16, blue: 0.13)
                : Color(red: 0.43, green: 0.66, blue: 0.30)
            let puffMain = isFresh
                ? Color(red: 1.00, green: 0.84, blue: 0.16)
                : Color(red: 0.72, green: 0.82, blue: 0.46)
            let puffShade = isFresh
                ? Color(red: 0.90, green: 0.66, blue: 0.04)
                : Color(red: 0.55, green: 0.66, blue: 0.32)

            // Fluffy popcorn puffs crowning the bucket
            let puffs: [(CGFloat, CGFloat, CGFloat)] = [
                (0.32, 0.26, 0.24),
                (0.52, 0.19, 0.28),
                (0.70, 0.27, 0.23),
                (0.24, 0.34, 0.20),
                (0.76, 0.35, 0.20),
                (0.47, 0.32, 0.26)
            ]
            for (px, py, pr) in puffs {
                let rect = CGRect(x: w * (px - pr * 0.5), y: h * (py - pr * 0.5), width: w * pr, height: h * pr)
                context.fill(Path(ellipseIn: rect), with: .color(puffMain))
            }
            // Subtle shadow dimples for popcorn depth
            let dimples: [(CGFloat, CGFloat, CGFloat)] = [
                (0.41, 0.29, 0.07),
                (0.61, 0.28, 0.07),
                (0.51, 0.22, 0.06)
            ]
            for (dx, dy, dr) in dimples {
                let rect = CGRect(x: w * (dx - dr * 0.5), y: h * (dy - dr * 0.5), width: w * dr, height: h * dr)
                context.fill(Path(ellipseIn: rect), with: .color(puffShade.opacity(0.65)))
            }

            // Tapered bucket silhouette
            var bucket = Path()
            bucket.move(to: CGPoint(x: w * 0.16, y: h * 0.38))
            bucket.addLine(to: CGPoint(x: w * 0.84, y: h * 0.38))
            bucket.addLine(to: CGPoint(x: w * 0.75, y: h * 0.91))
            bucket.addQuadCurve(to: CGPoint(x: w * 0.68, y: h * 0.95), control: CGPoint(x: w * 0.74, y: h * 0.95))
            bucket.addLine(to: CGPoint(x: w * 0.32, y: h * 0.95))
            bucket.addQuadCurve(to: CGPoint(x: w * 0.25, y: h * 0.91), control: CGPoint(x: w * 0.26, y: h * 0.95))
            bucket.closeSubpath()

            context.drawLayer { layerCtx in
                layerCtx.clip(to: bucket)
                layerCtx.fill(bucket, with: .color(.white))

                // 3 crisp vertical stripes inside tapered bucket
                let stripeCount = 5
                for i in stride(from: 0, to: stripeCount, by: 2) {
                    let topL = w * (0.16 + 0.68 * CGFloat(i) / CGFloat(stripeCount))
                    let topR = w * (0.16 + 0.68 * CGFloat(i + 1) / CGFloat(stripeCount))
                    let botL = w * (0.25 + 0.50 * CGFloat(i) / CGFloat(stripeCount))
                    let botR = w * (0.25 + 0.50 * CGFloat(i + 1) / CGFloat(stripeCount))
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: topL, y: h * 0.38))
                    stripe.addLine(to: CGPoint(x: topR, y: h * 0.38))
                    stripe.addLine(to: CGPoint(x: botR, y: h * 0.95))
                    stripe.addLine(to: CGPoint(x: botL, y: h * 0.95))
                    stripe.closeSubpath()
                    layerCtx.fill(stripe, with: .color(primaryStripe))
                }
            }

            // Crisp rim highlight & subtle outline for Light Mode contrast
            context.stroke(
                bucket,
                with: .color(isLightSurface ? Color.black.opacity(0.24) : Color.black.opacity(0.32)),
                lineWidth: 0.65
            )
            var rim = Path()
            rim.move(to: CGPoint(x: w * 0.14, y: h * 0.38))
            rim.addLine(to: CGPoint(x: w * 0.86, y: h * 0.38))
            context.stroke(rim, with: .color(primaryStripe), style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Rotten Tomatoes Audience")
    }
}

// MARK: - 5. Letterboxd Tri-Dot Dark Emblem

private struct LetterboxdBadgeIcon: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height
            let bgRect = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
            context.fill(Path(ellipseIn: bgRect), with: .color(Color(red: 0.12, green: 0.15, blue: 0.18)))

            let dotD = w * 0.285
            let y = (h - dotD) * 0.5
            let centersX: [CGFloat] = [w * 0.27, w * 0.50, w * 0.73]
            let colors: [Color] = [
                Color(red: 1.00, green: 0.50, blue: 0.00), // Orange
                Color(red: 0.00, green: 0.88, blue: 0.33), // Green
                Color(red: 0.25, green: 0.74, blue: 0.96)  // Sky Blue
            ]

            for (cx, color) in zip(centersX, colors) {
                let rect = CGRect(x: cx - dotD * 0.5, y: y, width: dotD, height: dotD)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Letterboxd")
    }
}

// MARK: - 6. Trakt Gradient Checkmark Emblem

private struct TraktBadgeIcon: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height
            let circleRect = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
            context.fill(
                Path(ellipseIn: circleRect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.96, green: 0.11, blue: 0.17),
                        Color(red: 0.83, green: 0.13, blue: 0.47),
                        Color(red: 0.60, green: 0.15, blue: 0.73)
                    ]),
                    startPoint: CGPoint(x: w * 0.10, y: h * 0.90),
                    endPoint: CGPoint(x: w * 0.90, y: h * 0.10)
                )
            )

            // White inner ring arc
            let center = CGPoint(x: w * 0.5, y: h * 0.5)
            let ringR = w * 0.36
            var ring = Path()
            ring.addArc(
                center: center,
                radius: ringR,
                startAngle: .degrees(-18),
                endAngle: .degrees(305),
                clockwise: false
            )
            context.stroke(ring, with: .color(.white.opacity(0.94)), style: StrokeStyle(lineWidth: w * 0.068, lineCap: .round))

            // Iconic crisp Trakt angled checkmark
            var check = Path()
            check.move(to: CGPoint(x: w * 0.33, y: h * 0.50))
            check.addLine(to: CGPoint(x: w * 0.46, y: h * 0.63))
            check.addLine(to: CGPoint(x: w * 0.78, y: h * 0.29))
            context.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: w * 0.095, lineCap: .round, lineJoin: .round))

            // Subtle parallel inner highlight stroke echoing Trakt's double-line mark
            var innerTick = Path()
            innerTick.move(to: CGPoint(x: w * 0.45, y: h * 0.46))
            innerTick.addLine(to: CGPoint(x: w * 0.70, y: h * 0.20))
            context.stroke(innerTick, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: w * 0.048, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Trakt")
    }
}

// MARK: - 7. Metacritic Yellow-Ring Angled "m" Emblem

private struct MetacriticBadgeIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.08, green: 0.10, blue: 0.13))
            Circle()
                .strokeBorder(Color(red: 1.00, green: 0.80, blue: 0.20), lineWidth: max(1.7, size * 0.115))
            Text("m")
                .font(.system(size: size * 0.62, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: -size * 0.03)
                .rotationEffect(.degrees(-42))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Metacritic")
    }
}

import SwiftUI
import DonbyCore
import DonbyNetwork

public struct DonbyCardAppearance: Equatable, Sendable {
    public let server: EmbyServerConfig?
    public let isLightMode: Bool
    public let accentColor: Color
    public let accentTextColor: Color
    public let showResolutionBadge: Bool
    public let showRatingBadge: Bool
    public let isMonochromeTheme: Bool

    public init(
        server: EmbyServerConfig?,
        isLightMode: Bool,
        accentColor: Color,
        accentTextColor: Color,
        showResolutionBadge: Bool,
        showRatingBadge: Bool,
        isMonochromeTheme: Bool = false
    ) {
        self.server = server
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
        self.showResolutionBadge = showResolutionBadge
        self.showRatingBadge = showRatingBadge
        self.isMonochromeTheme = isMonochromeTheme
    }

    public var hidesLibraryTextOverlay: Bool {
        server?.usesUHDLogo == true
    }

    public static func == (lhs: DonbyCardAppearance, rhs: DonbyCardAppearance) -> Bool {
        lhs.server?.id == rhs.server?.id &&
        lhs.server?.activeBaseURL == rhs.server?.activeBaseURL &&
        lhs.server?.accessToken == rhs.server?.accessToken &&
        lhs.server?.usesUHDLogo == rhs.server?.usesUHDLogo &&
        lhs.isLightMode == rhs.isLightMode &&
        lhs.accentColor == rhs.accentColor &&
        lhs.accentTextColor == rhs.accentTextColor &&
        lhs.showResolutionBadge == rhs.showResolutionBadge &&
        lhs.showRatingBadge == rhs.showRatingBadge &&
        lhs.isMonochromeTheme == rhs.isMonochromeTheme
    }
}

private struct PosterHoverOverlay: View {
    let cornerRadius: CGFloat
    let borderDefaultColor: Color
    let accentColor: Color
    let showPlayButton: Bool
    let playCircleSize: CGFloat
    let playIconSize: CGFloat
    let onPlay: (() -> Void)?

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack {
            if isHovered && showPlayButton, let onPlay {
                Color.black.opacity(0.22)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                Button(action: onPlay) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.62))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.32), lineWidth: 0.75))
                            .frame(width: playCircleSize, height: playCircleSize)
                        Image(systemName: "play.fill")
                            .font(.system(size: playIconSize, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                }
                .buttonStyle(.plain)
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isHovered ? accentColor.opacity(0.88) : borderDefaultColor,
                    lineWidth: isHovered ? 1.5 : 0.65
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovered in
            if isHovered != hovered {
                isHovered = hovered
            }
        }
    }
}

// MARK: - High-Performance Fractional Progress Bar (Zero GeometryReader Layout Invalidation)
public struct FractionalProgressBar: View {
    public var fraction: Double
    public var color: Color
    public var height: CGFloat = 3.0
    public var trackColor: Color = Color.white.opacity(0.28)

    public init(fraction: Double, color: Color, height: CGFloat = 3.0, trackColor: Color = Color.white.opacity(0.28)) {
        self.fraction = fraction
        self.color = color
        self.height = height
        self.trackColor = trackColor
    }

    public var body: some View {
        Capsule()
            .fill(trackColor)
            .overlay(
                Capsule()
                    .fill(color)
                    .scaleEffect(x: CGFloat(max(0.0, min(1.0, fraction))), y: 1.0, anchor: .leading)
            )
            .clipShape(Capsule())
            .frame(height: height)
    }
}

// MARK: - Native Poster Card
public struct PosterCardView: View, Equatable {
    public let item: EmbyItem
    public var width: CGFloat? = nil
    public let appearance: DonbyCardAppearance
    public var onSelect: () -> Void
    public var onPlay: (() -> Void)? = nil

    private var targetWidth: CGFloat { width ?? 152 }
    private var targetHeight: CGFloat { targetWidth * 1.5 }

    public init(
        item: EmbyItem,
        width: CGFloat? = nil,
        appearance: DonbyCardAppearance,
        onSelect: @escaping () -> Void,
        onPlay: (() -> Void)? = nil
    ) {
        self.item = item
        self.width = width
        self.appearance = appearance
        self.onSelect = onSelect
        self.onPlay = onPlay
    }

    public static func == (lhs: PosterCardView, rhs: PosterCardView) -> Bool {
        lhs.item == rhs.item &&
        lhs.width == rhs.width &&
        lhs.appearance == rhs.appearance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                MediaArtworkView(server: appearance.server, item: item, kind: .primary, maxWidth: 360)
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
                        if appearance.showResolutionBadge, let resBadge = item.resolutionBadge {
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
                                .foregroundStyle(appearance.accentTextColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(appearance.accentColor)
                                .clipShape(Capsule())
                        } else if item.userData?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(appearance.accentColor)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                    }
                    .padding(7)

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if appearance.showRatingBadge, let rating = item.communityRating, rating > 0 {
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
                            FractionalProgressBar(fraction: item.progressFraction, color: appearance.accentColor, height: 3)
                        }
                    }
                    .padding(7)
                }

                PosterHoverOverlay(
                    cornerRadius: 10,
                    borderDefaultColor: Color.white.opacity(0.06),
                    accentColor: appearance.accentColor,
                    showPlayButton: onPlay != nil,
                    playCircleSize: 40,
                    playIconSize: 15,
                    onPlay: onPlay
                )
            }
            .frame(width: targetWidth, height: targetHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appearance.isLightMode))
                    .lineLimit(1)

                Text(item.displaySubtitle.isEmpty ? (item.isSeries ? "剧集" : "电影") : item.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appearance.isLightMode))
                    .lineLimit(1)
            }
            .frame(width: targetWidth, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Native Landscape Card
public struct LandscapeCardView: View, Equatable {
    public let item: EmbyItem
    public var width: CGFloat = 248
    public var subtitleOverride: String? = nil
    public let appearance: DonbyCardAppearance
    public var onPlay: () -> Void
    public var onDetail: () -> Void

    private var height: CGFloat { width * 9.0 / 16.0 }

    public init(
        item: EmbyItem,
        width: CGFloat = 248,
        subtitleOverride: String? = nil,
        appearance: DonbyCardAppearance,
        onPlay: @escaping () -> Void,
        onDetail: @escaping () -> Void
    ) {
        self.item = item
        self.width = width
        self.subtitleOverride = subtitleOverride
        self.appearance = appearance
        self.onPlay = onPlay
        self.onDetail = onDetail
    }

    public static func == (lhs: LandscapeCardView, rhs: LandscapeCardView) -> Bool {
        lhs.item == rhs.item &&
        lhs.width == rhs.width &&
        lhs.subtitleOverride == rhs.subtitleOverride &&
        lhs.appearance == rhs.appearance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                MediaArtworkView(server: appearance.server, item: item, kind: .thumb, maxWidth: 500)
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
                        FractionalProgressBar(fraction: item.progressFraction, color: appearance.accentColor, height: 3.5)
                            .padding(8)
                    }
                }

                PosterHoverOverlay(
                    cornerRadius: 10,
                    borderDefaultColor: Color.white.opacity(0.06),
                    accentColor: appearance.accentColor,
                    showPlayButton: true,
                    playCircleSize: 36,
                    playIconSize: 13,
                    onPlay: onPlay
                )
            }
            .frame(width: width, height: height)
            .onTapGesture { onPlay() }

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isEpisode ? (item.seriesName ?? item.name) : item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appearance.isLightMode))
                        .lineLimit(1)

                    Text(subtitleOverride ?? (item.isEpisode ? item.name : item.displaySubtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appearance.isLightMode))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appearance.isLightMode))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("查看作品详情")
            }
            .frame(width: width)
        }
    }
}

// MARK: - Native Library Card
public struct LibraryCardView: View, Equatable {
    public let library: EmbyItem
    public let itemCount: Int?
    public let appearance: DonbyCardAppearance
    public let action: () -> Void

    private var hidesTextOverlay: Bool {
        appearance.hidesLibraryTextOverlay
    }

    private var artworkKind: EmbyImageKind {
        (library.backdropImageTags?.isEmpty == false) ? .backdrop : .primary
    }

    public init(
        library: EmbyItem,
        itemCount: Int?,
        appearance: DonbyCardAppearance,
        action: @escaping () -> Void
    ) {
        self.library = library
        self.itemCount = itemCount
        self.appearance = appearance
        self.action = action
    }

    public static func == (lhs: LibraryCardView, rhs: LibraryCardView) -> Bool {
        lhs.library == rhs.library &&
        lhs.itemCount == rhs.itemCount &&
        lhs.appearance == rhs.appearance
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(server: appearance.server, item: library, kind: artworkKind, maxWidth: 440)
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

                PosterHoverOverlay(
                    cornerRadius: 12,
                    borderDefaultColor: appearance.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08),
                    accentColor: Color.white.opacity(0.50),
                    showPlayButton: false,
                    playCircleSize: 36,
                    playIconSize: 13,
                    onPlay: nil
                )
            }
            .frame(width: 205, height: 112)
        }
        .buttonStyle(.plain)
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

import SwiftUI
import DonbyCore

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
                                .foregroundStyle(appState.accentTextColor)
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

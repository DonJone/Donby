import SwiftUI

/// Standard page/tab header with 18pt bold title and 12pt secondary subtitle.
public struct DonbySettingsSectionHeader: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public let subtitle: String
    public var isLightModeOverride: Bool? = nil

    public init(title: String, subtitle: String, isLightMode: Bool? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.isLightModeOverride = isLightMode
    }

    public var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
        }
    }
}

/// Full-width settings card container matching Donby's 12pt radius and subtle border.
public struct DonbySettingsCard<Content: View>: View {
    @Environment(\.donbyTheme) private var theme
    public var alignment: HorizontalAlignment
    public var spacing: CGFloat
    public var padding: CGFloat
    public var isLightModeOverride: Bool?
    @ViewBuilder public let content: () -> Content

    public init(
        alignment: HorizontalAlignment = .leading,
        spacing: CGFloat = 14,
        padding: CGFloat = 18,
        isLightMode: Bool? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.padding = padding
        self.isLightModeOverride = isLightMode
        self.content = content
    }

    public var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode
        VStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .padding(padding)
        .background(DonbyGlassPalette.cardBackground(isLight: isLight))
        .clipShape(RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: 0.6)
        )
    }
}

/// Standard two-column settings row (title + optional subtitle on the left, trailing control on the right).
public struct DonbySettingsRow<Trailing: View>: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public var subtitle: String? = nil
    public var showsDivider: Bool = false
    @ViewBuilder public let trailing: () -> Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        showsDivider: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsDivider = showsDivider
        self.trailing = trailing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.primaryText)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }

            if showsDivider {
                Divider().opacity(0.12)
            }
        }
    }
}

/// Standard sidebar/settings tab row (34pt height, 8pt radius, accent fill when selected).
public struct DonbySidebarTabRow: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public let systemImage: String
    public let isSelected: Bool
    public var showBadgeDot: Bool = false
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        title: String,
        systemImage: String,
        isSelected: Bool,
        showBadgeDot: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.showBadgeDot = showBadgeDot
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? theme.accentTextColor : (isHovered ? theme.primaryText : theme.secondaryText))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.accentTextColor : theme.primaryText)
                Spacer()
                if showBadgeDot {
                    Circle()
                        .fill(isSelected ? theme.accentTextColor : theme.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accentColor)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.07))
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Canonical selectable option row with circular checkmark indicator, subtitle, and trailing accessory.
public struct DonbySelectableRow<Trailing: View>: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public var subtitle: String? = nil
    public let isSelected: Bool
    public let action: () -> Void
    @ViewBuilder public let trailing: () -> Trailing

    @State private var isHovered: Bool = false

    public init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
        self.trailing = trailing
    }

    private var rowBackground: Color {
        if isSelected {
            return theme.accentColor.opacity(theme.isLightMode ? 0.08 : 0.14)
        } else if isHovered {
            return DonbyGlassPalette.hoverFill(isLight: theme.isLightMode)
        }
        return theme.cardBackground
    }

    private var rowBorderColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.40)
        } else if isHovered {
            return theme.separator.opacity(1.3)
        }
        return theme.separator
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if isSelected {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .foregroundStyle(theme.accentTextColor)
                            )
                    } else {
                        Circle()
                            .strokeBorder(theme.separator, lineWidth: DonbyDesignTokens.Stroke.focus)
                            .frame(width: 16, height: 16)
                    }

                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9.5)
        .background(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.row, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.row, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: isSelected ? 0.9 : 0.65)
        )
        .onHover { isHovered = $0 }
    }
}

/// Canonical modal sheet shell combining Donby header typography, close button, and footer slot.
public struct DonbySheetContainer<Content: View, Footer: View>: View {
    @Environment(\.donbyTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    public var eyebrow: String?
    public let title: String
    public var subtitle: String?
    public var padding: CGFloat
    @ViewBuilder public let content: () -> Content
    @ViewBuilder public let footer: () -> Footer

    public init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        padding: CGFloat = 22,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.padding = padding
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let eyebrow, !eyebrow.isEmpty {
                        Text(eyebrow)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                    }
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            content()

            footer()
        }
        .padding(padding)
        .background(theme.canvas)
        .tint(theme.accentColor)
    }
}

/// Canonical dark cinema drawer card shared across player-style dark overlay drawers.
public struct PlayerDrawerGlassCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.card, style: .continuous)
                .fill(DonbyGlassPalette.darkCinemaCardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DonbyGlassPalette.darkCinemaCardBorder, lineWidth: DonbyDesignTokens.Stroke.standard)
        )
    }
}

/// Canonical dark cinema drawer row background for selected/unselected items.
public struct PlayerDrawerRowBackground: View {
    public let isSelected: Bool
    public let isMonochromeTheme: Bool
    public let accentColor: Color

    public init(isSelected: Bool, isMonochromeTheme: Bool, accentColor: Color) {
        self.isSelected = isSelected
        self.isMonochromeTheme = isMonochromeTheme
        self.accentColor = accentColor
    }

    public var body: some View {
        let fill: Color = {
            if !isSelected { return Color.white.opacity(0.045) }
            return isMonochromeTheme ? Color.white.opacity(0.18) : accentColor.opacity(0.24)
        }()
        let stroke: Color = {
            if !isSelected { return Color.white.opacity(0.06) }
            return isMonochromeTheme ? Color.white.opacity(0.36) : accentColor.opacity(0.68)
        }()
        RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.row, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.row, style: .continuous)
                    .strokeBorder(stroke, lineWidth: isSelected ? DonbyDesignTokens.Stroke.active : 0.55)
            )
    }
}

/// Standard centered empty state view with subtle icon well and optional action button.
public struct DonbyEmptyStateView: View {
    @Environment(\.donbyTheme) private var theme
    public let systemImage: String
    public let title: String
    public var message: String? = nil
    public var actionTitle: String? = nil
    public var action: (() -> Void)? = nil

    public init(
        systemImage: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.cardBackground)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Circle()
                            .strokeBorder(theme.separator, lineWidth: DonbyDesignTokens.Stroke.standard)
                    )
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionTitle, let action {
                DonbyPrimaryActionButton(title: actionTitle, action: action)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Standard themed loading state view.
public struct DonbyLoadingStateView: View {
    @Environment(\.donbyTheme) private var theme
    public var message: String? = nil

    public init(message: String? = nil) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(theme.accentColor)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

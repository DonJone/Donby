import SwiftUI
import AppKit

/// Optical Visual Effect View for sidebar translucency and desktop-bleed.
public struct DonbyVisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .sidebar
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    public init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
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

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Groups nearby Liquid Glass controls into a shared WindowServer refraction & batching field on macOS 26+.
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
                        // Dark mode omits .ultraThinMaterial to prevent Light Mode NSVisualEffectView frost leakage.
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.11, green: 0.115, blue: 0.135).opacity(isHovered ? 0.94 : 0.88))
                    }
                }
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        tint != nil
                            ? Color.white.opacity(0.18)
                            : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(isHovered ? 0.16 : 0.10)),
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
                        // Dark mode omits .ultraThinMaterial to prevent Light Mode NSVisualEffectView frost leakage.
                        shape.fill(Color(red: 0.11, green: 0.115, blue: 0.135).opacity(isHovered ? 0.94 : 0.88))
                    }
                }
                .clipShape(shape)
            )
            .overlay(
                shape.strokeBorder(
                    tint != nil
                        ? Color.white.opacity(0.18)
                        : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(isHovered ? 0.16 : 0.10)),
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

/// Non-observable hover signal bridge so hovering a Menu trigger updates detached visual chrome
/// without re-evaluating `Menu { menuContent() }` (preserving macOS NSMenu stability & full custom chrome).
public final class DonbyMenuHoverBox {
    private var current: Bool = false
    public var onHoverChange: ((Bool) -> Void)?

    public init() {}

    public func setHovered(_ next: Bool) {
        guard current != next else { return }
        current = next
        onHoverChange?(next)
    }

    public var isHovered: Bool { current }
}

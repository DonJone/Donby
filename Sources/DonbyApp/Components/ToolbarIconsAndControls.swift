import SwiftUI

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

/// Custom geometric vector icon for Downloads (matches RouteSwitchVectorIcon & RefreshVectorIcon stroke geometry)
public struct DownloadVectorIcon: View {
    public enum State: Equatable {
        case idle
        case active(progress: Double)
        case paused
        case completed
        case locked
    }

    public var state: State = .idle
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)

    public init(state: State = .idle, size: CGFloat = 15, color: Color = Color(white: 0.90)) {
        self.state = state
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.35, w * 0.105)
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            switch state {
            case .idle:
                // Minimalist rounded U-tray at bottom + crisp geometric download arrow
                var tray = Path()
                tray.move(to: CGPoint(x: w * 0.17, y: h * 0.62))
                tray.addLine(to: CGPoint(x: w * 0.17, y: h * 0.77))
                tray.addQuadCurve(
                    to: CGPoint(x: w * 0.29, y: h * 0.85),
                    control: CGPoint(x: w * 0.17, y: h * 0.85)
                )
                tray.addLine(to: CGPoint(x: w * 0.71, y: h * 0.85))
                tray.addQuadCurve(
                    to: CGPoint(x: w * 0.83, y: h * 0.77),
                    control: CGPoint(x: w * 0.83, y: h * 0.85)
                )
                tray.addLine(to: CGPoint(x: w * 0.83, y: h * 0.62))
                context.stroke(tray, with: .color(color), style: stroke)

                var arrow = Path()
                arrow.move(to: CGPoint(x: w * 0.50, y: h * 0.15))
                arrow.addLine(to: CGPoint(x: w * 0.50, y: h * 0.64))
                arrow.move(to: CGPoint(x: w * 0.30, y: h * 0.46))
                arrow.addLine(to: CGPoint(x: w * 0.50, y: h * 0.65))
                arrow.addLine(to: CGPoint(x: w * 0.70, y: h * 0.46))
                context.stroke(arrow, with: .color(color), style: stroke)

            case .active(let progress):
                let c = CGPoint(x: w * 0.5, y: h * 0.5)
                let r = w * 0.40
                let clamped = min(1.0, max(0.06, progress))

                var track = Path()
                track.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(color.opacity(0.22)), style: StrokeStyle(lineWidth: lw * 0.92, lineCap: .round))

                var arc = Path()
                arc.addArc(
                    center: c,
                    radius: r,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360.0 * clamped),
                    clockwise: false
                )
                context.stroke(arc, with: .color(color), style: stroke)

                var arrow = Path()
                arrow.move(to: CGPoint(x: w * 0.50, y: h * 0.28))
                arrow.addLine(to: CGPoint(x: w * 0.50, y: h * 0.68))
                arrow.move(to: CGPoint(x: w * 0.35, y: h * 0.53))
                arrow.addLine(to: CGPoint(x: w * 0.50, y: h * 0.68))
                arrow.addLine(to: CGPoint(x: w * 0.65, y: h * 0.53))
                context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.95, lineCap: .round, lineJoin: .round))

            case .paused:
                let c = CGPoint(x: w * 0.5, y: h * 0.5)
                let r = w * 0.40
                var ring = Path()
                ring.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.stroke(ring, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: lw * 0.92, lineCap: .round))

                var bars = Path()
                bars.move(to: CGPoint(x: w * 0.40, y: h * 0.34))
                bars.addLine(to: CGPoint(x: w * 0.40, y: h * 0.66))
                bars.move(to: CGPoint(x: w * 0.60, y: h * 0.34))
                bars.addLine(to: CGPoint(x: w * 0.60, y: h * 0.66))
                context.stroke(bars, with: .color(color), style: stroke)

            case .completed:
                var tray = Path()
                tray.move(to: CGPoint(x: w * 0.17, y: h * 0.64))
                tray.addLine(to: CGPoint(x: w * 0.17, y: h * 0.77))
                tray.addQuadCurve(
                    to: CGPoint(x: w * 0.29, y: h * 0.85),
                    control: CGPoint(x: w * 0.17, y: h * 0.85)
                )
                tray.addLine(to: CGPoint(x: w * 0.71, y: h * 0.85))
                tray.addQuadCurve(
                    to: CGPoint(x: w * 0.83, y: h * 0.77),
                    control: CGPoint(x: w * 0.83, y: h * 0.85)
                )
                tray.addLine(to: CGPoint(x: w * 0.83, y: h * 0.64))
                context.stroke(tray, with: .color(color), style: stroke)

                var check = Path()
                check.move(to: CGPoint(x: w * 0.29, y: h * 0.44))
                check.addLine(to: CGPoint(x: w * 0.45, y: h * 0.60))
                check.addLine(to: CGPoint(x: w * 0.73, y: h * 0.27))
                context.stroke(check, with: .color(color), style: stroke)

            case .locked:
                let bodyRect = CGRect(x: w * 0.23, y: h * 0.46, width: w * 0.54, height: h * 0.38)
                let bodyPath = Path(roundedRect: bodyRect, cornerRadius: w * 0.10)
                context.stroke(bodyPath, with: .color(color), style: stroke)

                var shackle = Path()
                shackle.move(to: CGPoint(x: w * 0.34, y: h * 0.46))
                shackle.addLine(to: CGPoint(x: w * 0.34, y: h * 0.33))
                shackle.addArc(
                    center: CGPoint(x: w * 0.50, y: h * 0.33),
                    radius: w * 0.16,
                    startAngle: .degrees(180),
                    endAngle: .degrees(0),
                    clockwise: false
                )
                shackle.addLine(to: CGPoint(x: w * 0.66, y: h * 0.46))
                context.stroke(shackle, with: .color(color), style: stroke)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Custom 2x2 Poster Grid vector icon
public struct GridWallVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.10)
            let cellW = w * 0.31
            let cellH = h * 0.31
            let cr = w * 0.075
            let coords: [(CGFloat, CGFloat)] = [
                (w * 0.14, h * 0.14),
                (w * 0.55, h * 0.14),
                (w * 0.14, h * 0.55),
                (w * 0.55, h * 0.55)
            ]
            for (x, y) in coords {
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                context.stroke(Path(roundedRect: rect, cornerRadius: cr), with: .color(color), style: StrokeStyle(lineWidth: lw))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Custom minimalist Folder vector icon
public struct FolderVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.102)
            var p = Path()
            p.move(to: CGPoint(x: w * 0.13, y: h * 0.28))
            p.addQuadCurve(to: CGPoint(x: w * 0.21, y: h * 0.20), control: CGPoint(x: w * 0.13, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.39, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.48, y: h * 0.31))
            p.addLine(to: CGPoint(x: w * 0.79, y: h * 0.31))
            p.addQuadCurve(to: CGPoint(x: w * 0.87, y: h * 0.39), control: CGPoint(x: w * 0.87, y: h * 0.31))
            p.addLine(to: CGPoint(x: w * 0.87, y: h * 0.73))
            p.addQuadCurve(to: CGPoint(x: w * 0.79, y: h * 0.81), control: CGPoint(x: w * 0.87, y: h * 0.81))
            p.addLine(to: CGPoint(x: w * 0.21, y: h * 0.81))
            p.addQuadCurve(to: CGPoint(x: w * 0.13, y: h * 0.73), control: CGPoint(x: w * 0.13, y: h * 0.81))
            p.closeSubpath()
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Custom Finder / Reveal External Folder vector icon (replaces stock "macwindow")
public struct FinderRevealVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.102)
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            var box = Path()
            box.move(to: CGPoint(x: w * 0.46, y: h * 0.18))
            box.addLine(to: CGPoint(x: w * 0.24, y: h * 0.18))
            box.addQuadCurve(to: CGPoint(x: w * 0.15, y: h * 0.27), control: CGPoint(x: w * 0.15, y: h * 0.18))
            box.addLine(to: CGPoint(x: w * 0.15, y: h * 0.76))
            box.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.85), control: CGPoint(x: w * 0.15, y: h * 0.85))
            box.addLine(to: CGPoint(x: w * 0.73, y: h * 0.85))
            box.addQuadCurve(to: CGPoint(x: w * 0.82, y: h * 0.76), control: CGPoint(x: w * 0.82, y: h * 0.85))
            box.addLine(to: CGPoint(x: w * 0.82, y: h * 0.54))
            context.stroke(box, with: .color(color), style: stroke)

            var arrow = Path()
            arrow.move(to: CGPoint(x: w * 0.45, y: h * 0.55))
            arrow.addLine(to: CGPoint(x: w * 0.84, y: h * 0.16))
            arrow.move(to: CGPoint(x: w * 0.60, y: h * 0.16))
            arrow.addLine(to: CGPoint(x: w * 0.84, y: h * 0.16))
            arrow.addLine(to: CGPoint(x: w * 0.84, y: h * 0.40))
            context.stroke(arrow, with: .color(color), style: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Custom Sort & Filter dual opposite vertical arrows vector icon
public struct SortArrowsVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.102)
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            var p = Path()
            // Left upward arrow
            p.move(to: CGPoint(x: w * 0.32, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.20))
            p.move(to: CGPoint(x: w * 0.17, y: h * 0.36))
            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.47, y: h * 0.36))

            // Right downward arrow
            p.move(to: CGPoint(x: w * 0.68, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.80))
            p.move(to: CGPoint(x: w * 0.53, y: h * 0.64))
            p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.83, y: h * 0.64))

            context.stroke(p, with: .color(color), style: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Custom geometric Play triangle vector icon
public struct PlayVectorIcon: View {
    public var size: CGFloat = 12.5
    public var color: Color = .white
    public init(size: CGFloat = 12.5, color: Color = .white) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            var p = Path()
            p.move(to: CGPoint(x: w * 0.24, y: h * 0.16))
            p.addLine(to: CGPoint(x: w * 0.84, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.84))
            p.closeSubpath()
            context.fill(p, with: .color(color))
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(1.0, w * 0.08), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Custom geometric Pause twin bars vector icon
public struct PauseVectorIcon: View {
    public var size: CGFloat = 12.5
    public var color: Color = Color(white: 0.90)
    public init(size: CGFloat = 12.5, color: Color = Color(white: 0.90)) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.6, w * 0.14)
            var p = Path()
            p.move(to: CGPoint(x: w * 0.34, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.80))
            p.move(to: CGPoint(x: w * 0.66, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.80))
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Custom minimalist Trash vector icon
public struct TrashVectorIcon: View {
    public var size: CGFloat = 14
    public var color: Color = .red
    public init(size: CGFloat = 14, color: Color = .red) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.25, w * 0.098)
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            var lid = Path()
            lid.move(to: CGPoint(x: w * 0.18, y: h * 0.26))
            lid.addLine(to: CGPoint(x: w * 0.82, y: h * 0.26))
            lid.move(to: CGPoint(x: w * 0.38, y: h * 0.26))
            lid.addLine(to: CGPoint(x: w * 0.38, y: h * 0.16))
            lid.addLine(to: CGPoint(x: w * 0.62, y: h * 0.16))
            lid.addLine(to: CGPoint(x: w * 0.62, y: h * 0.26))
            context.stroke(lid, with: .color(color), style: stroke)

            var bin = Path()
            bin.move(to: CGPoint(x: w * 0.25, y: h * 0.28))
            bin.addLine(to: CGPoint(x: w * 0.29, y: h * 0.81))
            bin.addQuadCurve(to: CGPoint(x: w * 0.38, y: h * 0.86), control: CGPoint(x: w * 0.29, y: h * 0.86))
            bin.addLine(to: CGPoint(x: w * 0.62, y: h * 0.86))
            bin.addQuadCurve(to: CGPoint(x: w * 0.71, y: h * 0.81), control: CGPoint(x: w * 0.71, y: h * 0.86))
            bin.addLine(to: CGPoint(x: w * 0.75, y: h * 0.28))
            context.stroke(bin, with: .color(color), style: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Custom minimalist Bookmark / Keep Pin vector icon
public struct BookmarkVectorIcon: View {
    public var size: CGFloat = 14
    public var color: Color = .orange
    public init(size: CGFloat = 14, color: Color = .orange) { self.size = size; self.color = color }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.102)
            var p = Path()
            p.move(to: CGPoint(x: w * 0.24, y: h * 0.16))
            p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.16))
            p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.85))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.67))
            p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.85))
            p.closeSubpath()
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
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
                .donbyFocusEffectDisabled()
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
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
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

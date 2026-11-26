import SwiftUI

/// Custom vector icon for route/line switching (dual-route directional node switch).
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

/// Custom vector icon for refresh (twin-arc sync arrows with exact center rotation).
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

/// Custom 3-dot more icon.
public struct MoreDotsVectorIcon: View {
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
            let r = max(1.3, w * 0.095)
            for xf in [0.23, 0.50, 0.77] {
                let rect = CGRect(x: w * xf - r, y: h * 0.5 - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Custom geometric Plus icon.
public struct PlusVectorIcon: View {
    public var size: CGFloat = 14
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 14, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

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

/// Custom geometric vector icon for Downloads with 5 states.
public struct DownloadVectorIcon: View {
    public enum State: Equatable, Sendable {
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
                var tray = Path()
                tray.move(to: CGPoint(x: w * 0.17, y: h * 0.62))
                tray.addLine(to: CGPoint(x: w * 0.17, y: h * 0.77))
                tray.addQuadCurve(to: CGPoint(x: w * 0.29, y: h * 0.85), control: CGPoint(x: w * 0.17, y: h * 0.85))
                tray.addLine(to: CGPoint(x: w * 0.71, y: h * 0.85))
                tray.addQuadCurve(to: CGPoint(x: w * 0.83, y: h * 0.77), control: CGPoint(x: w * 0.83, y: h * 0.85))
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
                tray.addQuadCurve(to: CGPoint(x: w * 0.29, y: h * 0.85), control: CGPoint(x: w * 0.17, y: h * 0.85))
                tray.addLine(to: CGPoint(x: w * 0.71, y: h * 0.85))
                tray.addQuadCurve(to: CGPoint(x: w * 0.83, y: h * 0.77), control: CGPoint(x: w * 0.83, y: h * 0.85))
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

/// Custom 2x2 Poster Grid vector icon.
public struct GridWallVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

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

/// Custom minimalist Folder vector icon.
public struct FolderVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

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

/// Custom Finder / Reveal External Folder vector icon.
public struct FinderRevealVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

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

/// Custom Sort & Filter dual opposite vertical arrows vector icon.
public struct SortArrowsVectorIcon: View {
    public var size: CGFloat = 14.5
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 14.5, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.102)
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            var p = Path()
            p.move(to: CGPoint(x: w * 0.32, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.20))
            p.move(to: CGPoint(x: w * 0.17, y: h * 0.36))
            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.47, y: h * 0.36))

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

import SwiftUI

/// Custom geometric Play triangle vector icon.
public struct PlayVectorIcon: View {
    public var size: CGFloat = 12.5
    public var color: Color = .white

    public init(size: CGFloat = 12.5, color: Color = .white) {
        self.size = size
        self.color = color
    }

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

/// Custom geometric Pause twin bars vector icon.
public struct PauseVectorIcon: View {
    public var size: CGFloat = 12.5
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 12.5, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

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

/// Custom minimalist Trash vector icon.
public struct TrashVectorIcon: View {
    public var size: CGFloat = 14
    public var color: Color = .red

    public init(size: CGFloat = 14, color: Color = .red) {
        self.size = size
        self.color = color
    }

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

/// Custom minimalist Bookmark / Keep Pin vector icon.
public struct BookmarkVectorIcon: View {
    public var size: CGFloat = 14
    public var color: Color = .orange

    public init(size: CGFloat = 14, color: Color = .orange) {
        self.size = size
        self.color = color
    }

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

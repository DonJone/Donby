import AppKit
import CoreGraphics
import Foundation

func createEmblem(s: CGFloat, bodySize: CGFloat, cx: CGFloat, cy: CGFloat) -> CGPath {
    let scale = bodySize / 824.0
    let xOffset: CGFloat = 16.0 * scale
    let rOut: CGFloat = 48.0 * scale
    let rIn: CGFloat = 14.0 * scale

    let totalH = bodySize * 0.62
    let strokeW = bodySize * 0.118
    let dRadius = totalH * 0.5 - strokeW * 0.5
    let dLeft = (cx + xOffset) - bodySize * 0.230
    let dArcCenterX = (cx + xOffset) - bodySize * 0.040

    let openAngle: CGFloat = 0.28 * .pi

    let rOuterArc = dRadius + strokeW * 0.5
    let rInnerArc = dRadius - strokeW * 0.5
    let capRadius = strokeW * 0.5

    let topCenter = CGPoint(
        x: dArcCenterX + dRadius * cos(openAngle),
        y: cy + dRadius * sin(openAngle)
    )
    let btmCenter = CGPoint(
        x: dArcCenterX + dRadius * cos(-openAngle),
        y: cy + dRadius * sin(-openAngle)
    )

    let path = CGMutablePath()

    let topOuter = CGPoint(
        x: dArcCenterX + rOuterArc * cos(openAngle),
        y: cy + rOuterArc * sin(openAngle)
    )

    // Outer boundary:
    path.move(to: topOuter)
    path.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: rOuterArc,
        startAngle: openAngle,
        endAngle: 0.5 * .pi,
        clockwise: false
    )

    let outerLeftX = dLeft - strokeW * 0.5
    let outerTopY = cy + dRadius + strokeW * 0.5
    let outerBtmY = cy - dRadius - strokeW * 0.5

    path.addArc(
        tangent1End: CGPoint(x: outerLeftX, y: outerTopY),
        tangent2End: CGPoint(x: outerLeftX, y: cy),
        radius: rOut
    )
    path.addArc(
        tangent1End: CGPoint(x: outerLeftX, y: outerBtmY),
        tangent2End: CGPoint(x: dArcCenterX, y: outerBtmY),
        radius: rOut
    )
    path.addLine(to: CGPoint(x: dArcCenterX, y: outerBtmY))
    path.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: rOuterArc,
        startAngle: -0.5 * .pi,
        endAngle: -openAngle,
        clockwise: false
    )

    // Bottom end cap
    path.addArc(
        center: btmCenter,
        radius: capRadius,
        startAngle: -openAngle,
        endAngle: -openAngle + .pi,
        clockwise: false
    )

    // Inner boundary:
    path.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: rInnerArc,
        startAngle: -openAngle,
        endAngle: -0.5 * .pi,
        clockwise: true
    )

    let innerLeftX = dLeft + strokeW * 0.5
    let innerBtmY = cy - dRadius + strokeW * 0.5
    let innerTopY = cy + dRadius - strokeW * 0.5

    path.addArc(
        tangent1End: CGPoint(x: innerLeftX, y: innerBtmY),
        tangent2End: CGPoint(x: innerLeftX, y: cy),
        radius: rIn
    )
    path.addArc(
        tangent1End: CGPoint(x: innerLeftX, y: innerTopY),
        tangent2End: CGPoint(x: dArcCenterX, y: innerTopY),
        radius: rIn
    )
    path.addLine(to: CGPoint(x: dArcCenterX, y: innerTopY))
    path.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: rInnerArc,
        startAngle: 0.5 * .pi,
        endAngle: openAngle,
        clockwise: true
    )

    // Top end cap
    path.addArc(
        center: topCenter,
        radius: capRadius,
        startAngle: openAngle + .pi,
        endAngle: openAngle,
        clockwise: false
    )

    path.closeSubpath()

    // Play triangle nestled inside
    let triLeftX = dLeft + strokeW * 1.35
    let triRightX = (cx + xOffset) + bodySize * 0.290
    let triHalfH = totalH * 0.35
    let triCorner: CGFloat = bodySize * 0.042

    let p1 = CGPoint(x: triLeftX, y: cy + triHalfH)
    let p2 = CGPoint(x: triRightX, y: cy)
    let p3 = CGPoint(x: triLeftX, y: cy - triHalfH)

    let playPath = CGMutablePath()
    let mid12 = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
    playPath.move(to: mid12)
    playPath.addArc(tangent1End: p2, tangent2End: p3, radius: triCorner)
    playPath.addArc(tangent1End: p3, tangent2End: p1, radius: triCorner)
    playPath.addArc(tangent1End: p1, tangent2End: p2, radius: triCorner)
    playPath.closeSubpath()

    path.addPath(playPath)
    return path
}

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return nil
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let gradAllOptions: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Standard macOS Big Sur / Sonoma / Tahoe icon metrics:
    let margin = s * (100.0 / 1024.0)
    let bodySize = s - margin * 2.0
    let bodyRect = CGRect(x: margin, y: margin, width: bodySize, height: bodySize)
    let cornerRadius = bodySize * 0.225

    let squirclePath = CGPath(
        roundedRect: bodyRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // 1. Outer macOS subtle drop shadow (for sizes >= 32)
    if size >= 32 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.018),
            blur: s * 0.038,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24)
        )
        ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.945, blue: 0.955, alpha: 1.0))
        ctx.addPath(squirclePath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Clip to squircle body
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // 2A. macOS Music Pro Luminous Porcelain White Gradient Chassis (matching Apple Music)
    let bgColors = [
        CGColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
        CGColor(srgbRed: 0.985, green: 0.988, blue: 0.992, alpha: 1.0),
        CGColor(srgbRed: 0.948, green: 0.953, blue: 0.962, alpha: 1.0)
    ] as CFArray
    let bgLocs: [CGFloat] = [0.0, 0.45, 1.0]
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocs) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: s * 0.50, y: bodyRect.maxY),
            end: CGPoint(x: s * 0.50, y: bodyRect.minY),
            options: gradAllOptions
        )
    }

    // 3. Centerpiece Emblem: Sculpted Obsidian "D" Aperture (with soft organic inner fillets) + Nested Play Prism
    let cx = s * 0.50
    let cy = s * 0.50
    let emblem = createEmblem(s: s, bodySize: bodySize, cx: cx, cy: cy)

    // 3A. Grounding elevation drop shadow onto white porcelain chassis & inside cutout
    if size >= 32 {
        let outsideClip = CGMutablePath()
        outsideClip.addRect(CGRect(x: -s, y: -s, width: s * 3.0, height: s * 3.0))
        outsideClip.addPath(emblem)

        // Soft ambient elevation shadow (pointing downwards matching Apple Music)
        ctx.saveGState()
        ctx.addPath(outsideClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.018),
            blur: s * 0.022,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.16)
        )
        ctx.addPath(emblem)
        ctx.fillPath()
        ctx.restoreGState()

        // Crisp contact shadow directly underneath base
        ctx.saveGState()
        ctx.addPath(outsideClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.005),
            blur: s * 0.008,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.22)
        )
        ctx.addPath(emblem)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 3B. Solid Deep Obsidian Velvet Fill (matching Apple Music)
    ctx.saveGState()
    ctx.addPath(emblem)
    ctx.clip()
    let obsidianColors = [
        CGColor(srgbRed: 0.075, green: 0.080, blue: 0.090, alpha: 1.0),
        CGColor(srgbRed: 0.015, green: 0.016, blue: 0.018, alpha: 1.0),
        CGColor(srgbRed: 0.000, green: 0.000, blue: 0.000, alpha: 1.0)
    ] as CFArray
    if let obsGrad = CGGradient(colorsSpace: colorSpace, colors: obsidianColors, locations: [0.0, 0.40, 1.0]) {
        ctx.drawLinearGradient(
            obsGrad,
            start: CGPoint(x: cx, y: cy + bodySize * 0.32),
            end: CGPoint(x: cx, y: cy - bodySize * 0.32),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()

    // 3C. Crisp Light-Catching Top Chamfer Bevel
    ctx.saveGState()
    ctx.addPath(emblem)
    ctx.clip()

    let rimPath = emblem.copy(
        strokingWithWidth: max(1.0, s * 0.0035),
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )
    ctx.addPath(rimPath)
    ctx.clip()

    let bevelColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.85),
        CGColor(srgbRed: 0.50, green: 0.52, blue: 0.58, alpha: 0.30),
        CGColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 0.00)
    ] as CFArray
    if let bevelGrad = CGGradient(colorsSpace: colorSpace, colors: bevelColors, locations: [0.0, 0.35, 1.0]) {
        ctx.drawLinearGradient(
            bevelGrad,
            start: CGPoint(x: cx - bodySize * 0.25, y: cy + bodySize * 0.32),
            end: CGPoint(x: cx + bodySize * 0.25, y: cy - bodySize * 0.32),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()

    // 4. Subtle perimeter hairline on squircle
    let insetAmt = max(0.4, s * 0.0035)
    let innerRect = bodyRect.insetBy(dx: insetAmt, dy: insetAmt)
    let innerPath = CGPath(
        roundedRect: innerRect,
        cornerWidth: cornerRadius - insetAmt,
        cornerHeight: cornerRadius - insetAmt,
        transform: nil
    )
    ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.86, blue: 0.89, alpha: 0.50))
    ctx.setLineWidth(max(0.8, s * 0.0018))
    ctx.addPath(innerPath)
    ctx.strokePath()

    ctx.restoreGState() // end squircle clip

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
let iconsetDir = "Resources/AppIcon.iconset"
try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    guard let data = renderIcon(size: px) else {
        fputs("Failed to render \(filename)\n", stderr)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(filename)"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", "Resources/AppIcon.icns"]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
print("Generated Resources/AppIcon.icns successfully!")

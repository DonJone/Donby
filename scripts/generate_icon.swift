import AppKit
import CoreGraphics
import Foundation

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
    // 824x824 squircle centered inside 1024x1024 canvas (margin = 100/1024 = 0.09765625)
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

    // 2A. macOS Music Pro Luminous Porcelain White Gradient Chassis (top -> bottom)
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

    // 3. Centerpiece Emblem: Unified Sculptural Obsidian "D" Monogram with Inverted Play Prism (▶) Cutout
    let cx = s * 0.50
    let cy = s * 0.50
    let totalH = bodySize * 0.63
    let totalW = bodySize * 0.525
    let leftX = cx - totalW * 0.515
    let cornerR = totalH * 0.21
    let rightArcR = totalH * 0.5

    let emblem = CGMutablePath()
    let outerD = CGMutablePath()
    let rightArcCenterX = leftX + totalW - rightArcR

    outerD.move(to: CGPoint(x: leftX + cornerR, y: cy + totalH * 0.5))
    outerD.addLine(to: CGPoint(x: rightArcCenterX, y: cy + totalH * 0.5))
    outerD.addArc(
        center: CGPoint(x: rightArcCenterX, y: cy),
        radius: rightArcR,
        startAngle: 0.5 * .pi,
        endAngle: -0.5 * .pi,
        clockwise: true
    )
    outerD.addLine(to: CGPoint(x: leftX + cornerR, y: cy - totalH * 0.5))
    outerD.addArc(
        tangent1End: CGPoint(x: leftX, y: cy - totalH * 0.5),
        tangent2End: CGPoint(x: leftX, y: cy),
        radius: cornerR
    )
    outerD.addArc(
        tangent1End: CGPoint(x: leftX, y: cy + totalH * 0.5),
        tangent2End: CGPoint(x: leftX + cornerR, y: cy + totalH * 0.5),
        radius: cornerR
    )
    outerD.closeSubpath()

    // Inner sculpted Play Triangle (▶) cutout
    let triLeftX = leftX + totalW * 0.275
    let triRightX = leftX + totalW * 0.765
    let triHalfH = totalH * 0.305
    let triCorner = bodySize * 0.042

    let p1 = CGPoint(x: triLeftX, y: cy + triHalfH)
    let p2 = CGPoint(x: triRightX, y: cy)
    let p3 = CGPoint(x: triLeftX, y: cy - triHalfH)

    let playCutout = CGMutablePath()
    let mid12 = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
    playCutout.move(to: mid12)
    playCutout.addArc(tangent1End: p2, tangent2End: p3, radius: triCorner)
    playCutout.addArc(tangent1End: p3, tangent2End: p1, radius: triCorner)
    playCutout.addArc(tangent1End: p1, tangent2End: p2, radius: triCorner)
    playCutout.closeSubpath()

    emblem.addPath(outerD)
    emblem.addPath(playCutout)

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
        ctx.fillPath(using: .evenOdd)
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
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // 3B. Solid Deep Obsidian Velvet Fill (matching Apple Music)
    ctx.saveGState()
    ctx.addPath(emblem)
    ctx.clip(using: .evenOdd)
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
    ctx.clip(using: .evenOdd)

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

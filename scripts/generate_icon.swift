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
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.56)
        )
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.042, blue: 0.048, alpha: 1.0))
        ctx.addPath(squirclePath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Clip to squircle body
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Base Apple Pro Space Black / Obsidian Titanium gradient (top -> bottom)
    let bgColors = [
        CGColor(srgbRed: 0.105, green: 0.110, blue: 0.124, alpha: 1.0),
        CGColor(srgbRed: 0.048, green: 0.050, blue: 0.058, alpha: 1.0),
        CGColor(srgbRed: 0.018, green: 0.019, blue: 0.024, alpha: 1.0)
    ] as CFArray
    let bgLocs: [CGFloat] = [0.0, 0.54, 1.0]
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocs) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: s * 0.5, y: bodyRect.maxY),
            end: CGPoint(x: s * 0.5, y: bodyRect.minY),
            options: []
        )
    }

    // Subtle anodized Space Black titanium top-left studio sheen
    let titaniumSheenColors = [
        CGColor(srgbRed: 0.72, green: 0.76, blue: 0.84, alpha: 0.12),
        CGColor(srgbRed: 0.32, green: 0.35, blue: 0.42, alpha: 0.04),
        CGColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 0.0)
    ] as CFArray
    if let titaniumGrad = CGGradient(colorsSpace: colorSpace, colors: titaniumSheenColors, locations: [0.0, 0.48, 1.0]) {
        let glowCenter = CGPoint(x: bodyRect.minX + bodySize * 0.24, y: bodyRect.maxY - bodySize * 0.18)
        ctx.drawRadialGradient(
            titaniumGrad,
            startCenter: glowCenter, startRadius: 0,
            endCenter: glowCenter, endRadius: bodySize * 0.68,
            options: []
        )
    }

    // Restrained deep-graphite center depth halo behind aperture
    let depthGlowColors = [
        CGColor(srgbRed: 0.46, green: 0.52, blue: 0.64, alpha: 0.09),
        CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.0)
    ] as CFArray
    if let depthGrad = CGGradient(colorsSpace: colorSpace, colors: depthGlowColors, locations: [0.0, 1.0]) {
        let glowCenter = CGPoint(x: s * 0.52, y: s * 0.48)
        ctx.drawRadialGradient(
            depthGrad,
            startCenter: glowCenter, startRadius: 0,
            endCenter: glowCenter, endRadius: bodySize * 0.54,
            options: []
        )
    }

    // Subtle precision optical ring in background
    ctx.saveGState()
    let ringRadius = bodySize * 0.355
    let ringRect = CGRect(x: s * 0.5 - ringRadius, y: s * 0.5 - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
    ctx.setStrokeColor(CGColor(srgbRed: 0.82, green: 0.85, blue: 0.92, alpha: 0.085))
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokeEllipse(in: ringRect)
    ctx.restoreGState()

    // 3. Centerpiece Emblem: Sculpted "D + Play Prism" Cinema Mark
    // Outer luminous D-aperture arc/ribbon + crisp floating optical play triangle
    let cx = s * 0.50
    let cy = s * 0.50

    // Create outer sculpted D-frame path (thick rounded geometric D-loop open slightly to frame the play prism)
    let dLeft = cx - bodySize * 0.245
    let dTop = cy + bodySize * 0.255
    let dBot = cy - bodySize * 0.255
    let dArcCenterX = cx - bodySize * 0.045
    let dRadius = (dTop - dBot) * 0.5
    let strokeW = bodySize * 0.105

    let dTrack = CGMutablePath()
    // Start from upper-right of D curve, sweep around bottom, up left stem, back to top-left curve
    dTrack.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: dRadius,
        startAngle: CGFloat.pi * 0.27,
        endAngle: -CGFloat.pi * 0.27,
        clockwise: false
    )
    // Wait: let's construct clean closed/stroked geometric D-ribbon explicitly for rock-solid control!
    let dRibbon = CGMutablePath()
    dRibbon.move(to: CGPoint(x: dArcCenterX + dRadius * cos(0.32 * .pi), y: cy + dRadius * sin(0.32 * .pi)))
    dRibbon.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: dRadius,
        startAngle: 0.32 * .pi,
        endAngle: 0.5 * .pi,
        clockwise: false
    )
    dRibbon.addLine(to: CGPoint(x: dLeft + strokeW * 0.35, y: dTop))
    dRibbon.addArc(
        tangent1End: CGPoint(x: dLeft, y: dTop),
        tangent2End: CGPoint(x: dLeft, y: cy),
        radius: strokeW * 0.42
    )
    dRibbon.addLine(to: CGPoint(x: dLeft, y: dBot + strokeW * 0.42))
    dRibbon.addArc(
        tangent1End: CGPoint(x: dLeft, y: dBot),
        tangent2End: CGPoint(x: dArcCenterX, y: dBot),
        radius: strokeW * 0.42
    )
    dRibbon.addLine(to: CGPoint(x: dArcCenterX, y: dBot))
    dRibbon.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: dRadius,
        startAngle: -0.5 * .pi,
        endAngle: -0.32 * .pi,
        clockwise: false
    )

    let strokedDRibbon = dRibbon.copy(
        strokingWithWidth: strokeW,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )

    // Drop shadow behind D-ribbon
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.016),
        blur: s * 0.035,
        color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.85)
    )
    ctx.addPath(strokedDRibbon)
    ctx.setFillColor(CGColor(srgbRed: 0.52, green: 0.56, blue: 0.64, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill on D-ribbon (Machined Platinum-Titanium -> Brushed Space Steel -> Deep Gunmetal)
    ctx.saveGState()
    ctx.addPath(strokedDRibbon)
    ctx.clip()
    let ribbonColors = [
        CGColor(srgbRed: 0.88, green: 0.91, blue: 0.96, alpha: 1.0),
        CGColor(srgbRed: 0.55, green: 0.60, blue: 0.68, alpha: 1.0),
        CGColor(srgbRed: 0.30, green: 0.34, blue: 0.41, alpha: 1.0)
    ] as CFArray
    if let ribGrad = CGGradient(colorsSpace: colorSpace, colors: ribbonColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            ribGrad,
            start: CGPoint(x: dLeft, y: dTop + strokeW * 0.5),
            end: CGPoint(x: cx + bodySize * 0.24, y: dBot - strokeW * 0.5),
            options: []
        )
    }
    ctx.restoreGState()

    // 4. Crisp Rounded Play Prism (▶) nestled and projecting rightwards through the D-aperture!
    let triLeftX = cx - bodySize * 0.055
    let triRightX = cx + bodySize * 0.285
    let triHalfH = bodySize * 0.195
    let triCorner = bodySize * 0.036

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

    // Glow & shadow under Play Prism
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.014),
        blur: s * 0.036,
        color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.78)
    )
    ctx.addPath(playPath)
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Specular Diamond White -> Cool Moonlight Silver gradient fill on Play Prism
    ctx.saveGState()
    ctx.addPath(playPath)
    ctx.clip()
    let playColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(srgbRed: 0.91, green: 0.93, blue: 0.97, alpha: 1.0),
        CGColor(srgbRed: 0.76, green: 0.80, blue: 0.86, alpha: 1.0)
    ] as CFArray
    if let playGrad = CGGradient(colorsSpace: colorSpace, colors: playColors, locations: [0.0, 0.6, 1.0]) {
        ctx.drawLinearGradient(
            playGrad,
            start: CGPoint(x: triLeftX, y: cy + triHalfH),
            end: CGPoint(x: triRightX, y: cy - triHalfH),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle top glass reflection across upper squircle
    ctx.saveGState()
    let glossPath = CGMutablePath()
    glossPath.move(to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY))
    glossPath.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY))
    glossPath.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.midY + bodySize * 0.08))
    glossPath.addQuadCurve(
        to: CGPoint(x: bodyRect.minX, y: bodyRect.midY + bodySize * 0.14),
        control: CGPoint(x: s * 0.5, y: bodyRect.midY - bodySize * 0.02)
    )
    glossPath.closeSubpath()
    ctx.addPath(glossPath)
    ctx.clip()
    let glossColors = [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.065),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray
    if let glossGrad = CGGradient(colorsSpace: colorSpace, colors: glossColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            glossGrad,
            start: CGPoint(x: s * 0.5, y: bodyRect.maxY),
            end: CGPoint(x: s * 0.5, y: bodyRect.midY),
            options: []
        )
    }
    ctx.restoreGState()

    // Inner specular border along squircle edge
    let insetAmt = max(0.5, s * 0.004)
    let innerRect = bodyRect.insetBy(dx: insetAmt, dy: insetAmt)
    let innerPath = CGPath(
        roundedRect: innerRect,
        cornerWidth: cornerRadius - insetAmt,
        cornerHeight: cornerRadius - insetAmt,
        transform: nil
    )
    ctx.setStrokeColor(CGColor(srgbRed: 0.82, green: 0.85, blue: 0.90, alpha: 0.16))
    ctx.setLineWidth(max(1.0, s * 0.006))
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

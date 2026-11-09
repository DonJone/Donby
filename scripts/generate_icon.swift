import AppKit
import CoreGraphics
import Foundation

/// Draws an inner meniscus highlight or inner shadow clipped strictly inside `path`
/// using an even-odd outer cutout (requires `path` to be non-self-intersecting).
private func drawInnerMeniscus(
    in ctx: CGContext,
    path: CGPath,
    canvasSize s: CGFloat,
    offset: CGSize,
    blur: CGFloat,
    color: CGColor,
    blendMode: CGBlendMode = .normal
) {
    ctx.saveGState()
    ctx.setBlendMode(blendMode)
    ctx.addPath(path)
    ctx.clip()

    let cutout = CGMutablePath()
    cutout.addRect(CGRect(x: -s, y: -s, width: s * 3.0, height: s * 3.0))
    cutout.addPath(path)

    ctx.setShadow(offset: offset, blur: blur, color: color)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(cutout)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
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
        CGColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.0), // #FFFFFF Pure Top White
        CGColor(srgbRed: 0.980, green: 0.983, blue: 0.990, alpha: 1.0), // #FAFBFC Luminous Pearl
        CGColor(srgbRed: 0.925, green: 0.932, blue: 0.945, alpha: 1.0)  // #ECEEF2 Soft Porcelain Off-White
    ] as CFArray
    let bgLocs: [CGFloat] = [0.0, 0.50, 1.0]
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocs) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: s * 0.50, y: bodyRect.maxY),
            end: CGPoint(x: s * 0.50, y: bodyRect.minY),
            options: gradAllOptions
        )
    }

    // Top-left studio softbox reflection wash on porcelain white chassis
    let titaniumSheenColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.70),
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.20),
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let titaniumGrad = CGGradient(colorsSpace: colorSpace, colors: titaniumSheenColors, locations: [0.0, 0.48, 1.0]) {
        let glowCenter = CGPoint(x: bodyRect.minX + bodySize * 0.20, y: bodyRect.maxY - bodySize * 0.16)
        ctx.drawRadialGradient(
            titaniumGrad,
            startCenter: glowCenter, startRadius: 0,
            endCenter: glowCenter, endRadius: bodySize * 0.72,
            options: []
        )
    }

    // Subtle bottom-right internal bounce reflection inside porcelain slab
    let bounceSheenColors = [
        CGColor(srgbRed: 0.88, green: 0.90, blue: 0.94, alpha: 0.25),
        CGColor(srgbRed: 0.92, green: 0.94, blue: 0.96, alpha: 0.08),
        CGColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 0.0)
    ] as CFArray
    if let bounceGrad = CGGradient(colorsSpace: colorSpace, colors: bounceSheenColors, locations: [0.0, 0.50, 1.0]) {
        let bounceCenter = CGPoint(x: bodyRect.maxX - bodySize * 0.18, y: bodyRect.minY + bodySize * 0.16)
        ctx.drawRadialGradient(
            bounceGrad,
            startCenter: bounceCenter, startRadius: 0,
            endCenter: bounceCenter, endRadius: bodySize * 0.60,
            options: []
        )
    }

    // Soft center depth halo behind aperture
    let depthGlowColors = [
        CGColor(srgbRed: 0.94, green: 0.95, blue: 0.98, alpha: 0.40),
        CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 0.15),
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let depthGrad = CGGradient(colorsSpace: colorSpace, colors: depthGlowColors, locations: [0.0, 0.46, 1.0]) {
        let glowCenter = CGPoint(x: s * 0.51, y: s * 0.50)
        ctx.drawRadialGradient(
            depthGrad,
            startCenter: glowCenter, startRadius: 0,
            endCenter: glowCenter, endRadius: bodySize * 0.58,
            options: []
        )
    }

    // Precompute Centerpiece "D" Aperture geometry so background elements can refract cleanly behind it
    let cx = s * 0.50
    let cy = s * 0.50
    // Bold, empowered centerpiece scale (matching macOS Music emblem prominence)
    let dLeft = cx - bodySize * 0.295
    let dTop = cy + bodySize * 0.315
    let dBot = cy - bodySize * 0.315
    let dArcCenterX = cx - bodySize * 0.055
    let dRadius = (dTop - dBot) * 0.5
    let strokeW = bodySize * 0.128
    // Corner radius > 0.5 * strokeW guarantees a smooth non-self-intersecting stroked outline
    let dCornerR = strokeW * 0.56

    let dRibbon = CGMutablePath()
    dRibbon.move(to: CGPoint(x: dArcCenterX + dRadius * cos(0.32 * .pi), y: cy + dRadius * sin(0.32 * .pi)))
    dRibbon.addArc(
        center: CGPoint(x: dArcCenterX, y: cy),
        radius: dRadius,
        startAngle: 0.32 * .pi,
        endAngle: 0.5 * .pi,
        clockwise: false
    )
    dRibbon.addArc(
        tangent1End: CGPoint(x: dLeft, y: dTop),
        tangent2End: CGPoint(x: dLeft, y: dBot),
        radius: dCornerR
    )
    dRibbon.addArc(
        tangent1End: CGPoint(x: dLeft, y: dBot),
        tangent2End: CGPoint(x: dArcCenterX, y: dBot),
        radius: dCornerR
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

    let outsideDClip = CGMutablePath()
    outsideDClip.addRect(CGRect(x: -s, y: -s, width: s * 3.0, height: s * 3.0))
    outsideDClip.addPath(strokedDRibbon)

    // 3. Centerpiece Emblem: Sculpted Deep Obsidian "D" Aperture + Solid Obsidian Play Prism (Matching macOS Music Note)
    // 3A. Grounding elevation shadow beneath D-ribbon onto white porcelain chassis
    if size >= 32 {
        // Diffused ambient elevation shadow
        ctx.saveGState()
        ctx.addPath(outsideDClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.022),
            blur: s * 0.024,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.20)
        )
        ctx.addPath(strokedDRibbon)
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()

        // Crisp contact shadow directly beneath base
        ctx.saveGState()
        ctx.addPath(outsideDClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.007),
            blur: s * 0.010,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.24)
        )
        ctx.addPath(strokedDRibbon)
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 3B. Sculpted Deep Obsidian Body of D-ribbon
    ctx.saveGState()
    ctx.addPath(strokedDRibbon)
    ctx.clip()

    // Rich Obsidian Gradient (identical to macOS Music Note)
    let ribbonColors = [
        CGColor(srgbRed: 0.135, green: 0.142, blue: 0.162, alpha: 1.0), // Top charcoal highlight
        CGColor(srgbRed: 0.052, green: 0.055, blue: 0.065, alpha: 1.0), // Body obsidian
        CGColor(srgbRed: 0.016, green: 0.018, blue: 0.022, alpha: 1.0), // Deep space black
        CGColor(srgbRed: 0.035, green: 0.038, blue: 0.045, alpha: 1.0)
    ] as CFArray
    if let ribGrad = CGGradient(colorsSpace: colorSpace, colors: ribbonColors, locations: [0.0, 0.40, 0.80, 1.0]) {
        ctx.drawLinearGradient(
            ribGrad,
            start: CGPoint(x: dLeft, y: dTop + strokeW * 0.5),
            end: CGPoint(x: cx + bodySize * 0.24, y: dBot - strokeW * 0.5),
            options: gradAllOptions
        )
    }

    // Feathered studio softbox sheen across upper-left shoulder of the obsidian ribbon
    let softboxCenter = CGPoint(x: dLeft + bodySize * 0.06, y: dTop - bodySize * 0.02)
    let dSheenColors = [
        CGColor(srgbRed: 0.75, green: 0.80, blue: 0.90, alpha: 0.32),
        CGColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 0.10),
        CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.0)
    ] as CFArray
    if let dSheenGrad = CGGradient(colorsSpace: colorSpace, colors: dSheenColors, locations: [0.0, 0.50, 1.0]) {
        ctx.drawRadialGradient(
            dSheenGrad,
            startCenter: softboxCenter, startRadius: 0,
            endCenter: softboxCenter, endRadius: bodySize * 0.36,
            options: []
        )
    }

    ctx.restoreGState()

    // 3C. Smooth Pillowed Tactile Volume & Specular Edge Bevel (matching macOS Music Note)
    // Underside shading
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: -s * 0.008, height: s * 0.010),
        blur: strokeW * 0.44,
        color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.65),
        blendMode: .multiply
    )
    // Convex highlight cushion from top-left
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: s * 0.009, height: -s * 0.010),
        blur: strokeW * 0.30,
        color: CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.35),
        blendMode: .screen
    )
    // Tight razor-sharp specular gleam along top-left perimeter (matching macOS Music Note bevel)
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: s * 0.0050, height: -s * 0.0055),
        blur: s * 0.0070,
        color: CGColor(srgbRed: 0.95, green: 0.97, blue: 1.00, alpha: 0.88),
        blendMode: .screen
    )
    // Subtle bottom-right curvature bounce lip
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: -s * 0.0042, height: s * 0.0046),
        blur: s * 0.0065,
        color: CGColor(srgbRed: 0.60, green: 0.65, blue: 0.75, alpha: 0.35),
        blendMode: .screen
    )

    // 3D. Crisp Dual-Rim Specular Bevel around D-ribbon
    ctx.saveGState()
    ctx.addPath(strokedDRibbon)
    ctx.clip()
    let dRimBorder = strokedDRibbon.copy(
        strokingWithWidth: max(0.8, s * 0.0085),
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )
    ctx.addPath(dRimBorder)
    ctx.clip()
    let dRimColors = [
        CGColor(srgbRed: 0.92, green: 0.95, blue: 1.00, alpha: 0.82), // Top-left specular catch
        CGColor(srgbRed: 0.30, green: 0.32, blue: 0.38, alpha: 0.22),
        CGColor(srgbRed: 0.68, green: 0.72, blue: 0.80, alpha: 0.50)  // Bottom-right rim
    ] as CFArray
    if let dRimGrad = CGGradient(colorsSpace: colorSpace, colors: dRimColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            dRimGrad,
            start: CGPoint(x: dLeft - strokeW * 0.5, y: dTop + strokeW * 0.5),
            end: CGPoint(x: cx + bodySize * 0.22, y: dBot - strokeW * 0.5),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()

    // 4. Crisp Rounded Obsidian Play Prism (▶) nestled and projecting rightwards through the D-aperture!
    let triLeftX = cx - bodySize * 0.065
    let triRightX = cx + bodySize * 0.345
    let triHalfH = bodySize * 0.240
    let triCorner = bodySize * 0.044

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

    let outsidePlayClip = CGMutablePath()
    outsidePlayClip.addRect(CGRect(x: -s, y: -s, width: s * 3.0, height: s * 3.0))
    outsidePlayClip.addPath(playPath)

    // Ambient elevation shadow under Play Prism
    if size >= 32 {
        ctx.saveGState()
        ctx.addPath(outsidePlayClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.022),
            blur: s * 0.024,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.20)
        )
        ctx.addPath(playPath)
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()

        // Contact shadow under Play Prism
        ctx.saveGState()
        ctx.addPath(outsidePlayClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.007),
            blur: s * 0.010,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.24)
        )
        ctx.addPath(playPath)
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Obsidian gradient fill on Play Prism matching the D body
    ctx.saveGState()
    ctx.addPath(playPath)
    ctx.clip()
    let playColors = [
        CGColor(srgbRed: 0.145, green: 0.152, blue: 0.175, alpha: 1.0),
        CGColor(srgbRed: 0.060, green: 0.063, blue: 0.072, alpha: 1.0),
        CGColor(srgbRed: 0.018, green: 0.020, blue: 0.024, alpha: 1.0)
    ] as CFArray
    if let playGrad = CGGradient(colorsSpace: colorSpace, colors: playColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            playGrad,
            start: CGPoint(x: triLeftX, y: cy + triHalfH),
            end: CGPoint(x: triRightX, y: cy - triHalfH),
            options: gradAllOptions
        )
    }

    // Specular highlight rim on Play Prism
    let playRim = playPath.copy(
        strokingWithWidth: max(0.8, s * 0.0075),
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )
    ctx.addPath(playRim)
    ctx.clip()
    let playRimColors = [
        CGColor(srgbRed: 0.95, green: 0.97, blue: 1.00, alpha: 0.85),
        CGColor(srgbRed: 0.32, green: 0.34, blue: 0.40, alpha: 0.20),
        CGColor(srgbRed: 0.65, green: 0.70, blue: 0.80, alpha: 0.45)
    ] as CFArray
    if let pRimGrad = CGGradient(colorsSpace: colorSpace, colors: playRimColors, locations: [0.0, 0.50, 1.0]) {
        ctx.drawLinearGradient(
            pRimGrad,
            start: CGPoint(x: triLeftX, y: cy + triHalfH),
            end: CGPoint(x: triRightX, y: cy - triHalfH),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()

    // 5. Porcelain Chassis Surface Sheen & Dual-Rim Meniscus Bevel
    ctx.saveGState()
    let glossColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.45),
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.12),
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let glossGrad = CGGradient(colorsSpace: colorSpace, colors: glossColors, locations: [0.0, 0.48, 1.0]) {
        ctx.drawLinearGradient(
            glossGrad,
            start: CGPoint(x: s * 0.5, y: bodyRect.maxY),
            end: CGPoint(x: s * 0.5, y: bodyRect.midY + bodySize * 0.04),
            options: []
        )
    }
    ctx.restoreGState()

    // Soft inner liquid meniscus cushion around the Porcelain White squircle perimeter
    if size >= 32 {
        drawInnerMeniscus(
            in: ctx,
            path: squirclePath,
            canvasSize: s,
            offset: CGSize(width: s * 0.006, height: -s * 0.006),
            blur: s * 0.016,
            color: CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.60),
            blendMode: .screen
        )
        drawInnerMeniscus(
            in: ctx,
            path: squirclePath,
            canvasSize: s,
            offset: CGSize(width: -s * 0.005, height: s * 0.005),
            blur: s * 0.014,
            color: CGColor(srgbRed: 0.70, green: 0.72, blue: 0.78, alpha: 0.25),
            blendMode: .multiply
        )
    }

    // Directional specular rim along squircle edge (bright top-left lip + bottom-right subtle shadow rim)
    let insetAmt = max(0.4, s * 0.0035)
    let innerRect = bodyRect.insetBy(dx: insetAmt, dy: insetAmt)
    let innerPath = CGPath(
        roundedRect: innerRect,
        cornerWidth: cornerRadius - insetAmt,
        cornerHeight: cornerRadius - insetAmt,
        transform: nil
    )
    let strokedSquircleRim = innerPath.copy(
        strokingWithWidth: max(0.7, s * 0.0065),
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )
    ctx.saveGState()
    ctx.addPath(strokedSquircleRim)
    ctx.clip()
    let rimColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.90), // Top-left white specular lip
        CGColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 0.25),
        CGColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 0.50)  // Bottom-right defining hairline
    ] as CFArray
    if let rimGrad = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
            end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()

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

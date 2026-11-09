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
            color: CGColor(srgbRed: 0.35, green: 0.02, blue: 0.08, alpha: 0.58)
        )
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.08, blue: 0.24, alpha: 1.0))
        ctx.addPath(squirclePath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Clip to squircle body
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // 2A. Apple Music macOS Pro Luminous Red Gradient Chassis (top -> bottom)
    let bgColors = [
        CGColor(srgbRed: 0.996, green: 0.235, blue: 0.388, alpha: 1.0), // #FE3C63 Vibrant Coral Red
        CGColor(srgbRed: 0.960, green: 0.145, blue: 0.315, alpha: 1.0), // #F52550 Pure Apple Music Red
        CGColor(srgbRed: 0.825, green: 0.055, blue: 0.215, alpha: 1.0)  // #D20E37 Rich Deep Crimson
    ] as CFArray
    let bgLocs: [CGFloat] = [0.0, 0.55, 1.0]
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocs) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: s * 0.38, y: bodyRect.maxY),
            end: CGPoint(x: s * 0.62, y: bodyRect.minY),
            options: gradAllOptions
        )
    }

    // Top-left Liquid Glass studio refraction wash on Apple Music Red chassis
    let titaniumSheenColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.24),
        CGColor(srgbRed: 1.00, green: 0.68, blue: 0.78, alpha: 0.09),
        CGColor(srgbRed: 0.98, green: 0.18, blue: 0.34, alpha: 0.0)
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

    // Subtle bottom-right internal bounce reflection inside luminous chassis
    let bounceSheenColors = [
        CGColor(srgbRed: 1.00, green: 0.48, blue: 0.62, alpha: 0.15),
        CGColor(srgbRed: 0.92, green: 0.12, blue: 0.28, alpha: 0.04),
        CGColor(srgbRed: 0.80, green: 0.04, blue: 0.20, alpha: 0.0)
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

    // Luminous center depth halo behind aperture
    let depthGlowColors = [
        CGColor(srgbRed: 1.00, green: 0.48, blue: 0.62, alpha: 0.26),
        CGColor(srgbRed: 0.96, green: 0.18, blue: 0.34, alpha: 0.09),
        CGColor(srgbRed: 0.82, green: 0.05, blue: 0.22, alpha: 0.0)
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
    let dLeft = cx - bodySize * 0.245
    let dTop = cy + bodySize * 0.255
    let dBot = cy - bodySize * 0.255
    let dArcCenterX = cx - bodySize * 0.045
    let dRadius = (dTop - dBot) * 0.5
    let strokeW = bodySize * 0.105
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

    // 2B. Concentric Liquid Glass Optical Ring (sharp outside D-ribbon, frosted-diffused inside D-ribbon)
    let ringRadius = bodySize * 0.355
    let ringRect = CGRect(x: s * 0.5 - ringRadius, y: s * 0.5 - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
    let ringStrokeWidth = max(0.75, s * 0.014)
    let ringCirclePath = CGPath(ellipseIn: ringRect, transform: nil)
    let strokedRingHalo = ringCirclePath.copy(
        strokingWithWidth: ringStrokeWidth,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )

    ctx.saveGState()
    ctx.addPath(outsideDClip)
    ctx.clip(using: .evenOdd)

    // Soft ambient glass aura under concentric ring
    if size >= 32 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.004),
            blur: s * 0.012,
            color: CGColor(srgbRed: 0.35, green: 0.02, blue: 0.08, alpha: 0.50)
        )
        ctx.addPath(strokedRingHalo)
        ctx.setFillColor(CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.08))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Directional Liquid Glass specular fill along concentric ring (bright top-left & bottom-right glints)
    ctx.saveGState()
    ctx.addPath(strokedRingHalo)
    ctx.clip()
    let ringColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.42),
        CGColor(srgbRed: 1.00, green: 0.88, blue: 0.92, alpha: 0.14),
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.32)
    ] as CFArray
    if let ringGrad = CGGradient(colorsSpace: colorSpace, colors: ringColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            ringGrad,
            start: CGPoint(x: ringRect.minX, y: ringRect.maxY),
            end: CGPoint(x: ringRect.maxX, y: ringRect.minY),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()
    if size >= 64 {
        drawInnerMeniscus(
            in: ctx,
            path: strokedRingHalo,
            canvasSize: s,
            offset: CGSize(width: s * 0.002, height: -s * 0.002),
            blur: s * 0.003,
            color: CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.35),
            blendMode: .screen
        )
    }
    ctx.restoreGState() // end outsideDClip for sharp background ring

    // 3. Centerpiece Emblem: Sculpted Liquid Glass "D" Aperture + Solid Radiant Play Prism
    // 3A. Grounding shadow + transmitted Liquid Glass caustic bloom beneath D-ribbon
    // (Cast using an exterior clip so the translucent glass interior isn't muddied by solid shadow fill)
    if size >= 32 {
        // Deep elevation shadow onto Apple Music Red chassis
        ctx.saveGState()
        ctx.addPath(outsideDClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.018),
            blur: s * 0.038,
            color: CGColor(srgbRed: 0.36, green: 0.02, blue: 0.09, alpha: 0.74)
        )
        ctx.addPath(strokedDRibbon)
        ctx.setFillColor(CGColor(srgbRed: 0.36, green: 0.02, blue: 0.09, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()

        // Transmitted caustic light focus & luminous halo around Liquid Glass D-ribbon
        ctx.saveGState()
        ctx.addPath(outsideDClip)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(
            offset: CGSize(width: s * 0.006, height: -s * 0.008),
            blur: s * 0.030,
            color: CGColor(srgbRed: 1.00, green: 0.75, blue: 0.84, alpha: 0.30)
        )
        ctx.addPath(strokedDRibbon)
        ctx.setFillColor(CGColor(srgbRed: 1.00, green: 0.96, blue: 0.98, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 3B. Sculpted Translucent Crystal-Silver Liquid Glass Body of D-ribbon
    ctx.saveGState()
    ctx.addPath(strokedDRibbon)
    ctx.clip()

    // Frosted backdrop diffusion of the concentric optical ring underneath the thick D glass lens
    // (Soft Gaussian bloom rather than an unblurred sharp line, matching real Apple Liquid Glass backdrop blur)
    ctx.saveGState()
    let refractedRadius = ringRadius * 1.022
    let refractedCenter = CGPoint(x: s * 0.505, y: s * 0.495)
    let refractedRect = CGRect(
        x: refractedCenter.x - refractedRadius,
        y: refractedCenter.y - refractedRadius,
        width: refractedRadius * 2.0,
        height: refractedRadius * 2.0
    )
    ctx.setShadow(
        offset: .zero,
        blur: s * 0.038,
        color: CGColor(srgbRed: 0.90, green: 0.96, blue: 1.00, alpha: 0.42)
    )
    ctx.setStrokeColor(CGColor(srgbRed: 0.92, green: 0.97, blue: 1.00, alpha: 0.04))
    ctx.setLineWidth(max(1.0, s * 0.032))
    ctx.strokeEllipse(in: refractedRect)
    ctx.restoreGState()

    // Smooth High-Luminance Translucent Crystal-Silver Glass Body
    // Luminous pearl-crystal interior (~0.80-0.88) so the 1.00 pure-white liquid meniscus lip
    // pops crisply all the way around (including top-left shoulder & rounded tips)
    let ribbonColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.96),
        CGColor(srgbRed: 0.97, green: 0.98, blue: 1.00, alpha: 0.90),
        CGColor(srgbRed: 0.92, green: 0.94, blue: 0.98, alpha: 0.86),
        CGColor(srgbRed: 0.98, green: 0.99, blue: 1.00, alpha: 0.94)
    ] as CFArray
    if let ribGrad = CGGradient(colorsSpace: colorSpace, colors: ribbonColors, locations: [0.0, 0.38, 0.72, 1.0]) {
        ctx.drawLinearGradient(
            ribGrad,
            start: CGPoint(x: dLeft, y: dTop + strokeW * 0.5),
            end: CGPoint(x: cx + bodySize * 0.24, y: dBot - strokeW * 0.5),
            options: gradAllOptions
        )
    }

    // Feathered studio softbox glow across upper-left shoulder of the D lens (zero hard cutoff edges)
    let softboxCenter = CGPoint(x: dLeft + bodySize * 0.06, y: dTop - bodySize * 0.02)
    let dSheenColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.20),
        CGColor(srgbRed: 0.96, green: 0.98, blue: 1.00, alpha: 0.07),
        CGColor(srgbRed: 0.94, green: 0.97, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let dSheenGrad = CGGradient(colorsSpace: colorSpace, colors: dSheenColors, locations: [0.0, 0.50, 1.0]) {
        ctx.drawRadialGradient(
            dSheenGrad,
            startCenter: softboxCenter, startRadius: 0,
            endCenter: softboxCenter, endRadius: bodySize * 0.36,
            options: []
        )
    }

    // Radiant white light bounce cast from the solid center Play triangle onto the D aperture jaws
    let prismBounceCenter = CGPoint(x: cx + bodySize * 0.05, y: cy)
    let prismBounceColors = [
        CGColor(srgbRed: 0.94, green: 0.98, blue: 1.00, alpha: 0.28),
        CGColor(srgbRed: 0.84, green: 0.92, blue: 1.00, alpha: 0.10),
        CGColor(srgbRed: 0.80, green: 0.90, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let prismBounceGrad = CGGradient(colorsSpace: colorSpace, colors: prismBounceColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawRadialGradient(
            prismBounceGrad,
            startCenter: prismBounceCenter, startRadius: bodySize * 0.08,
            endCenter: prismBounceCenter, endRadius: bodySize * 0.34,
            options: []
        )
    }

    ctx.saveGState()
    // Subtle cool azure refractive dispersion whisper near lower-right curve & upper-right tip
    let dispersionCenter = CGPoint(x: dArcCenterX + dRadius * 0.65, y: dBot)
    let dispersionColors = [
        CGColor(srgbRed: 0.78, green: 0.90, blue: 1.00, alpha: 0.24),
        CGColor(srgbRed: 0.78, green: 0.90, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let dispGrad = CGGradient(colorsSpace: colorSpace, colors: dispersionColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            dispGrad,
            startCenter: dispersionCenter, startRadius: 0,
            endCenter: dispersionCenter, endRadius: strokeW * 2.1,
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState()

    // 3C. Smooth Pillowed Liquid Glass Volume & Wet Meniscus Edge Reflections inside D-ribbon
    // Wide smooth convex glass shading on underside (no harsh bands)
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: -s * 0.008, height: s * 0.010),
        blur: strokeW * 0.44,
        color: CGColor(srgbRed: 0.16, green: 0.21, blue: 0.32, alpha: 0.25),
        blendMode: .multiply
    )
    // Wide velvety convex highlight cushion from top-left
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: s * 0.009, height: -s * 0.010),
        blur: strokeW * 0.30,
        color: CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.44),
        blendMode: .screen
    )
    // Tight wet liquid meniscus specular lip along top-left perimeter
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: s * 0.0050, height: -s * 0.0055),
        blur: s * 0.0070,
        color: CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.98),
        blendMode: .screen
    )
    // Tight opposite internal refractive bounce lip along bottom-right curvature & rounded tips
    drawInnerMeniscus(
        in: ctx,
        path: strokedDRibbon,
        canvasSize: s,
        offset: CGSize(width: -s * 0.0042, height: s * 0.0046),
        blur: s * 0.0065,
        color: CGColor(srgbRed: 0.90, green: 0.96, blue: 1.00, alpha: 0.84),
        blendMode: .screen
    )

    // 3D. Crisp Dual-Rim Specular Glass Bevel around D-ribbon
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
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.98),
        CGColor(srgbRed: 0.88, green: 0.93, blue: 1.00, alpha: 0.38),
        CGColor(srgbRed: 0.94, green: 0.98, blue: 1.00, alpha: 0.88)
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
        color: CGColor(srgbRed: 0.36, green: 0.02, blue: 0.09, alpha: 0.75)
    )
    ctx.addPath(playPath)
    ctx.setFillColor(CGColor(srgbRed: 0.36, green: 0.02, blue: 0.09, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: s * 0.028,
        color: CGColor(srgbRed: 1.00, green: 0.80, blue: 0.88, alpha: 0.35)
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
        CGColor(srgbRed: 0.97, green: 0.98, blue: 1.00, alpha: 1.0),
        CGColor(srgbRed: 0.89, green: 0.92, blue: 0.97, alpha: 1.0)
    ] as CFArray
    if let playGrad = CGGradient(colorsSpace: colorSpace, colors: playColors, locations: [0.0, 0.6, 1.0]) {
        ctx.drawLinearGradient(
            playGrad,
            start: CGPoint(x: triLeftX, y: cy + triHalfH),
            end: CGPoint(x: triRightX, y: cy - triHalfH),
            options: gradAllOptions
        )
    }
    ctx.restoreGState()

    // 5. Chassis Liquid Glass Surface Sheet & Dual-Rim Meniscus Bevel
    ctx.saveGState()
    let glossColors = [
        CGColor(srgbRed: 0.96, green: 0.98, blue: 1.00, alpha: 0.095),
        CGColor(srgbRed: 0.90, green: 0.95, blue: 1.00, alpha: 0.022),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
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

    // Soft inner liquid meniscus cushion around the Space Black squircle perimeter
    if size >= 32 {
        drawInnerMeniscus(
            in: ctx,
            path: squirclePath,
            canvasSize: s,
            offset: CGSize(width: s * 0.006, height: -s * 0.006),
            blur: s * 0.016,
            color: CGColor(srgbRed: 0.90, green: 0.95, blue: 1.00, alpha: 0.17),
            blendMode: .screen
        )
        drawInnerMeniscus(
            in: ctx,
            path: squirclePath,
            canvasSize: s,
            offset: CGSize(width: -s * 0.005, height: s * 0.005),
            blur: s * 0.014,
            color: CGColor(srgbRed: 0.76, green: 0.86, blue: 1.00, alpha: 0.11),
            blendMode: .screen
        )
    }

    // Directional Liquid Glass specular rim along squircle edge (bright top-left lip + bottom-right bounce)
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
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.48),
        CGColor(srgbRed: 1.00, green: 0.70, blue: 0.80, alpha: 0.10),
        CGColor(srgbRed: 1.00, green: 0.88, blue: 0.94, alpha: 0.28)
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

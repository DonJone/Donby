import Foundation

/// Synthesizes a crisp, non-blurry weighted vertical top-edge extension texture (#03) from a poster's top pixel band.
/// Uses purely vertical per-column weighting (ZERO horizontal Gaussian blur):
/// 1. Vertical exponential decay weighting (`exp(-y / 2.0)`) locked tightly to pixels nearest the top edge.
/// 2. Per-column robust RGB outlier suppression (`1 / (1 + (dist / 0.28)^2)`) rejecting stray speckles without horizontal smearing.
/// 3. Subtle upward tonal easing (`<= 12%` blend toward weighted global mean at the far top) while keeping the seam row 100% exact.
public enum HeroTopEdgeSynthesizer {
    public static func synthesizeWeightedStrip(
        topBandRGBA: [UInt8],
        width: Int,
        rows: Int,
        outputHeight: Int = 64
    ) -> [UInt8] {
        guard width > 0, rows > 0, outputHeight > 0, topBandRGBA.count >= width * rows * 4 else {
            return []
        }

        let tau = 2.0
        var vertWeights = [Double](repeating: 1.0, count: rows)
        for y in 0..<rows {
            vertWeights[y] = exp(-Double(y) / tau)
        }

        var colR = [Double](repeating: 0, count: width)
        var colG = [Double](repeating: 0, count: width)
        var colB = [Double](repeating: 0, count: width)

        for x in 0..<width {
            // Pass 1: initial exponentially-weighted column RGB mean
            var r0 = 0.0, g0 = 0.0, b0 = 0.0, w0 = 0.0
            for y in 0..<rows {
                let idx = (y * width + x) * 4
                let w = vertWeights[y]
                r0 += (Double(topBandRGBA[idx]) / 255.0) * w
                g0 += (Double(topBandRGBA[idx + 1]) / 255.0) * w
                b0 += (Double(topBandRGBA[idx + 2]) / 255.0) * w
                w0 += w
            }
            let meanR = w0 > 0 ? (r0 / w0) : 0.0
            let meanG = w0 > 0 ? (g0 / w0) : 0.0
            let meanB = w0 > 0 ? (b0 / w0) : 0.0

            // Pass 2: robust RGB distance re-weighting (suppresses isolated speckles/sparkles along the column, zero horizontal blur)
            var rAcc = 0.0, gAcc = 0.0, bAcc = 0.0, wAcc = 0.0
            for y in 0..<rows {
                let idx = (y * width + x) * 4
                let r = Double(topBandRGBA[idx]) / 255.0
                let g = Double(topBandRGBA[idx + 1]) / 255.0
                let b = Double(topBandRGBA[idx + 2]) / 255.0
                let dr = r - meanR
                let dg = g - meanG
                let db = b - meanB
                let distSq = dr * dr + dg * dg + db * db
                let outlierWeight = 1.0 / (1.0 + distSq / (0.28 * 0.28))
                let w = vertWeights[y] * outlierWeight
                rAcc += r * w
                gAcc += g * w
                bAcc += b * w
                wAcc += w
            }
            if wAcc > 0 {
                colR[x] = rAcc / wAcc
                colG[x] = gAcc / wAcc
                colB[x] = bAcc / wAcc
            }
        }

        let invW = 1.0 / Double(width)
        let globalR = colR.reduce(0, +) * invW
        let globalG = colG.reduce(0, +) * invW
        let globalB = colB.reduce(0, +) * invW

        var out = [UInt8](repeating: 255, count: width * outputHeight * 4)
        let maxY = max(1, outputHeight - 1)
        for y in 0..<outputHeight {
            // t = 0 at bottom (touching poster top edge = 100% exact column color), t = 1 at top
            let t = Double(maxY - y) / Double(maxY)
            let globalMix = 0.12 * t * t
            let localMix = 1.0 - globalMix
            for x in 0..<width {
                let r = colR[x] * localMix + globalR * globalMix
                let g = colG[x] * localMix + globalG * globalMix
                let b = colB[x] * localMix + globalB * globalMix
                let idx = (y * width + x) * 4
                out[idx] = UInt8(max(0, min(255, Int((r * 255.0).rounded()))))
                out[idx + 1] = UInt8(max(0, min(255, Int((g * 255.0).rounded()))))
                out[idx + 2] = UInt8(max(0, min(255, Int((b * 255.0).rounded()))))
                out[idx + 3] = 255
            }
        }
        return out
    }
}

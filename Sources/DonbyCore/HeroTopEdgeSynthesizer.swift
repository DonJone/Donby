import Foundation

/// Synthesizes a 1:1 color-matched, zero-blur weighted vertical top-edge strip (#03) from a poster's top rows.
/// Uses purely vertical per-column weighting (ZERO horizontal blur, ZERO muddy global averaging):
/// 1. Tight vertical exponential decay weighting (`exp(-y / 1.1)`) anchored strongly to row 0.
/// 2. Per-column robust RGB outlier suppression (`1 / (1 + (dist / 0.28)^2)`) to prevent single-pixel sparkle stripes without washing out contrast.
public enum HeroTopEdgeSynthesizer {
    public static func synthesizeWeightedStrip(
        topBandRGBA: [UInt8],
        width: Int,
        rows: Int,
        outputHeight: Int = 1
    ) -> [UInt8] {
        guard width > 0, rows > 0, outputHeight > 0, topBandRGBA.count >= width * rows * 4 else {
            return []
        }

        let tau = 1.1
        var vertWeights = [Double](repeating: 1.0, count: rows)
        for y in 0..<rows {
            vertWeights[y] = exp(-Double(y) / tau)
        }

        var rowRGBA = [UInt8](repeating: 255, count: width * 4)

        var rVals = [Double](repeating: 0, count: rows)
        var gVals = [Double](repeating: 0, count: rows)
        var bVals = [Double](repeating: 0, count: rows)

        for x in 0..<width {
            // Pass 1: unweighted per-channel median across the column's top rows so a single row-0 sparkle cannot bias the reference
            for y in 0..<rows {
                let idx = (y * width + x) * 4
                rVals[y] = Double(topBandRGBA[idx]) / 255.0
                gVals[y] = Double(topBandRGBA[idx + 1]) / 255.0
                bVals[y] = Double(topBandRGBA[idx + 2]) / 255.0
            }
            let mid = rows / 2
            let medR = rVals.sorted()[mid]
            let medG = gVals.sorted()[mid]
            let medB = bVals.sorted()[mid]

            // Pass 2: exponential decay + robust RGB distance re-weighting against column median (zero horizontal blur, zero contrast loss)
            var rAcc = 0.0, gAcc = 0.0, bAcc = 0.0, wAcc = 0.0
            for y in 0..<rows {
                let r = rVals[y]
                let g = gVals[y]
                let b = bVals[y]
                let dr = r - medR
                let dg = g - medG
                let db = b - medB
                let distSq = dr * dr + dg * dg + db * db
                let outlierWeight = 1.0 / (1.0 + distSq / (0.28 * 0.28))
                let w = vertWeights[y] * outlierWeight
                rAcc += r * w
                gAcc += g * w
                bAcc += b * w
                wAcc += w
            }
            let rFinal = wAcc > 0 ? (rAcc / wAcc) : medR
            let gFinal = wAcc > 0 ? (gAcc / wAcc) : medG
            let bFinal = wAcc > 0 ? (bAcc / wAcc) : medB

            let outIdx = x * 4
            rowRGBA[outIdx] = UInt8(max(0, min(255, Int((rFinal * 255.0).rounded()))))
            rowRGBA[outIdx + 1] = UInt8(max(0, min(255, Int((gFinal * 255.0).rounded()))))
            rowRGBA[outIdx + 2] = UInt8(max(0, min(255, Int((bFinal * 255.0).rounded()))))
            rowRGBA[outIdx + 3] = 255
        }

        if outputHeight == 1 {
            return rowRGBA
        }
        var out = [UInt8](repeating: 255, count: width * outputHeight * 4)
        let rowBytes = width * 4
        for y in 0..<outputHeight {
            out.replaceSubrange((y * rowBytes)..<((y + 1) * rowBytes), with: rowRGBA)
        }
        return out
    }
}

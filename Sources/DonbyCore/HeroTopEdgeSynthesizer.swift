import Foundation

/// Synthesizes a smooth, artifact-free vertical top-edge extension texture from a poster's top pixel band.
/// Uses 4-stage weighting:
/// 1. Vertical exponential decay weighting (`exp(-y / 3.5)`) favoring pixels nearest the top edge.
/// 2. Robust luminance outlier suppression (`1 / (1 + (|L - meanL| / 0.22)^2)`) to reject bright speckles/lights.
/// 3. Multi-pass 1D Gaussian horizontal smoothing (`[1, 4, 6, 4, 1]` x 3) to prevent barcode striping while preserving left-to-right color gradients.
/// 4. Vertical atmospheric diffusion from exact local column color at the poster seam (`row = outputHeight - 1`) toward the global weighted top mean (`row = 0`).
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

        // Precompute vertical exponential decay weights (row 0 = top-most sampled row nearest poster edge)
        let tau = 3.5
        var vertWeights = [Double](repeating: 1.0, count: rows)
        for y in 0..<rows {
            vertWeights[y] = exp(-Double(y) / tau)
        }

        // Stage 1 + 2: Per-column weighted average with luminance outlier suppression
        var colR = [Double](repeating: 0, count: width)
        var colG = [Double](repeating: 0, count: width)
        var colB = [Double](repeating: 0, count: width)

        for x in 0..<width {
            // First pass: weighted mean luminance for this column
            var lumaSum = 0.0
            var wSum0 = 0.0
            for y in 0..<rows {
                let idx = (y * width + x) * 4
                let r = Double(topBandRGBA[idx]) / 255.0
                let g = Double(topBandRGBA[idx + 1]) / 255.0
                let b = Double(topBandRGBA[idx + 2]) / 255.0
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let w = vertWeights[y]
                lumaSum += luma * w
                wSum0 += w
            }
            let meanLuma = wSum0 > 0 ? (lumaSum / wSum0) : 0.5

            // Second pass: Huber-like outlier suppression against bright speckles or dark edge artifacts
            var rAcc = 0.0, gAcc = 0.0, bAcc = 0.0, wAcc = 0.0
            for y in 0..<rows {
                let idx = (y * width + x) * 4
                let r = Double(topBandRGBA[idx]) / 255.0
                let g = Double(topBandRGBA[idx + 1]) / 255.0
                let b = Double(topBandRGBA[idx + 2]) / 255.0
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let diff = abs(luma - meanLuma) / 0.22
                let outlierWeight = 1.0 / (1.0 + diff * diff)
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

        // Stage 3: 3-pass separable 1D Gaussian smoothing ([1, 4, 6, 4, 1] / 16) with edge clamping
        @inline(__always)
        func smooth1D(_ src: [Double]) -> [Double] {
            guard src.count >= 3 else { return src }
            var cur = src
            var tmp = [Double](repeating: 0, count: src.count)
            let last = src.count - 1
            for _ in 0..<3 {
                for x in 0...last {
                    let xm2 = max(0, x - 2)
                    let xm1 = max(0, x - 1)
                    let xp1 = min(last, x + 1)
                    let xp2 = min(last, x + 2)
                    tmp[x] = (cur[xm2] + 4.0 * cur[xm1] + 6.0 * cur[x] + 4.0 * cur[xp1] + cur[xp2]) / 16.0
                }
                swap(&cur, &tmp)
            }
            return cur
        }

        colR = smooth1D(colR)
        colG = smooth1D(colG)
        colB = smooth1D(colB)

        // Global top-edge mean for atmospheric upward diffusion
        let invW = 1.0 / Double(width)
        let globalR = colR.reduce(0, +) * invW
        let globalG = colG.reduce(0, +) * invW
        let globalB = colB.reduce(0, +) * invW

        // Stage 4: Build 2D vertical diffusion strip (bottom row = exact poster top edge, top row = diffused horizon)
        var out = [UInt8](repeating: 255, count: width * outputHeight * 4)
        let maxY = max(1, outputHeight - 1)
        for y in 0..<outputHeight {
            // t = 0 at bottom (touching poster top edge), t = 1 at top (deep overscroll)
            let t = Double(maxY - y) / Double(maxY)
            let globalMix = 0.48 * pow(t, 1.25)
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

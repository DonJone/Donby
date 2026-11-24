import Accelerate
import Foundation

extension SubtitleAutoAligner {
    private static let cinemaScaleCandidates: [Double] = [
        1.0,
        25.0 / (24_000.0 / 1001.0),   // 23.976 -> 25.000 PAL speedup (~1.042708)
        (24_000.0 / 1001.0) / 25.0,   // 25.000 -> 23.976 (~0.959041)
        24.0 / (24_000.0 / 1001.0),   // 23.976 -> 24.000 (~1.001000)
        (24_000.0 / 1001.0) / 24.0,   // 24.000 -> 23.976 (~0.999001)
        25.0 / 24.0,                  // 24.000 -> 25.000 (~1.041667)
        24.0 / 25.0                   // 25.000 -> 24.000 (~0.960000)
    ]

    // MARK: - Dual-Subtitle Auto-Alignment (Constant Shift + Cinema FPS Drift)

    public static func alignDualSubtitles(
        primaryCues: [SubtitleCueInterval],
        secondaryCues: [SubtitleCueInterval],
        currentPrimaryDelay: Double = 0.0,
        maxShiftSeconds: Double = 120.0
    ) -> DualSubtitleAlignmentOutcome {
        let pri = filterDialogueCues(primaryCues)
        let sec = filterDialogueCues(secondaryCues)
        guard pri.count >= 5, sec.count >= 5 else {
            return .insufficientData("可用主/副字幕条数不足 (主 \(pri.count) / 副 \(sec.count))，请稍候重试")
        }

        let priSpan = (pri.last?.endSeconds ?? 0) - (pri.first?.startSeconds ?? 0)
        let secSpan = (sec.last?.endSeconds ?? 0) - (sec.first?.startSeconds ?? 0)
        let allowScaleSearch = (pri.count >= 14 && sec.count >= 14 && min(priSpan, secSpan) >= 180.0)

        struct ScaleEval {
            let scale: Double
            let offset: Double
            let mad: Double
            let inliers: Int
            let inlierRatio: Double
            let corr: Double
            let score: Double
        }

        func evaluateCandidate(scale: Double) -> ScaleEval? {
            let scaledSec = (abs(scale - 1.0) < 1e-9)
                ? sec
                : sec.map { SubtitleCueInterval(startSeconds: $0.startSeconds * scale, endSeconds: $0.endSeconds * scale) }

            let candidateShifts = coarseAndFineEnvelopeShiftCandidates(
                primary: pri,
                secondary: scaledSec,
                maxShiftSeconds: maxShiftSeconds
            )
            guard !candidateShifts.isEmpty else { return nil }

            var bestForScale: ScaleEval? = nil
            for candShift in candidateShifts {
                var deltas: [Double] = []
                deltas.reserveCapacity(scaledSec.count)
                var j = 0
                for idx in 0..<scaledSec.count {
                    let sc = scaledSec[idx]
                    let predStart = sc.startSeconds + candShift.shift
                    let predMid = sc.midpoint + candShift.shift
                    while j + 1 < pri.count && pri[j + 1].startSeconds < predStart - 1.6 {
                        j += 1
                    }
                    var bestDist = Double.greatestFiniteMagnitude
                    var bestPriIdx = -1
                    var scan = j
                    while scan < pri.count && pri[scan].startSeconds <= predStart + 1.6 {
                        let pc = pri[scan]
                        let durRatio = max(pc.duration, 0.05) / max(sc.duration, 0.05)
                        if durRatio >= 0.22 && durRatio <= 4.5 {
                            let dStart = abs(pc.startSeconds - predStart)
                            let dMid = abs(pc.midpoint - predMid)
                            let dist = 0.7 * dStart + 0.3 * dMid
                            if dist < bestDist {
                                bestDist = dist
                                bestPriIdx = scan
                            }
                        }
                        scan += 1
                    }
                    if bestPriIdx >= 0 && bestDist <= 1.6 {
                        let pc = pri[bestPriIdx]
                        let res = 0.7 * (pc.startSeconds - predStart) + 0.3 * (pc.midpoint - predMid)
                        deltas.append(res)
                    }
                }

                guard deltas.count >= 4 else { continue }
                let medDelta = median(of: deltas)
                let refinedOffset = candShift.shift + medDelta

                var absRes: [Double] = []
                absRes.reserveCapacity(deltas.count)
                var inliers = 0
                for d in deltas {
                    let err = abs(d - medDelta)
                    if err <= 0.65 {
                        inliers += 1
                        absRes.append(err)
                    }
                }
                guard inliers >= 4 else { continue }
                let mad = median(of: absRes)
                let denom = Double(min(pri.count, sec.count))
                let ratio = min(1.0, Double(inliers) / max(1.0, denom))
                // Small near-zero tie-breaker prevents sparse far-away edge flukes from beating a dense near-zero match
                let shiftPenalty = 0.02 * min(1.0, abs(refinedOffset) / 60.0)
                let quality = ratio * 0.58 + max(0.0, 1.0 - mad / 0.55) * 0.27 + min(1.0, max(0.0, candShift.corr)) * 0.15 - shiftPenalty
                let eval = ScaleEval(
                    scale: scale,
                    offset: refinedOffset,
                    mad: mad,
                    inliers: inliers,
                    inlierRatio: ratio,
                    corr: candShift.corr,
                    score: quality
                )
                if bestForScale == nil || eval.score > bestForScale!.score {
                    bestForScale = eval
                }
            }
            return bestForScale
        }

        let unityEval = evaluateCandidate(scale: 1.0)
        var bestEval = unityEval

        let needsScaleCheck = allowScaleSearch && (
            unityEval == nil ||
            (unityEval!.mad > 0.14 || unityEval!.inlierRatio < 0.72)
        )
        if needsScaleCheck {
            for candidateScale in cinemaScaleCandidates where abs(candidateScale - 1.0) > 1e-6 {
                guard let cand = evaluateCandidate(scale: candidateScale) else { continue }
                let beatsUnity: Bool
                if let u = unityEval {
                    let madImproved = cand.mad <= u.mad * 0.60 && cand.mad <= 0.25
                    let inliersImproved = Double(cand.inliers) >= Double(u.inliers) * 1.18 && cand.mad <= 0.25
                    beatsUnity = (madImproved || inliersImproved) && cand.score > u.score + 0.06
                } else {
                    beatsUnity = cand.mad <= 0.28 && cand.inliers >= 10
                }
                if beatsUnity {
                    if bestEval == nil || cand.score > bestEval!.score {
                        bestEval = cand
                    }
                }
            }
        }

        guard let chosen = bestEval else {
            return .lowConfidence(reason: "主副字幕时间轴重叠度过低，无法可靠对齐")
        }

        let isValid = (chosen.inliers >= 5 && chosen.inlierRatio >= 0.30 && chosen.mad <= 0.45) ||
                      (chosen.inliers >= 16 && chosen.inlierRatio >= 0.25 && chosen.mad <= 0.35)
        guard isValid else {
            return .lowConfidence(reason: "主副字幕匹配比例过低 (\(chosen.inliers) 条 / \(Int((chosen.inlierRatio * 100).rounded()))%)，请播放更多对白后重试")
        }

        let roundedOffset = roundCenti(chosen.offset)
        let targetSecondaryDelay = roundCenti(roundedOffset + currentPrimaryDelay)
        let drifted = abs(chosen.scale - 1.0) > 5e-4
        let confidence = min(0.99, max(0.0, chosen.score))

        return .aligned(DualSubtitleAlignmentResult(
            rawOffsetSeconds: roundedOffset,
            suggestedSecondaryDelaySeconds: targetSecondaryDelay,
            secondaryTimeScale: drifted ? chosen.scale : 1.0,
            detectedFrameRateDrift: drifted,
            confidence: confidence,
            residualMADSeconds: chosen.mad,
            matchedPairCount: chosen.inliers
        ))
    }

    // MARK: - Internal DSP & Geometry Helpers

    static func roundCenti(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }

    static func smoothVAD(_ vadProbabilities: [Float]) -> [Float] {
        let n = vadProbabilities.count
        var smooth = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let prev = i > 0 ? vadProbabilities[i - 1] : vadProbabilities[i]
            let next = i + 1 < n ? vadProbabilities[i + 1] : vadProbabilities[i]
            smooth[i] = 0.25 * prev + 0.5 * vadProbabilities[i] + 0.25 * next
        }
        return smooth
    }

    static func buildAudioActivityVector(vadProbabilities: [Float]) -> [Float] {
        buildAudioActivityVector(smoothedVAD: smoothVAD(vadProbabilities))
    }

    static func buildAudioActivityVector(smoothedVAD smooth: [Float]) -> [Float] {
        let n = smooth.count
        var aVec = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let base = max(0, (smooth[i] - 0.15) / 0.85)
            let prev2 = i >= 2 ? smooth[i - 2] : smooth[0]
            let onset = max(0, smooth[i] - prev2)
            aVec[i] = base + 0.45 * onset
        }
        return aVec
    }

    static func buildPrefixSums(_ values: [Float]) -> (sum: [Double], sum2: [Double]) {
        let n = values.count
        var sum = [Double](repeating: 0, count: n + 1)
        var sum2 = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let v = Double(values[i])
            sum[i + 1] = sum[i] + v
            sum2[i + 1] = sum2[i] + v * v
        }
        return (sum, sum2)
    }

    @inline(__always)
    static func pearsonCorrelation(
        aBase: UnsafePointer<Float>,
        aStart: Int,
        prefA: (sum: [Double], sum2: [Double]),
        bBase: UnsafePointer<Float>,
        bStart: Int,
        prefB: (sum: [Double], sum2: [Double]),
        count: Int,
        minSamples: Int = 1,
        minVariance: Double
    ) -> Double? {
        guard count >= minSamples else { return nil }
        let invLen = 1.0 / Double(count)
        let sumA = prefA.sum[aStart + count] - prefA.sum[aStart]
        let sumA2 = prefA.sum2[aStart + count] - prefA.sum2[aStart]
        let varA = sumA2 - sumA * sumA * invLen
        guard varA > minVariance else { return nil }

        let sumB = prefB.sum[bStart + count] - prefB.sum[bStart]
        let sumB2 = prefB.sum2[bStart + count] - prefB.sum2[bStart]
        let varB = sumB2 - sumB * sumB * invLen
        guard varB > minVariance else { return nil }

        var dot: Float = 0
        vDSP_dotpr(aBase.advanced(by: aStart), 1, bBase.advanced(by: bStart), 1, &dot, vDSP_Length(count))
        return (Double(dot) - sumA * sumB * invLen) / sqrt(varA * varB)
    }

    static func rasterizeCueEnvelope(
        cues: [SubtitleCueInterval],
        origin: Double,
        windowEnd: Double? = nil,
        count: Int,
        dt: Double,
        onsetPeak: Float,
        onsetExtraBins: Int
    ) -> [Float] {
        var vec = [Float](repeating: 0, count: count)
        for cue in cues {
            if let windowEnd, cue.endSeconds < origin || cue.startSeconds > windowEnd {
                continue
            }
            let c0 = max(0, Int(floor((cue.startSeconds - origin) / dt)))
            let c1 = min(count - 1, Int(ceil((cue.endSeconds - origin) / dt)))
            guard c1 >= c0 else { continue }
            for idx in c0...c1 where vec[idx] < 1.0 { vec[idx] = 1.0 }
            let onsetEnd = min(count - 1, c0 + onsetExtraBins)
            for idx in c0...onsetEnd { vec[idx] = max(vec[idx], onsetPeak) }
        }
        return vec
    }

    static func filterDialogueCues(_ cues: [SubtitleCueInterval]) -> [SubtitleCueInterval] {
        let valid = cues
            .filter { $0.duration >= 0.12 && $0.duration <= 14.0 && $0.startSeconds >= 0 }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !valid.isEmpty else { return [] }

        var merged: [SubtitleCueInterval] = []
        merged.reserveCapacity(valid.count)
        for cue in valid {
            if let last = merged.last, abs(cue.startSeconds - last.startSeconds) <= 0.05 {
                if cue.endSeconds > last.endSeconds {
                    merged[merged.count - 1] = SubtitleCueInterval(startSeconds: last.startSeconds, endSeconds: cue.endSeconds)
                }
            } else {
                merged.append(cue)
            }
        }
        return merged
    }

    /// Overlap-clipped 2-stage coarse (`0.25s`) -> fine (`0.04s`) envelope cross-correlation returning top distinct candidate shifts
    /// (plus `0.0s` baseline), preventing empty-void edge inflation on freshly demuxed embedded subtitle windows.
    static func coarseAndFineEnvelopeShiftCandidates(
        primary: [SubtitleCueInterval],
        secondary: [SubtitleCueInterval],
        maxShiftSeconds: Double
    ) -> [(shift: Double, corr: Double)] {
        guard let priFirst = primary.first, let priLast = primary.last,
              let secFirst = secondary.first, let secLast = secondary.last else {
            return []
        }

        let priSpan = max(0.0, priLast.endSeconds - priFirst.startSeconds)
        let secSpan = max(0.0, secLast.endSeconds - secFirst.startSeconds)
        let minTrackSpan = min(priSpan, secSpan)
        guard minTrackSpan >= 2.0 else { return [] }

        // Never search lags larger than ~45% of the buffered embedded subtitle span (prevents ±70s void jumps on 80s clips)
        let effectiveMaxShift = (minTrackSpan < 260.0)
            ? min(maxShiftSeconds, max(12.0, minTrackSpan * 0.45))
            : maxShiftSeconds

        let spanStart = max(0.0, priFirst.startSeconds)
        let spanEnd = priLast.endSeconds
        let totalSpan = spanEnd - spanStart
        guard totalSpan >= 2.0 else { return [] }

        var windows: [(Double, Double)] = []
        if totalSpan <= 1500.0 {
            windows.append((spanStart, spanEnd))
        } else {
            let winLen = 480.0
            windows.append((spanStart, spanStart + winLen))
            let mid = spanStart + 0.5 * totalSpan
            windows.append((mid - 0.5 * winLen, mid + 0.5 * winLen))
            windows.append((spanEnd - winLen, spanEnd))
        }

        func correlateTopPeaks(dt: Double, lagMinSec: Double, lagMaxSec: Double, maxPeaks: Int, minSepSec: Double) -> [(shift: Double, corr: Double)] {
            let kMin = Int(floor(lagMinSec / dt))
            let kMax = Int(ceil(lagMaxSec / dt))
            let lagCount = kMax - kMin + 1
            guard lagCount >= 1 else { return [] }

            var scoreSum = [Double](repeating: 0, count: lagCount)
            var weightSum = [Double](repeating: 0, count: lagCount)

            for (wStart, wEnd) in windows {
                let n = max(16, Int(ceil((wEnd - wStart) / dt)))
                let pVec = rasterizeCueEnvelope(cues: primary, origin: wStart, windowEnd: wEnd, count: n, dt: dt, onsetPeak: 1.5, onsetExtraBins: 0)
                let prefP = buildPrefixSums(pVec)

                let sOrigin = wStart - Double(kMax) * dt
                let sLen = n + (kMax - kMin) + 2
                let sWinEnd = sOrigin + Double(sLen) * dt
                let sVec = rasterizeCueEnvelope(cues: secondary, origin: sOrigin, windowEnd: sWinEnd, count: sLen, dt: dt, onsetPeak: 1.5, onsetExtraBins: 0)
                let prefS = buildPrefixSums(sVec)

                let minOvSamples = max(12, Int(ceil(0.50 * Double(n))))

                sVec.withUnsafeBufferPointer { sPtr in
                    pVec.withUnsafeBufferPointer { pPtr in
                        guard let sBase = sPtr.baseAddress, let pBase = pPtr.baseAddress else { return }
                        for li in 0..<lagCount {
                            let k = kMin + li
                            let lagSec = Double(k) * dt
                            // Clip strictly to the valid overlap where secondary actually has demuxed cues
                            let ovStart = max(wStart, secFirst.startSeconds + lagSec - 2.0)
                            let ovEnd = min(wEnd, secLast.endSeconds + lagSec + 2.0)
                            let i0 = max(0, Int(ceil((ovStart - wStart) / dt)))
                            let i1 = min(n, Int(floor((ovEnd - wStart) / dt)))
                            let ovN = i1 - i0
                            guard ovN >= minOvSamples else { continue }

                            let sIdx = (kMax - k) + i0
                            guard let r = pearsonCorrelation(
                                aBase: pBase, aStart: i0, prefA: prefP,
                                bBase: sBase, bStart: sIdx, prefB: prefS,
                                count: ovN, minSamples: 1, minVariance: 1e-4
                            ) else { continue }

                            let ovFrac = Double(ovN) / Double(n)
                            // Weight by overlap fraction so sparse partial overlaps never outrank dense full overlaps
                            let w = ovFrac * Double(ovN)
                            scoreSum[li] += (r * sqrt(ovFrac)) * w
                            weightSum[li] += w
                        }
                    }
                }
            }

            var scored: [(li: Int, score: Double)] = []
            scored.reserveCapacity(lagCount)
            for li in 0..<lagCount where weightSum[li] > 0 {
                scored.append((li, scoreSum[li] / weightSum[li]))
            }
            scored.sort { $0.score > $1.score }

            let sepBins = max(1, Int(ceil(minSepSec / dt)))
            var peaks: [(shift: Double, corr: Double)] = []
            var pickedLi: [Int] = []
            for item in scored {
                if pickedLi.allSatisfy({ abs($0 - item.li) >= sepBins }) {
                    pickedLi.append(item.li)
                    peaks.append((Double(kMin + item.li) * dt, item.score))
                    if peaks.count >= maxPeaks { break }
                }
            }
            return peaks
        }

        var coarseSeeds = correlateTopPeaks(
            dt: 0.25,
            lagMinSec: -effectiveMaxShift,
            lagMaxSec: effectiveMaxShift,
            maxPeaks: 4,
            minSepSec: 2.0
        )
        // Always include near-zero baseline candidate so closely aligned tracks are guaranteed evaluation
        if coarseSeeds.allSatisfy({ abs($0.shift) > 1.5 }) {
            coarseSeeds.append((0.0, 0.0))
        }

        var refined: [(shift: Double, corr: Double)] = []
        for seed in coarseSeeds {
            if let fine = correlateTopPeaks(
                dt: 0.04,
                lagMinSec: seed.shift - 1.5,
                lagMaxSec: seed.shift + 1.5,
                maxPeaks: 1,
                minSepSec: 0.5
            ).first {
                if refined.allSatisfy({ abs($0.shift - fine.shift) > 0.35 }) {
                    refined.append(fine)
                }
            } else if refined.allSatisfy({ abs($0.shift - seed.shift) > 0.35 }) {
                refined.append(seed)
            }
        }
        return refined
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return 0.5 * (sorted[mid - 1] + sorted[mid])
    }
}

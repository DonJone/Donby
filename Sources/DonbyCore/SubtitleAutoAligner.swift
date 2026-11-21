import Accelerate
import Foundation

// MARK: - Subtitle Interval & Alignment Result Models

public struct SubtitleCueInterval: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var duration: Double { endSeconds - startSeconds }
    public var midpoint: Double { 0.5 * (startSeconds + endSeconds) }
}

public struct AudioSubtitleAlignmentResult: Equatable, Sendable {
    /// Target `primaryDelaySeconds` (= t_audio - t_sub_raw) to apply in SubtitleStyleConfiguration.
    public let suggestedPrimaryDelaySeconds: Double
    /// Confidence score normalized to [0, 1].
    public let confidence: Double
    /// Peak Pearson correlation score over the valid overlap.
    public let peakCorrelation: Double
    /// Peak z-score over background lag correlation distribution.
    public let zScore: Double
    /// Split-half Pearson correlation on first half of the overlap (0 if too short to split).
    public let firstHalfCorrelation: Double
    /// Split-half Pearson correlation on second half of the overlap (0 if too short to split).
    public let secondHalfCorrelation: Double
    /// Correlation evaluated at the caller's existing delay.
    public let currentDelayCorrelation: Double
    /// Total detected speech seconds inside the analyzed audio window.
    public let speechSeconds: Double
    /// Analyzed audio window duration in seconds.
    public let analyzedAudioSeconds: Double
    /// Number of candidate subtitle cues overlapping the aligned window.
    public let matchedCueCount: Int
    /// Whether the subtitle was already within ±0.14s of the best audio match.
    public let alreadyAligned: Bool
}

public enum AudioSubtitleAlignmentOutcome: Equatable, Sendable {
    case aligned(AudioSubtitleAlignmentResult)
    case insufficientData(String)
    case lowConfidence(bestDelaySeconds: Double, confidence: Double, reason: String)
}

public struct DualSubtitleAlignmentResult: Equatable, Sendable {
    /// Raw offset such that t_pri_raw ~= secondaryTimeScale * t_sec_raw + rawOffsetSeconds.
    public let rawOffsetSeconds: Double
    /// Target `secondaryDelaySeconds` (= rawOffsetSeconds + currentPrimaryDelay).
    public let suggestedSecondaryDelaySeconds: Double
    /// Linear time scale (1.0 for pure shift, or cinema ratio such as 25/23.976 or 23.976/25).
    public let secondaryTimeScale: Double
    /// Whether a non-unity frame-rate drift scale was confirmed.
    public let detectedFrameRateDrift: Bool
    /// Normalized confidence in [0, 1].
    public let confidence: Double
    /// Median absolute deviation (seconds) of paired inlier cues after alignment.
    public let residualMADSeconds: Double
    /// Number of matched cue pairs supporting this alignment.
    public let matchedPairCount: Int
}

public enum DualSubtitleAlignmentOutcome: Equatable, Sendable {
    case aligned(DualSubtitleAlignmentResult)
    case insufficientData(String)
    case lowConfidence(reason: String)
}

/// Unified audio-first alignment plan that guarantees the audio track is treated as ground truth.
public struct UnifiedSubtitleAlignmentPlan: Equatable, Sendable {
    public let primaryDelaySeconds: Double
    public let secondaryDelaySeconds: Double
    public let secondaryTimeScale: Double
    public let detectedFrameRateDrift: Bool
    public let alreadyAligned: Bool
    public let confidence: Double
    public let summaryMessage: String
    public let diagnosticLog: String
}

public enum UnifiedSubtitleAlignmentOutcome: Equatable, Sendable {
    case applied(UnifiedSubtitleAlignmentPlan)
    case failed(userMessage: String, diagnosticLog: String)
}

public enum SileroVADError: LocalizedError, Sendable {
    case modelNotFound
    case invalidSafetensors(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "未找到内置 Silero VAD 语音模型文件 (silero_vad_16k.safetensors)"
        case .invalidSafetensors(let detail):
            return "Silero VAD 模型加载失败: \(detail)"
        }
    }
}

// MARK: - Native Accelerate Silero VAD (16kHz, v5/v6)

/// Zero-dependency native Apple Accelerate forward pass for official Silero VAD 16kHz weights (`safetensors`).
/// Verified to match official `silero_vad.jit` / `silero_vad_16k_op15.onnx` within ~1e-7 max abs diff.
public final class SileroVAD: @unchecked Sendable {
    public static let sampleRate: Int = 16_000
    public static let frameSize: Int = 512
    public static let contextSize: Int = 64
    public static let frameDurationSeconds: Double = Double(frameSize) / Double(sampleRate) // 0.032s

    private struct Weights {
        let stftW: [Float]      // [258, 256]
        let conv1W: [Float]     // [128, 129 * 3]
        let conv1B: [Float]     // [128]
        let conv2W: [Float]     // [64, 128 * 3]
        let conv2B: [Float]     // [64]
        let conv3W: [Float]     // [64, 64 * 3]
        let conv3B: [Float]     // [64]
        let conv4W: [Float]     // [128, 64 * 3]
        let conv4B: [Float]     // [128]
        let lstmWih: [Float]    // [512, 128]
        let lstmWhh: [Float]    // [512, 128]
        let lstmBias: [Float]   // [512] = bias_ih + bias_hh
        let finalW: [Float]     // [128]
        let finalB: Float
    }

    private let w: Weights
    private static let sharedLock = NSLock()
    private static var cachedShared: SileroVAD?

    public init(modelURL: URL) throws {
        self.w = try Self.loadWeights(from: modelURL)
    }

    public static func locateDefaultModelURL() -> URL? {
        let filename = "silero_vad_16k"
        let ext = "safetensors"
        if let bundled = Bundle.main.url(forResource: filename, withExtension: ext),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("\(filename).\(ext)"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        let repoRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(filename).\(ext)")
        if FileManager.default.fileExists(atPath: repoRelative.path) {
            return repoRelative
        }
        let cwdRelative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(filename).\(ext)")
        if FileManager.default.fileExists(atPath: cwdRelative.path) {
            return cwdRelative
        }
        return nil
    }

    public static func shared() throws -> SileroVAD {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = cachedShared {
            return existing
        }
        guard let url = locateDefaultModelURL() else {
            throw SileroVADError.modelNotFound
        }
        let instance = try SileroVAD(modelURL: url)
        cachedShared = instance
        return instance
    }

    /// Runs Silero VAD across contiguous 16kHz mono float PCM, returning one speech probability per 512-sample (32ms) frame.
    public func predictFrameProbabilities(pcm16k: [Float]) -> [Float] {
        let frameCount = pcm16k.count / Self.frameSize
        guard frameCount > 0 else { return [] }

        var probs = [Float](repeating: 0, count: frameCount)
        var context = [Float](repeating: 0, count: Self.contextSize)
        var h = [Float](repeating: 0, count: 128)
        var c = [Float](repeating: 0, count: 128)

        var x = [Float](repeating: 0, count: 576)
        var xp = [Float](repeating: 0, count: 640)
        var stftCol = [Float](repeating: 0, count: 256 * 4)
        var stftOut = [Float](repeating: 0, count: 258 * 4)
        var mag = [Float](repeating: 0, count: 129 * 4)
        var colBuf = [Float](repeating: 0, count: 129 * 3 * 4)
        var b1 = [Float](repeating: 0, count: 128 * 4)
        var b2 = [Float](repeating: 0, count: 64 * 2)
        var b3 = [Float](repeating: 0, count: 64 * 1)
        var b4 = [Float](repeating: 0, count: 128 * 1)
        var gatesIh = [Float](repeating: 0, count: 512)
        var gatesHh = [Float](repeating: 0, count: 512)

        pcm16k.withUnsafeBufferPointer { pcmPtr in
            guard let pcmBase = pcmPtr.baseAddress else { return }
            for frameIdx in 0..<frameCount {
                for i in 0..<64 { x[i] = context[i] }
                let chunkBase = pcmBase.advanced(by: frameIdx * Self.frameSize)
                for i in 0..<512 { x[64 + i] = chunkBase[i] }
                for i in 0..<64 { context[i] = x[512 + i] }

                for i in 0..<576 { xp[i] = x[i] }
                for k in 0..<64 { xp[576 + k] = x[574 - k] }

                for k in 0..<256 {
                    let row = k * 4
                    stftCol[row]     = xp[k]
                    stftCol[row + 1] = xp[128 + k]
                    stftCol[row + 2] = xp[256 + k]
                    stftCol[row + 3] = xp[384 + k]
                }
                vDSP_mmul(w.stftW, 1, stftCol, 1, &stftOut, 1, 258, 4, 256)
                for f in 0..<129 {
                    let rOff = f * 4
                    let iOff = (f + 129) * 4
                    for t in 0..<4 {
                        let re = stftOut[rOff + t]
                        let im = stftOut[iOff + t]
                        mag[rOff + t] = sqrtf(re * re + im * im)
                    }
                }

                Self.conv1dReLU(input: mag, inC: 129, inT: 4, weight: w.conv1W, bias: w.conv1B, outC: 128, stride: 1, colBuf: &colBuf, output: &b1)
                Self.conv1dReLU(input: b1,  inC: 128, inT: 4, weight: w.conv2W, bias: w.conv2B, outC: 64,  stride: 2, colBuf: &colBuf, output: &b2)
                Self.conv1dReLU(input: b2,  inC: 64,  inT: 2, weight: w.conv3W, bias: w.conv3B, outC: 64,  stride: 2, colBuf: &colBuf, output: &b3)
                Self.conv1dReLU(input: b3,  inC: 64,  inT: 1, weight: w.conv4W, bias: w.conv4B, outC: 128, stride: 1, colBuf: &colBuf, output: &b4)

                vDSP_mmul(w.lstmWih, 1, b4, 1, &gatesIh, 1, 512, 1, 128)
                vDSP_mmul(w.lstmWhh, 1, h,  1, &gatesHh, 1, 512, 1, 128)

                var logit = w.finalB
                for j in 0..<128 {
                    let gi = w.lstmBias[j] + gatesIh[j] + gatesHh[j]
                    let gf = w.lstmBias[128 + j] + gatesIh[128 + j] + gatesHh[128 + j]
                    let ggRaw = w.lstmBias[256 + j] + gatesIh[256 + j] + gatesHh[256 + j]
                    let go = w.lstmBias[384 + j] + gatesIh[384 + j] + gatesHh[384 + j]
                    let ig = 1.0 / (1.0 + expf(-gi))
                    let fg = 1.0 / (1.0 + expf(-gf))
                    let gg = tanhf(ggRaw)
                    let og = 1.0 / (1.0 + expf(-go))
                    let cNew = fg * c[j] + ig * gg
                    let hNew = og * tanhf(cNew)
                    c[j] = cNew
                    h[j] = hNew
                    if hNew > 0 {
                        logit += w.finalW[j] * hNew
                    }
                }
                probs[frameIdx] = 1.0 / (1.0 + expf(-logit))
            }
        }
        return probs
    }

    @inline(__always)
    private static func conv1dReLU(
        input: [Float],
        inC: Int,
        inT: Int,
        weight: [Float],
        bias: [Float],
        outC: Int,
        stride: Int,
        colBuf: inout [Float],
        output: inout [Float]
    ) {
        let outT = (inT + 2 - 3) / stride + 1
        let kRows = inC * 3
        for ic in 0..<inC {
            let inRow = ic * inT
            for k in 0..<3 {
                let colRow = (ic * 3 + k) * outT
                for ot in 0..<outT {
                    let it = ot * stride - 1 + k
                    colBuf[colRow + ot] = (it >= 0 && it < inT) ? input[inRow + it] : 0
                }
            }
        }
        vDSP_mmul(weight, 1, colBuf, 1, &output, 1, vDSP_Length(outC), vDSP_Length(outT), vDSP_Length(kRows))
        for oc in 0..<outC {
            let b = bias[oc]
            let row = oc * outT
            for ot in 0..<outT {
                let v = output[row + ot] + b
                output[row + ot] = v > 0 ? v : 0
            }
        }
    }

    private static func loadWeights(from url: URL) throws -> Weights {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 16 else {
            throw SileroVADError.invalidSafetensors("file too small")
        }
        var headerLenLE: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &headerLenLE) { dst in
            data.copyBytes(to: dst, from: 0..<8)
        }
        let headerLen = Int(UInt64(littleEndian: headerLenLE))
        guard headerLen > 2, 8 + headerLen <= data.count else {
            throw SileroVADError.invalidSafetensors("invalid header length \(headerLen)")
        }
        let headerData = data.subdata(in: 8..<(8 + headerLen))
        let rawObj = try JSONSerialization.jsonObject(with: headerData)
        guard let dict = rawObj as? [String: Any] else {
            throw SileroVADError.invalidSafetensors("header is not a JSON object")
        }
        let dataBaseOffset = 8 + headerLen

        func extractF32(_ name: String, expectedCount: Int) throws -> [Float] {
            guard let entry = dict[name] as? [String: Any],
                  let dtype = entry["dtype"] as? String,
                  dtype == "F32",
                  let offsets = entry["data_offsets"] as? [Int],
                  offsets.count == 2 else {
                throw SileroVADError.invalidSafetensors("missing or invalid tensor \(name)")
            }
            let start = dataBaseOffset + offsets[0]
            let end = dataBaseOffset + offsets[1]
            let byteCount = end - start
            guard start >= dataBaseOffset, end <= data.count, byteCount == expectedCount * MemoryLayout<Float>.size else {
                throw SileroVADError.invalidSafetensors("unexpected byte size for \(name): \(byteCount)")
            }
            var arr = [Float](repeating: 0, count: expectedCount)
            arr.withUnsafeMutableBytes { dst in
                _ = data.copyBytes(to: dst, from: start..<end)
            }
            return arr
        }

        let stftW   = try extractF32("stft_conv.weight", expectedCount: 258 * 256)
        let conv1W  = try extractF32("conv1.weight", expectedCount: 128 * 129 * 3)
        let conv1B  = try extractF32("conv1.bias", expectedCount: 128)
        let conv2W  = try extractF32("conv2.weight", expectedCount: 64 * 128 * 3)
        let conv2B  = try extractF32("conv2.bias", expectedCount: 64)
        let conv3W  = try extractF32("conv3.weight", expectedCount: 64 * 64 * 3)
        let conv3B  = try extractF32("conv3.bias", expectedCount: 64)
        let conv4W  = try extractF32("conv4.weight", expectedCount: 128 * 64 * 3)
        let conv4B  = try extractF32("conv4.bias", expectedCount: 128)
        let lstmWih = try extractF32("lstm_cell.weight_ih", expectedCount: 512 * 128)
        let lstmBih = try extractF32("lstm_cell.bias_ih", expectedCount: 512)
        let lstmWhh = try extractF32("lstm_cell.weight_hh", expectedCount: 512 * 128)
        let lstmBhh = try extractF32("lstm_cell.bias_hh", expectedCount: 512)
        let finalW  = try extractF32("final_conv.weight", expectedCount: 128)
        let finalBArr = try extractF32("final_conv.bias", expectedCount: 1)

        var lstmBias = [Float](repeating: 0, count: 512)
        vDSP_vadd(lstmBih, 1, lstmBhh, 1, &lstmBias, 1, 512)

        return Weights(
            stftW: stftW,
            conv1W: conv1W, conv1B: conv1B,
            conv2W: conv2W, conv2B: conv2B,
            conv3W: conv3W, conv3B: conv3B,
            conv4W: conv4W, conv4B: conv4B,
            lstmWih: lstmWih, lstmWhh: lstmWhh, lstmBias: lstmBias,
            finalW: finalW, finalB: finalBArr[0]
        )
    }
}

// MARK: - Subtitle Auto-Aligner (Audio-First Ground Truth + Dual-Subtitle Shift & FPS Drift)

public enum SubtitleAutoAligner {
    private static let cinemaScaleCandidates: [Double] = [
        1.0,
        25.0 / (24_000.0 / 1001.0),   // 23.976 -> 25.000 PAL speedup (~1.042708)
        (24_000.0 / 1001.0) / 25.0,   // 25.000 -> 23.976 (~0.959041)
        24.0 / (24_000.0 / 1001.0),   // 23.976 -> 24.000 (~1.001000)
        (24_000.0 / 1001.0) / 24.0,   // 24.000 -> 23.976 (~0.999001)
        25.0 / 24.0,                  // 24.000 -> 25.000 (~1.041667)
        24.0 / 25.0                   // 25.000 -> 24.000 (~0.960000)
    ]

    // MARK: 0. High-Level Audio-First Orchestrators (Audio Track Is Always Ground Truth)

    /// Button 1 ("字音对齐"): aligns active subtitle(s) to the audio track via Silero VAD.
    /// When dual subtitles are active, locks BOTH tracks to the audio track and to each other in one shot.
    public static func alignAudioFirst(
        pcm16k: [Float],
        audioStartPTS: Double,
        primaryCues: [SubtitleCueInterval],
        secondaryCues: [SubtitleCueInterval] = [],
        currentPrimaryDelay: Double = 0.0,
        currentSecondaryDelay: Double = 0.0,
        currentSecondaryScale: Double = 1.0,
        maxShiftSeconds: Double = 30.0,
        vad: SileroVAD? = nil
    ) throws -> UnifiedSubtitleAlignmentOutcome {
        let engine = try vad ?? SileroVAD.shared()
        let probs = engine.predictFrameProbabilities(pcm16k: pcm16k)
        return alignAudioFirst(
            vadProbabilities: probs,
            audioStartPTS: audioStartPTS,
            primaryCues: primaryCues,
            secondaryCues: secondaryCues,
            currentPrimaryDelay: currentPrimaryDelay,
            currentSecondaryDelay: currentSecondaryDelay,
            currentSecondaryScale: currentSecondaryScale,
            maxShiftSeconds: maxShiftSeconds
        )
    }

    public static func alignAudioFirst(
        vadProbabilities: [Float],
        audioStartPTS: Double,
        frameDuration dt: Double = SileroVAD.frameDurationSeconds,
        primaryCues: [SubtitleCueInterval],
        secondaryCues: [SubtitleCueInterval] = [],
        currentPrimaryDelay: Double = 0.0,
        currentSecondaryDelay: Double = 0.0,
        currentSecondaryScale: Double = 1.0,
        maxShiftSeconds: Double = 30.0
    ) -> UnifiedSubtitleAlignmentOutcome {
        let audioDur = Double(vadProbabilities.count) * dt
        let priAudio = alignSubtitleToVADProbabilities(
            vadProbabilities: vadProbabilities,
            audioStartPTS: audioStartPTS,
            frameDuration: dt,
            cues: primaryCues,
            currentPrimaryDelay: currentPrimaryDelay,
            maxShiftSeconds: maxShiftSeconds
        )

        let hasSecondary = !secondaryCues.isEmpty
        if !hasSecondary {
            switch priAudio {
            case .aligned(let res):
                let diag = String(
                    format: "mode=audio-single win=[%.1f..%.1f](%.1fs,speech=%.1fs) cues=%d delay=%.2f->%.2f r=%.3f z=%.2f h=(%.2f,%.2f) curR=%.3f already=%@",
                    audioStartPTS, audioStartPTS + audioDur, audioDur, res.speechSeconds,
                    res.matchedCueCount, currentPrimaryDelay, res.suggestedPrimaryDelaySeconds,
                    res.peakCorrelation, res.zScore, res.firstHalfCorrelation, res.secondHalfCorrelation,
                    res.currentDelayCorrelation, res.alreadyAligned ? "1" : "0"
                )
                let msg = res.alreadyAligned
                    ? String(format: "字音已对齐 (当前 %+.2fs，无需调整)", res.suggestedPrimaryDelaySeconds)
                    : String(format: "字音已对齐 %+.2fs · 置信度 %d%%", res.suggestedPrimaryDelaySeconds, Int((res.confidence * 100).rounded()))
                return .applied(UnifiedSubtitleAlignmentPlan(
                    primaryDelaySeconds: res.suggestedPrimaryDelaySeconds,
                    secondaryDelaySeconds: currentSecondaryDelay,
                    secondaryTimeScale: currentSecondaryScale,
                    detectedFrameRateDrift: false,
                    alreadyAligned: res.alreadyAligned,
                    confidence: res.confidence,
                    summaryMessage: msg,
                    diagnosticLog: diag
                ))
            case .insufficientData(let reason):
                return .failed(
                    userMessage: reason,
                    diagnosticLog: "mode=audio-single insufficient: audioDur=\(String(format: "%.1f", audioDur))s priCues=\(primaryCues.count) reason=\(reason)"
                )
            case .lowConfidence(let best, let conf, let reason):
                return .failed(
                    userMessage: reason,
                    diagnosticLog: String(format: "mode=audio-single lowConf: best=%+.2fs conf=%.2f audioDur=%.1fs reason=%@", best, conf, audioDur, reason)
                )
            }
        }

        // Dual subtitles active: compute dual relation + secondary-to-audio in < 5ms reusing the same VAD curve
        let dual = alignDualSubtitles(
            primaryCues: primaryCues,
            secondaryCues: secondaryCues,
            currentPrimaryDelay: currentPrimaryDelay,
            maxShiftSeconds: 120.0
        )
        let secAudio = alignSubtitleToVADProbabilities(
            vadProbabilities: vadProbabilities,
            audioStartPTS: audioStartPTS,
            frameDuration: dt,
            cues: secondaryCues,
            currentPrimaryDelay: currentSecondaryDelay,
            maxShiftSeconds: maxShiftSeconds
        )

        // Case 1: Primary locked cleanly to audio -> lock primary to audio, and lock secondary onto it via dual fit
        if case .aligned(let priRes) = priAudio {
            let targetPri = priRes.suggestedPrimaryDelaySeconds
            var targetSec = currentSecondaryDelay
            var targetScale = currentSecondaryScale
            var drifted = false
            var secNote = ""

            if case .aligned(let dualRes) = dual {
                targetSec = roundCenti(dualRes.rawOffsetSeconds + targetPri)
                targetScale = dualRes.secondaryTimeScale
                drifted = dualRes.detectedFrameRateDrift
                secNote = drifted
                    ? String(format: "dual(raw=%+.2f,scale=%.4f)", dualRes.rawOffsetSeconds, targetScale)
                    : String(format: "dual(raw=%+.2f)", dualRes.rawOffsetSeconds)
            } else if case .aligned(let secRes) = secAudio {
                targetSec = secRes.suggestedPrimaryDelaySeconds
                targetScale = 1.0
                secNote = String(format: "secVAD(%+.2f,r=%.2f)", targetSec, secRes.peakCorrelation)
            }

            let priMoved = abs(targetPri - currentPrimaryDelay) > 0.14
            let secMoved = abs(targetSec - currentSecondaryDelay) > 0.14 || abs(targetScale - currentSecondaryScale) > 5e-4
            let already = !priMoved && !secMoved
            let msg: String
            if already {
                msg = String(format: "双字幕均已与音轨对齐 (主 %+.2fs / 副 %+.2fs)", targetPri, targetSec)
            } else if drifted {
                msg = String(format: "字音已对齐: 主 %+.2fs · 副 %+.2fs (速率 %.4fx)", targetPri, targetSec, targetScale)
            } else {
                msg = String(format: "字音已对齐: 主 %+.2fs · 副 %+.2fs", targetPri, targetSec)
            }
            let diag = String(
                format: "mode=audio-dual(priAnchor) win=[%.1f..%.1f] pri=%.2f->%.2f(r=%.3f,z=%.2f,h=%.2f/%.2f) sec=%.2f->%.2f via=%@",
                audioStartPTS, audioStartPTS + audioDur, currentPrimaryDelay, targetPri,
                priRes.peakCorrelation, priRes.zScore, priRes.firstHalfCorrelation, priRes.secondHalfCorrelation,
                currentSecondaryDelay, targetSec, secNote
            )
            return .applied(UnifiedSubtitleAlignmentPlan(
                primaryDelaySeconds: targetPri,
                secondaryDelaySeconds: targetSec,
                secondaryTimeScale: targetScale,
                detectedFrameRateDrift: drifted,
                alreadyAligned: already,
                confidence: priRes.confidence,
                summaryMessage: msg,
                diagnosticLog: diag
            ))
        }

        // Case 2: Primary failed audio lock (e.g. shifted >30s) but Secondary locked cleanly to audio + Dual relation exists
        if case .aligned(let secRes) = secAudio, case .aligned(let dualRes) = dual, !dualRes.detectedFrameRateDrift {
            let targetSec = secRes.suggestedPrimaryDelaySeconds
            let targetPri = roundCenti(targetSec - dualRes.rawOffsetSeconds)
            let msg = String(format: "字音已对齐(副轨校准): 主 %+.2fs · 副 %+.2fs", targetPri, targetSec)
            let diag = String(
                format: "mode=audio-dual(secRescue) sec=%.2f->%.2f(r=%.3f,z=%.2f) dualRaw=%+.2f => pri=%.2f->%.2f",
                currentSecondaryDelay, targetSec, secRes.peakCorrelation, secRes.zScore,
                dualRes.rawOffsetSeconds, currentPrimaryDelay, targetPri
            )
            return .applied(UnifiedSubtitleAlignmentPlan(
                primaryDelaySeconds: targetPri,
                secondaryDelaySeconds: targetSec,
                secondaryTimeScale: 1.0,
                detectedFrameRateDrift: false,
                alreadyAligned: abs(targetPri - currentPrimaryDelay) <= 0.14 && abs(targetSec - currentSecondaryDelay) <= 0.14,
                confidence: secRes.confidence,
                summaryMessage: msg,
                diagnosticLog: diag
            ))
        }

        switch priAudio {
        case .insufficientData(let reason):
            return .failed(userMessage: reason, diagnosticLog: "mode=audio-dual insufficient: \(reason)")
        case .lowConfidence(let best, let conf, let reason):
            return .failed(userMessage: reason, diagnosticLog: String(format: "mode=audio-dual lowConf: priBest=%+.2fs conf=%.2f", best, conf))
        case .aligned:
            return .failed(userMessage: "字音对齐失败", diagnosticLog: "mode=audio-dual unexpected")
        }
    }

    /// Button 2 ("双字对齐"): aligns dual subtitles to each other AND uses Silero VAD (when speech is buffered)
    /// to pick whichever subtitle track is closer to the true audio track as anchor (preventing dragging an accurate track off-sync).
    public static func alignDualAudioAnchored(
        primaryCues: [SubtitleCueInterval],
        secondaryCues: [SubtitleCueInterval],
        pcm16k: [Float] = [],
        audioStartPTS: Double = 0.0,
        currentPrimaryDelay: Double = 0.0,
        currentSecondaryDelay: Double = 0.0,
        currentSecondaryScale: Double = 1.0,
        maxShiftSeconds: Double = 120.0,
        vad: SileroVAD? = nil
    ) -> UnifiedSubtitleAlignmentOutcome {
        var probs: [Float] = []
        if pcm16k.count >= SileroVAD.sampleRate * 10, let engine = try? (vad ?? SileroVAD.shared()) {
            probs = engine.predictFrameProbabilities(pcm16k: pcm16k)
        }
        return alignDualAudioAnchored(
            primaryCues: primaryCues,
            secondaryCues: secondaryCues,
            vadProbabilities: probs,
            audioStartPTS: audioStartPTS,
            currentPrimaryDelay: currentPrimaryDelay,
            currentSecondaryDelay: currentSecondaryDelay,
            currentSecondaryScale: currentSecondaryScale,
            maxShiftSeconds: maxShiftSeconds
        )
    }

    public static func alignDualAudioAnchored(
        primaryCues: [SubtitleCueInterval],
        secondaryCues: [SubtitleCueInterval],
        vadProbabilities: [Float] = [],
        audioStartPTS: Double = 0.0,
        frameDuration dt: Double = SileroVAD.frameDurationSeconds,
        currentPrimaryDelay: Double = 0.0,
        currentSecondaryDelay: Double = 0.0,
        currentSecondaryScale: Double = 1.0,
        maxShiftSeconds: Double = 120.0
    ) -> UnifiedSubtitleAlignmentOutcome {
        let dualOutcome = alignDualSubtitles(
            primaryCues: primaryCues,
            secondaryCues: secondaryCues,
            currentPrimaryDelay: currentPrimaryDelay,
            maxShiftSeconds: maxShiftSeconds
        )
        let dual: DualSubtitleAlignmentResult
        switch dualOutcome {
        case .aligned(let res):
            dual = res
        case .insufficientData(let reason):
            return .failed(userMessage: reason, diagnosticLog: "mode=dual insufficient: \(reason)")
        case .lowConfidence(let reason):
            return .failed(userMessage: reason, diagnosticLog: "mode=dual lowConf: \(reason)")
        }

        // Default fallback (if no audio speech available): anchor to primary, move secondary
        var targetPri = currentPrimaryDelay
        var targetSec = dual.suggestedSecondaryDelaySeconds
        let targetScale = dual.secondaryTimeScale
        var anchorTag = "主字幕基准"
        var diagExtra = "vad=skipped"

        // If enough audio is buffered, verify against Audio Ground Truth so we NEVER drag a synced track toward a drifted one!
        if Double(vadProbabilities.count) * dt >= 10.0 {
            let priAtCur = evaluateVADCorrelation(
                vadProbabilities: vadProbabilities,
                audioStartPTS: audioStartPTS,
                frameDuration: dt,
                cues: primaryCues,
                delaySeconds: currentPrimaryDelay
            )
            let secAtCur = evaluateVADCorrelation(
                vadProbabilities: vadProbabilities,
                audioStartPTS: audioStartPTS,
                frameDuration: dt,
                cues: secondaryCues,
                delaySeconds: currentSecondaryDelay
            )
            diagExtra = String(format: "vadCur(priR=%.3f,secR=%.3f)", priAtCur, secAtCur)

            if !dual.detectedFrameRateDrift && secAtCur >= 0.25 && secAtCur > priAtCur + 0.08 {
                // Secondary is clearly synced to audio while Primary is off -> anchor to Secondary and pull Primary to it!
                targetSec = currentSecondaryDelay
                targetPri = roundCenti(currentSecondaryDelay - dual.rawOffsetSeconds)
                anchorTag = "音轨验证·副字幕基准"
                diagExtra += " decision=secAnchor"
            } else if priAtCur >= 0.25 && priAtCur >= secAtCur - 0.04 {
                // Primary is already synced to audio -> anchor to Primary and pull Secondary to it
                targetPri = currentPrimaryDelay
                targetSec = roundCenti(dual.rawOffsetSeconds + currentPrimaryDelay)
                anchorTag = "音轨验证·主字幕基准"
                diagExtra += " decision=priAnchor"
            } else {
                // Neither track is currently synced to audio -> try anchoring BOTH directly to audio!
                let priAudio = alignSubtitleToVADProbabilities(
                    vadProbabilities: vadProbabilities,
                    audioStartPTS: audioStartPTS,
                    frameDuration: dt,
                    cues: primaryCues,
                    currentPrimaryDelay: currentPrimaryDelay,
                    maxShiftSeconds: 30.0
                )
                if case .aligned(let pa) = priAudio, pa.confidence >= 0.55 {
                    targetPri = pa.suggestedPrimaryDelaySeconds
                    targetSec = roundCenti(dual.rawOffsetSeconds + targetPri)
                    anchorTag = "音轨同步基准"
                    diagExtra += String(format: " decision=audioBoth(pri=%+.2f,r=%.3f)", targetPri, pa.peakCorrelation)
                } else if !dual.detectedFrameRateDrift {
                    let secAudio = alignSubtitleToVADProbabilities(
                        vadProbabilities: vadProbabilities,
                        audioStartPTS: audioStartPTS,
                        frameDuration: dt,
                        cues: secondaryCues,
                        currentPrimaryDelay: currentSecondaryDelay,
                        maxShiftSeconds: 30.0
                    )
                    if case .aligned(let sa) = secAudio, sa.confidence >= 0.55 {
                        targetSec = sa.suggestedPrimaryDelaySeconds
                        targetPri = roundCenti(targetSec - dual.rawOffsetSeconds)
                        anchorTag = "音轨同步基准"
                        diagExtra += String(format: " decision=audioBothViaSec(sec=%+.2f,r=%.3f)", targetSec, sa.peakCorrelation)
                    } else {
                        diagExtra += " decision=priFallback"
                    }
                }
            }
        }

        let already = abs(targetPri - currentPrimaryDelay) <= 0.10 &&
                      abs(targetSec - currentSecondaryDelay) <= 0.10 &&
                      abs(targetScale - currentSecondaryScale) <= 5e-4

        let msg: String
        if already {
            msg = "主/副字幕已对齐，无需调整"
        } else if dual.detectedFrameRateDrift {
            msg = String(format: "双字已对齐(%@): 副 %+.2fs · 速率 %.4fx", anchorTag, targetSec, targetScale)
        } else if abs(targetPri - currentPrimaryDelay) > 0.10 && abs(targetSec - currentSecondaryDelay) <= 0.10 {
            msg = String(format: "双字已对齐(%@): 主 %+.2fs", anchorTag, targetPri)
        } else if abs(targetPri - currentPrimaryDelay) > 0.10 {
            msg = String(format: "双字已对齐(%@): 主 %+.2fs / 副 %+.2fs", anchorTag, targetPri, targetSec)
        } else {
            msg = String(format: "双字已对齐(%@): 副 %+.2fs · 匹配 %d 条", anchorTag, targetSec, dual.matchedPairCount)
        }

        let diag = String(
            format: "mode=dual raw=%+.2f scale=%.4f mad=%.3f pairs=%d pri=%.2f->%.2f sec=%.2f->%.2f %@",
            dual.rawOffsetSeconds, targetScale, dual.residualMADSeconds, dual.matchedPairCount,
            currentPrimaryDelay, targetPri, currentSecondaryDelay, targetSec, diagExtra
        )
        return .applied(UnifiedSubtitleAlignmentPlan(
            primaryDelaySeconds: targetPri,
            secondaryDelaySeconds: targetSec,
            secondaryTimeScale: targetScale,
            detectedFrameRateDrift: dual.detectedFrameRateDrift,
            alreadyAligned: already,
            confidence: dual.confidence,
            summaryMessage: msg,
            diagnosticLog: diag
        ))
    }

    // MARK: 1. Subtitle-to-Audio Alignment (Silero VAD + Overlap-Clipped Exact Pearson + Split-Half Gate)

    public static func alignSubtitleToAudio(
        pcm16k: [Float],
        audioStartPTS: Double,
        cues: [SubtitleCueInterval],
        currentPrimaryDelay: Double = 0.0,
        maxShiftSeconds: Double = 30.0,
        vad: SileroVAD? = nil
    ) throws -> AudioSubtitleAlignmentOutcome {
        let engine = try vad ?? SileroVAD.shared()
        let probs = engine.predictFrameProbabilities(pcm16k: pcm16k)
        return alignSubtitleToVADProbabilities(
            vadProbabilities: probs,
            audioStartPTS: audioStartPTS,
            frameDuration: SileroVAD.frameDurationSeconds,
            cues: cues,
            currentPrimaryDelay: currentPrimaryDelay,
            maxShiftSeconds: maxShiftSeconds
        )
    }

    /// Evaluates normalized Pearson correlation between VAD probabilities and subtitle cues at one fixed delay.
    public static func evaluateVADCorrelation(
        vadProbabilities: [Float],
        audioStartPTS: Double,
        frameDuration dt: Double = SileroVAD.frameDurationSeconds,
        cues: [SubtitleCueInterval],
        delaySeconds: Double
    ) -> Double {
        let n = vadProbabilities.count
        let audioDur = Double(n) * dt
        guard audioDur >= 8.0, n >= 240 else { return 0 }
        let filtered = filterDialogueCues(cues)
        guard let firstCue = filtered.first, let lastCue = filtered.last, filtered.count >= 4 else { return 0 }

        let aVec = buildAudioActivityVector(vadProbabilities: vadProbabilities)
        let audioEndPTS = audioStartPTS + audioDur
        let covStart = firstCue.startSeconds + delaySeconds - 2.0
        let covEnd = lastCue.endSeconds + delaySeconds + 2.0
        let ovStart = max(audioStartPTS, covStart)
        let ovEnd = min(audioEndPTS, covEnd)
        let i0 = max(0, Int(ceil((ovStart - audioStartPTS) / dt)))
        let i1 = min(n, Int(floor((ovEnd - audioStartPTS) / dt)))
        let ovN = i1 - i0
        guard Double(ovN) * dt >= max(7.0, 0.55 * audioDur) else { return 0 }

        var sVec = [Float](repeating: 0, count: ovN)
        let subOrigin = audioStartPTS + Double(i0) * dt - delaySeconds
        for cue in filtered {
            let c0 = max(0, Int(floor((cue.startSeconds - subOrigin) / dt)))
            let c1 = min(ovN - 1, Int(ceil((cue.endSeconds - subOrigin) / dt)))
            guard c1 >= c0 else { continue }
            for idx in c0...c1 where sVec[idx] < 1.0 { sVec[idx] = 1.0 }
            let onsetEnd = min(ovN - 1, c0 + 2)
            for idx in c0...onsetEnd { sVec[idx] = max(sVec[idx], 1.45) }
        }

        var sumA = 0.0, sumA2 = 0.0, sumS = 0.0, sumS2 = 0.0, dot = 0.0
        for idx in 0..<ovN {
            let av = Double(aVec[i0 + idx])
            let sv = Double(sVec[idx])
            sumA += av; sumA2 += av * av
            sumS += sv; sumS2 += sv * sv
            dot += av * sv
        }
        let invN = 1.0 / Double(ovN)
        let varA = sumA2 - sumA * sumA * invN
        let varS = sumS2 - sumS * sumS * invN
        guard varA > 1e-5, varS > 1e-5 else { return 0 }
        return (dot - sumA * sumS * invN) / sqrt(varA * varS)
    }

    public static func alignSubtitleToVADProbabilities(
        vadProbabilities: [Float],
        audioStartPTS: Double,
        frameDuration dt: Double = SileroVAD.frameDurationSeconds,
        cues: [SubtitleCueInterval],
        currentPrimaryDelay: Double = 0.0,
        maxShiftSeconds: Double = 30.0
    ) -> AudioSubtitleAlignmentOutcome {
        let n = vadProbabilities.count
        let audioDuration = Double(n) * dt
        guard audioDuration >= 10.0, n >= 300 else {
            return .insufficientData("已捕获音频不足 10 秒，请播放一小段对白后再点字音对齐")
        }

        var smooth = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let prev = i > 0 ? vadProbabilities[i - 1] : vadProbabilities[i]
            let next = i + 1 < n ? vadProbabilities[i + 1] : vadProbabilities[i]
            smooth[i] = 0.25 * prev + 0.5 * vadProbabilities[i] + 0.25 * next
        }

        var speechFrames = 0
        var silenceFrames = 0
        for p in smooth {
            if p >= 0.38 { speechFrames += 1 }
            if p <= 0.22 { silenceFrames += 1 }
        }
        let speechSeconds = Double(speechFrames) * dt
        guard speechSeconds >= 2.8 else {
            return .insufficientData("当前片段人声过少 (\(String(format: "%.1f", speechSeconds))s)，请在对白段落重试")
        }
        guard Double(silenceFrames) / Double(n) >= 0.05 else {
            return .insufficientData("当前片段缺少语音停顿边界，请稍后重试")
        }

        let searchMin = max(-120.0, min(-maxShiftSeconds, currentPrimaryDelay - 15.0))
        let searchMax = min(120.0, max(maxShiftSeconds, currentPrimaryDelay + 15.0))
        let audioEndPTS = audioStartPTS + audioDuration

        let allFiltered = filterDialogueCues(cues)
        let filteredCues = allFiltered.filter { cue in
            cue.endSeconds >= (audioStartPTS - searchMax - 1.0) &&
            cue.startSeconds <= (audioEndPTS - searchMin + 1.0)
        }
        guard let firstCue = filteredCues.first, let lastCue = filteredCues.last, filteredCues.count >= 5 else {
            return .insufficientData("当前窗口内可用字幕不足 (\(filteredCues.count) 条)，请播放约 15 秒或使用外挂字幕后重试")
        }

        let aVec = buildAudioActivityVector(smoothedVAD: smooth)
        var prefA = [Double](repeating: 0, count: n + 1)
        var prefA2 = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let v = Double(aVec[i])
            prefA[i + 1] = prefA[i] + v
            prefA2[i + 1] = prefA2[i] + v * v
        }
        let totalVarA = prefA2[n] - (prefA[n] * prefA[n]) / Double(n)
        guard totalVarA > 1e-4 else {
            return .insufficientData("音频语音能量变化不足，请在对白段落重试")
        }

        let kMin = Int(floor(searchMin / dt))
        let kMax = Int(ceil(searchMax / dt))
        let lagCount = kMax - kMin + 1
        guard lagCount >= 3 else {
            return .insufficientData("搜索范围无效")
        }

        let sOrigin = audioStartPTS - Double(kMax) * dt
        let sLen = n + (kMax - kMin) + 2
        var sVec = [Float](repeating: 0, count: sLen)
        for cue in filteredCues {
            let i0 = max(0, Int(floor((cue.startSeconds - sOrigin) / dt)))
            let i1 = min(sLen - 1, Int(ceil((cue.endSeconds - sOrigin) / dt)))
            guard i1 >= i0 else { continue }
            for idx in i0...i1 where sVec[idx] < 1.0 { sVec[idx] = 1.0 }
            let onsetEnd = min(sLen - 1, i0 + 2)
            for idx in i0...onsetEnd { sVec[idx] = max(sVec[idx], 1.45) }
        }

        var prefS = [Double](repeating: 0, count: sLen + 1)
        var prefS2 = [Double](repeating: 0, count: sLen + 1)
        for i in 0..<sLen {
            let v = Double(sVec[i])
            prefS[i + 1] = prefS[i] + v
            prefS2[i + 1] = prefS2[i] + v * v
        }

        let minOverlapSamples = max(Int(ceil(8.0 / dt)), Int(ceil(0.65 * Double(n))))

        // Exact overlap-clipped Pearson correlation across all candidate lags (prevents embedded post-seek boundary inflation!)
        var rawR = [Double](repeating: 0, count: lagCount)
        var weightedScores = [Double](repeating: 0, count: lagCount)
        var ovRanges = [(Int, Int)](repeating: (0, 0), count: lagCount)
        var validLagCount = 0

        sVec.withUnsafeBufferPointer { sPtr in
            aVec.withUnsafeBufferPointer { aPtr in
                guard let sBase = sPtr.baseAddress, let aBase = aPtr.baseAddress else { return }

                @inline(__always)
                func localPearson(aStart: Int, aEnd: Int, sStart: Int) -> Double {
                    let len = aEnd - aStart
                    guard len >= 32 else { return 0 }
                    let invLen = 1.0 / Double(len)
                    let sumA = prefA[aEnd] - prefA[aStart]
                    let sumA2 = prefA2[aEnd] - prefA2[aStart]
                    let varA = sumA2 - sumA * sumA * invLen
                    if varA < 1e-5 { return 0 }
                    let sumS = prefS[sStart + len] - prefS[sStart]
                    let sumS2 = prefS2[sStart + len] - prefS2[sStart]
                    let varS = sumS2 - sumS * sumS * invLen
                    if varS < 1e-5 { return 0 }
                    var dot: Float = 0
                    vDSP_dotpr(aBase.advanced(by: aStart), 1, sBase.advanced(by: sStart), 1, &dot, vDSP_Length(len))
                    let cov = Double(dot) - (sumA * sumS) * invLen
                    return cov / sqrt(varA * varS)
                }

                for li in 0..<lagCount {
                    let k = kMin + li
                    let delay = Double(k) * dt
                    let covStart = firstCue.startSeconds + delay - 2.0
                    let covEnd = lastCue.endSeconds + delay + 2.0
                    let ovStart = max(audioStartPTS, covStart)
                    let ovEnd = min(audioEndPTS, covEnd)
                    let i0 = max(0, Int(ceil((ovStart - audioStartPTS) / dt)))
                    let i1 = min(n, Int(floor((ovEnd - audioStartPTS) / dt)))
                    let ovN = i1 - i0
                    guard ovN >= minOverlapSamples else { continue }

                    let sStart = (kMax - k) + i0
                    let r = localPearson(aStart: i0, aEnd: i1, sStart: sStart)
                    let weight = sqrt(Double(ovN) / Double(n))
                    rawR[li] = r
                    weightedScores[li] = r * weight
                    ovRanges[li] = (i0, i1)
                    validLagCount += 1
                }
            }
        }

        guard validLagCount >= 5 else {
            return .insufficientData("有效字幕时间覆盖不足，请稍后播放更多对白后重试")
        }

        // Collect top-5 distinct local peaks (separated by >= 1.2s) and rank with split-half consistency
        let sepBins = max(1, Int(ceil(1.2 / dt)))
        var topPeaks: [Int] = []
        let sortedIndices = (0..<lagCount).sorted { weightedScores[$0] > weightedScores[$1] }
        for li in sortedIndices {
            guard ovRanges[li].1 > ovRanges[li].0 else { continue }
            if topPeaks.allSatisfy({ abs($0 - li) >= sepBins }) {
                topPeaks.append(li)
                if topPeaks.count >= 5 { break }
            }
        }
        guard let initialTop = topPeaks.first else {
            return .insufficientData("未找到有效的字幕匹配区间")
        }

        func splitHalfCorrelations(for li: Int) -> (Double, Double) {
            let (i0, i1) = ovRanges[li]
            let ovN = i1 - i0
            guard ovN >= 420 else { return (rawR[li], rawR[li]) } // < 13.4s: skip split-half penalty
            let mid = i0 + ovN / 2
            let k = kMin + li
            let sBase0 = (kMax - k) + i0
            let sBase1 = (kMax - k) + mid

            var h1 = 0.0
            var h2 = 0.0
            sVec.withUnsafeBufferPointer { sPtr in
                aVec.withUnsafeBufferPointer { aPtr in
                    guard let sBase = sPtr.baseAddress, let aBase = aPtr.baseAddress else { return }
                    func halfR(_ aStart: Int, _ aEnd: Int, _ sStart: Int) -> Double {
                        let len = aEnd - aStart
                        let invLen = 1.0 / Double(len)
                        let sumA = prefA[aEnd] - prefA[aStart]
                        let sumA2 = prefA2[aEnd] - prefA2[aStart]
                        let varA = sumA2 - sumA * sumA * invLen
                        let sumS = prefS[sStart + len] - prefS[sStart]
                        let sumS2 = prefS2[sStart + len] - prefS2[sStart]
                        let varS = sumS2 - sumS * sumS * invLen
                        guard varA > 1e-5, varS > 1e-5 else { return 0 }
                        var dot: Float = 0
                        vDSP_dotpr(aBase.advanced(by: aStart), 1, sBase.advanced(by: sStart), 1, &dot, vDSP_Length(len))
                        return (Double(dot) - sumA * sumS * invLen) / sqrt(varA * varS)
                    }
                    h1 = halfR(i0, mid, sBase0)
                    h2 = halfR(mid, i1, sBase1)
                }
            }
            return (h1, h2)
        }

        var bestIdx = initialTop
        var bestJoint = -Double.infinity
        var bestH1 = 0.0
        var bestH2 = 0.0
        for li in topPeaks {
            let (h1, h2) = splitHalfCorrelations(for: li)
            let minHalf = min(h1, h2)
            let splitPenalty = max(0.0, 0.14 - minHalf) * 0.75
            let joint = weightedScores[li] - splitPenalty
            if joint > bestJoint {
                bestJoint = joint
                bestIdx = li
                bestH1 = h1
                bestH2 = h2
            }
        }

        // Sub-frame parabolic interpolation around bestIdx
        var refinedLag = Double(kMin + bestIdx)
        if bestIdx > 0 && bestIdx + 1 < lagCount &&
           ovRanges[bestIdx - 1].1 > ovRanges[bestIdx - 1].0 &&
           ovRanges[bestIdx + 1].1 > ovRanges[bestIdx + 1].0 {
            let y0 = weightedScores[bestIdx - 1]
            let y1 = weightedScores[bestIdx]
            let y2 = weightedScores[bestIdx + 1]
            let denom = y0 - 2.0 * y1 + y2
            if denom < -1e-6 {
                let delta = max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom))
                refinedLag += delta
            }
        }
        let bestScore = rawR[bestIdx]
        let bestWeighted = weightedScores[bestIdx]
        var suggestedDelay = roundCenti(refinedLag * dt)

        // Evaluate stability against currentPrimaryDelay (and 0.0s) so marginal noise never causes a 3s detour!
        func scoreAt(delay: Double) -> Double {
            let li = Int((delay / dt).rounded()) - kMin
            guard li >= 0 && li < lagCount && ovRanges[li].1 > ovRanges[li].0 else { return 0 }
            let lo = max(0, li - 3)
            let hi = min(lagCount - 1, li + 3)
            var m = -1.0
            for idx in lo...hi where ovRanges[idx].1 > ovRanges[idx].0 {
                m = max(m, weightedScores[idx])
            }
            return m
        }

        let currentScore = scoreAt(delay: currentPrimaryDelay)
        let zeroScore = scoreAt(delay: 0.0)

        var alreadyAligned = abs(suggestedDelay - currentPrimaryDelay) <= 0.14
        if !alreadyAligned && abs(suggestedDelay - currentPrimaryDelay) > 0.35 && currentScore >= 0.26 && bestWeighted < currentScore + 0.06 {
            // Current delay is already strongly supported; refuse marginal noisy jump!
            suggestedDelay = currentPrimaryDelay
            alreadyAligned = true
        } else if !alreadyAligned && abs(currentPrimaryDelay) > 0.35 && abs(suggestedDelay) > 0.35 && zeroScore >= 0.26 && bestWeighted < zeroScore + 0.06 {
            suggestedDelay = 0.0
        }

        // Background statistics outside ±1.5s exclusion zone around bestIdx
        let exclHalfBins = max(1, Int(ceil(1.5 / dt)))
        var bgSum = 0.0
        var bgSum2 = 0.0
        var bgCount = 0
        var secondPeak = -1.0
        for li in 0..<lagCount {
            guard ovRanges[li].1 > ovRanges[li].0 else { continue }
            if abs(li - bestIdx) <= exclHalfBins { continue }
            let sc = weightedScores[li]
            bgSum += sc
            bgSum2 += sc * sc
            bgCount += 1
            if sc > secondPeak { secondPeak = sc }
        }
        let bgMean = bgCount > 0 ? bgSum / Double(bgCount) : 0.0
        let bgVar = bgCount > 1 ? max(0.0, bgSum2 / Double(bgCount) - bgMean * bgMean) : 0.01
        let bgStd = max(sqrt(bgVar), 0.015)
        let zScore = (bestWeighted - bgMean) / bgStd
        let margin = bestWeighted - max(secondPeak, 0.0)

        let confCorr = min(1.0, max(0.0, (bestScore - 0.15) / 0.48))
        let confZ = min(1.0, max(0.0, (zScore - 2.6) / 5.4))
        let confMargin = min(1.0, max(0.0, margin / 0.15))
        let confidence = min(0.99, max(0.0, 0.45 * confCorr + 0.35 * confZ + 0.20 * confMargin))

        let (ovI0, ovI1) = ovRanges[bestIdx]
        let splitChecked = (ovI1 - ovI0) >= 420
        let splitConsistent = !splitChecked || (bestH1 >= 0.08 && bestH2 >= 0.08)

        let passed = alreadyAligned
            ? (max(bestScore, currentScore) >= 0.22)
            : (bestScore >= 0.22 && zScore >= 3.0 && splitConsistent && (margin >= 0.04 || bestScore >= 0.48))

        if !passed {
            let reason = !splitConsistent
                ? "前后两段对白偏移不一致，请继续播放几秒稳定对白后再试"
                : "对白与字幕匹配度偏低 (置信度 \(Int((confidence * 100).rounded()))%)，建议播放更多对白后重试"
            return .lowConfidence(bestDelaySeconds: suggestedDelay, confidence: confidence, reason: reason)
        }

        let alignedCueCount = filteredCues.reduce(into: 0) { count, cue in
            let shiftedStart = cue.startSeconds + suggestedDelay
            let shiftedEnd = cue.endSeconds + suggestedDelay
            if shiftedEnd >= audioStartPTS && shiftedStart <= audioEndPTS {
                count += 1
            }
        }
        guard alignedCueCount >= 4 || alreadyAligned else {
            return .lowConfidence(
                bestDelaySeconds: suggestedDelay,
                confidence: confidence,
                reason: "对齐窗口内命中字幕过少 (\(alignedCueCount) 条)，请播放更多对白后重试"
            )
        }

        return .aligned(AudioSubtitleAlignmentResult(
            suggestedPrimaryDelaySeconds: suggestedDelay,
            confidence: confidence,
            peakCorrelation: bestScore,
            zScore: zScore,
            firstHalfCorrelation: bestH1,
            secondHalfCorrelation: bestH2,
            currentDelayCorrelation: currentScore,
            speechSeconds: speechSeconds,
            analyzedAudioSeconds: audioDuration,
            matchedCueCount: max(alignedCueCount, 1),
            alreadyAligned: alreadyAligned
        ))
    }

    // MARK: 2. Dual-Subtitle Auto-Alignment (Constant Shift + Cinema FPS Drift)

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

            guard let coarse = coarseAndFineEnvelopeShift(
                primary: pri,
                secondary: scaledSec,
                maxShiftSeconds: maxShiftSeconds
            ) else {
                return nil
            }

            var deltas: [Double] = []
            deltas.reserveCapacity(scaledSec.count)
            var j = 0
            for idx in 0..<scaledSec.count {
                let sc = scaledSec[idx]
                let predStart = sc.startSeconds + coarse.shift
                let predMid = sc.midpoint + coarse.shift
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

            guard deltas.count >= 4 else { return nil }
            let medDelta = median(of: deltas)
            let refinedOffset = coarse.shift + medDelta

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
            guard inliers >= 4 else { return nil }
            let mad = median(of: absRes)
            let denom = Double(min(pri.count, sec.count))
            let ratio = min(1.0, Double(inliers) / max(1.0, denom))
            let quality = ratio * 0.55 + max(0.0, 1.0 - mad / 0.55) * 0.30 + min(1.0, max(0.0, coarse.corr)) * 0.15
            return ScaleEval(
                scale: scale,
                offset: refinedOffset,
                mad: mad,
                inliers: inliers,
                inlierRatio: ratio,
                corr: coarse.corr,
                score: quality
            )
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

        let isValid = (chosen.inliers >= 4 && chosen.inlierRatio >= 0.22 && chosen.mad <= 0.45) ||
                      (chosen.inliers >= 12 && chosen.mad <= 0.38)
        guard isValid else {
            return .lowConfidence(reason: "主副字幕匹配条数不足 (\(chosen.inliers) 条)，无法可靠对齐")
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

    private static func roundCenti(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }

    private static func buildAudioActivityVector(vadProbabilities: [Float]) -> [Float] {
        let n = vadProbabilities.count
        var smooth = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let prev = i > 0 ? vadProbabilities[i - 1] : vadProbabilities[i]
            let next = i + 1 < n ? vadProbabilities[i + 1] : vadProbabilities[i]
            smooth[i] = 0.25 * prev + 0.5 * vadProbabilities[i] + 0.25 * next
        }
        return buildAudioActivityVector(smoothedVAD: smooth)
    }

    private static func buildAudioActivityVector(smoothedVAD smooth: [Float]) -> [Float] {
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

    private static func filterDialogueCues(_ cues: [SubtitleCueInterval]) -> [SubtitleCueInterval] {
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

    private static func coarseAndFineEnvelopeShift(
        primary: [SubtitleCueInterval],
        secondary: [SubtitleCueInterval],
        maxShiftSeconds: Double
    ) -> (shift: Double, corr: Double)? {
        guard let priFirst = primary.first, let priLast = primary.last,
              let secFirst = secondary.first, let secLast = secondary.last else {
            return nil
        }

        let spanStart = max(0.0, min(priFirst.startSeconds, secFirst.startSeconds))
        let spanEnd = max(priLast.endSeconds, secLast.endSeconds)
        let totalSpan = spanEnd - spanStart
        guard totalSpan >= 2.0 else { return nil }

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

        func correlate(dt: Double, lagMinSec: Double, lagMaxSec: Double) -> (shift: Double, corr: Double)? {
            let kMin = Int(floor(lagMinSec / dt))
            let kMax = Int(ceil(lagMaxSec / dt))
            let lagCount = kMax - kMin + 1
            guard lagCount >= 1 else { return nil }

            var totalNum = [Double](repeating: 0, count: lagCount)
            var totalDenP = 0.0
            var totalDenS = [Double](repeating: 0, count: lagCount)

            for (wStart, wEnd) in windows {
                let n = max(16, Int(ceil((wEnd - wStart) / dt)))
                var pVec = [Float](repeating: 0, count: n)
                for cue in primary where cue.endSeconds >= wStart && cue.startSeconds <= wEnd {
                    let i0 = max(0, Int(floor((cue.startSeconds - wStart) / dt)))
                    let i1 = min(n - 1, Int(ceil((cue.endSeconds - wStart) / dt)))
                    if i1 >= i0 {
                        for idx in i0...i1 { pVec[idx] = max(pVec[idx], 1.0) }
                        pVec[i0] = 1.5
                    }
                }
                var meanP: Float = 0
                vDSP_meanv(pVec, 1, &meanP, vDSP_Length(n))
                var negMeanP = -meanP
                vDSP_vsadd(pVec, 1, &negMeanP, &pVec, 1, vDSP_Length(n))
                var normPSq: Float = 0
                vDSP_dotpr(pVec, 1, pVec, 1, &normPSq, vDSP_Length(n))
                if normPSq < 1e-4 { continue }
                totalDenP += Double(normPSq)

                let sOrigin = wStart - Double(kMax) * dt
                let sLen = n + (kMax - kMin) + 2
                var sVec = [Float](repeating: 0, count: sLen)
                let sWinEnd = sOrigin + Double(sLen) * dt
                for cue in secondary where cue.endSeconds >= sOrigin && cue.startSeconds <= sWinEnd {
                    let i0 = max(0, Int(floor((cue.startSeconds - sOrigin) / dt)))
                    let i1 = min(sLen - 1, Int(ceil((cue.endSeconds - sOrigin) / dt)))
                    if i1 >= i0 {
                        for idx in i0...i1 { sVec[idx] = max(sVec[idx], 1.0) }
                        sVec[i0] = 1.5
                    }
                }

                var prefS = [Double](repeating: 0, count: sLen + 1)
                var prefS2 = [Double](repeating: 0, count: sLen + 1)
                for i in 0..<sLen {
                    let v = Double(sVec[i])
                    prefS[i + 1] = prefS[i] + v
                    prefS2[i + 1] = prefS2[i] + v * v
                }
                let invN = 1.0 / Double(n)

                sVec.withUnsafeBufferPointer { sPtr in
                    pVec.withUnsafeBufferPointer { pPtr in
                        guard let sBase = sPtr.baseAddress, let pBase = pPtr.baseAddress else { return }
                        for li in 0..<lagCount {
                            let k = kMin + li
                            let sIdx = kMax - k
                            let sumS = prefS[sIdx + n] - prefS[sIdx]
                            let sumS2 = prefS2[sIdx + n] - prefS2[sIdx]
                            let varS = max(0.0, sumS2 - (sumS * sumS) * invN)
                            if varS < 1e-4 { continue }
                            var dot: Float = 0
                            vDSP_dotpr(pBase, 1, sBase.advanced(by: sIdx), 1, &dot, vDSP_Length(n))
                            totalNum[li] += Double(dot)
                            totalDenS[li] += varS
                        }
                    }
                }
            }

            guard totalDenP > 1e-4 else { return nil }
            var bestLi = -1
            var bestR = -1.0
            for li in 0..<lagCount {
                let den = sqrt(totalDenP * totalDenS[li])
                guard den > 1e-4 else { continue }
                let r = totalNum[li] / den
                if r > bestR {
                    bestR = r
                    bestLi = li
                }
            }
            guard bestLi >= 0 else { return nil }
            return (Double(kMin + bestLi) * dt, bestR)
        }

        guard let coarse = correlate(dt: 0.25, lagMinSec: -maxShiftSeconds, lagMaxSec: maxShiftSeconds) else {
            return nil
        }
        if let fine = correlate(dt: 0.04, lagMinSec: coarse.shift - 1.5, lagMaxSec: coarse.shift + 1.5) {
            return fine
        }
        return coarse
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return 0.5 * (sorted[mid - 1] + sorted[mid])
    }
}

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

// MARK: - Subtitle Auto-Aligner (Audio-First Ground Truth + Dual-Subtitle Shift & FPS Drift)

public enum SubtitleAutoAligner {
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
            } else {
                // Even if secondary cues couldn't be matched independently yet, carry secondary by the same primary delta
                // so both subtitles ALWAYS move together in lockstep when clicking "字音对齐".
                let priDelta = targetPri - currentPrimaryDelay
                targetSec = roundCenti(currentSecondaryDelay + priDelta)
                secNote = String(format: "carryDelta(%+.2f)", priDelta)
            }

            let priMoved = abs(targetPri - currentPrimaryDelay) > 0.14
            let secMoved = abs(targetSec - currentSecondaryDelay) > 0.14 || abs(targetScale - currentSecondaryScale) > 5e-4
            let already = !priMoved && !secMoved
            let msg: String
            if already {
                msg = String(format: "双字幕均已与音轨对齐 (主 %+.2fs / 副 %+.2fs)", targetPri, targetSec)
            } else if drifted {
                msg = String(format: "字音已对齐(主副同步): 主 %+.2fs · 副 %+.2fs (速率 %.4fx)", targetPri, targetSec, targetScale)
            } else {
                msg = String(format: "字音已对齐(主副同步): 主 %+.2fs · 副 %+.2fs", targetPri, targetSec)
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

        let subOrigin = audioStartPTS + Double(i0) * dt - delaySeconds
        let sVec = rasterizeCueEnvelope(cues: filtered, origin: subOrigin, count: ovN, dt: dt, onsetPeak: 1.45, onsetExtraBins: 2)

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

        let smooth = smoothVAD(vadProbabilities)
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
        let prefA = buildPrefixSums(aVec)
        let totalVarA = prefA.sum2[n] - (prefA.sum[n] * prefA.sum[n]) / Double(n)
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
        let sVec = rasterizeCueEnvelope(cues: filteredCues, origin: sOrigin, count: sLen, dt: dt, onsetPeak: 1.45, onsetExtraBins: 2)
        let prefS = buildPrefixSums(sVec)

        let minOverlapSamples = max(Int(ceil(8.0 / dt)), Int(ceil(0.65 * Double(n))))

        // Exact overlap-clipped Pearson correlation across all candidate lags (prevents embedded post-seek boundary inflation!)
        var rawR = [Double](repeating: 0, count: lagCount)
        var weightedScores = [Double](repeating: 0, count: lagCount)
        var ovRanges = [(Int, Int)](repeating: (0, 0), count: lagCount)
        var validLagCount = 0

        sVec.withUnsafeBufferPointer { sPtr in
            aVec.withUnsafeBufferPointer { aPtr in
                guard let sBase = sPtr.baseAddress, let aBase = aPtr.baseAddress else { return }

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
                    let r = pearsonCorrelation(
                        aBase: aBase, aStart: i0, prefA: prefA,
                        bBase: sBase, bStart: sStart, prefB: prefS,
                        count: ovN, minSamples: 32, minVariance: 1e-5
                    ) ?? 0.0
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
                    h1 = pearsonCorrelation(
                        aBase: aBase, aStart: i0, prefA: prefA,
                        bBase: sBase, bStart: sBase0, prefB: prefS,
                        count: mid - i0, minSamples: 1, minVariance: 1e-5
                    ) ?? 0.0
                    h2 = pearsonCorrelation(
                        aBase: aBase, aStart: mid, prefA: prefA,
                        bBase: sBase, bStart: sBase1, prefB: prefS,
                        count: i1 - mid, minSamples: 1, minVariance: 1e-5
                    ) ?? 0.0
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
}

import Foundation
import CoreFoundation

// MARK: - Task A.1: External Subtitle Encoding Auto-Detection

public enum SubtitleTextEncodingKind: String, CaseIterable, Sendable {
    case utf8 = "UTF-8"
    case big5 = "Big5"
    case gb18030 = "GB18030"
    case utf16LE = "UTF-16LE"
    case utf16BE = "UTF-16BE"
    case utf8Lossy = "UTF-8(容错)"

    public var nsStringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8Lossy:
            return .utf8
        case .big5:
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(2563))
            return String.Encoding(rawValue: cfEnc)
        case .gb18030:
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(1586))
            return String.Encoding(rawValue: cfEnc)
        case .utf16LE:
            return .utf16LittleEndian
        case .utf16BE:
            return .utf16BigEndian
        }
    }
}

public struct SubtitleDecodedTextResult: Sendable {
    public let text: String
    public let encoding: SubtitleTextEncodingKind
    public let isASS: Bool

    public init(text: String, encoding: SubtitleTextEncodingKind, isASS: Bool) {
        self.text = text
        self.encoding = encoding
        self.isASS = isASS
    }
}

public enum SubtitleTextDecoder {
    private static let probeOrder: [SubtitleTextEncodingKind] = [
        .utf8,
        .big5,
        .gb18030,
        .utf16LE,
        .utf16BE
    ]

    private static let commonPunctuation: Set<Character> = Set(
        "，。！？；：“”‘’（）《》、…—,.!?;:\"'()-[]<>{}"
    )

    public static func decode(data: Data, fileExtension: String? = nil) -> SubtitleDecodedTextResult? {
        guard !data.isEmpty else { return nil }

        // 1. Priority BOM Detection
        if let bomDecoded = decodeBOM(data) {
            let isAss = detectIsASS(text: bomDecoded.text, fileExtension: fileExtension)
            return SubtitleDecodedTextResult(text: bomDecoded.text, encoding: bomDecoded.encoding, isASS: isAss)
        }

        // 2. Strict Probe Order: UTF-8 -> Big5 (2563) -> GB18030 (1586) -> UTF-16LE -> UTF-16BE
        var bestText: String?
        var bestEncoding: SubtitleTextEncodingKind = .utf8
        var bestScore: Double = -Double.infinity

        for kind in probeOrder {
            guard let candidate = String(data: data, encoding: kind.nsStringEncoding),
                  !candidate.isEmpty else {
                continue
            }
            let score = plausibility(of: candidate, encoding: kind)
            if kind == .utf8 && score >= 0.45 && !candidate.contains("\u{FFFD}") {
                let isAss = detectIsASS(text: candidate, fileExtension: fileExtension)
                return SubtitleDecodedTextResult(text: candidate, encoding: .utf8, isASS: isAss)
            }
            if score > bestScore {
                bestScore = score
                bestText = candidate
                bestEncoding = kind
            }
        }

        if let bestText {
            let isAss = detectIsASS(text: bestText, fileExtension: fileExtension)
            return SubtitleDecodedTextResult(text: bestText, encoding: bestEncoding, isASS: isAss)
        }

        // 3. Lossy UTF-8 fallback
        let fallback = String(decoding: data, as: UTF8.self)
        guard !fallback.isEmpty else { return nil }
        let isAss = detectIsASS(text: fallback, fileExtension: fileExtension)
        return SubtitleDecodedTextResult(text: fallback, encoding: .utf8Lossy, isASS: isAss)
    }

    private static func decodeBOM(_ data: Data) -> (text: String, encoding: SubtitleTextEncodingKind)? {
        if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
            let payload = data.dropFirst(3)
            if let str = String(data: payload, encoding: .utf8) {
                return (str, .utf8)
            }
        }
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xFE {
            let payload = data.dropFirst(2)
            if let str = String(data: payload, encoding: .utf16LittleEndian) {
                return (str, .utf16LE)
            }
        }
        if data.count >= 2 && data[0] == 0xFE && data[1] == 0xFF {
            let payload = data.dropFirst(2)
            if let str = String(data: payload, encoding: .utf16BigEndian) {
                return (str, .utf16BE)
            }
        }
        return nil
    }

    public static func plausibility(of text: String, encoding: SubtitleTextEncodingKind) -> Double {
        let sample = String(text.prefix(16384))
        guard !sample.isEmpty else { return -100.0 }

        var total = 0
        var cjkCount = 0
        var asciiPrintable = 0
        var punctCount = 0
        var badCount = 0
        var nullOrControlCount = 0

        for ch in sample {
            total += 1
            if ch == "\u{FFFD}" {
                badCount += 1
                continue
            }
            if commonPunctuation.contains(ch) {
                punctCount += 1
            }
            for scalar in ch.unicodeScalars {
                let v = scalar.value
                if v == 0 || (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) {
                    nullOrControlCount += 1
                } else if v >= 0x20 && v <= 0x7E {
                    asciiPrintable += 1
                } else if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) {
                    cjkCount += 1
                } else if v >= 0xE000 && v <= 0xF8FF {
                    badCount += 1
                }
            }
        }

        guard total > 0 else { return -100.0 }
        let invTotal = 1.0 / Double(total)
        var score = Double(asciiPrintable + cjkCount * 2 + punctCount * 2) * invTotal
        score -= Double(badCount * 12 + nullOrControlCount * 20) * invTotal

        if sample.contains("-->") || sample.contains("Dialogue:") || sample.contains("[Script Info]") {
            score += 0.65
        }
        // Without explicit UTF-16 BOM, penalize raw UTF-16 slightly unless structure markers are present
        if (encoding == .utf16LE || encoding == .utf16BE) && !sample.contains("-->") && !sample.contains("Dialogue:") {
            score -= 0.85
        }
        return score
    }

    public static func detectIsASS(text: String, fileExtension: String?) -> Bool {
        if let ext = fileExtension?.lowercased(), (ext == "ass" || ext == "ssa") {
            return true
        }
        let head = String(text.prefix(4096))
        return head.contains("[Script Info]") || head.contains("[V4+ Styles]") || head.contains("Dialogue:")
    }
}

// MARK: - Task A.2: Subtitle Simplified / Traditional Real-time Transform

public enum SubtitleTextTransform: Int, CaseIterable, Codable, Identifiable, Sendable {
    case off = 0
    case simplified = 1
    case traditional = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "原文字幕"
        case .simplified: return "繁转简 (简体)"
        case .traditional: return "简转繁 (繁体)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .off: return "原文"
        case .simplified: return "转简"
        case .traditional: return "转繁"
        }
    }

    public var icuIdentifier: String? {
        switch self {
        case .off: return nil
        case .simplified: return "Hant-Hans"
        case .traditional: return "Hans-Hant"
        }
    }

    public func apply(toPlainText text: String) -> String {
        guard let transformId = icuIdentifier, !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, transformId as CFString, false)
        return mutable as String
    }

    /// Transforms subtitle payload while protecting `{...}` ASS tags and `\N`, `\n`, `\h` escapes.
    public func apply(toASSText payload: String) -> String {
        guard icuIdentifier != nil, !payload.isEmpty else { return payload }
        var result = String()
        result.reserveCapacity(payload.count)
        var buffer = String()

        func flushBuffer() {
            if !buffer.isEmpty {
                result.append(apply(toPlainText: buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        var idx = payload.startIndex
        while idx < payload.endIndex {
            let ch = payload[idx]
            if ch == "{" {
                if let closeIdx = payload[idx...].firstIndex(of: "}") {
                    flushBuffer()
                    result.append(contentsOf: payload[idx...closeIdx])
                    idx = payload.index(after: closeIdx)
                    continue
                }
            } else if ch == "\\" {
                let nextIdx = payload.index(after: idx)
                if nextIdx < payload.endIndex {
                    let nextCh = payload[nextIdx]
                    if nextCh == "N" || nextCh == "n" || nextCh == "h" {
                        flushBuffer()
                        result.append(ch)
                        result.append(nextCh)
                        idx = payload.index(after: nextIdx)
                        continue
                    }
                }
            }
            buffer.append(ch)
            idx = payload.index(after: idx)
        }
        flushBuffer()
        return result
    }
}

// MARK: - Task A.3 & A.4: Subtitle Style, Dual Subtitles, HDR Peak Nits & Anti-Occlusion

public enum SubtitleHDRPeakNits: Int, CaseIterable, Codable, Identifiable, Sendable {
    case nits203 = 203
    case nits250 = 250
    case nits400 = 400

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .nits203: return "203 nit (标准参考白)"
        case .nits250: return "250 nit (柔和增强)"
        case .nits400: return "400 nit (高亮 HDR)"
        }
    }

    public var shortTitle: String {
        "\(rawValue) nit"
    }
}

public struct SubtitleStyleConfiguration: Codable, Equatable, Sendable {
    public var scale: Double
    public var borderWidth: Double
    public var verticalPositionPercent: Double
    public var primaryDelaySeconds: Double
    public var secondaryDelaySeconds: Double
    public var overrideASSStyle: Bool
    public var forcedOnly: Bool
    public var transform: SubtitleTextTransform
    public var hdrPeakNits: SubtitleHDRPeakNits
    public var antiOcclusionEnabled: Bool
    public var unifyPingFangFont: Bool
    public var enhanceSecondaryYellow: Bool
    public var secondaryScale: Double
    public var dualSubtitleGapPx: Double
    public var primaryOnTop: Bool
    public var dualLayoutMode: Int

    public init(
        scale: Double = 1.0,
        borderWidth: Double = 2.8,
        verticalPositionPercent: Double = 92.0,
        primaryDelaySeconds: Double = 0.0,
        secondaryDelaySeconds: Double = 0.0,
        overrideASSStyle: Bool = false,
        forcedOnly: Bool = false,
        transform: SubtitleTextTransform = .off,
        hdrPeakNits: SubtitleHDRPeakNits = .nits203,
        antiOcclusionEnabled: Bool = true,
        unifyPingFangFont: Bool = true,
        enhanceSecondaryYellow: Bool = true,
        secondaryScale: Double = 0.80,
        dualSubtitleGapPx: Double = 10.0,
        primaryOnTop: Bool = true,
        dualLayoutMode: Int = 0
    ) {
        self.scale = scale
        self.borderWidth = borderWidth
        self.verticalPositionPercent = verticalPositionPercent
        self.primaryDelaySeconds = primaryDelaySeconds
        self.secondaryDelaySeconds = secondaryDelaySeconds
        self.overrideASSStyle = overrideASSStyle
        self.forcedOnly = forcedOnly
        self.transform = transform
        self.hdrPeakNits = hdrPeakNits
        self.antiOcclusionEnabled = antiOcclusionEnabled
        self.unifyPingFangFont = unifyPingFangFont
        self.enhanceSecondaryYellow = enhanceSecondaryYellow
        self.secondaryScale = secondaryScale
        self.dualSubtitleGapPx = dualSubtitleGapPx
        self.primaryOnTop = primaryOnTop
        self.dualLayoutMode = dualLayoutMode
    }

    private enum CodingKeys: String, CodingKey {
        case scale, borderWidth, verticalPositionPercent, primaryDelaySeconds, secondaryDelaySeconds
        case overrideASSStyle, forcedOnly, transform, hdrPeakNits, antiOcclusionEnabled
        case unifyPingFangFont, enhanceSecondaryYellow
        case secondaryScale, dualSubtitleGapPx, primaryOnTop, dualLayoutMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        self.borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 2.8
        self.verticalPositionPercent = try c.decodeIfPresent(Double.self, forKey: .verticalPositionPercent) ?? 92.0
        self.primaryDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .primaryDelaySeconds) ?? 0.0
        self.secondaryDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .secondaryDelaySeconds) ?? 0.0
        self.overrideASSStyle = try c.decodeIfPresent(Bool.self, forKey: .overrideASSStyle) ?? false
        self.forcedOnly = try c.decodeIfPresent(Bool.self, forKey: .forcedOnly) ?? false
        self.transform = try c.decodeIfPresent(SubtitleTextTransform.self, forKey: .transform) ?? .off
        self.hdrPeakNits = try c.decodeIfPresent(SubtitleHDRPeakNits.self, forKey: .hdrPeakNits) ?? .nits203
        self.antiOcclusionEnabled = try c.decodeIfPresent(Bool.self, forKey: .antiOcclusionEnabled) ?? true
        self.unifyPingFangFont = try c.decodeIfPresent(Bool.self, forKey: .unifyPingFangFont) ?? true
        self.enhanceSecondaryYellow = try c.decodeIfPresent(Bool.self, forKey: .enhanceSecondaryYellow) ?? true
        self.secondaryScale = try c.decodeIfPresent(Double.self, forKey: .secondaryScale) ?? 0.80
        self.dualSubtitleGapPx = try c.decodeIfPresent(Double.self, forKey: .dualSubtitleGapPx) ?? 10.0
        self.primaryOnTop = try c.decodeIfPresent(Bool.self, forKey: .primaryOnTop) ?? true
        self.dualLayoutMode = try c.decodeIfPresent(Int.self, forKey: .dualLayoutMode) ?? 0
    }
}

// MARK: - Task B.1: Per-Season Intro/Outro Skip Preference & Chapter Detection

public enum SeasonSkipMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case manual = "manual"
    case automatic = "automatic"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: return "手动提示跳过"
        case .automatic: return "自动跳过片头与连播片尾"
        }
    }
}

public struct SeasonSkipPreference: Codable, Equatable, Sendable {
    public var introEnabled: Bool
    public var outroEnabled: Bool
    public var introSeconds: Double
    public var outroSeconds: Double
    public var mode: SeasonSkipMode
    public var chapterDetection: Bool
    public var hasUserMarkedIntro: Bool
    public var hasUserMarkedOutro: Bool

    public init(
        introEnabled: Bool = true,
        outroEnabled: Bool = true,
        introSeconds: Double = 90.0,
        outroSeconds: Double = 90.0,
        mode: SeasonSkipMode = .manual,
        chapterDetection: Bool = true,
        hasUserMarkedIntro: Bool = false,
        hasUserMarkedOutro: Bool = false
    ) {
        self.introEnabled = introEnabled
        self.outroEnabled = outroEnabled
        self.introSeconds = introSeconds
        self.outroSeconds = outroSeconds
        self.mode = mode
        self.chapterDetection = chapterDetection
        self.hasUserMarkedIntro = hasUserMarkedIntro
        self.hasUserMarkedOutro = hasUserMarkedOutro
    }
}

public struct PlaybackChapterItem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let title: String

    public init(id: Int, startSeconds: Double, endSeconds: Double, title: String) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
    }
}

public enum ChapterSkipDetector {
    private static let introRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(opening|op|intro|prologue|cold\s*open)\b|(片头|片頭|序幕|オープニング)"#
    )
    private static let outroRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(ending|ed|outro|credits|epilogue|next\s*episode\s*preview)\b|(片尾|尾声|尾聲|预告|預告|エンディング)"#
    )

    public static func detectIntroEndSeconds(chapters: [PlaybackChapterItem], duration: Double) -> Double? {
        guard !chapters.isEmpty else { return nil }
        let maxIntroEnd = min(duration > 0 ? duration * 0.35 : 300.0, 300.0)
        for ch in chapters {
            let t = ch.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let regex = introRegex,
               regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil,
               ch.startSeconds <= 180.0,
               ch.endSeconds > ch.startSeconds + 10.0,
               ch.endSeconds <= maxIntroEnd {
                return ch.endSeconds
            }
        }
        return nil
    }

    public static func detectOutroStartSeconds(chapters: [PlaybackChapterItem], duration: Double) -> Double? {
        guard !chapters.isEmpty, duration > 180.0 else { return nil }
        let minOutroStart = max(60.0, duration - 360.0)
        for ch in chapters.reversed() {
            let t = ch.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let regex = outroRegex,
               regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil,
               ch.startSeconds >= minOutroStart,
               ch.startSeconds < duration - 5.0 {
                return ch.startSeconds
            }
        }
        return nil
    }
}

// MARK: - Task B.2: Playback Stall Detection & Bounded Auto-Recovery Policy

public enum PlaybackHealthEvaluation: Equatable, Sendable {
    case none
    case progressed
    case recover
    case fail(String)
}

public struct PlaybackHealthPolicy: Sendable {
    public var stallBudgetSeconds: TimeInterval
    private var baselinePosition: Double = -1.0
    private var baselineBuffered: Double = -1.0
    private var lastProgressTimestamp: TimeInterval = 0
    private var steadyProgressStartPosition: Double = -1.0
    private var lastSeekGeneration: Int = -1
    public private(set) var recoveryUsed: Bool = false

    public init(stallBudgetSeconds: TimeInterval = 12.0) {
        self.stallBudgetSeconds = stallBudgetSeconds
    }

    public mutating func reset() {
        baselinePosition = -1.0
        baselineBuffered = -1.0
        lastProgressTimestamp = 0
        steadyProgressStartPosition = -1.0
        recoveryUsed = false
    }

    /// Evaluates playback progress using Moonglass thresholds (`pos >= 0.1s` or `buffered >= 0.5s`).
    public mutating func evaluate(
        now: TimeInterval,
        position: Double,
        bufferedAhead: Double,
        isPaused: Bool,
        isOpening: Bool,
        isEnded: Bool,
        isScrubbing: Bool,
        seekGeneration: Int
    ) -> PlaybackHealthEvaluation {
        if isPaused || isOpening || isEnded || isScrubbing || seekGeneration != lastSeekGeneration {
            lastSeekGeneration = seekGeneration
            baselinePosition = position
            baselineBuffered = bufferedAhead
            lastProgressTimestamp = now
            steadyProgressStartPosition = position
            return .none
        }

        if lastProgressTimestamp <= 0 || baselinePosition < 0 {
            baselinePosition = position
            baselineBuffered = bufferedAhead
            lastProgressTimestamp = now
            steadyProgressStartPosition = position
            return .none
        }

        let posDelta = position - baselinePosition
        let bufDelta = bufferedAhead - baselineBuffered

        // Observed Moonglass constants: position advances >= 0.1s or buffer advances >= 0.5s
        if posDelta >= 0.1 || bufDelta >= 0.5 {
            baselinePosition = position
            baselineBuffered = bufferedAhead
            lastProgressTimestamp = now
            if recoveryUsed && (position - steadyProgressStartPosition) >= 3.0 {
                recoveryUsed = false
            }
            return .progressed
        }

        let stalledDuration = now - lastProgressTimestamp
        if stalledDuration >= stallBudgetSeconds {
            lastProgressTimestamp = now
            if !recoveryUsed {
                recoveryUsed = true
                steadyProgressStartPosition = position
                return .recover
            } else {
                return .fail("自动恢复后仍无媒体进展 (超时 \(Int(stallBudgetSeconds)) 秒)，请检查网络或切换备用播放线路")
            }
        }

        return .none
    }
}

// MARK: - Task B.3: Desensitized Playback Diagnostics Exporter

public enum PlaybackDiagnosticsRedactor {
    private static let kvRedactionRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(token|password|passwd|pwd|authorization|api[_-]?key|x-emby-token|delivery[_-]?key)\b(\s*[:=]\s*)((?:(?:Bearer|Basic)\s+)?[^\s&"',;\]]+)"#
    )
    private static let queryRedactionRegex = try? NSRegularExpression(
        pattern: #"(?i)([?&](?:token|api_key|apikey|delivery_key|password|passwd|pwd|auth|x-emby-token)=)([^&\s"']+)"#
    )
    private static let bearerRedactionRegex = try? NSRegularExpression(
        pattern: #"(?i)\b((?:Bearer|Basic)\s+)([^\s"',;\]]+)"#
    )
    private static let danmuPathTokenRegex = try? NSRegularExpression(
        pattern: #"(?i)(/api/v1/danmu/)([^/\s]+)(/)"#
    )
    private static let embyTokenQuoteRegex = try? NSRegularExpression(
        pattern: #"(?i)(Token\s*=\s*")([^"]+)(")"#
    )
    private static let urlHostRedactionRegex = try? NSRegularExpression(
        pattern: #"(?i)(https?://)([^/\s"'?]+)"#
    )

    public static func redact(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var out = raw
        if let regex = queryRedactionRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1<REDACTED>"
            )
        }
        if let regex = bearerRedactionRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1<REDACTED>"
            )
        }
        if let regex = embyTokenQuoteRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1<REDACTED>$3"
            )
        }
        if let regex = kvRedactionRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1$2<REDACTED>"
            )
        }
        if let regex = danmuPathTokenRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1<REDACTED>$3"
            )
        }
        if let regex = urlHostRedactionRegex {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1<HOST>"
            )
        }
        return out
    }
}

// MARK: - Subtitle Track Memory & Cross-Episode Matching

public enum SubtitleLanguageBucket: String, Codable, Sendable {
    case simplifiedChinese
    case traditionalChinese
    case chineseGeneral
    case english
    case japanese
    case korean
    case other

    public static func detect(language: String?, title: String?) -> SubtitleLanguageBucket {
        let lang = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(lang) \(label)"

        if combined.contains("chs") || combined.contains("zh-cn") || combined.contains("zh-hans") ||
            combined.contains("简体") || combined.contains("简中") || combined.contains("sc") && (combined.contains("chi") || combined.contains("zho") || combined.contains("sub")) {
            return .simplifiedChinese
        }
        if combined.contains("cht") || combined.contains("zh-tw") || combined.contains("zh-hk") || combined.contains("zh-hant") ||
            combined.contains("繁體") || combined.contains("繁体") || combined.contains("繁中") || combined.contains("big5") {
            return .traditionalChinese
        }
        if ["chi", "zho", "zh", "cmn", "chinese"].contains(lang) ||
            combined.contains("中文") || combined.contains("中字") || combined.contains("双语") || combined.contains("雙語") || combined.contains("国语") {
            return .chineseGeneral
        }
        if ["eng", "en", "english"].contains(lang) || combined.contains("english") || combined.contains("英文") || combined.contains("英语") {
            return .english
        }
        if ["jpn", "ja", "japanese"].contains(lang) || combined.contains("japanese") || combined.contains("日文") || combined.contains("日语") {
            return .japanese
        }
        if ["kor", "ko", "korean"].contains(lang) || combined.contains("korean") || combined.contains("韩文") || combined.contains("韩语") {
            return .korean
        }
        return .other
    }

    public var isChinese: Bool {
        self == .simplifiedChinese || self == .traditionalChinese || self == .chineseGeneral
    }
}

public struct SubtitleTrackPreference: Codable, Equatable, Sendable {
    public var isDisabled: Bool
    public var language: String?
    public var titleHint: String?
    public var codec: String?
    public var isExternal: Bool
    public var embyStreamIndex: Int?
    public var localFilePath: String?

    public init(
        isDisabled: Bool = false,
        language: String? = nil,
        titleHint: String? = nil,
        codec: String? = nil,
        isExternal: Bool = false,
        embyStreamIndex: Int? = nil,
        localFilePath: String? = nil
    ) {
        self.isDisabled = isDisabled
        self.language = language
        self.titleHint = titleHint
        self.codec = codec
        self.isExternal = isExternal
        self.embyStreamIndex = embyStreamIndex
        self.localFilePath = localFilePath
    }

    public static var disabled: SubtitleTrackPreference {
        SubtitleTrackPreference(isDisabled: true)
    }

    public var languageBucket: SubtitleLanguageBucket {
        SubtitleLanguageBucket.detect(language: language, title: titleHint)
    }
}

public struct SeriesSubtitleMemory: Codable, Equatable, Sendable {
    public var primary: SubtitleTrackPreference?
    public var secondary: SubtitleTrackPreference?
    public var updatedAt: Date

    public init(
        primary: SubtitleTrackPreference? = nil,
        secondary: SubtitleTrackPreference? = nil,
        updatedAt: Date = Date()
    ) {
        self.primary = primary
        self.secondary = secondary
        self.updatedAt = updatedAt
    }
}

public struct SubtitleTrackCandidate: Sendable {
    public let id: String
    public let language: String?
    public let title: String
    public let codec: String?
    public let isExternal: Bool
    public let embyIndex: Int?
    public let avStreamIndex: Int?
    public let isDefault: Bool

    public init(
        id: String,
        language: String?,
        title: String,
        codec: String?,
        isExternal: Bool,
        embyIndex: Int?,
        avStreamIndex: Int?,
        isDefault: Bool = false
    ) {
        self.id = id
        self.language = language
        self.title = title
        self.codec = codec
        self.isExternal = isExternal
        self.embyIndex = embyIndex
        self.avStreamIndex = avStreamIndex
        self.isDefault = isDefault
    }
}

public enum SubtitleTrackMatcher {
    private static let descriptorTokens: [String] = [
        "简英", "简中英", "繁英", "简体", "繁体", "繁體", "双语", "雙語", "特效", "chs", "cht", "ass", "srt", "vtt",
        "pgs", "sup", "forced", "sdh", "commentary", "zh-cn", "zh-tw", "zh-hk", "中英", "中日"
    ]

    public static func bestMatchIndex(
        in candidates: [SubtitleTrackCandidate],
        for preference: SubtitleTrackPreference
    ) -> Int? {
        guard !preference.isDisabled, !candidates.isEmpty else { return nil }

        let targetBucket = preference.languageBucket
        let prefLang = (preference.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefTitle = (preference.titleHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefCodec = (preference.codec ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var bestIndex: Int?
        var bestScore = Int.min

        for (idx, candidate) in candidates.enumerated() {
            var score = 0
            let candLang = (candidate.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let candTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let candCodec = (candidate.codec ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let candBucket = SubtitleLanguageBucket.detect(language: candidate.language, title: candidate.title)

            if let wantedEmbyIdx = preference.embyStreamIndex, candidate.embyIndex == wantedEmbyIdx {
                // Exact stream index match receives strong boost if title/language do not conflict.
                let bucketConflict = (targetBucket != .other && candBucket != .other && targetBucket != candBucket && !(targetBucket.isChinese && candBucket.isChinese))
                score += bucketConflict ? 5 : 45
            }

            if candidate.isExternal == preference.isExternal {
                score += 12
            }

            if !prefLang.isEmpty && !candLang.isEmpty {
                if prefLang == candLang {
                    score += 24
                } else if targetBucket.isChinese && candBucket.isChinese {
                    score += 18
                }
            }

            if targetBucket != .other {
                if candBucket == targetBucket {
                    score += 64
                } else if targetBucket.isChinese && candBucket.isChinese {
                    score += 22
                } else if candBucket != .other {
                    score -= 45
                } else {
                    score -= 15
                }
            }

            if !prefTitle.isEmpty && !candTitle.isEmpty {
                if prefTitle == candTitle {
                    score += 55
                } else if candTitle.contains(prefTitle) || prefTitle.contains(candTitle) {
                    score += 28
                }
                for token in descriptorTokens where prefTitle.contains(token) && candTitle.contains(token) {
                    score += 10
                }
            }

            if !prefCodec.isEmpty && !candCodec.isEmpty && prefCodec == candCodec {
                score += 10
            }

            if candidate.isDefault {
                score += 2
            }

            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }

        // Require non-negative alignment so completely unrelated language tracks aren't forced blindly
        if let bestIndex, bestScore >= 10 {
            return bestIndex
        }
        return nil
    }

    public static func defaultPreferredIndex(in candidates: [SubtitleTrackCandidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }

        var bestIndex: Int?
        var bestScore = Int.min

        for (idx, candidate) in candidates.enumerated() {
            let lang = (candidate.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let codec = (candidate.codec ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let combined = "\(lang) \(title)"
            let bucket = SubtitleLanguageBucket.detect(language: candidate.language, title: candidate.title)

            let hasSimplified = (bucket == .simplifiedChinese) ||
                combined.contains("简英") || combined.contains("简中") || combined.contains("简体") ||
                combined.contains("chs") || combined.contains("zh-cn") || combined.contains("zh-hans") ||
                combined.contains("sc&en") || combined.contains("sc+en") || combined.contains("sc_en")
            let hasTraditional = (bucket == .traditionalChinese) ||
                combined.contains("繁英") || combined.contains("繁中") || combined.contains("繁体") ||
                combined.contains("繁體") || combined.contains("cht") || combined.contains("zh-tw") || combined.contains("zh-hk")
            let hasBilingual =
                combined.contains("简英") || combined.contains("简中英") || combined.contains("繁英") ||
                combined.contains("中英") || combined.contains("双语") || combined.contains("雙語") ||
                combined.contains("bilingual") || combined.contains("chs&eng") || combined.contains("chs+eng") ||
                combined.contains("chs_eng") || combined.contains("sc&en") || combined.contains("sc+en") ||
                combined.contains("cht&eng") || combined.contains("cht+eng") ||
                ((hasSimplified || hasTraditional || bucket.isChinese) && (combined.contains("英") || combined.contains("eng")))

            var score = 0
            // Tier 1: Simplified Chinese + English bilingual ("简英" / "简中英" / "chs&eng")
            if hasSimplified && hasBilingual {
                score += 140
            } else if combined.contains("简英") || combined.contains("简中英") {
                score += 140
            }
            // Tier 2: Traditional/General Chinese + English bilingual ("繁英" / "中英" / "双语")
            else if hasBilingual && (bucket.isChinese || hasTraditional) {
                score += 105
            }
            // Tier 3: Pure Simplified Chinese
            else if hasSimplified {
                score += 78
            }
            // Tier 4: Pure Traditional / General Chinese
            else if bucket.isChinese {
                score += 50
            }

            // Slight preference for text-based subtitles over bitmap when in the same language tier
            if codec.contains("ass") || codec.contains("ssa") {
                score += 10
            } else if codec.contains("srt") || codec.contains("subrip") || codec.contains("vtt") {
                score += 8
            }

            // Penalize commentary / forced-only tracks so main dialogue tracks win
            if combined.contains("commentary") || combined.contains("评论") || combined.contains("評論") || combined.contains("解说") {
                score -= 90
            }
            if combined.contains("forced") || combined.contains("强制") || combined.contains("強制") {
                score -= 35
            }

            if candidate.isDefault {
                score += 2
            }

            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }

        if let bestIndex, bestScore > 0 {
            return bestIndex
        }
        return candidates.firstIndex(where: \.isDefault) ?? 0
    }
}

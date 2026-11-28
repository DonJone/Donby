import Foundation

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
    public var seekStallBudgetSeconds: TimeInterval
    private var baselinePosition: Double = -1.0
    private var baselineBuffered: Double = -1.0
    private var lastProgressTimestamp: TimeInterval = 0
    private var steadyProgressStartPosition: Double = -1.0
    private var lastSeekGeneration: Int = -1
    public private(set) var recoveryUsed: Bool = false

    public init(stallBudgetSeconds: TimeInterval = 12.0, seekStallBudgetSeconds: TimeInterval = 20.0) {
        self.stallBudgetSeconds = stallBudgetSeconds
        self.seekStallBudgetSeconds = seekStallBudgetSeconds
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
        seekGeneration: Int,
        isSeeking: Bool = false
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

        let activeBudget = isSeeking ? max(stallBudgetSeconds, seekStallBudgetSeconds) : stallBudgetSeconds
        let stalledDuration = now - lastProgressTimestamp
        if stalledDuration >= activeBudget {
            lastProgressTimestamp = now
            if !recoveryUsed {
                recoveryUsed = true
                steadyProgressStartPosition = position
                return .recover
            } else {
                return .fail("自动恢复后仍无媒体进展 (超时 \(Int(activeBudget)) 秒)，请检查网络或切换备用播放线路")
            }
        }

        return .none
    }
}

// MARK: - Task B.3: Desensitized Playback Diagnostics Exporter

public enum PlaybackDiagnosticsRedactor {
    private static let redactionRules: [(regex: NSRegularExpression?, template: String)] = [
        (try? NSRegularExpression(pattern: #"(?i)([?&](?:token|api_key|apikey|delivery_key|password|passwd|pwd|auth|x-emby-token)=)([^&\s"']+)"#), "$1<REDACTED>"),
        (try? NSRegularExpression(pattern: #"(?i)\b((?:Bearer|Basic)\s+)([^\s"',;\]]+)"#), "$1<REDACTED>"),
        (try? NSRegularExpression(pattern: #"(?i)(Token\s*=\s*")([^"]+)(")"#), "$1<REDACTED>$3"),
        (try? NSRegularExpression(pattern: #"(?i)\b(token|password|passwd|pwd|authorization|api[_-]?key|x-emby-token|delivery[_-]?key)\b(\s*[:=]\s*)((?:(?:Bearer|Basic)\s+)?[^\s&"',;\]]+)"#), "$1$2<REDACTED>"),
        (try? NSRegularExpression(pattern: #"(?i)(/api/v1/danmu/)([^/\s]+)(/)"#), "$1<REDACTED>$3"),
        (try? NSRegularExpression(pattern: #"(?i)(https?://)([^/\s"'?]+)"#), "$1<HOST>")
    ]

    public static func redact(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var out = raw
        for (regex, template) in redactionRules {
            if let regex {
                out = regex.stringByReplacingMatches(
                    in: out,
                    range: NSRange(out.startIndex..., in: out),
                    withTemplate: template
                )
            }
        }
        return out
    }
}

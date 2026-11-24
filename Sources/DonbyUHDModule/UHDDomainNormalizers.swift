import Foundation
import DonbyCore

// MARK: - UHDNow Domain Normalizers, Parsers & Metrics Engine

public enum UHDRatingNormalizer {
    /// UHD Streaming API returns ratings as 10x integers (e.g. `85` -> `8.5`, `0` -> unrated).
    /// Also tolerates already-normalized decimals (`<= 10.0`) from legacy endpoints.
    public static func normalize(_ raw: Double?) -> Double? {
        guard let raw, raw > 0 else { return nil }
        if raw > 10.0 {
            return (raw / 10.0 * 10.0).rounded() / 10.0
        }
        return raw
    }
}

public enum UHDLoginCodeNormalizer {
    /// Strips whitespace/hyphens/grouping punctuation and validates an exact 8-digit code preserving leading zeros.
    public static func normalize(_ raw: String) -> String? {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 8 else { return nil }
        return digits
    }

    public static func formattedDisplay(_ raw: String) -> String {
        let digits = String(raw.filter { $0.isASCII && $0.isNumber }.prefix(8))
        guard digits.count > 4 else { return digits }
        let idx = digits.index(digits.startIndex, offsetBy: 4)
        return "\(digits[..<idx]) \(digits[idx...])"
    }
}

public enum UHDWatchPartyInviteParser {
    /// Extracts an 8-digit invite code from either a raw code (e.g. `"0428 1736"`)
    /// or a shared invite URL (e.g. `"https://example.com/stream/play?invite=04281736"`).
    public static func extractInviteCode(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let comps = URLComponents(string: trimmed),
           let inviteVal = comps.queryItems?.first(where: { $0.name.lowercased() == "invite" })?.value,
           let normalized = UHDLoginCodeNormalizer.normalize(inviteVal) {
            return normalized
        }

        if let range = trimmed.range(of: #"invite=([0-9]{8})"#, options: [.regularExpression, .caseInsensitive]) {
            let match = String(trimmed[range])
            if let eq = match.lastIndex(of: "=") {
                let code = String(match[match.index(after: eq)...])
                if let normalized = UHDLoginCodeNormalizer.normalize(code) {
                    return normalized
                }
            }
        }

        return UHDLoginCodeNormalizer.normalize(trimmed)
    }
}

public enum UHDTmdbSearchQueryParser {
    /// Parses queries like `tmdb:1399`, `tmdb=1399`, `tmdb 1399`, or `https://www.themoviedb.org/tv/1399`.
    public static func parse(_ raw: String) -> (tmdbId: Int, mediaType: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("tmdb:") || lower.hasPrefix("tmdb=") || lower.hasPrefix("tmdb ") {
            let suffix = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = suffix.split(separator: ":")
            if parts.count == 2 {
                let maybeType = String(parts[0]).lowercased()
                if (maybeType == "movie" || maybeType == "tv"),
                   let id = Int(parts[1]), id > 0 {
                    return (id, maybeType)
                }
            }
            if let id = Int(suffix), id > 0 {
                return (id, nil)
            }
        }

        if lower.contains("themoviedb.org/") {
            if let range = lower.range(of: #"/(movie|tv)/([0-9]+)"#, options: .regularExpression) {
                let segment = String(lower[range]).dropFirst() // drop leading /
                let comps = segment.split(separator: "/")
                if comps.count == 2, let id = Int(comps[1]), id > 0 {
                    return (id, String(comps[0]))
                }
            }
        }
        return nil
    }
}

public enum UHDProxyRoutingRules {
    public static let standardRulesText: String = """
    DOMAIN,v1.uhdnow.com,PROXY
    DOMAIN,v1.uhdgo.com,PROXY
    DOMAIN,v1-vod1.uhdnow.com,PROXY
    DOMAIN,v1-vod2.uhdnow.com,PROXY
    DOMAIN,www.uhdnow.com,DIRECT
    DOMAIN,smart.uhdnow.com,DIRECT
    DOMAIN,speed.uhdnow.com,DIRECT
    DOMAIN-SUFFIX,uhdnow.online,DIRECT
    """
}

public enum UHDDisplayNormalizer {
    private static let countryMap: [String: String] = [
        "CN": "中国",
        "HK": "香港",
        "TW": "台湾",
        "MO": "澳门",
        "JP": "日本",
        "SG": "新加坡",
        "KR": "韩国",
        "US": "美国",
        "GB": "英国",
        "UK": "英国",
        "DE": "德国",
        "NL": "荷兰",
        "FR": "法国",
        "CA": "加拿大",
        "AU": "澳大利亚",
        "RU": "俄罗斯",
        "MY": "马来西亚",
        "TH": "泰国",
        "IN": "印度",
        "SE": "瑞典",
        "CH": "瑞士"
    ]

    private static let ispMap: [String: String] = [
        "cmcc": "中国移动",
        "chinamobile": "中国移动",
        "china mobile": "中国移动",
        "ctcc": "中国电信",
        "chinanet": "中国电信",
        "chinatelecom": "中国电信",
        "china telecom": "中国电信",
        "cucc": "中国联通",
        "unicom": "中国联通",
        "chinaunicom": "中国联通",
        "china unicom": "中国联通",
        "cernet": "教育网",
        "cbn": "中国广电"
    ]

    /// Maps UHD Anycast CDN playback routes to professional CDN tier names without fake fixed geography.
    public static func formatCDNLineName(rawName: String, description: String? = nil, url: String) -> String {
        let host = ServerLineInfo.normalizeBaseURL(url)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .lowercased()
        let combined = "\(rawName) \(description ?? "")".lowercased()

        if host == "smart.uhdnow.com" || combined.contains("中国") || combined.contains("大陆") || combined.contains("cn cdn") {
            return "中国大陆 CDN"
        }
        if host == "v1.uhdnow.com" || combined.contains("cloudflare pro") || combined.contains("cf cdn pro") {
            return "Cloudflare Pro CDN"
        }
        if host == "v1.uhdgo.com" || combined.contains("备用") || combined.contains("国际") || combined.contains("cf cdn") || combined.contains("cloudflare") {
            return "Cloudflare CDN"
        }
        let cleaned = ServerLineInfo(name: rawName, url: url).cleanDisplayName
        return cleaned.isEmpty ? host : cleaned
    }

    /// Normalizes awkward mixed-language plan names from upstream API into restrained Donby Chinese UI copy.
    public static func formatPlanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("China ") {
            s = "中国" + s.dropFirst(6)
        } else if s.hasPrefix("CHINA ") {
            s = "中国" + s.dropFirst(6)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes raw upstream exit location strings (e.g. `"GB / 欧洲"` -> `"英国"`, `"陕西省"` -> `"陕西"`).
    public static func formatLocation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "未知" else { return nil }

        let segments = trimmed
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = segments.first {
            let upper = first.uppercased()
            if let mappedCountry = countryMap[upper] {
                if segments.count > 1 {
                    let second = segments[1]
                    let genericContinents: Set<String> = ["欧洲", "亚洲", "北美洲", "南美洲", "大洋洲", "非洲", "Europe", "Asia", "North America"]
                    if !genericContinents.contains(second) {
                        return "\(mappedCountry) · \(stripAdminSuffix(second))"
                    }
                }
                return mappedCountry
            }
            return stripAdminSuffix(first)
        }
        return stripAdminSuffix(trimmed)
    }

    /// Normalizes raw lowercase carrier identifiers (e.g. `"cmcc"` -> `"中国移动"`).
    public static func formatISP(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let mapped = ispMap[lower] {
            return mapped
        }
        return trimmed
    }

    public static func formatExitBadge(location: String?, isp: String?) -> String? {
        var parts: [String] = []
        if let loc = formatLocation(location) { parts.append(loc) }
        if let carrier = formatISP(isp) { parts.append(carrier) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func stripAdminSuffix(_ s: String) -> String {
        for suffix in ["省", "市", "特别行政区", "维吾尔自治区", "壮族自治区", "回族自治区", "自治区"] {
            if s.hasSuffix(suffix) && s.count > suffix.count + 1 {
                return String(s.dropLast(suffix.count))
            }
        }
        return s
    }
}

/// Implements the official UHD Streaming API speed-test reference statistical rules:
/// - Monotonic clock starts once HTTP response headers arrive.
/// - Warmup exclusion: record measurement baseline after >= 300ms AND > 1 MiB read.
/// - Steady-state average: post-warmup bytes / max(250ms, post-warmup elapsed).
/// - Instantaneous & peak: ~300ms rolling window sampled every ~100ms, clamped to
///   min(raw, max(avg * 4, avg + 200), 5000) Mbps.
/// - Short test fallback: if no valid post-warmup average/sample exists, compute from total bytes / max(250ms, totalElapsed) with sampleCount = 1.
public struct UHDSpeedTestMetricsEngine: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let currentMbps: Double
        public let averageMbps: Double
        public let peakMbps: Double
        public let elapsedMs: Int64
        public let sampleCount: Int
        public let totalBytes: Int64
        public let samplesMbps: [Double]
    }

    private let startTimeSec: Double
    private let warmupMinSec: Double = 0.30
    private let warmupMinBytes: Int64 = 1_048_576
    private let sampleIntervalSec: Double = 0.10
    private let rollingWindowSec: Double = 0.30
    private let minAvgWindowSec: Double = 0.25
    private let maxClampMbps: Double = 5000.0

    private var totalBytes: Int64 = 0
    private var warmupDone: Bool = false
    private var baselineTimeSec: Double = 0
    private var baselineBytes: Int64 = 0
    private var lastSampleTimeSec: Double = 0

    // Rolling history of (timestampSec, cumulativeBytes) for ~300ms window
    private var windowPoints: [(time: Double, bytes: Int64)] = []
    private var samplesMbps: [Double] = []
    private var currentMbps: Double = 0
    private var averageMbps: Double = 0
    private var peakMbps: Double = 0

    public init(startTimeSec: Double) {
        self.startTimeSec = startTimeSec
        self.windowPoints = [(startTimeSec, 0)]
    }

    @discardableResult
    public mutating func ingest(chunkBytes: Int64, at nowSec: Double) -> Bool {
        guard chunkBytes > 0 else { return false }
        let t = max(startTimeSec, nowSec)
        totalBytes += chunkBytes
        windowPoints.append((t, totalBytes))

        let pruneCutoff = t - (rollingWindowSec + 0.15)
        while windowPoints.count > 2, windowPoints[1].time < pruneCutoff {
            windowPoints.removeFirst()
        }

        let elapsed = t - startTimeSec
        if !warmupDone {
            if elapsed >= warmupMinSec && totalBytes > warmupMinBytes {
                warmupDone = true
                baselineTimeSec = t
                baselineBytes = totalBytes
                lastSampleTimeSec = t
            }
            return false
        }

        let sinceLastSample = t - lastSampleTimeSec
        guard sinceLastSample >= sampleIntervalSec else { return false }
        lastSampleTimeSec = t

        let postWarmupDt = t - baselineTimeSec
        let postWarmupBytes = totalBytes - baselineBytes
        if postWarmupDt >= minAvgWindowSec && postWarmupBytes > 0 {
            averageMbps = Self.bytesToMbps(bytes: postWarmupBytes, seconds: max(minAvgWindowSec, postWarmupDt))
        }

        let rawInstant = computeRollingWindowMbps(at: t)
        let clampedInstant = clampInstantaneous(rawInstant, average: averageMbps)
        currentMbps = clampedInstant
        samplesMbps.append(clampedInstant)
        if clampedInstant > peakMbps {
            peakMbps = clampedInstant
        }
        return true
    }

    public mutating func finalize(at endSec: Double) -> Snapshot {
        let t = max(startTimeSec, endSec)
        let totalElapsedSec = max(0.0, t - startTimeSec)
        let elapsedMs = Int64((totalElapsedSec * 1000.0).rounded())

        if warmupDone {
            let postWarmupDt = t - baselineTimeSec
            let postWarmupBytes = totalBytes - baselineBytes
            if postWarmupBytes > 0 {
                averageMbps = Self.bytesToMbps(bytes: postWarmupBytes, seconds: max(minAvgWindowSec, postWarmupDt))
            }
        }

        if averageMbps <= 0 || samplesMbps.isEmpty {
            let denom = max(minAvgWindowSec, totalElapsedSec)
            let fallback = Self.bytesToMbps(bytes: totalBytes, seconds: denom)
            if averageMbps <= 0 {
                averageMbps = min(fallback, maxClampMbps)
            }
            if samplesMbps.isEmpty {
                let single = min(fallback, maxClampMbps)
                samplesMbps = [single]
                currentMbps = single
                peakMbps = max(peakMbps, single)
            }
        }

        peakMbps = max(peakMbps, averageMbps)
        return Snapshot(
            currentMbps: currentMbps,
            averageMbps: averageMbps,
            peakMbps: peakMbps,
            elapsedMs: elapsedMs,
            sampleCount: samplesMbps.count,
            totalBytes: totalBytes,
            samplesMbps: samplesMbps
        )
    }

    public func currentSnapshot(at nowSec: Double) -> Snapshot {
        let t = max(startTimeSec, nowSec)
        let elapsedMs = Int64((max(0.0, t - startTimeSec) * 1000.0).rounded())
        let liveAvg: Double
        if averageMbps > 0 {
            liveAvg = averageMbps
        } else if totalBytes > 0 {
            liveAvg = min(Self.bytesToMbps(bytes: totalBytes, seconds: max(minAvgWindowSec, t - startTimeSec)), maxClampMbps)
        } else {
            liveAvg = 0
        }
        return Snapshot(
            currentMbps: currentMbps > 0 ? currentMbps : liveAvg,
            averageMbps: liveAvg,
            peakMbps: max(peakMbps, liveAvg),
            elapsedMs: elapsedMs,
            sampleCount: samplesMbps.count,
            totalBytes: totalBytes,
            samplesMbps: samplesMbps
        )
    }

    private func computeRollingWindowMbps(at nowSec: Double) -> Double {
        let targetTime = nowSec - rollingWindowSec
        var anchor = windowPoints.first ?? (startTimeSec, 0)
        for pt in windowPoints {
            if pt.time <= targetTime {
                anchor = pt
            } else {
                break
            }
        }
        let dt = nowSec - anchor.time
        let delta = totalBytes - anchor.bytes
        guard dt > 0.02, delta > 0 else { return 0 }
        return Self.bytesToMbps(bytes: delta, seconds: dt)
    }

    private func clampInstantaneous(_ raw: Double, average: Double) -> Double {
        if average > 0 {
            let cap = min(max(average * 4.0, average + 200.0), maxClampMbps)
            return min(raw, cap)
        }
        return min(raw, maxClampMbps)
    }

    public static func bytesToMbps(bytes: Int64, seconds: Double) -> Double {
        guard bytes > 0, seconds > 0 else { return 0 }
        return (Double(bytes) * 8.0) / (seconds * 1_000_000.0)
    }
}

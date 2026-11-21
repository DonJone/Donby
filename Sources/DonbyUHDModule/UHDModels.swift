import Foundation
import DonbyCore

// MARK: - UHDNow Native API Domain Models & Pure Policies

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

// MARK: - Subscription, Traffic & Account Snapshot

public struct UHDSubscriptionPlanInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let planType: String?
    public let trafficLimitGB: Int64?
    public let activeVideoDeliveryLimit: Int?
    public let loginDeviceLimit: Int?
    public let monthlyPriceUSD: Double?
    public let yearlyPriceUSD: Double?
    public let teamTrafficLimitGB: Int64?
    public let memberQuota: Int?
    public let allowDownload: Bool?
    public let displayUnlimitedTraffic: Bool?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        planType: String? = nil,
        trafficLimitGB: Int64? = nil,
        activeVideoDeliveryLimit: Int? = nil,
        loginDeviceLimit: Int? = nil,
        monthlyPriceUSD: Double? = nil,
        yearlyPriceUSD: Double? = nil,
        teamTrafficLimitGB: Int64? = nil,
        memberQuota: Int? = nil,
        allowDownload: Bool? = nil,
        displayUnlimitedTraffic: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.planType = planType
        self.trafficLimitGB = trafficLimitGB
        self.activeVideoDeliveryLimit = activeVideoDeliveryLimit
        self.loginDeviceLimit = loginDeviceLimit
        self.monthlyPriceUSD = monthlyPriceUSD
        self.yearlyPriceUSD = yearlyPriceUSD
        self.teamTrafficLimitGB = teamTrafficLimitGB
        self.memberQuota = memberQuota
        self.allowDownload = allowDownload
        self.displayUnlimitedTraffic = displayUnlimitedTraffic
    }
}

public struct UHDSubscriptionInfo: Codable, Equatable, Sendable {
    public let isTrial: Bool
    public let allowDownload: Bool
    public let displayUnlimitedTraffic: Bool
    public let userId: String
    public let planId: String
    public let plan: UHDSubscriptionPlanInfo?
    public let ownerId: String?
    public let memberUsage: Int?
    public let subscribedAt: String?
    public let expiresAt: String?
    public let cancelledAt: String?
    public let trafficLimitBytes: Int64
    public let activeVideoDeliveryLimit: Int
    public let renewDay: Int?
    public let autoRenew: Bool

    public init(
        isTrial: Bool = false,
        allowDownload: Bool,
        displayUnlimitedTraffic: Bool,
        userId: String = "",
        planId: String = "",
        plan: UHDSubscriptionPlanInfo? = nil,
        ownerId: String? = nil,
        memberUsage: Int? = nil,
        subscribedAt: String? = nil,
        expiresAt: String? = nil,
        cancelledAt: String? = nil,
        trafficLimitBytes: Int64,
        activeVideoDeliveryLimit: Int,
        renewDay: Int? = nil,
        autoRenew: Bool = false
    ) {
        self.isTrial = isTrial
        self.allowDownload = allowDownload
        self.displayUnlimitedTraffic = displayUnlimitedTraffic
        self.userId = userId
        self.planId = planId
        self.plan = plan
        self.ownerId = ownerId
        self.memberUsage = memberUsage
        self.subscribedAt = subscribedAt
        self.expiresAt = expiresAt
        self.cancelledAt = cancelledAt
        self.trafficLimitBytes = trafficLimitBytes
        self.activeVideoDeliveryLimit = activeVideoDeliveryLimit
        self.renewDay = renewDay
        self.autoRenew = autoRenew
    }

    public var expiresDate: Date? {
        guard let expiresAt, !expiresAt.isEmpty else { return nil }
        return Self.parseRFC3339(expiresAt)
    }

    public var remainingDays: Int? {
        guard let exp = expiresDate else { return nil }
        let seconds = exp.timeIntervalSinceNow
        return Int(ceil(seconds / 86400.0))
    }

    public var isExpired: Bool {
        guard let exp = expiresDate else { return false }
        return exp < Date()
    }

    public var isExpiringSoon: Bool {
        guard let days = remainingDays else { return false }
        return days >= 0 && days <= 7
    }

    public var formattedExpiresDate: String? {
        guard let exp = expiresDate else { return expiresAt }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: exp)
    }

    public var nextResetDaysRemaining: Int? {
        guard let renewDay, renewDay >= 1 && renewDay <= 31 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let comps = cal.dateComponents([.year, .month, .day], from: today)
        guard let year = comps.year, let month = comps.month else { return nil }

        func clampedDate(year y: Int, month m: Int, day d: Int) -> Date? {
            var dc = DateComponents(year: y, month: m, day: 1)
            guard let firstOfMonth = cal.date(from: dc),
                  let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return nil }
            dc.day = min(d, range.count)
            return cal.date(from: dc)
        }

        if let thisMonthReset = clampedDate(year: year, month: month, day: renewDay), thisMonthReset > today {
            return cal.dateComponents([.day], from: today, to: thisMonthReset).day
        }
        let nextMonth = month == 12 ? 1 : month + 1
        let nextYear = month == 12 ? year + 1 : year
        if let nextMonthReset = clampedDate(year: nextYear, month: nextMonth, day: renewDay) {
            return cal.dateComponents([.day], from: today, to: nextMonthReset).day
        }
        return nil
    }

    public static func parseRFC3339(_ str: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }
}

public struct UHDTrafficSummary: Sendable, Codable, Equatable {
    public let userId: String?
    public let displayUnlimitedTraffic: Bool
    public let usedBytes: Int64
    public let limitBytes: Int64
    public let updatedAt: String

    public init(
        userId: String? = nil,
        displayUnlimitedTraffic: Bool,
        usedBytes: Int64,
        limitBytes: Int64,
        updatedAt: String
    ) {
        self.userId = userId
        self.displayUnlimitedTraffic = displayUnlimitedTraffic
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
        self.updatedAt = updatedAt
    }

    public var remainingBytes: Int64 {
        guard !displayUnlimitedTraffic, limitBytes > 0 else { return 0 }
        return max(0, limitBytes - usedBytes)
    }

    public var usageFraction: Double {
        guard !displayUnlimitedTraffic, limitBytes > 0 else { return 0 }
        return max(0.0, min(1.0, Double(usedBytes) / Double(limitBytes)))
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let b = max(0, bytes)
        let tib = 1099511627776.0
        let gib = 1073741824.0
        let mib = 1048576.0
        let val = Double(b)
        if val >= tib {
            return String(format: "%.2f TiB", val / tib)
        } else if val >= gib {
            return String(format: "%.2f GiB", val / gib)
        } else if val >= mib {
            return String(format: "%.1f MiB", val / mib)
        } else {
            return ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
        }
    }

    public var shortToolbarBadgeText: String {
        if displayUnlimitedTraffic {
            return "不限流量"
        }
        if limitBytes > 0 {
            return "剩 \(Self.formatBytes(remainingBytes))"
        }
        return "已用 \(Self.formatBytes(usedBytes))"
    }
}

public struct UHDAccountSnapshot: Codable, Equatable, Sendable {
    public let subscription: UHDSubscriptionInfo?
    public let traffic: UHDTrafficSummary?
    public let fetchedAt: Date

    public init(subscription: UHDSubscriptionInfo?, traffic: UHDTrafficSummary?, fetchedAt: Date = Date()) {
        self.subscription = subscription
        self.traffic = traffic
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Speed Test Models & Official Reference Metrics Engine

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

public struct UHDSpeedTestNetworkInfo: Codable, Equatable, Sendable {
    public let ip: String
    public let country: String
    public let countryName: String
    public let region: String
    public let regionName: String
    public let province: String
    public let provinceName: String
    public let isp: String
    public let displayLocation: String

    public init(
        ip: String = "",
        country: String = "",
        countryName: String = "",
        region: String = "",
        regionName: String = "",
        province: String = "",
        provinceName: String = "",
        isp: String = "",
        displayLocation: String = "未知"
    ) {
        self.ip = ip
        self.country = country
        self.countryName = countryName
        self.region = region
        self.regionName = regionName
        self.province = province
        self.provinceName = provinceName
        self.isp = isp
        self.displayLocation = displayLocation.isEmpty ? "未知" : displayLocation
    }

    public var isChinaMainlandExit: Bool {
        country.uppercased() == "CN"
    }

    public var compactSummary: String {
        let locCandidate = (!displayLocation.isEmpty && displayLocation != "未知") ? displayLocation : country
        return UHDDisplayNormalizer.formatExitBadge(location: locCandidate, isp: isp) ?? "未知出口"
    }
}

public struct UHDSpeedTestProgress: Sendable, Equatable {
    public let fraction: Double
    public let currentMbps: Double
    public let averageMbps: Double
    public let peakMbps: Double
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let recentSamplesMbps: [Double]

    public init(
        fraction: Double,
        currentMbps: Double,
        averageMbps: Double,
        peakMbps: Double,
        downloadedBytes: Int64,
        totalBytes: Int64,
        recentSamplesMbps: [Double]
    ) {
        self.fraction = fraction
        self.currentMbps = currentMbps
        self.averageMbps = averageMbps
        self.peakMbps = peakMbps
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.recentSamplesMbps = recentSamplesMbps
    }
}

public struct UHDSpeedTestResult: Sendable, Equatable {
    public let domainId: String
    public let resolvedHost: String
    public let networkInfo: UHDSpeedTestNetworkInfo
    public let averageMbps: Double
    public let peakMbps: Double
    public let elapsedMs: Int64
    public let sampleCount: Int
    public let downloadedBytes: Int64
    public let sizeMiB: Int
    public let samplesMbps: [Double]
    public let reportSubmitted: Bool
    public let testedAt: Date

    public var location: String { networkInfo.displayLocation }
    public var isp: String { networkInfo.isp }

    public init(
        domainId: String,
        resolvedHost: String = "",
        networkInfo: UHDSpeedTestNetworkInfo,
        averageMbps: Double,
        peakMbps: Double,
        elapsedMs: Int64,
        sampleCount: Int,
        downloadedBytes: Int64,
        sizeMiB: Int = 32,
        samplesMbps: [Double] = [],
        reportSubmitted: Bool = true,
        testedAt: Date = Date()
    ) {
        self.domainId = domainId
        self.resolvedHost = resolvedHost
        self.networkInfo = networkInfo
        self.averageMbps = averageMbps
        self.peakMbps = peakMbps
        self.elapsedMs = elapsedMs
        self.sampleCount = sampleCount
        self.downloadedBytes = downloadedBytes
        self.sizeMiB = sizeMiB
        self.samplesMbps = samplesMbps
        self.reportSubmitted = reportSubmitted
        self.testedAt = testedAt
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

// MARK: - Catalog Innovations (Anime Calendar, Genres, Persons, TV Resume)

public struct UHDAnimeCalendarDay: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { weekday }
    public let weekday: Int // 1 = Monday ... 7 = Sunday
    public let total: Int

    public init(weekday: Int, total: Int) {
        self.weekday = weekday
        self.total = total
    }

    public var shortTitle: String {
        switch weekday {
        case 1: return "周一"
        case 2: return "周二"
        case 3: return "周三"
        case 4: return "周四"
        case 5: return "周五"
        case 6: return "周六"
        case 7: return "周日"
        default: return "周\(weekday)"
        }
    }

    public static func todayShanghaiWeekday() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        // Calendar weekday: 1 = Sunday, 2 = Monday ... 7 = Saturday -> map to 1=Mon..7=Sun
        let wd = cal.component(.weekday, from: Date())
        return wd == 1 ? 7 : (wd - 1)
    }
}

public struct UHDAnimeCalendarSchedule: Codable, Equatable, Sendable {
    public let airDate: String
    public let estimated: Bool

    public init(airDate: String, estimated: Bool) {
        self.airDate = airDate
        self.estimated = estimated
    }

    public var badgeText: String {
        let shortDate: String
        if airDate.count >= 10 {
            let idx = airDate.index(airDate.startIndex, offsetBy: 5)
            shortDate = String(airDate[idx...])
        } else {
            shortDate = airDate
        }
        return estimated ? "预计 \(shortDate)" : shortDate
    }
}

public struct UHDAnimeCalendarEntry: Identifiable, Equatable, Sendable {
    public var id: String { "\(item.id)|\(schedule.airDate)" }
    public let item: EmbyItem
    public let schedule: UHDAnimeCalendarSchedule

    public init(item: EmbyItem, schedule: UHDAnimeCalendarSchedule) {
        self.item = item
        self.schedule = schedule
    }
}

public struct UHDGenreInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let slug: String

    public init(id: String, name: String, slug: String = "") {
        self.id = id
        self.name = name
        self.slug = slug
    }
}

public struct UHDPersonDetail: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tmdbId: String?
    public let imdbId: String?
    public let imageURL: String?
    public var favorite: Bool

    public init(
        id: String,
        name: String,
        tmdbId: String? = nil,
        imdbId: String? = nil,
        imageURL: String? = nil,
        favorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.imageURL = imageURL
        self.favorite = favorite
    }
}

public struct UHDTVPlaybackEpisode: Codable, Equatable, Sendable {
    public let episodeId: String
    public let mediaId: String
    public let seasonId: String
    public let seasonNumber: Int
    public let episodeNumber: Int
    public let title: String?
    public let thumbURL: String?
    public let durationSeconds: Int64
    public let positionMs: Int64
    public let progressPct: Int
    public let lastPlayedAt: String?

    public init(
        episodeId: String,
        mediaId: String,
        seasonId: String,
        seasonNumber: Int,
        episodeNumber: Int,
        title: String? = nil,
        thumbURL: String? = nil,
        durationSeconds: Int64 = 0,
        positionMs: Int64 = 0,
        progressPct: Int = 0,
        lastPlayedAt: String? = nil
    ) {
        self.episodeId = episodeId
        self.mediaId = mediaId
        self.seasonId = seasonId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.thumbURL = thumbURL
        self.durationSeconds = durationSeconds
        self.positionMs = positionMs
        self.progressPct = progressPct
        self.lastPlayedAt = lastPlayedAt
    }
}

public struct UHDTVPlaybackState: Codable, Equatable, Sendable {
    public let resume: UHDTVPlaybackEpisode?
    public let nextUp: UHDTVPlaybackEpisode?

    public init(resume: UHDTVPlaybackEpisode? = nil, nextUp: UHDTVPlaybackEpisode? = nil) {
        self.resume = resume
        self.nextUp = nextUp
    }

    public var preferredEpisode: UHDTVPlaybackEpisode? {
        resume ?? nextUp
    }
}

// MARK: - Team Management v2 Models

public struct UHDTeamSettings: Codable, Equatable, Sendable {
    public var activeVideoDeliveryLimit: Int
    public var allowDownload: Bool

    public init(activeVideoDeliveryLimit: Int, allowDownload: Bool) {
        self.activeVideoDeliveryLimit = activeVideoDeliveryLimit
        self.allowDownload = allowDownload
    }
}

public struct UHDTeamOverview: Codable, Equatable, Sendable {
    public let expiresAt: String
    public let memberCount: Int
    public let memberLimit: Int
    public let trafficLimitBytes: Int64
    public let trafficUsedBytes: Int64
    public let renewDay: Int
    public let settings: UHDTeamSettings

    public init(
        expiresAt: String,
        memberCount: Int,
        memberLimit: Int,
        trafficLimitBytes: Int64,
        trafficUsedBytes: Int64,
        renewDay: Int,
        settings: UHDTeamSettings
    ) {
        self.expiresAt = expiresAt
        self.memberCount = memberCount
        self.memberLimit = memberLimit
        self.trafficLimitBytes = trafficLimitBytes
        self.trafficUsedBytes = trafficUsedBytes
        self.renewDay = renewDay
        self.settings = settings
    }
}

public struct UHDTeamMember: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let expiresAt: String
    public let trafficLimitBytes: Int64
    public let trafficUsedBytes: Int64
    public let renewDay: Int
    public let activeVideoDeliveryLimit: Int
    public let allowDownload: Bool
    public let sessionCount: Int

    public init(
        id: String,
        username: String,
        expiresAt: String,
        trafficLimitBytes: Int64,
        trafficUsedBytes: Int64,
        renewDay: Int,
        activeVideoDeliveryLimit: Int,
        allowDownload: Bool,
        sessionCount: Int
    ) {
        self.id = id
        self.username = username
        self.expiresAt = expiresAt
        self.trafficLimitBytes = trafficLimitBytes
        self.trafficUsedBytes = trafficUsedBytes
        self.renewDay = renewDay
        self.activeVideoDeliveryLimit = activeVideoDeliveryLimit
        self.allowDownload = allowDownload
        self.sessionCount = sessionCount
    }
}

// MARK: - Watch Party (同看) Models

public struct UHDWatchPartyCreatedRoom: Codable, Equatable, Sendable {
    public let id: String
    public let invite: String

    public init(id: String, invite: String) {
        self.id = id
        self.invite = invite
    }
}

public struct UHDWatchPartyMember: Codable, Identifiable, Equatable, Sendable {
    public var id: String { userId }
    public let userId: String
    public let name: String
    public let online: Bool
    public let status: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name, online, status
    }

    public init(userId: String, name: String, online: Bool, status: String) {
        self.userId = userId
        self.name = name
        self.online = online
        self.status = status
    }

    public var localizedStatus: String {
        switch status.lowercased() {
        case "ready": return "就绪"
        case "loading": return "加载中"
        case "buffering": return "缓冲中"
        case "error": return "异常"
        case "gesture": return "待交互"
        default: return online ? "在线" : "离线"
        }
    }
}

public struct UHDWatchPartyMedia: Codable, Equatable, Sendable {
    public let itemType: String
    public let itemId: String
    public let assetId: String

    enum CodingKeys: String, CodingKey {
        case itemType = "item_type"
        case itemId = "item_id"
        case assetId = "asset_id"
    }

    public init(itemType: String, itemId: String, assetId: String) {
        self.itemType = itemType
        self.itemId = itemId
        self.assetId = assetId
    }
}

public struct UHDWatchPartyRoomSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let invite: String?
    public let hostId: String
    public let maxMembers: Int
    public let locked: Bool
    public let members: [UHDWatchPartyMember]
    public let media: UHDWatchPartyMedia
    public let phase: String
    public let positionMs: Int64
    public let serverMs: Int64
    public let rate: Double
    public let intent: Bool
    public let control: String
    public let epoch: Int
    public let term: Int
    public let revision: Int

    enum CodingKeys: String, CodingKey {
        case id, invite
        case hostId = "host_id"
        case maxMembers = "max_members"
        case locked, members, media, phase
        case positionMs = "position_ms"
        case serverMs = "server_ms"
        case rate, intent, control, epoch, term, revision
    }

    public init(
        id: String,
        invite: String? = nil,
        hostId: String,
        maxMembers: Int,
        locked: Bool,
        members: [UHDWatchPartyMember],
        media: UHDWatchPartyMedia,
        phase: String,
        positionMs: Int64,
        serverMs: Int64,
        rate: Double,
        intent: Bool,
        control: String,
        epoch: Int,
        term: Int,
        revision: Int
    ) {
        self.id = id
        self.invite = invite
        self.hostId = hostId
        self.maxMembers = maxMembers
        self.locked = locked
        self.members = members
        self.media = media
        self.phase = phase
        self.positionMs = positionMs
        self.serverMs = serverMs
        self.rate = rate
        self.intent = intent
        self.control = control
        self.epoch = epoch
        self.term = term
        self.revision = revision
    }

    /// Extrapolates current playback position in seconds using the official spec formula:
    /// Only in `playing` phase: `position_ms + max(0, serverNowMs - server_ms) * rate`.
    public func extrapolatedPositionSeconds(estimatedServerNowMs: Int64) -> Double {
        if phase == "playing" {
            let deltaMs = max(0.0, Double(estimatedServerNowMs - serverMs))
            return max(0.0, (Double(positionMs) + deltaMs * max(0.25, rate)) / 1000.0)
        }
        return max(0.0, Double(positionMs) / 1000.0)
    }

    public var localizedPhase: String {
        switch phase {
        case "playing": return "同步播放中"
        case "paused": return "已暂停"
        case "aligning": return "成员加入对齐中"
        case "loading": return "房主加载中"
        case "buffering": return "房主缓冲中"
        case "waiting": return "等待房主重连"
        case "preparing": return "等待开始"
        case "ended": return "已播放结束"
        default: return phase
        }
    }
}

// MARK: - UHD Danmu Models

public struct UHDDanmuComment: Identifiable, Equatable, Sendable {
    public let id: String
    public let timeSeconds: Double
    public let mode: Int // 1 = scroll, 4 = bottom, 5 = top
    public let colorRGB: UInt32
    public let text: String

    public init(id: String, timeSeconds: Double, mode: Int, colorRGB: UInt32, text: String) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.mode = mode
        self.colorRGB = colorRGB
        self.text = text
    }
}

public struct UHDDanmuAnimeMatch: Identifiable, Equatable, Sendable {
    public var id: String { "\(animeId)-\(episodeId ?? 0)" }
    public let animeId: Int
    public let animeTitle: String
    public let episodeId: Int?
    public let episodeTitle: String?
    public let typeDescription: String?

    public init(
        animeId: Int,
        animeTitle: String,
        episodeId: Int? = nil,
        episodeTitle: String? = nil,
        typeDescription: String? = nil
    ) {
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.episodeId = episodeId
        self.episodeTitle = episodeTitle
        self.typeDescription = typeDescription
    }
}

public struct UHDDanmuEpisodeOption: Identifiable, Equatable, Sendable {
    public var id: Int { episodeId }
    public let episodeId: Int
    public let episodeTitle: String

    public init(episodeId: Int, episodeTitle: String) {
        self.episodeId = episodeId
        self.episodeTitle = episodeTitle
    }
}

import Foundation
import DonbyCore

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
            return "剩余 \(Self.formatBytes(remainingBytes))"
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

// MARK: - Speed Test Result & Progress Models

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

// MARK: - Watch Party Models

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

import Foundation
import DonbyCore
import DonbyNetwork

public struct UHDLoginResult: Sendable {
    public let token: String
    public let expiresAt: String
}

public struct UHDConnectionTestResult: Sendable {
    public let latencyMs: Int
    public let authenticated: Bool
    public let planName: String?
    public let message: String
}

private struct UHDEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let msg: String?
}

private struct UHDOkOnly: Decodable {
    let ok: Bool
    let msg: String?
}

private struct UHDLoginDataDTO: Decodable {
    let token: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

private struct UHDCollectionsDataDTO: Decodable {
    let items: [UHDCollectionDTO]
}

private struct UHDCollectionDTO: Decodable {
    let id: String
    let systemKey: String?
    let name: String
    let mediaType: String?
    let posterURL: String?
    let itemCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case systemKey = "system_key"
        case name
        case mediaType = "media_type"
        case posterURL = "poster_url"
        case itemCount = "item_count"
    }
}

private struct UHDUserStateDTO: Decodable {
    let played: Bool
    let favorite: Bool?
    let positionMs: Int64?
    let progressPct: Int?
    let lastPlayedAt: String?

    enum CodingKeys: String, CodingKey {
        case played
        case favorite
        case positionMs = "position_ms"
        case progressPct = "progress_pct"
        case lastPlayedAt = "last_played_at"
    }
}

private struct UHDGenreDTO: Decodable {
    let id: String
    let name: String
    let slug: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intId = try? c.decode(Int.self, forKey: .id) {
            self.id = String(intId)
        } else if let strId = try? c.decode(String.self, forKey: .id) {
            self.id = strId
        } else {
            self.id = ""
        }
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.slug = try? c.decodeIfPresent(String.self, forKey: .slug)
    }
}

private struct UHDMediaSummaryDTO: Decodable {
    let id: String
    let tmdbId: Int?
    let type: String
    let title: String
    let originTitle: String?
    let releaseDate: String?
    let releaseYear: Int?
    let rating: Double?
    let posterURL: String?
    let fanartURL: String?
    let logoURL: String?
    let duration: Int64?
    let totalSeasons: Int?
    let versionCount: Int?
    let assetUpdatedAt: String?
    let genres: [UHDGenreDTO]?
    let userState: UHDUserStateDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case tmdbId = "tmdb_id"
        case type
        case title
        case originTitle = "origin_title"
        case releaseDate = "release_date"
        case releaseYear = "release_year"
        case rating
        case posterURL = "poster_url"
        case fanartURL = "fanart_url"
        case logoURL = "logo_url"
        case duration
        case totalSeasons = "total_seasons"
        case versionCount = "version_count"
        case assetUpdatedAt = "asset_updated_at"
        case genres
        case userState = "user_state"
    }
}

private struct UHDAnimeCalendarDayDTO: Decodable {
    let weekday: Int
    let total: Int
}

private struct UHDAnimeCalendarScheduleDTO: Decodable {
    let airDate: String
    let estimated: Bool

    enum CodingKeys: String, CodingKey {
        case airDate = "air_date"
        case estimated
    }
}

private struct UHDAnimeCalendarItemDTO: Decodable {
    let summary: UHDMediaSummaryDTO
    let schedule: UHDAnimeCalendarScheduleDTO

    enum CodingKeys: String, CodingKey {
        case schedule
    }

    init(from decoder: Decoder) throws {
        self.summary = try UHDMediaSummaryDTO(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schedule = try c.decode(UHDAnimeCalendarScheduleDTO.self, forKey: .schedule)
    }
}

private struct UHDPersonCardDTO: Decodable {
    let id: String
    let name: String
    let tmdbId: String?
    let imdbId: String?
    let imageURL: String?
    let favorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, favorite
        case tmdbId = "tmdb_id"
        case imdbId = "imdb_id"
        case imageURL = "image_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        if let s = try? c.decodeIfPresent(String.self, forKey: .tmdbId) {
            self.tmdbId = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .tmdbId) {
            self.tmdbId = String(n)
        } else {
            self.tmdbId = nil
        }
        self.imdbId = try? c.decodeIfPresent(String.self, forKey: .imdbId)
        self.imageURL = try? c.decodeIfPresent(String.self, forKey: .imageURL)
        self.favorite = try? c.decodeIfPresent(Bool.self, forKey: .favorite)
    }
}

private struct UHDMediaDetailDTO: Decodable {
    let id: String
    let type: String
    let title: String
    let originTitle: String?
    let tagline: String?
    let description: String?
    let releaseDate: String?
    let releaseYear: Int?
    let rating: Double?
    let posterURL: String?
    let fanartURL: String?
    let logoURL: String?
    let duration: Int64?
    let totalSeasons: Int?
    let versionCount: Int?
    let genres: [UHDGenreDTO]?
    let userState: UHDUserStateDTO?
    let status: String?
    let tmdbId: Int?
    let imdbId: String?
    let doubanId: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, tagline, description, rating, duration, genres, status
        case originTitle = "origin_title"
        case releaseDate = "release_date"
        case releaseYear = "release_year"
        case posterURL = "poster_url"
        case fanartURL = "fanart_url"
        case logoURL = "logo_url"
        case totalSeasons = "total_seasons"
        case versionCount = "version_count"
        case userState = "user_state"
        case tmdbId = "tmdb_id"
        case imdbId = "imdb_id"
        case doubanId = "douban_id"
    }
}

private struct UHDMediaCursorDTO: Decodable {
    let items: [UHDMediaSummaryDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private struct UHDSearchDataDTO: Decodable {
    let items: [UHDMediaSummaryDTO]
    let truncated: Bool?
}

private struct UHDItemsOnlyDTO<T: Decodable>: Decodable {
    let items: [T]
}

private struct UHDFavoritesCursorDTO<T: Decodable>: Decodable {
    let total: Int?
    let items: [T]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case total, items
        case nextCursor = "next_cursor"
    }
}

private struct UHDTVPlaybackEpisodeDTO: Decodable {
    let episodeId: String
    let mediaId: String
    let seasonId: String
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let thumbURL: String?
    let duration: Int64
    let positionMs: Int64
    let progressPct: Int
    let lastPlayedAt: String?

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case mediaId = "media_id"
        case seasonId = "season_id"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case title
        case thumbURL = "thumb_url"
        case duration
        case positionMs = "position_ms"
        case progressPct = "progress_pct"
        case lastPlayedAt = "last_played_at"
    }
}

private struct UHDTVPlaybackStateDTO: Decodable {
    let resume: UHDTVPlaybackEpisodeDTO?
    let nextUp: UHDTVPlaybackEpisodeDTO?

    enum CodingKeys: String, CodingKey {
        case resume
        case nextUp = "next_up"
    }
}

private struct UHDSeasonCardDTO: Decodable {
    let id: String
    let mediaId: String
    let seasonNumber: Int
    let title: String?
    let description: String?
    let posterURL: String?
    let totalEpisodes: Int
    let userState: UHDUserStateDTO

    enum CodingKeys: String, CodingKey {
        case id
        case mediaId = "media_id"
        case seasonNumber = "season_number"
        case title, description
        case posterURL = "poster_url"
        case totalEpisodes = "total_episodes"
        case userState = "user_state"
    }
}

private struct UHDEpisodeCardDTO: Decodable {
    let id: String
    let mediaId: String
    let seasonId: String
    let episodeNumber: Int
    let title: String?
    let description: String?
    let airDate: String?
    let thumbURL: String?
    let duration: Int64
    let versionCount: Int
    let userState: UHDUserStateDTO

    enum CodingKeys: String, CodingKey {
        case id
        case mediaId = "media_id"
        case seasonId = "season_id"
        case episodeNumber = "episode_number"
        case title, description
        case airDate = "air_date"
        case thumbURL = "thumb_url"
        case duration
        case versionCount = "version_count"
        case userState = "user_state"
    }
}

private struct UHDEpisodeDetailDataDTO: Decodable {
    let series: UHDMediaSummaryDTO
    let season: UHDSeasonCardDTO
    let episode: UHDEpisodeCardDTO
}

private struct UHDEpisodePageDTO: Decodable {
    let page: Int
    let pageSize: Int
    let total: Int
    let items: [UHDEpisodeCardDTO]

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize = "page_size"
        case total, items
    }
}

private struct UHDCreditDTO: Decodable {
    let personId: String
    let name: String
    let role: String
    let character: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case name, role, character
        case imageURL = "image_url"
    }
}

private struct UHDCreditsPageDTO: Decodable {
    let items: [UHDCreditDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private struct UHDDolbyVisionDTO: Decodable {
    let versionMajor: Int?
    let versionMinor: Int?
    let profile: Int?
    let level: Int?
    let rpuPresent: Bool?
    let elPresent: Bool?
    let blPresent: Bool?

    enum CodingKeys: String, CodingKey {
        case versionMajor = "version_major"
        case versionMinor = "version_minor"
        case profile, level
        case rpuPresent = "rpu_present"
        case elPresent = "el_present"
        case blPresent = "bl_present"
    }
}

private struct UHDAudioTrackDTO: Decodable {
    let index: Int
    let language: String?
    let title: String?
    let codecName: String?
    let bitRate: Int64?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: String?
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case index, language, title, channels
        case codecName = "codec_name"
        case bitRate = "bit_rate"
        case channelLayout = "channel_layout"
        case sampleRate = "sample_rate"
        case isDefault = "is_default"
    }
}

private struct UHDSubtitleTrackDTO: Decodable {
    let index: Int
    let language: String?
    let title: String?
    let codecName: String?
    let isDefault: Bool
    let isForced: Bool

    enum CodingKeys: String, CodingKey {
        case index, language, title
        case codecName = "codec_name"
        case isDefault = "is_default"
        case isForced = "is_forced"
    }
}

private struct UHDVideoAssetDTO: Decodable {
    let assetId: String
    let mediaId: String
    let episodeId: String?
    let name: String
    let displayName: String
    let container: String
    let duration: Int64
    let fileSize: Int64
    let bitRate: Int64
    let width: Int
    let height: Int
    let resolution: Int
    let encoding: String
    let profile: String?
    let videoBitRate: Int64?
    let pixFmt: String?
    let frameRate: String?
    let colorSpace: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let bitDepth: Int?
    let videoRange: String
    let dolbyVision: UHDDolbyVisionDTO?
    let audioTracks: [UHDAudioTrackDTO]
    let subtitleTracks: [UHDSubtitleTrackDTO]
    let playURL: String
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case mediaId = "media_id"
        case episodeId = "episode_id"
        case name
        case displayName = "display_name"
        case container, duration
        case fileSize = "file_size"
        case bitRate = "bit_rate"
        case width, height, resolution, encoding, profile
        case videoBitRate = "video_bit_rate"
        case pixFmt = "pix_fmt"
        case frameRate = "frame_rate"
        case colorSpace = "color_space"
        case colorTransfer = "color_transfer"
        case colorPrimaries = "color_primaries"
        case bitDepth = "bit_depth"
        case videoRange = "video_range"
        case dolbyVision = "dolby_vision"
        case audioTracks = "audio_tracks"
        case subtitleTracks = "subtitle_tracks"
        case playURL = "play_url"
        case downloadURL = "download_url"
    }
}

private struct UHDSubtitleAssetDTO: Decodable {
    let assetId: String
    let mediaId: String
    let episodeId: String?
    let languages: [String]
    let displayName: String
    let name: String
    let format: String
    let playURL: String
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case mediaId = "media_id"
        case episodeId = "episode_id"
        case languages
        case displayName = "display_name"
        case name, format
        case playURL = "play_url"
        case downloadURL = "download_url"
    }
}

private struct UHDAssetResponseDTO: Decodable {
    let videos: [UHDVideoAssetDTO]
    let subtitles: [UHDSubtitleAssetDTO]
}

private struct UHDPlaybackDomainDTO: Decodable {
    let id: String
    let name: String
    let domain: String?
    let description: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, domain, description
        case sortOrder = "sort_order"
    }
}

private struct UHDResolveDomainDTO: Decodable {
    let domain: String
}

private struct UHDPlaybackItemDTO: Decodable {
    let itemType: String
    let itemId: String
    let mediaId: String
    let title: String
    let seriesTitle: String?
    let seasonId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let posterURL: String?
    let fanartURL: String?
    let thumbURL: String?
    let duration: Int64
    let positionMs: Int64
    let progressPct: Int
    let lastPlayedAt: String?

    enum CodingKeys: String, CodingKey {
        case itemType = "item_type"
        case itemId = "item_id"
        case mediaId = "media_id"
        case title
        case seriesTitle = "series_title"
        case seasonId = "season_id"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case posterURL = "poster_url"
        case fanartURL = "fanart_url"
        case thumbURL = "thumb_url"
        case duration
        case positionMs = "position_ms"
        case progressPct = "progress_pct"
        case lastPlayedAt = "last_played_at"
    }
}

private struct UHDPlaybackStatesDTO: Decodable {
    let resume: [UHDPlaybackItemDTO]
    let nextUp: [UHDPlaybackItemDTO]

    enum CodingKeys: String, CodingKey {
        case resume
        case nextUp = "next_up"
    }
}

private struct UHDSubscriptionPlanDTO: Decodable {
    let id: String
    let name: String
    let description: String?
    let planType: String?
    let trafficLimit: Int64?
    let activeVideoDeliveryLimit: Int?
    let loginDeviceLimit: Int?
    let monthlyPrice: Double?
    let yearlyPrice: Double?
    let teamTrafficLimit: Int64?
    let memberQuota: Int?
    let allowDownload: Bool?
    let displayUnlimitedTraffic: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case planType = "plan_type"
        case trafficLimit = "traffic_limit"
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case loginDeviceLimit = "login_device_limit"
        case monthlyPrice = "monthly_price"
        case yearlyPrice = "yearly_price"
        case teamTrafficLimit = "team_traffic_limit"
        case memberQuota = "member_quota"
        case allowDownload = "allow_download"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
    }
}

private struct UHDSubscriptionDTO: Decodable {
    let isTrial: Bool?
    let allowDownload: Bool
    let displayUnlimitedTraffic: Bool
    let userId: String?
    let planId: String?
    let plan: UHDSubscriptionPlanDTO?
    let ownerId: String?
    let memberUsage: Int?
    let subscribedAt: String?
    let expiresAt: String?
    let cancelledAt: String?
    let trafficLimitBytes: Int64?
    let trafficLimitLegacy: Int64?
    let activeVideoDeliveryLimit: Int
    let renewDay: Int?
    let autoRenew: Bool?

    enum CodingKeys: String, CodingKey {
        case isTrial = "is_trial"
        case allowDownload = "allow_download"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
        case userId = "user_id"
        case planId = "plan_id"
        case plan
        case ownerId = "owner_id"
        case memberUsage = "member_usage"
        case subscribedAt = "subscribed_at"
        case expiresAt = "expires_at"
        case cancelledAt = "cancelled_at"
        case trafficLimitBytes = "traffic_limit_bytes"
        case trafficLimitLegacy = "traffic_limit"
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case renewDay = "renew_day"
        case autoRenew = "auto_renew"
    }
}

private struct UHDTrafficDTO: Decodable {
    let userId: String?
    let displayUnlimitedTraffic: Bool
    let usedBytes: Int64
    let limitBytes: Int64
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
        case usedBytes = "used_bytes"
        case limitBytes = "limit_bytes"
        case updatedAt = "updated_at"
    }
}

private struct UHDSpeedTestNetworkInfoDTO: Decodable {
    let ip: String?
    let country: String?
    let countryName: String?
    let region: String?
    let regionName: String?
    let province: String?
    let provinceName: String?
    let isp: String?
    let displayLocation: String?

    enum CodingKeys: String, CodingKey {
        case ip, country, region, province, isp
        case countryName = "country_name"
        case regionName = "region_name"
        case provinceName = "province_name"
        case displayLocation = "display_location"
    }
}

private struct UHDSpeedTestSessionDTO: Decodable {
    let sessionId: String
    let reportToken: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case reportToken = "report_token"
    }
}

private struct UHDTeamSettingsDTO: Decodable {
    let activeVideoDeliveryLimit: Int
    let allowDownload: Bool

    enum CodingKeys: String, CodingKey {
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case allowDownload = "allow_download"
    }
}

private struct UHDTeamOverviewDTO: Decodable {
    let expiresAt: String
    let memberCount: Int
    let memberLimit: Int
    let trafficLimitBytes: Int64
    let trafficUsedBytes: Int64
    let renewDay: Int
    let settings: UHDTeamSettingsDTO

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
        case memberCount = "member_count"
        case memberLimit = "member_limit"
        case trafficLimitBytes = "traffic_limit_bytes"
        case trafficUsedBytes = "traffic_used_bytes"
        case renewDay = "renew_day"
        case settings
    }
}

private struct UHDTeamMemberDTO: Decodable {
    let id: String
    let username: String
    let expiresAt: String
    let trafficLimitBytes: Int64
    let trafficUsedBytes: Int64
    let renewDay: Int
    let activeVideoDeliveryLimit: Int
    let allowDownload: Bool
    let sessionCount: Int

    enum CodingKeys: String, CodingKey {
        case id, username
        case expiresAt = "expires_at"
        case trafficLimitBytes = "traffic_limit_bytes"
        case trafficUsedBytes = "traffic_used_bytes"
        case renewDay = "renew_day"
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case allowDownload = "allow_download"
        case sessionCount = "session_count"
    }
}

private struct UHDTeamMemberPageDTO: Decodable {
    let items: [UHDTeamMemberDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private actor UHDResolvedDomainCache {
    static let shared = UHDResolvedDomainCache()
    private var entries: [String: (url: URL, expiresAt: Date)] = [:]

    func get(serverId: UUID, domainId: String) -> URL? {
        let key = "\(serverId.uuidString)|\(domainId)"
        if let hit = entries[key], hit.expiresAt > Date() {
            return hit.url
        }
        entries.removeValue(forKey: key)
        return nil
    }

    func set(_ url: URL, serverId: UUID, domainId: String, ttlSeconds: TimeInterval = 300) {
        let key = "\(serverId.uuidString)|\(domainId)"
        entries[key] = (url: url, expiresAt: Date().addingTimeInterval(ttlSeconds))
    }

    func invalidate(serverId: UUID) {
        let prefix = "\(serverId.uuidString)|"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }
}

private actor UHDAssetResponseCache {
    static let shared = UHDAssetResponseCache()
    private var entries: [String: (dto: UHDAssetResponseDTO, expiresAt: Date)] = [:]

    func get(serverId: UUID, itemType: String, itemId: String) -> UHDAssetResponseDTO? {
        let key = "\(serverId.uuidString)|\(itemType)|\(itemId)"
        if let hit = entries[key], hit.expiresAt > Date() {
            return hit.dto
        }
        entries.removeValue(forKey: key)
        return nil
    }

    func set(_ dto: UHDAssetResponseDTO, serverId: UUID, itemType: String, itemId: String, ttlSeconds: TimeInterval = 300) {
        if entries.count > 128 {
            let now = Date()
            entries = entries.filter { $0.value.expiresAt > now }
        }
        let key = "\(serverId.uuidString)|\(itemType)|\(itemId)"
        entries[key] = (dto: dto, expiresAt: Date().addingTimeInterval(ttlSeconds))
    }

    func invalidate(serverId: UUID) {
        let prefix = "\(serverId.uuidString)|"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }
}

private actor UHDHostWarmCache {
    static let shared = UHDHostWarmCache()
    private var lastWarmedAt: [String: Date] = [:]

    func shouldWarm(hostKey: String) -> Bool {
        let now = Date()
        if let prev = lastWarmedAt[hostKey], now.timeIntervalSince(prev) < 120 {
            return false
        }
        lastWarmedAt[hostKey] = now
        return true
    }
}

// MARK: - High-Throughput Chunk-Level Speed Test Receiver (Zero Byte-by-Byte Bottleneck)

private final class UHDSpeedTestStreamRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onProgress: @Sendable (UHDSpeedTestProgress) -> Void
    private let lock = NSLock()
    private var engine: UHDSpeedTestMetricsEngine?
    private var contentLength: Int64
    private var continuation: CheckedContinuation<UHDSpeedTestMetricsEngine.Snapshot, Error>?
    private var finished = false
    private var lastProgressEmitTime: Double = 0
    private weak var activeTask: URLSessionDataTask?
    private var ownSession: URLSession?

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (UHDSpeedTestProgress) -> Void) {
        self.expectedBytes = expectedBytes
        self.contentLength = expectedBytes
        self.onProgress = onProgress
        super.init()
    }

    func run(request: URLRequest) async throws -> UHDSpeedTestMetricsEngine.Snapshot {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        let queue = OperationQueue()
        queue.name = "com.donby.uhd.speedtest"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        self.ownSession = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if finished {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                let task = session.dataTask(with: request)
                self.activeTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        let cont = continuation
        let wasFinished = finished
        finished = true
        continuation = nil
        lock.unlock()
        task?.cancel()
        ownSession?.invalidateAndCancel()
        ownSession = nil
        if !wasFinished {
            cont?.resume(throwing: CancellationError())
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let err: Error = (http.statusCode == 401)
                ? EmbyClientError.unauthorized
                : EmbyClientError.httpStatus(http.statusCode, "测速下载被拒绝 (HTTP \(http.statusCode))")
            complete(with: .failure(err))
            completionHandler(.cancel)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if response.expectedContentLength > 0 {
            contentLength = response.expectedContentLength
        }
        engine = UHDSpeedTestMetricsEngine(startTimeSec: now)
        lastProgressEmitTime = now
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        var emitPayload: UHDSpeedTestProgress?

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if engine == nil {
            engine = UHDSpeedTestMetricsEngine(startTimeSec: now)
        }
        let sampled = engine!.ingest(chunkBytes: Int64(data.count), at: now)
        if sampled || (now - lastProgressEmitTime) >= 0.12 {
            lastProgressEmitTime = now
            let snap = engine!.currentSnapshot(at: now)
            let denom = Double(max(1, contentLength))
            emitPayload = UHDSpeedTestProgress(
                fraction: min(1.0, Double(snap.totalBytes) / denom),
                currentMbps: snap.currentMbps,
                averageMbps: snap.averageMbps,
                peakMbps: snap.peakMbps,
                downloadedBytes: snap.totalBytes,
                totalBytes: contentLength,
                recentSamplesMbps: Array(snap.samplesMbps.suffix(48))
            )
        }
        lock.unlock()

        if let emitPayload {
            onProgress(emitPayload)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                complete(with: .failure(CancellationError()))
            } else {
                complete(with: .failure(error))
            }
            return
        }

        lock.lock()
        var eng = engine ?? UHDSpeedTestMetricsEngine(startTimeSec: now)
        let finalSnap = eng.finalize(at: now)
        let total = max(contentLength, finalSnap.totalBytes)
        lock.unlock()

        onProgress(UHDSpeedTestProgress(
            fraction: 1.0,
            currentMbps: finalSnap.currentMbps,
            averageMbps: finalSnap.averageMbps,
            peakMbps: finalSnap.peakMbps,
            downloadedBytes: finalSnap.totalBytes,
            totalBytes: total,
            recentSamplesMbps: Array(finalSnap.samplesMbps.suffix(48))
        ))
        complete(with: .success(finalSnap))
    }

    private func complete(with result: Result<UHDSpeedTestMetricsEngine.Snapshot, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let sessionToClose = ownSession
        ownSession = nil
        lock.unlock()

        sessionToClose?.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }
}

// MARK: - UHDStreamClient

public final class UHDStreamClient: Sendable {
    public static let shared = UHDStreamClient()

    private let apiSession: URLSession

    private init() {
        self.apiSession = DonbyNetworkSession.sharedURLSession
    }

    public var appVersion: String {
        DonbyAppInfo.version
    }

    private func normalizedAPIBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    public func resolveAbsoluteImageURL(apiBase: String, relativeOrAbsolute: String?) -> String? {
        guard let raw = relativeOrAbsolute?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        let base = normalizedAPIBase(apiBase)
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return base + path
    }

    private func resolveAbsoluteMediaURL(resolvedBase: String, path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let cleanBase = normalizedAPIBase(resolvedBase)
        let cleanPath = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return URL(string: cleanBase + cleanPath)
    }

    private func makeRequest(
        baseURL: String,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        token: String = "",
        bodyData: Data? = nil,
        timeout: TimeInterval = 15,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        let cleanBase = normalizedAPIBase(baseURL)
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: cleanBase + cleanPath) else {
            throw EmbyClientError.invalidServerURL(cleanBase + cleanPath)
        }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else {
            throw EmbyClientError.invalidServerURL(cleanBase + cleanPath)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Donby/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty {
            // UHD Native streaming API requires raw token without Bearer prefix
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            req.httpBody = bodyData
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    private func friendlyHTTPError(statusCode: Int, serverMsg: String, context: String? = nil) -> EmbyClientError {
        let cleanMsg = serverMsg.trimmingCharacters(in: .whitespacesAndNewlines)
        if statusCode == 401 {
            if !cleanMsg.isEmpty {
                return .httpStatus(401, cleanMsg)
            }
            return .unauthorized
        }
        if !cleanMsg.isEmpty {
            return .httpStatus(statusCode, cleanMsg)
        }
        switch statusCode {
        case 400: return .httpStatus(400, context ?? "请求参数无效")
        case 403: return .httpStatus(403, context ?? "订阅无效或权限不足")
        case 404: return .httpStatus(404, context ?? "资源不存在或线路已失效")
        case 409: return .httpStatus(409, context ?? "设备会话已达上限或状态冲突")
        case 429: return .httpStatus(429, "请求过于频繁，请稍后重试")
        case 503: return .httpStatus(503, "服务暂不可用，请稍后重试")
        default: return .httpStatus(statusCode, context ?? "服务端异常")
        }
    }

    private func performRequest<T: Decodable>(
        _ type: T.Type,
        request: URLRequest,
        priority: APIRequestGate.Priority = .normal,
        errorContext: String? = nil
    ) async throws -> T {
        try await APIRequestGate.shared.withPermit(priority: priority) {
            let (data, response) = try await self.apiSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let errMsg = (try? JSONDecoder().decode(UHDOkOnly.self, from: data))?.msg ?? ""
                throw self.friendlyHTTPError(statusCode: http.statusCode, serverMsg: errMsg, context: errorContext)
            }
            let envelope = try JSONDecoder().decode(UHDEnvelope<T>.self, from: data)
            guard envelope.ok, let payload = envelope.data else {
                throw EmbyClientError.httpStatus(500, envelope.msg ?? "UHD 接口返回异常")
            }
            return payload
        }
    }

    private func performAction(
        request: URLRequest,
        priority: APIRequestGate.Priority = .normal,
        errorContext: String? = nil
    ) async throws {
        try await APIRequestGate.shared.withPermit(priority: priority) {
            let (data, response) = try await self.apiSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let errMsg = (try? JSONDecoder().decode(UHDOkOnly.self, from: data))?.msg ?? ""
                throw self.friendlyHTTPError(statusCode: http.statusCode, serverMsg: errMsg, context: errorContext)
            }
        }
    }

    // MARK: - Auth & Connectivity

    public func login(baseURL: String, username: String, password: String) async throws -> UHDLoginResult {
        let payload = ["username": username, "password": password]
        let body = try JSONEncoder().encode(payload)
        let req = try makeRequest(
            baseURL: baseURL,
            path: "/api/v1/stream/login",
            method: "POST",
            bodyData: body,
            timeout: 12
        )
        let res = try await performRequest(
            UHDLoginDataDTO.self,
            request: req,
            priority: .playback,
            errorContext: "登录失败，请核对用户名、媒体客户端密码或订阅状态"
        )
        guard !res.token.isEmpty else { throw EmbyClientError.emptyToken }
        return UHDLoginResult(token: res.token, expiresAt: res.expiresAt)
    }

    /// Zero-URL UHD password login: tries `https://smart.uhdnow.com` first, and automatically falls back
    /// to `https://v1.uhdnow.com` if the account lacks a China-optimized plan or the smart endpoint rejects/fails.
    public func loginWithAutoFallback(
        customBaseURL: String? = nil,
        username: String,
        password: String
    ) async throws -> UHDResolvedLoginOutcome {
        let candidates = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: customBaseURL)
        var lastError: Error?
        for (idx, base) in candidates.enumerated() {
            do {
                let auth = try await login(baseURL: base, username: username, password: password)
                let parsed = UHDModuleEndpoints.parseEndpointComponents(from: base)
                return UHDResolvedLoginOutcome(
                    auth: auth,
                    baseURL: base,
                    host: parsed.host,
                    isHttps: parsed.isHttps,
                    port: parsed.port,
                    usedChinaOptimizedEndpoint: UHDModuleEndpoints.isChinaOptimizedHost(base)
                )
            } catch {
                lastError = error
                let hasNext = idx + 1 < candidates.count
                if hasNext && UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: error, authKind: .password) {
                    DonbyLogger.shared.log(
                        "UHD 优先节点 \(base) 登录回退至标准节点: \(error.localizedDescription)",
                        level: .info,
                        subsystem: "UHD"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? EmbyClientError.unauthorized
    }

    /// Exchanges an 8-digit code generated in the UHD Web Portal (`概览 -> 设备 -> 登录码`) for a Stream session token.
    public func loginWithCode(baseURL: String, rawCode: String) async throws -> UHDLoginResult {
        guard let normalized = UHDLoginCodeNormalizer.normalize(rawCode) else {
            throw EmbyClientError.httpStatus(400, "请输入完整的 8 位数字登录码（保留前导 0）")
        }
        let body = try JSONEncoder().encode(["code": normalized])
        let req = try makeRequest(
            baseURL: baseURL,
            path: "/api/v1/stream/login/code",
            method: "POST",
            bodyData: body,
            timeout: 12
        )
        let res = try await performRequest(
            UHDLoginDataDTO.self,
            request: req,
            priority: .playback,
            errorContext: "登录码无效、已过期（3 分钟有效）或已被使用，请重新生成"
        )
        guard !res.token.isEmpty else { throw EmbyClientError.emptyToken }
        return UHDLoginResult(token: res.token, expiresAt: res.expiresAt)
    }

    /// Zero-URL UHD 8-digit code login with `smart.uhdnow.com` -> `v1.uhdnow.com` fallback.
    public func loginWithCodeAutoFallback(
        customBaseURL: String? = nil,
        rawCode: String
    ) async throws -> UHDResolvedLoginOutcome {
        let candidates = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: customBaseURL)
        var lastError: Error?
        for (idx, base) in candidates.enumerated() {
            do {
                let auth = try await loginWithCode(baseURL: base, rawCode: rawCode)
                let parsed = UHDModuleEndpoints.parseEndpointComponents(from: base)
                return UHDResolvedLoginOutcome(
                    auth: auth,
                    baseURL: base,
                    host: parsed.host,
                    isHttps: parsed.isHttps,
                    port: parsed.port,
                    usedChinaOptimizedEndpoint: UHDModuleEndpoints.isChinaOptimizedHost(base)
                )
            } catch {
                lastError = error
                let hasNext = idx + 1 < candidates.count
                if hasNext && UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: error, authKind: .loginCode) {
                    DonbyLogger.shared.log(
                        "UHD 登录码优先节点 \(base) 回退至标准节点: \(error.localizedDescription)",
                        level: .info,
                        subsystem: "UHD"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? EmbyClientError.unauthorized
    }

    /// Zero-URL UHD token / API key validation with `smart.uhdnow.com` -> `v1.uhdnow.com` fallback.
    public func validateTokenAutoFallback(
        customBaseURL: String? = nil,
        token: String
    ) async throws -> UHDResolvedTokenOutcome {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw EmbyClientError.emptyToken }
        let candidates = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: customBaseURL)
        var lastError: Error?
        for (idx, base) in candidates.enumerated() {
            let parsed = UHDModuleEndpoints.parseEndpointComponents(from: base)
            let probeServer = EmbyServerConfig(
                name: "UHDNow",
                type: .uhdNative,
                host: parsed.host,
                port: parsed.port,
                isHttps: parsed.isHttps,
                username: "",
                accessToken: trimmedToken
            )
            do {
                let sub = try await fetchSubscriptionDetail(server: probeServer)
                return UHDResolvedTokenOutcome(
                    subscription: sub,
                    baseURL: base,
                    host: parsed.host,
                    isHttps: parsed.isHttps,
                    port: parsed.port,
                    usedChinaOptimizedEndpoint: UHDModuleEndpoints.isChinaOptimizedHost(base)
                )
            } catch {
                lastError = error
                let hasNext = idx + 1 < candidates.count
                if hasNext && UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: error, authKind: .token) {
                    DonbyLogger.shared.log(
                        "UHD 令牌校验优先节点 \(base) 回退至标准节点: \(error.localizedDescription)",
                        level: .info,
                        subsystem: "UHD"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? EmbyClientError.unauthorized
    }

    @discardableResult
    public func logout(server: EmbyServerConfig) async -> Bool {
        guard !server.accessToken.isEmpty,
              let req = try? makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/logout",
                method: "POST",
                token: server.accessToken,
                timeout: 8
              ) else { return true }
        do {
            try await performAction(request: req, priority: .normal)
            return true
        } catch let err as EmbyClientError {
            // Spec: 401 means token already revoked -> safe to clear local credentials
            if case .unauthorized = err { return true }
            if case .httpStatus(401, _) = err { return true }
            return false
        } catch {
            return false
        }
    }

    public func testConnection(baseURL: String, token: String = "") async throws -> UHDConnectionTestResult {
        let start = CFAbsoluteTimeGetCurrent()
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let req = try makeRequest(
                baseURL: baseURL,
                path: "/api/v1/stream/subscriptions/me",
                token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                timeout: 8
            )
            let dto = try await performRequest(UHDSubscriptionDTO.self, request: req, priority: .playback)
            let ms = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            let plan = dto.plan?.name
            return UHDConnectionTestResult(
                latencyMs: ms,
                authenticated: true,
                planName: plan,
                message: plan != nil ? "连接成功 · \(plan!) (\(ms) ms)" : "凭证有效 (\(ms) ms)"
            )
        } else {
            let req = try makeRequest(
                baseURL: baseURL,
                path: "/api/v1/stream/playback/domains",
                timeout: 8
            )
            let (_, response) = try await apiSession.data(for: req)
            let ms = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            guard let http = response as? HTTPURLResponse else {
                throw EmbyClientError.httpStatus(500, "未收到有效 HTTP 响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 || (200...299).contains(http.statusCode) {
                return UHDConnectionTestResult(
                    latencyMs: ms,
                    authenticated: (200...299).contains(http.statusCode),
                    planName: nil,
                    message: "服务器可达 · UHD API 正常 (\(ms) ms)"
                )
            }
            throw EmbyClientError.httpStatus(http.statusCode, "服务器返回 HTTP \(http.statusCode)")
        }
    }

    // MARK: - Subscription, Traffic & Account Snapshot

    public func fetchSubscriptionDetail(server: EmbyServerConfig) async throws -> UHDSubscriptionInfo {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/subscriptions/me",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDSubscriptionDTO.self, request: req, priority: .normal)
        let planInfo = dto.plan.map { p in
            UHDSubscriptionPlanInfo(
                id: p.id,
                name: p.name,
                description: p.description,
                planType: p.planType,
                trafficLimitGB: p.trafficLimit,
                activeVideoDeliveryLimit: p.activeVideoDeliveryLimit,
                loginDeviceLimit: p.loginDeviceLimit,
                monthlyPriceUSD: p.monthlyPrice,
                yearlyPriceUSD: p.yearlyPrice,
                teamTrafficLimitGB: p.teamTrafficLimit,
                memberQuota: p.memberQuota,
                allowDownload: p.allowDownload,
                displayUnlimitedTraffic: p.displayUnlimitedTraffic
            )
        }
        return UHDSubscriptionInfo(
            isTrial: dto.isTrial ?? false,
            allowDownload: dto.allowDownload,
            displayUnlimitedTraffic: dto.displayUnlimitedTraffic,
            userId: dto.userId ?? "",
            planId: dto.planId ?? "",
            plan: planInfo,
            ownerId: dto.ownerId,
            memberUsage: dto.memberUsage,
            subscribedAt: dto.subscribedAt,
            expiresAt: dto.expiresAt,
            cancelledAt: dto.cancelledAt,
            trafficLimitBytes: dto.trafficLimitBytes ?? dto.trafficLimitLegacy ?? 0,
            activeVideoDeliveryLimit: max(1, dto.activeVideoDeliveryLimit),
            renewDay: dto.renewDay,
            autoRenew: dto.autoRenew ?? false
        )
    }

    public func fetchSubscription(server: EmbyServerConfig) async throws -> ServerDeliveryCapabilities {
        let info = try await fetchSubscriptionDetail(server: server)
        return ServerDeliveryCapabilities(
            allowDownload: info.allowDownload,
            activeVideoDeliveryLimit: max(1, info.activeVideoDeliveryLimit),
            planName: info.plan?.name,
            displayUnlimitedTraffic: info.displayUnlimitedTraffic,
            trafficLimitBytes: info.trafficLimitBytes
        )
    }

    public func fetchTraffic(server: EmbyServerConfig) async throws -> UHDTrafficSummary {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/traffic/me",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDTrafficDTO.self, request: req, priority: .normal)
        return UHDTrafficSummary(
            userId: dto.userId,
            displayUnlimitedTraffic: dto.displayUnlimitedTraffic,
            usedBytes: dto.usedBytes,
            limitBytes: dto.limitBytes,
            updatedAt: dto.updatedAt
        )
    }

    public func fetchAccountSnapshot(server: EmbyServerConfig) async -> UHDAccountSnapshot {
        async let subTask = try? fetchSubscriptionDetail(server: server)
        async let trafficTask = try? fetchTraffic(server: server)
        let (sub, traffic) = await (subTask, trafficTask)
        return UHDAccountSnapshot(subscription: sub, traffic: traffic, fetchedAt: Date())
    }

    // MARK: - Playback Domains & Speed Test (Official Spec Compliant)

    public func fetchPlaybackDomains(server: EmbyServerConfig) async throws -> [ServerLineInfo] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/playback/domains",
            token: server.accessToken
        )
        let domains = try await performRequest([UHDPlaybackDomainDTO].self, request: req, priority: .normal)
        let sorted = domains.sorted { $0.sortOrder < $1.sortOrder }
        let existingByDomainId = Dictionary(
            server.backupLines.compactMap { line -> (String, ServerLineInfo)? in
                guard let did = line.domainId, !did.isEmpty else { return nil }
                return (did, line)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return sorted.map { dom in
            let prev = existingByDomainId[dom.id]
            let displayName = (dom.description?.isEmpty == false) ? "\(dom.name) · \(dom.description!)" : dom.name
            let baseURL = (dom.domain?.isEmpty == false) ? dom.domain! : (prev?.url ?? server.mainLineURL)
            return ServerLineInfo(
                id: prev?.id ?? UUID(),
                name: displayName,
                url: baseURL,
                domainId: dom.id,
                isAutoSynced: true,
                latencyMs: prev?.latencyMs,
                lastCheckedAt: prev?.lastCheckedAt,
                lastSpeedMbps: prev?.lastSpeedMbps,
                lastPeakMbps: prev?.lastPeakMbps,
                lastExitLocation: prev?.lastExitLocation,
                lastExitISP: prev?.lastExitISP
            )
        }
    }

    public func resolvePlaybackDomain(server: EmbyServerConfig, domainId: String, cacheTTL: TimeInterval = 300) async throws -> URL {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/playback/domains/\(domainId)/resolve",
            token: server.accessToken,
            timeout: 10
        )
        let dto = try await performRequest(UHDResolveDomainDTO.self, request: req, priority: .playback)
        let clean = ServerLineInfo.normalizeBaseURL(dto.domain)
        guard let url = URL(string: clean) else {
            throw EmbyClientError.invalidServerURL(dto.domain)
        }
        if cacheTTL > 0 {
            await UHDResolvedDomainCache.shared.set(url, serverId: server.id, domainId: domainId, ttlSeconds: cacheTTL)
        }
        return url
    }

    public func resolveActivePlaybackOrigin(server: EmbyServerConfig, forceFresh: Bool = false) async throws -> URL {
        let domainId: String? = {
            if let selectedId = server.selectedLineId,
               let line = server.backupLines.first(where: { $0.id == selectedId }),
               let id = line.domainId, !id.isEmpty {
                return id
            }
            return server.backupLines.first(where: { $0.domainId?.isEmpty == false })?.domainId
        }()
        if let domainId {
            if !forceFresh, let cached = await UHDResolvedDomainCache.shared.get(serverId: server.id, domainId: domainId) {
                return cached
            }
            return try await resolvePlaybackDomain(server: server, domainId: domainId)
        }
        let fetched = try await fetchPlaybackDomains(server: server)
        guard let firstId = fetched.first?.domainId, !firstId.isEmpty else {
            guard let fallback = URL(string: server.mainLineURL) else {
                throw EmbyClientError.invalidServerURL(server.mainLineURL)
            }
            return fallback
        }
        return try await resolvePlaybackDomain(server: server, domainId: firstId)
    }

    public func invalidateResolvedDomainCache(serverId: UUID) async {
        await UHDResolvedDomainCache.shared.invalidate(serverId: serverId)
        await UHDAssetResponseCache.shared.invalidate(serverId: serverId)
    }

    public func prewarmPlaybackDomain(server: EmbyServerConfig) async {
        guard server.type == .uhdNative, !server.mainLineURL.isEmpty, !server.accessToken.isEmpty else { return }
        if let resolvedURL = try? await resolveActivePlaybackOrigin(server: server, forceFresh: false),
           let host = resolvedURL.host,
           await UHDHostWarmCache.shared.shouldWarm(hostKey: host) {
            var headReq = URLRequest(url: resolvedURL, timeoutInterval: 3.0)
            headReq.httpMethod = "HEAD"
            headReq.cachePolicy = .reloadIgnoringLocalCacheData
            headReq.setValue("Donby/\(appVersion) (macOS; UHDNow Client)", forHTTPHeaderField: "User-Agent")
            _ = try? await apiSession.data(for: headReq)
        }
    }

    public func pingLine(server: EmbyServerConfig, line: ServerLineInfo?) async -> Int? {
        let domainId = line?.domainId ?? server.backupLines.first?.domainId
        let start = CFAbsoluteTimeGetCurrent()
        do {
            if let domainId, !domainId.isEmpty {
                let resolved = try await resolvePlaybackDomain(server: server, domainId: domainId)
                let probeStart = CFAbsoluteTimeGetCurrent()
                let netReq = try makeRequest(
                    baseURL: resolved.absoluteString,
                    path: "/api/v1/stream/speed-test/network-info",
                    token: server.accessToken,
                    timeout: 6
                )
                let (_, resp) = try await apiSession.data(for: netReq)
                if let http = resp as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                    return max(1, Int((CFAbsoluteTimeGetCurrent() - probeStart) * 1000))
                }
                return max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            } else {
                let req = try makeRequest(
                    baseURL: server.mainLineURL,
                    path: "/api/v1/stream/playback/domains",
                    token: server.accessToken,
                    timeout: 6
                )
                _ = try await apiSession.data(for: req)
                return max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            }
        } catch {
            return nil
        }
    }

    /// Resolves a fresh `TEST_BASE` for `domainId` and probes `TEST_BASE/api/v1/stream/speed-test/network-info`
    /// without consuming download traffic quota. Useful for verifying DIRECT vs PROXY exit routing.
    public func probeLineExitNetworkInfo(
        server: EmbyServerConfig,
        domainId: String
    ) async throws -> (resolvedBase: URL, networkInfo: UHDSpeedTestNetworkInfo, latencyMs: Int) {
        let resolvedBase = try await resolvePlaybackDomain(server: server, domainId: domainId, cacheTTL: 0)
        let probeStart = CFAbsoluteTimeGetCurrent()
        let netReq = try makeRequest(
            baseURL: resolvedBase.absoluteString,
            path: "/api/v1/stream/speed-test/network-info",
            token: server.accessToken,
            timeout: 10
        )
        let dto = try await performRequest(UHDSpeedTestNetworkInfoDTO.self, request: netReq, priority: .normal)
        let ms = max(1, Int((CFAbsoluteTimeGetCurrent() - probeStart) * 1000))
        let info = UHDSpeedTestNetworkInfo(
            ip: dto.ip ?? "",
            country: dto.country ?? "",
            countryName: dto.countryName ?? "",
            region: dto.region ?? "",
            regionName: dto.regionName ?? "",
            province: dto.province ?? "",
            provinceName: dto.provinceName ?? "",
            isp: dto.isp ?? "",
            displayLocation: dto.displayLocation ?? "未知"
        )
        return (resolvedBase, info, ms)
    }

    /// Spec-compliant UHD Speed Test:
    /// 1. Resolve fresh `TEST_BASE` via `API_BASE/api/v1/stream/playback/domains/{domain_id}/resolve`.
    /// 2. `GET TEST_BASE/api/v1/stream/speed-test/network-info`
    /// 3. `POST TEST_BASE/api/v1/stream/speed-test/session`
    /// 4. `GET TEST_BASE/api/v1/stream/speed-test/download?session_id=...&size_mb=...` (chunk-level delegate stream, warmup exclusion, 300ms rolling peak)
    /// 5. `POST API_BASE/api/v1/stream/speed-test/report` (submitted ONCE only on clean completion, never retried, never sent on cancel/error).
    public func runSpeedTest(
        server: EmbyServerConfig,
        domainId: String,
        sizeMiB: Int = 32,
        onNetworkInfo: (@Sendable (URL, UHDSpeedTestNetworkInfo) -> Void)? = nil,
        onProgress: @escaping @Sendable (UHDSpeedTestProgress) -> Void
    ) async throws -> UHDSpeedTestResult {
        let clampedMiB = [32, 64, 100].contains(sizeMiB) ? sizeMiB : 32
        let apiBase = server.mainLineURL

        // Step 1: Freshly resolve TEST_BASE for this round
        let testBaseURL = try await resolvePlaybackDomain(server: server, domainId: domainId, cacheTTL: 0)
        let testBase = testBaseURL.absoluteString
        try Task.checkCancellation()

        // Step 2: Query exit network info on TEST_BASE
        let netInfoReq = try makeRequest(
            baseURL: testBase,
            path: "/api/v1/stream/speed-test/network-info",
            token: server.accessToken,
            timeout: 12
        )
        let netInfoDTO = try await performRequest(UHDSpeedTestNetworkInfoDTO.self, request: netInfoReq, priority: .normal)
        let netInfo = UHDSpeedTestNetworkInfo(
            ip: netInfoDTO.ip ?? "",
            country: netInfoDTO.country ?? "",
            countryName: netInfoDTO.countryName ?? "",
            region: netInfoDTO.region ?? "",
            regionName: netInfoDTO.regionName ?? "",
            province: netInfoDTO.province ?? "",
            provinceName: netInfoDTO.provinceName ?? "",
            isp: netInfoDTO.isp ?? "",
            displayLocation: netInfoDTO.displayLocation ?? "未知"
        )
        onNetworkInfo?(testBaseURL, netInfo)
        try Task.checkCancellation()

        // Step 3: Create speed-test session on TEST_BASE
        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "parent_domain_id": domainId,
            "size_mib": clampedMiB
        ])
        let sessionReq = try makeRequest(
            baseURL: testBase,
            path: "/api/v1/stream/speed-test/session",
            method: "POST",
            token: server.accessToken,
            bodyData: sessionBody,
            timeout: 15
        )
        let session = try await performRequest(UHDSpeedTestSessionDTO.self, request: sessionReq, priority: .normal)
        try Task.checkCancellation()

        // Step 4: Stream binary payload from TEST_BASE with chunk-level delegate (no compression, no cache)
        var dlReq = try makeRequest(
            baseURL: testBase,
            path: "/api/v1/stream/speed-test/download",
            queryItems: [
                URLQueryItem(name: "session_id", value: session.sessionId),
                URLQueryItem(name: "size_mb", value: "\(clampedMiB)")
            ],
            token: server.accessToken,
            timeout: 180,
            extraHeaders: [
                "Accept": "application/octet-stream",
                "Accept-Encoding": "identity",
                "Cache-Control": "no-cache"
            ]
        )
        dlReq.cachePolicy = .reloadIgnoringLocalCacheData

        let expectedBytes = Int64(clampedMiB) * 1_048_576
        let runner = UHDSpeedTestStreamRunner(expectedBytes: expectedBytes, onProgress: onProgress)
        let snapshot = try await runner.run(request: dlReq)

        // Step 5: Submit single report to API_BASE (never retry; keep local metrics if report fails)
        var reportSubmitted = false
        let reportPayload: [String: Any] = [
            "session_id": session.sessionId,
            "report_token": session.reportToken,
            "average_mbps": snapshot.averageMbps,
            "peak_mbps": snapshot.peakMbps,
            "elapsed_ms": snapshot.elapsedMs,
            "sample_count": snapshot.sampleCount,
            "server_downloaded_bytes": snapshot.totalBytes
        ]
        if let reportData = try? JSONSerialization.data(withJSONObject: reportPayload),
           let reportReq = try? makeRequest(
                baseURL: apiBase,
                path: "/api/v1/stream/speed-test/report",
                method: "POST",
                token: server.accessToken,
                bodyData: reportData,
                timeout: 12
           ) {
            do {
                try await performAction(request: reportReq, priority: .normal)
                reportSubmitted = true
            } catch {
                reportSubmitted = false
            }
        }

        return UHDSpeedTestResult(
            domainId: domainId,
            resolvedHost: testBaseURL.host ?? testBase,
            networkInfo: netInfo,
            averageMbps: snapshot.averageMbps,
            peakMbps: snapshot.peakMbps,
            elapsedMs: snapshot.elapsedMs,
            sampleCount: snapshot.sampleCount,
            downloadedBytes: snapshot.totalBytes,
            sizeMiB: clampedMiB,
            samplesMbps: snapshot.samplesMbps,
            reportSubmitted: reportSubmitted,
            testedAt: Date()
        )
    }

    // MARK: - Catalog & Discovery

    public func fetchCollections(server: EmbyServerConfig) async throws -> [EmbyItem] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/collections",
            token: server.accessToken
        )
        let data = try await performRequest(UHDCollectionsDataDTO.self, request: req, priority: .normal)
        let apiBase = server.mainLineURL
        return data.items.map { col in
            let colType: String? = switch col.mediaType?.lowercased() {
            case "movie": "movies"
            case "tv": "tvshows"
            default: nil
            }
            return EmbyItem(
                id: col.id,
                name: col.name,
                serverId: server.serverId,
                type: "CollectionFolder",
                collectionType: colType,
                isFolder: true,
                childCount: col.itemCount,
                recursiveItemCount: col.itemCount,
                uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: col.posterURL)
            )
        }
    }

    public func fetchCollectionItems(
        server: EmbyServerConfig,
        collectionId: String,
        mediaType: String? = nil,
        sortBy: String = "release_date",
        sortOrder: String = "desc",
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> (items: [EmbyItem], nextCursor: String?) {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))"),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "sort_order", value: sortOrder)
        ]
        if let mediaType, !mediaType.isEmpty {
            query.append(URLQueryItem(name: "type", value: mediaType))
        }
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/collections/\(collectionId)/items",
            queryItems: query,
            token: server.accessToken
        )
        let data = try await performRequest(UHDMediaCursorDTO.self, request: req, priority: .normal)
        let items = data.items.map { mapSummary($0, server: server) }
        return (items, data.nextCursor)
    }

    public func fetchHot(server: EmbyServerConfig, mediaType: String? = nil, limit: Int = 24) async throws -> [EmbyItem] {
        var query = [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")]
        if let mediaType, !mediaType.isEmpty {
            query.append(URLQueryItem(name: "type", value: mediaType))
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/hot",
            queryItems: query,
            token: server.accessToken
        )
        let data = try await performRequest(UHDItemsOnlyDTO<UHDMediaSummaryDTO>.self, request: req, priority: .normal)
        return data.items.map { mapSummary($0, server: server) }
    }

    public func fetchAnimeHot(server: EmbyServerConfig, mediaType: String? = nil, limit: Int = 24) async throws -> [EmbyItem] {
        var query = [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")]
        if let mediaType, !mediaType.isEmpty {
            query.append(URLQueryItem(name: "type", value: mediaType))
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/anime/hot",
            queryItems: query,
            token: server.accessToken
        )
        let data = try await performRequest(UHDItemsOnlyDTO<UHDMediaSummaryDTO>.self, request: req, priority: .normal)
        return data.items.map { mapSummary($0, server: server) }
    }

    public func fetchAnimeCalendarDays(server: EmbyServerConfig) async throws -> [UHDAnimeCalendarDay] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/anime/calendar/days",
            token: server.accessToken
        )
        let data = try await performRequest([UHDAnimeCalendarDayDTO].self, request: req, priority: .normal)
        return data.sorted { $0.weekday < $1.weekday }.map { UHDAnimeCalendarDay(weekday: $0.weekday, total: $0.total) }
    }

    public func fetchAnimeCalendarItems(server: EmbyServerConfig, weekday: Int) async throws -> [UHDAnimeCalendarEntry] {
        let clampedDay = max(1, min(7, weekday))
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/anime/calendar/items",
            queryItems: [URLQueryItem(name: "weekday", value: "\(clampedDay)")],
            token: server.accessToken
        )
        let data = try await performRequest(UHDItemsOnlyDTO<UHDAnimeCalendarItemDTO>.self, request: req, priority: .normal)
        return data.items.map { entry in
            UHDAnimeCalendarEntry(
                item: mapSummary(entry.summary, server: server),
                schedule: UHDAnimeCalendarSchedule(airDate: entry.schedule.airDate, estimated: entry.schedule.estimated)
            )
        }
    }

    public func fetchGenres(server: EmbyServerConfig) async throws -> [UHDGenreInfo] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/genres",
            token: server.accessToken
        )
        let data = try await performRequest([UHDGenreDTO].self, request: req, priority: .normal)
        return data.map { UHDGenreInfo(id: $0.id, name: $0.name, slug: $0.slug ?? "") }
    }

    public func fetchPersonDetail(server: EmbyServerConfig, personId: String) async throws -> UHDPersonDetail {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/persons/\(personId)",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDPersonCardDTO.self, request: req, priority: .normal)
        return UHDPersonDetail(
            id: dto.id,
            name: dto.name,
            tmdbId: dto.tmdbId,
            imdbId: dto.imdbId,
            imageURL: resolveAbsoluteImageURL(apiBase: server.mainLineURL, relativeOrAbsolute: dto.imageURL),
            favorite: dto.favorite ?? false
        )
    }

    public func fetchPersonWorks(
        server: EmbyServerConfig,
        personId: String,
        mediaType: String? = nil,
        sortBy: String = "release_date",
        sortOrder: String = "desc",
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> (items: [EmbyItem], nextCursor: String?) {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))"),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "sort_order", value: sortOrder)
        ]
        if let mediaType, !mediaType.isEmpty {
            query.append(URLQueryItem(name: "type", value: mediaType))
        }
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/persons/\(personId)/works",
            queryItems: query,
            token: server.accessToken
        )
        let data = try await performRequest(UHDMediaCursorDTO.self, request: req, priority: .normal)
        return (data.items.map { mapSummary($0, server: server) }, data.nextCursor)
    }

    public func searchWithMeta(
        server: EmbyServerConfig,
        query: String,
        tmdbId: Int? = nil,
        mediaType: String? = nil,
        limit: Int = 60
    ) async throws -> (items: [EmbyItem], truncated: Bool) {
        var qItems: [URLQueryItem] = []
        let parsedTmdb = tmdbId.map { ($0, mediaType) } ?? UHDTmdbSearchQueryParser.parse(query)
        if let parsedTmdb {
            qItems.append(URLQueryItem(name: "tmdb_id", value: "\(parsedTmdb.0)"))
            if let t = parsedTmdb.1 ?? mediaType, !t.isEmpty {
                qItems.append(URLQueryItem(name: "type", value: t))
            }
        } else {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ([], false) }
            qItems.append(URLQueryItem(name: "q", value: trimmed))
            qItems.append(URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))"))
            if let mediaType, !mediaType.isEmpty {
                qItems.append(URLQueryItem(name: "type", value: mediaType))
            }
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/search",
            queryItems: qItems,
            token: server.accessToken
        )
        let data = try await performRequest(UHDSearchDataDTO.self, request: req, priority: .normal)
        return (data.items.map { mapSummary($0, server: server) }, data.truncated ?? false)
    }

    public func search(server: EmbyServerConfig, query: String, limit: Int = 50) async throws -> [EmbyItem] {
        try await searchWithMeta(server: server, query: query, limit: limit).items
    }

    public func fetchPlaybackStates(server: EmbyServerConfig, limit: Int = 20) async throws -> (resume: [EmbyItem], nextUp: [EmbyItem]) {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/me/playback-states",
            queryItems: [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")],
            token: server.accessToken
        )
        let data = try await performRequest(UHDPlaybackStatesDTO.self, request: req, priority: .normal)
        let resumeItems = data.resume.map { mapPlaybackItem($0, server: server) }
        let nextUpItems = data.nextUp.map { mapPlaybackItem($0, server: server) }
        return (resumeItems, nextUpItems)
    }

    public func fetchTVPlaybackState(server: EmbyServerConfig, tvId: String) async throws -> UHDTVPlaybackState {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/tv/\(tvId)/playback-state",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDTVPlaybackStateDTO.self, request: req, priority: .normal)
        let apiBase = server.mainLineURL
        func mapEp(_ ep: UHDTVPlaybackEpisodeDTO?) -> UHDTVPlaybackEpisode? {
            guard let ep else { return nil }
            return UHDTVPlaybackEpisode(
                episodeId: ep.episodeId,
                mediaId: ep.mediaId,
                seasonId: ep.seasonId,
                seasonNumber: ep.seasonNumber,
                episodeNumber: ep.episodeNumber,
                title: ep.title,
                thumbURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: ep.thumbURL),
                durationSeconds: ep.duration,
                positionMs: ep.positionMs,
                progressPct: ep.progressPct,
                lastPlayedAt: ep.lastPlayedAt
            )
        }
        return UHDTVPlaybackState(resume: mapEp(dto.resume), nextUp: mapEp(dto.nextUp))
    }

    /// Spec requires `type` in `movie | tv`. When `type == nil`, fetches both `movie` and `tv` concurrently.
    public func fetchFavorites(
        server: EmbyServerConfig,
        type: String? = nil,
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> (items: [EmbyItem], total: Int, nextCursor: String?) {
        if let explicitType = type, explicitType == "movie" || explicitType == "tv" {
            var query = [
                URLQueryItem(name: "type", value: explicitType),
                URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")
            ]
            if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/me/favorites",
                queryItems: query,
                token: server.accessToken
            )
            let data = try await performRequest(UHDFavoritesCursorDTO<UHDMediaSummaryDTO>.self, request: req, priority: .normal)
            let items = data.items.map { mapSummary($0, server: server) }
            return (items, data.total ?? items.count, data.nextCursor)
        }

        // Combined movie + tv favorites when caller did not specify a single category
        let halfLimit = max(1, min(100, limit))
        async let moviesTask = try? fetchFavorites(server: server, type: "movie", limit: halfLimit)
        async let tvTask = try? fetchFavorites(server: server, type: "tv", limit: halfLimit)
        let (moviesRes, tvRes) = await (moviesTask, tvTask)
        let combined = (moviesRes?.items ?? []) + (tvRes?.items ?? [])
        let total = (moviesRes?.total ?? 0) + (tvRes?.total ?? 0)
        return (combined, total, nil)
    }

    public func fetchFavoritePersons(
        server: EmbyServerConfig,
        limit: Int = 40,
        cursor: String? = nil
    ) async throws -> (items: [UHDPersonDetail], total: Int, nextCursor: String?) {
        var query = [
            URLQueryItem(name: "type", value: "person"),
            URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")
        ]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/me/favorites",
            queryItems: query,
            token: server.accessToken
        )
        let data = try await performRequest(UHDFavoritesCursorDTO<UHDPersonCardDTO>.self, request: req, priority: .normal)
        let apiBase = server.mainLineURL
        let people = data.items.map { p in
            UHDPersonDetail(
                id: p.id,
                name: p.name,
                tmdbId: p.tmdbId,
                imdbId: p.imdbId,
                imageURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: p.imageURL),
                favorite: p.favorite ?? true
            )
        }
        return (people, data.total ?? people.count, data.nextCursor)
    }

    // MARK: - Item Details, Seasons, Episodes & Credits

    public func fetchItemDetail(server: EmbyServerConfig, item: EmbyItem) async throws -> EmbyItem {
        let mediaKind = resolveItemType(item)
        if mediaKind == "episode" {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/episodes/\(item.id)",
                token: server.accessToken
            )
            let data = try await performRequest(UHDEpisodeDetailDataDTO.self, request: req, priority: .normal)
            return mapEpisode(
                data.episode,
                seriesId: data.series.id,
                seriesName: data.series.title,
                seasonNumber: data.season.seasonNumber,
                posterFallback: data.series.posterURL,
                fanartFallback: data.series.fanartURL,
                server: server
            )
        } else if mediaKind == "tv" {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/tv/\(item.id)",
                token: server.accessToken
            )
            let dto = try await performRequest(UHDMediaDetailDTO.self, request: req, priority: .normal)
            return mapDetail(dto, server: server)
        } else {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/movies/\(item.id)",
                token: server.accessToken
            )
            let dto = try await performRequest(UHDMediaDetailDTO.self, request: req, priority: .normal)
            return mapDetail(dto, server: server)
        }
    }

    public func fetchSeasons(server: EmbyServerConfig, tvId: String) async throws -> [EmbyItem] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/tv/\(tvId)/seasons",
            token: server.accessToken
        )
        let data = try await performRequest(UHDItemsOnlyDTO<UHDSeasonCardDTO>.self, request: req, priority: .normal)
        let apiBase = server.mainLineURL
        return data.items.map { s in
            let fallbackTitle = s.seasonNumber == 0 ? "特别篇" : "第 \(s.seasonNumber) 季"
            return EmbyItem(
                id: s.id,
                name: (s.title?.isEmpty == false) ? s.title! : fallbackTitle,
                serverId: server.serverId,
                type: "Season",
                overview: s.description,
                isFolder: true,
                seriesId: s.mediaId,
                indexNumber: s.seasonNumber,
                childCount: s.totalEpisodes,
                userData: EmbyUserData(played: s.userState.played),
                uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: s.posterURL),
                uhdMediaType: "season"
            )
        }
    }

    public func fetchSeasonEpisodes(
        server: EmbyServerConfig,
        tvId: String,
        seasonId: String,
        seasonNumber: Int? = nil,
        seriesName: String? = nil,
        page: Int = 1,
        pageSize: Int = 100
    ) async throws -> (items: [EmbyItem], total: Int) {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/tv/\(tvId)/seasons/\(seasonId)/episodes",
            queryItems: [
                URLQueryItem(name: "page", value: "\(max(1, page))"),
                URLQueryItem(name: "page_size", value: "\(max(1, min(100, pageSize)))")
            ],
            token: server.accessToken
        )
        let data = try await performRequest(UHDEpisodePageDTO.self, request: req, priority: .normal)
        let items = data.items.map { ep in
            mapEpisode(
                ep,
                seriesId: tvId,
                seriesName: seriesName,
                seasonNumber: seasonNumber,
                posterFallback: nil,
                fanartFallback: nil,
                server: server
            )
        }
        return (items, data.total)
    }

    public func fetchCredits(server: EmbyServerConfig, mediaId: String, limit: Int = 30) async throws -> [EmbyPerson] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/media/\(mediaId)/credits",
            queryItems: [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")],
            token: server.accessToken
        )
        let data = try await performRequest(UHDCreditsPageDTO.self, request: req, priority: .normal)
        let apiBase = server.mainLineURL
        return data.items.map { c in
            let embyRole: String
            switch c.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "director": embyRole = "Director"
            case "writer", "screenplay": embyRole = "Writer"
            case "producer", "executive producer": embyRole = "Producer"
            case "composer": embyRole = "Composer"
            default: embyRole = "Actor"
            }
            return EmbyPerson(
                id: c.personId,
                name: c.name,
                role: c.character,
                type: embyRole,
                primaryImageTag: nil,
                uhdImageURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: c.imageURL)
            )
        }
    }

    // MARK: - Assets & Playback Resolution

    public func fetchAssetMediaSources(server: EmbyServerConfig, item: EmbyItem) async throws -> [MediaSourceInfo] {
        let itemKind = resolveItemType(item)
        let isEpisode = (itemKind == "episode")
        let assetPath = isEpisode
            ? "/api/v1/stream/episodes/\(item.id)/assets"
            : "/api/v1/stream/movies/\(item.id)/assets"
        let assetReq = try makeRequest(
            baseURL: server.mainLineURL,
            path: assetPath,
            token: server.accessToken,
            timeout: 15
        )
        let assets = try await performRequest(UHDAssetResponseDTO.self, request: assetReq, priority: .normal)
        await UHDAssetResponseCache.shared.set(assets, serverId: server.id, itemType: itemKind, itemId: item.id)
        return assets.videos.map { mapVideoAsset($0, resolvedBase: server.activeBaseURL) }
    }

    public func resolvePlaybackResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        enable302Cache: Bool = true
    ) async throws -> ResolvedPlaybackResource {
        let itemKind = resolveItemType(item)
        let isEpisode = (itemKind == "episode")
        let assetPath = isEpisode
            ? "/api/v1/stream/episodes/\(item.id)/assets"
            : "/api/v1/stream/movies/\(item.id)/assets"
        let assetReq = try makeRequest(
            baseURL: server.mainLineURL,
            path: assetPath,
            token: server.accessToken,
            timeout: 15
        )

        let knownDomainId: String? = {
            if let selectedId = server.selectedLineId,
               let line = server.backupLines.first(where: { $0.id == selectedId }),
               let id = line.domainId, !id.isEmpty {
                return id
            }
            if let firstDomain = server.backupLines.first(where: { $0.domainId?.isEmpty == false })?.domainId {
                return firstDomain
            }
            return nil
        }()

        let cachedAssets = await UHDAssetResponseCache.shared.get(serverId: server.id, itemType: itemKind, itemId: item.id)
        async let knownDomainURLTask: URL? = {
            guard let knownDomainId else { return nil }
            if let cached = await UHDResolvedDomainCache.shared.get(serverId: server.id, domainId: knownDomainId) {
                return cached
            }
            return try? await resolvePlaybackDomain(server: server, domainId: knownDomainId)
        }()

        let assets: UHDAssetResponseDTO
        if let cachedAssets {
            assets = cachedAssets
        } else {
            assets = try await performRequest(UHDAssetResponseDTO.self, request: assetReq, priority: .playback)
            await UHDAssetResponseCache.shared.set(assets, serverId: server.id, itemType: itemKind, itemId: item.id)
        }
        guard !assets.videos.isEmpty else {
            throw EmbyClientError.noPlayableStream
        }

        let resolvedBase: String
        if let resolved = await knownDomainURLTask {
            resolvedBase = resolved.absoluteString
        } else {
            let domainId: String
            if let knownDomainId {
                domainId = knownDomainId
            } else {
                let fetched = try await fetchPlaybackDomains(server: server)
                guard let first = fetched.first?.domainId, !first.isEmpty else {
                    throw EmbyClientError.noPlayableStream
                }
                domainId = first
            }
            do {
                resolvedBase = try await resolvePlaybackDomain(server: server, domainId: domainId).absoluteString
            } catch {
                // Spec: 404 on domain resolve -> refresh domain list and retry with first available line
                let refreshed = try await fetchPlaybackDomains(server: server)
                guard let fallbackId = refreshed.first?.domainId, !fallbackId.isEmpty else {
                    throw error
                }
                resolvedBase = try await resolvePlaybackDomain(server: server, domainId: fallbackId).absoluteString
            }
        }

        let mediaSources = assets.videos.map { mapVideoAsset($0, resolvedBase: resolvedBase) }
        let selectedVideoDTO: UHDVideoAssetDTO
        let selectedSource: MediaSourceInfo

        if let preferredSourceId,
           let idx = assets.videos.firstIndex(where: { $0.assetId == preferredSourceId }) {
            selectedVideoDTO = assets.videos[idx]
            selectedSource = mediaSources[idx]
        } else if let preferred = mediaSources.preferredSource(for: preferredPreset),
                  let idx = assets.videos.firstIndex(where: { $0.assetId == preferred.id }) {
            selectedVideoDTO = assets.videos[idx]
            selectedSource = mediaSources[idx]
        } else {
            selectedVideoDTO = assets.videos[0]
            selectedSource = mediaSources[0]
        }

        guard let originStreamURL = resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: selectedVideoDTO.playURL) else {
            throw EmbyClientError.noPlayableStream
        }
        let downloadURL = resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: selectedVideoDTO.downloadURL)

        var resolvedStreamURL = originStreamURL
        var routeSuffix = ""
        if enable302Cache {
            let cacheKey = EmbyClient.redirectCacheKey(
                serverId: server.id,
                itemId: item.id,
                mediaSourceId: selectedSource.id,
                baseURL: server.activeBaseURL
            )
            if let cachedRedirect = await RedirectCacheStore.shared.cachedRedirect(for: cacheKey) {
                resolvedStreamURL = cachedRedirect
                routeSuffix = " · 302缓存命中"
            }
        }

        let subtitleItems: [SubtitleResourceItem] = assets.subtitles.compactMap { sub in
            guard let url = resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: sub.playURL) else { return nil }
            let lang = sub.languages.isEmpty ? "" : " (\(sub.languages.joined(separator: ",")))"
            return SubtitleResourceItem(
                name: "\(sub.displayName)\(lang)",
                url: url,
                streamIndex: nil,
                codec: sub.format,
                isExternal: true
            )
        }

        var headers = ["User-Agent": "Donby/\(appVersion) (macOS; UHDNow Client)"]
        if !server.accessToken.isEmpty {
            headers["Authorization"] = server.accessToken
        }
        return ResolvedPlaybackResource(
            streamURL: resolvedStreamURL,
            originStreamURL: originStreamURL,
            downloadURL: downloadURL,
            headers: headers,
            playSessionId: selectedVideoDTO.assetId,
            mediaSource: selectedSource,
            subtitleURLs: subtitleItems,
            isDirectStream: true,
            routeNote: "UHD 原生直连 · \(selectedVideoDTO.displayName)\(routeSuffix)"
        )
    }

    // MARK: - Playback & User State Mutations

    public enum PlaybackReportKind: String, Sendable {
        case progress
        case stopped
        case finished
    }

    public func reportPlayback(
        server: EmbyServerConfig,
        kind: PlaybackReportKind,
        item: EmbyItem,
        assetId: String,
        positionSeconds: Double
    ) async {
        guard !assetId.isEmpty else { return }
        let itemType = resolveItemType(item) == "episode" ? "episode" : "movie"
        let clampedMs = max(0, min(604_800_000, Int64(positionSeconds * 1000.0)))
        let payload: [String: Any] = [
            "item_type": itemType,
            "item_id": item.id,
            "asset_id": assetId,
            "position_ms": clampedMs
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let req = try? makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/playback/\(kind.rawValue)",
                method: "POST",
                token: server.accessToken,
                bodyData: body,
                timeout: 10
              ) else { return }
        try? await performAction(request: req, priority: .playback)
    }

    public func setFavorite(server: EmbyServerConfig, item: EmbyItem, isFavorite: Bool) async throws {
        let uhdType = resolveStateType(item, allowed: ["movie", "tv", "person"]) ?? "movie"
        try await setFavoriteRaw(server: server, itemType: uhdType, itemId: item.id, isFavorite: isFavorite)
    }

    public func setPersonFavorite(server: EmbyServerConfig, personId: String, isFavorite: Bool) async throws {
        try await setFavoriteRaw(server: server, itemType: "person", itemId: personId, isFavorite: isFavorite)
    }

    private func setFavoriteRaw(server: EmbyServerConfig, itemType: String, itemId: String, isFavorite: Bool) async throws {
        if isFavorite {
            let body = try JSONSerialization.data(withJSONObject: ["item_type": itemType, "item_id": itemId])
            let req = try makeRequest(baseURL: server.mainLineURL, path: "/api/v1/stream/me/favorites", method: "POST", token: server.accessToken, bodyData: body)
            try await performAction(request: req, priority: .normal)
        } else {
            let req = try makeRequest(baseURL: server.mainLineURL, path: "/api/v1/stream/me/favorites/\(itemType)/\(itemId)", method: "DELETE", token: server.accessToken)
            try await performAction(request: req, priority: .normal)
        }
    }

    public func setPlayed(server: EmbyServerConfig, item: EmbyItem, isPlayed: Bool) async throws {
        let uhdType = resolveStateType(item, allowed: ["movie", "tv", "season", "episode"]) ?? "movie"
        if isPlayed {
            let body = try JSONSerialization.data(withJSONObject: ["item_type": uhdType, "item_id": item.id])
            let req = try makeRequest(baseURL: server.mainLineURL, path: "/api/v1/stream/me/played", method: "POST", token: server.accessToken, bodyData: body)
            try await performAction(request: req, priority: .normal)
        } else {
            let req = try makeRequest(baseURL: server.mainLineURL, path: "/api/v1/stream/me/played/\(uhdType)/\(item.id)", method: "DELETE", token: server.accessToken)
            try await performAction(request: req, priority: .normal)
        }
    }

    // MARK: - Team Management API v2 (Platform API Key / Owner Only)

    public func fetchTeamOverview(server: EmbyServerConfig) async throws -> UHDTeamOverview {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v2/team",
            token: server.accessToken,
            timeout: 10
        )
        let dto = try await performRequest(UHDTeamOverviewDTO.self, request: req, priority: .normal)
        return UHDTeamOverview(
            expiresAt: dto.expiresAt,
            memberCount: dto.memberCount,
            memberLimit: dto.memberLimit,
            trafficLimitBytes: dto.trafficLimitBytes,
            trafficUsedBytes: dto.trafficUsedBytes,
            renewDay: dto.renewDay,
            settings: UHDTeamSettings(
                activeVideoDeliveryLimit: dto.settings.activeVideoDeliveryLimit,
                allowDownload: dto.settings.allowDownload
            )
        )
    }

    public func fetchTeamMembers(
        server: EmbyServerConfig,
        query: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> (items: [UHDTeamMember], nextCursor: String?) {
        var qItems = [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            qItems.append(URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let cursor, !cursor.isEmpty {
            qItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v2/team/members",
            queryItems: qItems,
            token: server.accessToken
        )
        let dto = try await performRequest(UHDTeamMemberPageDTO.self, request: req, priority: .normal)
        let members = dto.items.map { m in
            UHDTeamMember(
                id: m.id,
                username: m.username,
                expiresAt: m.expiresAt,
                trafficLimitBytes: m.trafficLimitBytes,
                trafficUsedBytes: m.trafficUsedBytes,
                renewDay: m.renewDay,
                activeVideoDeliveryLimit: m.activeVideoDeliveryLimit,
                allowDownload: m.allowDownload,
                sessionCount: m.sessionCount
            )
        }
        return (members, dto.nextCursor)
    }

    public func updateTeamSettings(
        server: EmbyServerConfig,
        activeVideoDeliveryLimit: Int? = nil,
        allowDownload: Bool? = nil
    ) async throws -> UHDTeamSettings {
        var payload: [String: Any] = [:]
        if let activeVideoDeliveryLimit { payload["active_video_delivery_limit"] = activeVideoDeliveryLimit }
        if let allowDownload { payload["allow_download"] = allowDownload }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v2/team/settings",
            method: "PATCH",
            token: server.accessToken,
            bodyData: body
        )
        let dto = try await performRequest(UHDTeamSettingsDTO.self, request: req, priority: .normal)
        return UHDTeamSettings(
            activeVideoDeliveryLimit: dto.activeVideoDeliveryLimit,
            allowDownload: dto.allowDownload
        )
    }

    public func setTeamMemberTrafficUsage(server: EmbyServerConfig, memberId: String, usedBytes: Int64) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["traffic_used_bytes": max(0, usedBytes)])
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v2/team/members/\(memberId)/traffic-usage",
            method: "PUT",
            token: server.accessToken,
            bodyData: body
        )
        try await performAction(request: req, priority: .normal)
    }

    // MARK: - DTO Mapping

    private func resolveItemType(_ item: EmbyItem) -> String {
        if let explicit = item.uhdMediaType?.lowercased(), !explicit.isEmpty {
            return explicit
        }
        let t = item.type?.lowercased() ?? ""
        if t == "episode" { return "episode" }
        if t == "series" || t == "show" || t == "tv" { return "tv" }
        if t == "season" { return "season" }
        return "movie"
    }

    private func resolveStateType(_ item: EmbyItem, allowed: [String]) -> String? {
        let resolved = resolveItemType(item)
        if allowed.contains(resolved) { return resolved }
        return allowed.first
    }

    private func mapSummary(_ dto: UHDMediaSummaryDTO, server: EmbyServerConfig) -> EmbyItem {
        let apiBase = server.mainLineURL
        let embyType = dto.type.lowercased() == "tv" ? "Series" : "Movie"
        let runtimeTicks = dto.duration.map { $0 * 10_000_000 }
        let posTicks = (dto.userState?.positionMs ?? 0) * 10_000
        let userData = dto.userState.map {
            EmbyUserData(
                playbackPositionTicks: posTicks,
                isFavorite: $0.favorite,
                played: $0.played,
                playedPercentage: $0.progressPct.map(Double.init),
                lastPlayedDate: $0.lastPlayedAt
            )
        }
        return EmbyItem(
            id: dto.id,
            name: dto.title,
            originalTitle: dto.originTitle,
            serverId: server.serverId,
            type: embyType,
            genres: dto.genres?.map(\.name),
            communityRating: UHDRatingNormalizer.normalize(dto.rating),
            productionYear: dto.releaseYear,
            premiereDate: dto.releaseDate,
            runTimeTicks: runtimeTicks,
            childCount: dto.totalSeasons,
            recursiveItemCount: dto.versionCount,
            userData: userData,
            providerIds: dto.tmdbId.map { ["Tmdb": "\($0)"] },
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.posterURL),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.fanartURL),
            uhdLogoURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.logoURL),
            uhdMediaType: dto.type.lowercased()
        )
    }

    private func mapDetail(_ dto: UHDMediaDetailDTO, server: EmbyServerConfig) -> EmbyItem {
        let apiBase = server.mainLineURL
        let embyType = dto.type.lowercased() == "tv" ? "Series" : "Movie"
        let runtimeTicks = dto.duration.map { $0 * 10_000_000 }
        let posTicks = (dto.userState?.positionMs ?? 0) * 10_000
        let userData = dto.userState.map {
            EmbyUserData(
                playbackPositionTicks: posTicks,
                isFavorite: $0.favorite,
                played: $0.played,
                playedPercentage: $0.progressPct.map(Double.init),
                lastPlayedDate: $0.lastPlayedAt
            )
        }
        var providers: [String: String] = [:]
        if let tmdb = dto.tmdbId { providers["Tmdb"] = "\(tmdb)" }
        if let imdb = dto.imdbId, !imdb.isEmpty { providers["Imdb"] = imdb }
        if let douban = dto.doubanId, !douban.isEmpty { providers["Douban"] = douban }
        return EmbyItem(
            id: dto.id,
            name: dto.title,
            originalTitle: dto.originTitle,
            serverId: server.serverId,
            type: embyType,
            overview: dto.description,
            taglines: dto.tagline.map { [$0] },
            genres: dto.genres?.map(\.name),
            communityRating: UHDRatingNormalizer.normalize(dto.rating),
            productionYear: dto.releaseYear,
            premiereDate: dto.releaseDate,
            status: dto.status,
            runTimeTicks: runtimeTicks,
            childCount: dto.totalSeasons,
            recursiveItemCount: dto.versionCount,
            userData: userData,
            providerIds: providers.isEmpty ? nil : providers,
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.posterURL),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.fanartURL),
            uhdLogoURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.logoURL),
            uhdMediaType: dto.type.lowercased()
        )
    }

    private func mapEpisode(
        _ ep: UHDEpisodeCardDTO,
        seriesId: String,
        seriesName: String?,
        seasonNumber: Int?,
        posterFallback: String?,
        fanartFallback: String?,
        server: EmbyServerConfig
    ) -> EmbyItem {
        let apiBase = server.mainLineURL
        let runtimeTicks = ep.duration > 0 ? ep.duration * 10_000_000 : nil
        let posTicks = (ep.userState.positionMs ?? 0) * 10_000
        let userData = EmbyUserData(
            playbackPositionTicks: posTicks,
            isFavorite: ep.userState.favorite,
            played: ep.userState.played,
            playedPercentage: ep.userState.progressPct.map(Double.init),
            lastPlayedDate: ep.userState.lastPlayedAt
        )
        return EmbyItem(
            id: ep.id,
            name: ep.title?.isEmpty == false ? ep.title! : "第 \(ep.episodeNumber) 集",
            serverId: server.serverId,
            type: "Episode",
            overview: ep.description,
            premiereDate: ep.airDate,
            runTimeTicks: runtimeTicks,
            seriesId: seriesId,
            seriesName: seriesName,
            seasonId: ep.seasonId,
            indexNumber: ep.episodeNumber,
            parentIndexNumber: seasonNumber,
            userData: userData,
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: posterFallback),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: fanartFallback),
            uhdThumbURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: ep.thumbURL),
            uhdMediaType: "episode"
        )
    }

    private func mapPlaybackItem(_ item: UHDPlaybackItemDTO, server: EmbyServerConfig) -> EmbyItem {
        let apiBase = server.mainLineURL
        let isEpisode = item.itemType.lowercased() == "episode"
        let embyType = isEpisode ? "Episode" : "Movie"
        let runtimeTicks = item.duration > 0 ? item.duration * 10_000_000 : nil
        let posTicks = item.positionMs * 10_000
        return EmbyItem(
            id: item.itemId,
            name: item.title,
            serverId: server.serverId,
            type: embyType,
            runTimeTicks: runtimeTicks,
            seriesId: isEpisode ? item.mediaId : nil,
            seriesName: item.seriesTitle,
            seasonId: item.seasonId,
            indexNumber: item.episodeNumber,
            parentIndexNumber: item.seasonNumber,
            userData: EmbyUserData(
                playbackPositionTicks: posTicks,
                played: false,
                playedPercentage: Double(item.progressPct),
                lastPlayedDate: item.lastPlayedAt
            ),
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: item.posterURL),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: item.fanartURL),
            uhdThumbURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: item.thumbURL),
            uhdMediaType: item.itemType.lowercased()
        )
    }

    private func mapVideoAsset(_ video: UHDVideoAssetDTO, resolvedBase: String) -> MediaSourceInfo {
        var streams: [MediaStream] = []
        let parsedFPS: Double? = {
            guard let raw = video.frameRate else { return nil }
            if raw.contains("/") {
                let parts = raw.split(separator: "/")
                if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                    return num / den
                }
            }
            return Double(raw)
        }()
        streams.append(
            MediaStream(
                index: 0,
                type: "Video",
                codec: video.encoding,
                displayTitle: "\(video.resolution > 0 ? "\(video.resolution)P" : "") \(video.encoding.uppercased()) \(video.videoRange)",
                width: video.width,
                height: video.height,
                bitRate: video.videoBitRate.map(Int.init) ?? Int(video.bitRate),
                bitDepth: video.bitDepth,
                averageFrameRate: parsedFPS,
                realFrameRate: parsedFPS,
                profile: video.profile,
                videoRange: video.videoRange,
                videoDoViTitle: video.dolbyVision != nil ? "Dolby Vision P\(video.dolbyVision?.profile ?? 0)" : nil,
                dvProfile: video.dolbyVision?.profile,
                colorSpace: video.colorSpace,
                colorTransfer: video.colorTransfer,
                colorPrimaries: video.colorPrimaries,
                pixelFormat: video.pixFmt
            )
        )
        for audio in video.audioTracks {
            streams.append(
                MediaStream(
                    index: audio.index,
                    type: "Audio",
                    codec: audio.codecName,
                    language: audio.language,
                    displayTitle: audio.title,
                    title: audio.title,
                    isDefault: audio.isDefault,
                    bitRate: audio.bitRate.map(Int.init),
                    channels: audio.channels,
                    channelLayout: audio.channelLayout,
                    sampleRate: audio.sampleRate.flatMap { Int($0) }
                )
            )
        }
        for sub in video.subtitleTracks {
            streams.append(
                MediaStream(
                    index: sub.index,
                    type: "Subtitle",
                    codec: sub.codecName,
                    language: sub.language,
                    displayTitle: sub.title,
                    title: sub.title,
                    isDefault: sub.isDefault,
                    isForced: sub.isForced,
                    isExternal: false
                )
            )
        }
        return MediaSourceInfo(
            id: video.assetId,
            name: video.displayName.isEmpty ? video.name : video.displayName,
            container: video.container,
            size: video.fileSize,
            bitrate: Int(video.bitRate),
            runTimeTicks: video.duration * 10_000_000,
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: false,
            directStreamUrl: resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: video.playURL)?.absoluteString,
            mediaStreams: streams
        )
    }
}

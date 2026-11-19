import Foundation
import DonbyCore

public struct UHDTrafficSummary: Sendable, Codable, Equatable {
    public let displayUnlimitedTraffic: Bool
    public let usedBytes: Int64
    public let limitBytes: Int64
    public let updatedAt: String
}

public struct UHDSpeedTestResult: Sendable, Equatable {
    public let domainId: String
    public let location: String
    public let isp: String
    public let averageMbps: Double
    public let peakMbps: Double
    public let elapsedMs: Int64
    public let downloadedBytes: Int64
}

public struct UHDLoginResult: Sendable {
    public let token: String
    public let expiresAt: String
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

private struct UHDFavoritesCursorDTO: Decodable {
    let total: Int?
    let items: [UHDMediaSummaryDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case total, items
        case nextCursor = "next_cursor"
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
    let description: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, description
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
}

private struct UHDSubscriptionDTO: Decodable {
    let allowDownload: Bool
    let displayUnlimitedTraffic: Bool
    let trafficLimitBytes: Int64
    let activeVideoDeliveryLimit: Int
    let plan: UHDSubscriptionPlanDTO?

    enum CodingKeys: String, CodingKey {
        case allowDownload = "allow_download"
        case displayUnlimitedTraffic = "display_unlimited_traffic"
        case trafficLimitBytes = "traffic_limit_bytes"
        case activeVideoDeliveryLimit = "active_video_delivery_limit"
        case plan
    }
}

private struct UHDTrafficDTO: Decodable {
    let displayUnlimitedTraffic: Bool
    let usedBytes: Int64
    let limitBytes: Int64
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case displayUnlimitedTraffic = "display_unlimited_traffic"
        case usedBytes = "used_bytes"
        case limitBytes = "limit_bytes"
        case updatedAt = "updated_at"
    }
}

private struct UHDSpeedTestNetworkInfoDTO: Decodable {
    let isp: String
    let displayLocation: String

    enum CodingKeys: String, CodingKey {
        case isp
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

public final class UHDStreamClient: Sendable {
    public static let shared = UHDStreamClient()

    private let apiSession: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 45
        self.apiSession = URLSession(configuration: cfg)
    }

    public var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.24"
    }

    private func normalizedAPIBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private func resolveAbsoluteImageURL(apiBase: String, relativeOrAbsolute: String?) -> String? {
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
        timeout: TimeInterval = 15
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
        return req
    }

    private func performRequest<T: Decodable>(
        _ type: T.Type,
        request: URLRequest,
        priority: APIRequestGate.Priority = .normal
    ) async throws -> T {
        try await APIRequestGate.shared.withPermit(priority: priority) {
            let (data, response) = try await self.apiSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let errMsg = (try? JSONDecoder().decode(UHDOkOnly.self, from: data))?.msg ?? ""
                if http.statusCode == 401 { throw EmbyClientError.unauthorized }
                throw EmbyClientError.httpStatus(http.statusCode, errMsg)
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
        priority: APIRequestGate.Priority = .normal
    ) async throws {
        try await APIRequestGate.shared.withPermit(priority: priority) {
            let (data, response) = try await self.apiSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let errMsg = (try? JSONDecoder().decode(UHDOkOnly.self, from: data))?.msg ?? ""
                if http.statusCode == 401 { throw EmbyClientError.unauthorized }
                throw EmbyClientError.httpStatus(http.statusCode, errMsg)
            }
        }
    }

    // MARK: - Auth

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
        let res = try await performRequest(UHDLoginDataDTO.self, request: req, priority: .playback)
        guard !res.token.isEmpty else { throw EmbyClientError.emptyToken }
        return UHDLoginResult(token: res.token, expiresAt: res.expiresAt)
    }

    public func logout(server: EmbyServerConfig) async {
        guard let req = try? makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/logout",
            method: "POST",
            token: server.accessToken,
            timeout: 8
        ) else { return }
        try? await performAction(request: req, priority: .normal)
    }

    // MARK: - Subscription, Traffic & Domains

    public func fetchSubscription(server: EmbyServerConfig) async throws -> ServerDeliveryCapabilities {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/subscriptions/me",
            token: server.accessToken
        )
        let dto = try await performRequest(UHDSubscriptionDTO.self, request: req, priority: .normal)
        return ServerDeliveryCapabilities(
            allowDownload: dto.allowDownload,
            activeVideoDeliveryLimit: max(1, dto.activeVideoDeliveryLimit),
            planName: dto.plan?.name,
            displayUnlimitedTraffic: dto.displayUnlimitedTraffic,
            trafficLimitBytes: dto.trafficLimitBytes
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
            displayUnlimitedTraffic: dto.displayUnlimitedTraffic,
            usedBytes: dto.usedBytes,
            limitBytes: dto.limitBytes,
            updatedAt: dto.updatedAt
        )
    }

    public func fetchPlaybackDomains(server: EmbyServerConfig) async throws -> [ServerLineInfo] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/playback/domains",
            token: server.accessToken
        )
        let domains = try await performRequest([UHDPlaybackDomainDTO].self, request: req, priority: .normal)
        let sorted = domains.sorted { $0.sortOrder < $1.sortOrder }
        var lines: [ServerLineInfo] = []
        for dom in sorted {
            let existingURL = server.backupLines.first(where: { $0.domainId == dom.id })?.url
            let resolvedOrPlaceholder: String
            if let existingURL, existingURL.hasPrefix("http") {
                resolvedOrPlaceholder = existingURL
            } else if let url = try? await resolvePlaybackDomain(server: server, domainId: dom.id) {
                resolvedOrPlaceholder = url.absoluteString
            } else {
                resolvedOrPlaceholder = server.mainLineURL
            }
            lines.append(
                ServerLineInfo(
                    name: dom.description?.isEmpty == false ? "\(dom.name) · \(dom.description!)" : dom.name,
                    url: resolvedOrPlaceholder,
                    domainId: dom.id,
                    isAutoSynced: true
                )
            )
        }
        return lines
    }

    public func resolvePlaybackDomain(server: EmbyServerConfig, domainId: String) async throws -> URL {
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
        return url
    }

    public func pingLine(server: EmbyServerConfig, line: ServerLineInfo?) async -> Int? {
        let domainId = line?.domainId ?? server.backupLines.first?.domainId
        let start = CFAbsoluteTimeGetCurrent()
        do {
            if let domainId, !domainId.isEmpty {
                _ = try await resolvePlaybackDomain(server: server, domainId: domainId)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                return max(1, ms)
            } else {
                let req = try makeRequest(
                    baseURL: server.mainLineURL,
                    path: "/api/v1/stream/playback/domains",
                    token: server.accessToken,
                    timeout: 6
                )
                _ = try await apiSession.data(for: req)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                return max(1, ms)
            }
        } catch {
            return nil
        }
    }

    public func runSpeedTest(
        server: EmbyServerConfig,
        domainId: String,
        sizeMiB: Int = 32,
        onProgress: @escaping @Sendable (Double, Double) -> Void
    ) async throws -> UHDSpeedTestResult {
        let clampedMiB = [32, 64, 100].contains(sizeMiB) ? sizeMiB : 32
        let apiBase = server.mainLineURL
        let netInfoReq = try makeRequest(baseURL: apiBase, path: "/api/v1/stream/speed-test/network-info", token: server.accessToken)
        let netInfo = try await performRequest(UHDSpeedTestNetworkInfoDTO.self, request: netInfoReq, priority: .normal)

        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "parent_domain_id": domainId,
            "size_mib": clampedMiB
        ])
        let sessionReq = try makeRequest(baseURL: apiBase, path: "/api/v1/stream/speed-test/session", method: "POST", token: server.accessToken, bodyData: sessionBody)
        let session = try await performRequest(UHDSpeedTestSessionDTO.self, request: sessionReq, priority: .normal)

        let dlReq = try makeRequest(
            baseURL: apiBase,
            path: "/api/v1/stream/speed-test/download",
            queryItems: [
                URLQueryItem(name: "session_id", value: session.sessionId),
                URLQueryItem(name: "size_mb", value: "\(clampedMiB)")
            ],
            token: server.accessToken,
            timeout: 120
        )

        let expectedTotal = Double(clampedMiB) * 1_048_576.0
        let (byteStream, response) = try await apiSession.bytes(for: dlReq)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EmbyClientError.httpStatus(http.statusCode, "测速下载被拒绝")
        }

        let readStart = CFAbsoluteTimeGetCurrent()
        var lastSampleTime = readStart
        var lastSampleBytes: Int64 = 0
        var totalRead: Int64 = 0
        var samplesMbps: [Double] = []
        var peakMbps = 0.0

        for try await _ in byteStream {
            totalRead += 1
            if totalRead & 0xFFFF == 0 {
                let now = CFAbsoluteTimeGetCurrent()
                let dt = now - lastSampleTime
                if dt >= 0.1 {
                    let deltaBytes = totalRead - lastSampleBytes
                    let mbps = (Double(deltaBytes) * 8.0) / (dt * 1_000_000.0)
                    samplesMbps.append(mbps)
                    peakMbps = max(peakMbps, mbps)
                    lastSampleTime = now
                    lastSampleBytes = totalRead
                    onProgress(min(1.0, Double(totalRead) / expectedTotal), mbps)
                }
            }
        }

        let totalElapsedSec = max(0.05, CFAbsoluteTimeGetCurrent() - readStart)
        let avgMbps = (Double(totalRead) * 8.0) / (totalElapsedSec * 1_000_000.0)
        peakMbps = max(peakMbps, avgMbps)
        let elapsedMs = Int64(totalElapsedSec * 1000.0)

        let reportPayload: [String: Any] = [
            "session_id": session.sessionId,
            "report_token": session.reportToken,
            "average_mbps": avgMbps,
            "peak_mbps": peakMbps,
            "elapsed_ms": elapsedMs,
            "sample_count": samplesMbps.count,
            "server_downloaded_bytes": totalRead
        ]
        if let reportData = try? JSONSerialization.data(withJSONObject: reportPayload),
           let reportReq = try? makeRequest(baseURL: apiBase, path: "/api/v1/stream/speed-test/report", method: "POST", token: server.accessToken, bodyData: reportData) {
            // OpenAPI explicitly specifies: never retry speed-test report
            try? await performAction(request: reportReq, priority: .normal)
        }

        return UHDSpeedTestResult(
            domainId: domainId,
            location: netInfo.displayLocation,
            isp: netInfo.isp,
            averageMbps: avgMbps,
            peakMbps: peakMbps,
            elapsedMs: elapsedMs,
            downloadedBytes: totalRead
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

    public func fetchHot(server: EmbyServerConfig, limit: Int = 24) async throws -> [EmbyItem] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/hot",
            queryItems: [URLQueryItem(name: "limit", value: "\(max(1, min(50, limit)))")],
            token: server.accessToken
        )
        let data = try await performRequest(UHDItemsOnlyDTO<UHDMediaSummaryDTO>.self, request: req, priority: .normal)
        return data.items.map { mapSummary($0, server: server) }
    }

    public func search(server: EmbyServerConfig, query: String, limit: Int = 30) async throws -> [EmbyItem] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "\(max(1, min(50, limit)))")
            ],
            token: server.accessToken
        )
        let data = try await performRequest(UHDSearchDataDTO.self, request: req, priority: .normal)
        return data.items.map { mapSummary($0, server: server) }
    }

    public func fetchPlaybackStates(server: EmbyServerConfig, limit: Int = 20) async throws -> (resume: [EmbyItem], nextUp: [EmbyItem]) {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/me/playback-states",
            queryItems: [URLQueryItem(name: "limit", value: "\(max(1, min(50, limit)))")],
            token: server.accessToken
        )
        let data = try await performRequest(UHDPlaybackStatesDTO.self, request: req, priority: .normal)
        let resumeItems = data.resume.map { mapPlaybackItem($0, server: server) }
        let nextUpItems = data.nextUp.map { mapPlaybackItem($0, server: server) }
        return (resumeItems, nextUpItems)
    }

    public func fetchFavorites(
        server: EmbyServerConfig,
        type: String? = nil,
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> (items: [EmbyItem], total: Int, nextCursor: String?) {
        var query = [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")]
        if let type, !type.isEmpty { query.append(URLQueryItem(name: "type", value: type)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/me/favorites",
            queryItems: query,
            token: server.accessToken
        )
        let data = try await performRequest(UHDFavoritesCursorDTO.self, request: req, priority: .normal)
        let items = data.items.map { mapSummary($0, server: server) }
        return (items, data.total ?? items.count, data.nextCursor)
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
            let embyRole = c.role.lowercased() == "director" ? "Director" : "Actor"
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
        let isEpisode = resolveItemType(item) == "episode"
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
        return assets.videos.map { mapVideoAsset($0, resolvedBase: server.activeBaseURL) }
    }

    public func resolvePlaybackResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate
    ) async throws -> ResolvedPlaybackResource {
        let isEpisode = resolveItemType(item) == "episode"
        let assetPath = isEpisode
            ? "/api/v1/stream/episodes/\(item.id)/assets"
            : "/api/v1/stream/movies/\(item.id)/assets"
        let assetReq = try makeRequest(
            baseURL: server.mainLineURL,
            path: assetPath,
            token: server.accessToken,
            timeout: 15
        )
        let assets = try await performRequest(UHDAssetResponseDTO.self, request: assetReq, priority: .playback)
        guard !assets.videos.isEmpty else {
            throw EmbyClientError.noPlayableStream
        }

        // Resolve fresh domain URL from parent domain ID per UHD OpenAPI requirement
        let domainId: String
        if let selectedId = server.selectedLineId,
           let line = server.backupLines.first(where: { $0.id == selectedId }),
           let id = line.domainId, !id.isEmpty {
            domainId = id
        } else if let firstDomain = server.backupLines.first(where: { $0.domainId?.isEmpty == false })?.domainId {
            domainId = firstDomain
        } else {
            let fetched = try await fetchPlaybackDomains(server: server)
            guard let first = fetched.first?.domainId, !first.isEmpty else {
                throw EmbyClientError.noPlayableStream
            }
            domainId = first
        }
        let resolvedBase = try await resolvePlaybackDomain(server: server, domainId: domainId).absoluteString

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

        guard let streamURL = resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: selectedVideoDTO.playURL) else {
            throw EmbyClientError.noPlayableStream
        }
        let downloadURL = resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: selectedVideoDTO.downloadURL)

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

        let headers = server.accessToken.isEmpty ? [:] : ["Authorization": server.accessToken]
        return ResolvedPlaybackResource(
            streamURL: streamURL,
            downloadURL: downloadURL,
            headers: headers,
            playSessionId: selectedVideoDTO.assetId,
            mediaSource: selectedSource,
            subtitleURLs: subtitleItems,
            isDirectStream: true,
            routeNote: "UHD 原生直连 · \(selectedVideoDTO.displayName)"
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
        let payload: [String: Any] = [
            "item_type": itemType,
            "item_id": item.id,
            "asset_id": assetId,
            "position_ms": max(0, Int64(positionSeconds * 1000.0))
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
        if isFavorite {
            let body = try JSONSerialization.data(withJSONObject: ["item_type": uhdType, "item_id": item.id])
            let req = try makeRequest(baseURL: server.mainLineURL, path: "/api/v1/stream/me/favorites", method: "POST", token: server.accessToken, bodyData: body)
            try await performAction(request: req, priority: .normal)
        } else {
            let req = try makeRequest(baseURL: server.mainLineURL, path: "/api/v1/stream/me/favorites/\(uhdType)/\(item.id)", method: "DELETE", token: server.accessToken)
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
            communityRating: dto.rating,
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
        return EmbyItem(
            id: dto.id,
            name: dto.title,
            originalTitle: dto.originTitle,
            serverId: server.serverId,
            type: embyType,
            overview: dto.description,
            taglines: dto.tagline.map { [$0] },
            genres: dto.genres?.map(\.name),
            communityRating: dto.rating,
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

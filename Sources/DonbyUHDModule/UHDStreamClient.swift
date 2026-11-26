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

struct UHDUserStateDTO: Decodable {
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

struct UHDGenreDTO: Decodable {
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

struct UHDMediaSummaryDTO: Decodable {
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

struct UHDItemsOnlyDTO<T: Decodable>: Decodable {
    let items: [T]
}

actor UHDResolvedDomainCache {
    static let shared = UHDResolvedDomainCache()
    private var entries: [String: (url: URL, expiresAt: Date)] = [:]

    func get(serverId: UUID, domainId: String) -> URL? {
        let key = "\(serverId.uuidString)|\(domainId)"
        if let hit = entries[key], hit.expiresAt > Date() {
            return hit.url
        }
        entries.removeValue(forKey: key)
        if let warm = NetworkRouteWarmStore.shared.cachedEdgeOrigin(serverId: serverId, lineKey: domainId) {
            entries[key] = (warm, Date().addingTimeInterval(180))
            return warm
        }
        return nil
    }

    func set(_ url: URL, serverId: UUID, domainId: String, ttlSeconds: TimeInterval = 300) {
        let key = "\(serverId.uuidString)|\(domainId)"
        entries[key] = (url: url, expiresAt: Date().addingTimeInterval(ttlSeconds))
        NetworkRouteWarmStore.shared.storeEdgeOrigin(url, serverId: serverId, lineKey: domainId, ttlSeconds: ttlSeconds)
    }

    func invalidate(serverId: UUID) {
        let prefix = "\(serverId.uuidString)|"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        NetworkRouteWarmStore.shared.invalidateServer(serverId)
    }
}

actor UHDAssetResponseCache {
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

// MARK: - UHDStreamClient

public final class UHDStreamClient: Sendable {
    public static let shared = UHDStreamClient()

    let apiSession: URLSession

    private init() {
        self.apiSession = DonbyNetworkSession.sharedURLSession
    }

    public var appVersion: String {
        DonbyAppInfo.version
    }

    func normalizedAPIBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    func makeRequest(
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

    func performRequest<T: Decodable>(
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

    func performAction(
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
}

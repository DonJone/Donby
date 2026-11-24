import Foundation
import DonbyCore
import DonbyNetwork

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

extension UHDStreamClient {
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
}

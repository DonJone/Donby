import Foundation

public enum EmbyClientError: LocalizedError, Sendable {
    case invalidServerURL(String)
    case unauthorized
    case httpStatus(Int, String)
    case emptyToken
    case noPlayableStream
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL(let url): return "服务器地址不合法: \(url)"
        case .unauthorized: return "认证失败 (401)"
        case .httpStatus(let code, let msg): return "HTTP \(code) \(msg)"
        case .emptyToken: return "未获取到 Token"
        case .noPlayableStream: return "无可用播放流"
        case .decodingFailed(let r): return "解码失败: \(r)"
        }
    }
}

public struct EmbyExtServerDomainsResponse: Codable, Sendable {
    public let ok: Bool?
    public let data: [EmbyExtDomainItem]?
    public let error: String?

    public init(ok: Bool? = true, data: [EmbyExtDomainItem]? = nil, error: String? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
    }
}

public struct EmbyExtDomainItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(name)|\(url)" }
    public let name: String
    public let url: String
    public init(name: String, url: String) { self.name = name; self.url = url }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var foundUrl = ""
            for key in ["url", "domain", "host", "address", "server", "ip", "line"] {
                if let codingKey = DynamicCodingKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey),
                   !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    foundUrl = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if !foundUrl.isEmpty && !foundUrl.contains("://") {
                foundUrl = "https://\(foundUrl)"
            }
            self.url = foundUrl

            var foundName = ""
            for key in ["name", "label", "title", "remark", "desc", "note"] {
                if let codingKey = DynamicCodingKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey),
                   !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    foundName = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            self.name = foundName.isEmpty ? foundUrl : foundName
            return
        }
        if let singleVal = try? decoder.singleValueContainer(), let str = try? singleVal.decode(String.self) {
            let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
            self.url = clean.contains("://") ? clean : "https://\(clean)"
            self.name = clean
            return
        }
        self.name = ""
        self.url = ""
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

public struct EmbyCountsResponse: Codable, Sendable {
    public let movieCount: Int?
    public let seriesCount: Int?
    public let episodeCount: Int?
    public let songCount: Int?
    public let itemCount: Int?

    enum CodingKeys: String, CodingKey {
        case movieCount = "MovieCount"
        case seriesCount = "SeriesCount"
        case episodeCount = "EpisodeCount"
        case songCount = "SongCount"
        case itemCount = "ItemCount"
    }
    public init(movieCount: Int? = nil, seriesCount: Int? = nil, episodeCount: Int? = nil, songCount: Int? = nil, itemCount: Int? = nil) {
        self.movieCount = movieCount; self.seriesCount = seriesCount; self.episodeCount = episodeCount; self.songCount = songCount; self.itemCount = itemCount
    }
}

public enum ServerType: String, Codable, CaseIterable, Identifiable, Sendable {
    case emby = "emby"
    case uhdNative = "uhdNative"
    case jellyfin = "jellyfin"
    case feiniu = "feiniu"
    case plex = "plex"
    case webdav = "webdav"
    case smb = "smb"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .emby: return "Emby / UHDNow"
        case .uhdNative: return "UHDNow 原生 API"
        case .jellyfin: return "Jellyfin"
        case .feiniu: return "飞牛影视 (fnOS)"
        case .plex: return "Plex"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        }
    }
}

public struct ServerLineInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var domainId: String?
    public var isAutoSynced: Bool
    public var latencyMs: Int?
    public var lastCheckedAt: Date?
    public var lastSpeedMbps: Double?
    public var lastPeakMbps: Double?
    public var lastExitLocation: String?
    public var lastExitISP: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        domainId: String? = nil,
        isAutoSynced: Bool = false,
        latencyMs: Int? = nil,
        lastCheckedAt: Date? = nil,
        lastSpeedMbps: Double? = nil,
        lastPeakMbps: Double? = nil,
        lastExitLocation: String? = nil,
        lastExitISP: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = Self.normalizeBaseURL(url)
        self.domainId = domainId
        self.isAutoSynced = isAutoSynced
        self.latencyMs = latencyMs
        self.lastCheckedAt = lastCheckedAt
        self.lastSpeedMbps = lastSpeedMbps
        self.lastPeakMbps = lastPeakMbps
        self.lastExitLocation = lastExitLocation
        self.lastExitISP = lastExitISP
    }

    public static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.lowercased().hasSuffix("/emby") { trimmed = String(trimmed.dropLast(5)) }
        return trimmed
    }

    /// Normalizes verbose backend line names into concise, professional Donby UI labels.
    /// Known Anycast CDN hosts map directly to their full CDN tier name without geographic copy.
    public var cleanDisplayName: String {
        let host = cleanDisplayHost.lowercased()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if host == "smart.uhdnow.com" || (host.contains("uhd") && (lower.contains("中国") || lower.contains("大陆") || lower == "cn cdn")) {
            return "中国大陆 CDN"
        }
        if host == "v1.uhdnow.com" || (host.contains("uhd") && (lower.contains("cloudflare pro") || lower == "cf cdn pro" || lower == "cloudflare cdn pro")) {
            return "Cloudflare Pro CDN"
        }
        if host == "v1.uhdgo.com" || (host.contains("uhd") && (lower.contains("备用") || lower == "cf cdn" || lower == "cloudflare cdn")) {
            return "Cloudflare CDN"
        }
        if let range = trimmed.range(of: " · ") {
            let head = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { return head }
        }
        return trimmed
    }

    /// Concise host-only representation (strips `https://` / `http://` scheme prefix) for clean UI display.
    public var cleanDisplayHost: String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        else if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

public struct EmbyServerConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var note: String
    public var type: ServerType
    public var host: String
    public var port: Int
    public var isHttps: Bool
    public var path: String
    public var username: String
    public var password: String
    public var accessToken: String
    public var userId: String
    public var serverId: String
    public var serverName: String
    public var serverVersion: String
    public var iconURL: String
    public var isDefaultHome: Bool
    public var isEncrypted: Bool
    public var enableGlobalSearch: Bool
    public var strmUsePath: Bool
    public var cache302Request: Bool
    public var movieCount: Int
    public var episodeCount: Int
    public var selectedLineId: UUID?
    public var mainLineLatencyMs: Int?
    public var backupLines: [ServerLineInfo]
    public var lastExtDomainSyncDate: Date?
    public var lastWatchedDate: Date?
    public var isDemoServer: Bool
    public var keepSignedIn: Bool
    public var lastLoginDate: Date?
    public var tokenExpiresAt: String?

    public init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        type: ServerType = .emby,
        host: String,
        port: Int = 443,
        isHttps: Bool = true,
        path: String = "",
        username: String,
        password: String = "",
        accessToken: String = "",
        userId: String = "",
        serverId: String = "",
        serverName: String = "",
        serverVersion: String = "",
        iconURL: String = "uhd",
        isDefaultHome: Bool = false,
        isEncrypted: Bool = false,
        enableGlobalSearch: Bool = true,
        strmUsePath: Bool = false,
        cache302Request: Bool = true,
        movieCount: Int = 0,
        episodeCount: Int = 0,
        selectedLineId: UUID? = nil,
        mainLineLatencyMs: Int? = nil,
        backupLines: [ServerLineInfo] = [],
        lastExtDomainSyncDate: Date? = nil,
        lastWatchedDate: Date? = nil,
        isDemoServer: Bool = false,
        keepSignedIn: Bool = true,
        lastLoginDate: Date? = nil,
        tokenExpiresAt: String? = nil
    ) {
        self.id = id; self.name = name; self.note = note; self.type = type; self.host = host; self.port = port; self.isHttps = isHttps; self.path = path; self.username = username; self.password = password; self.accessToken = accessToken; self.userId = userId; self.serverId = serverId; self.serverName = serverName; self.serverVersion = serverVersion; self.iconURL = iconURL; self.isDefaultHome = isDefaultHome; self.isEncrypted = isEncrypted; self.enableGlobalSearch = enableGlobalSearch; self.strmUsePath = strmUsePath; self.cache302Request = cache302Request; self.movieCount = movieCount; self.episodeCount = episodeCount; self.selectedLineId = selectedLineId; self.mainLineLatencyMs = mainLineLatencyMs; self.backupLines = backupLines; self.lastExtDomainSyncDate = lastExtDomainSyncDate; self.lastWatchedDate = lastWatchedDate; self.isDemoServer = isDemoServer; self.keepSignedIn = keepSignedIn; self.lastLoginDate = lastLoginDate; self.tokenExpiresAt = tokenExpiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.type = try c.decodeIfPresent(ServerType.self, forKey: .type) ?? .emby
        self.host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 443
        self.isHttps = try c.decodeIfPresent(Bool.self, forKey: .isHttps) ?? true
        self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        self.userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? ""
        self.serverId = try c.decodeIfPresent(String.self, forKey: .serverId) ?? ""
        self.serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        self.serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        self.iconURL = try c.decodeIfPresent(String.self, forKey: .iconURL) ?? "uhd"
        self.isDefaultHome = try c.decodeIfPresent(Bool.self, forKey: .isDefaultHome) ?? false
        self.isEncrypted = try c.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        self.enableGlobalSearch = try c.decodeIfPresent(Bool.self, forKey: .enableGlobalSearch) ?? true
        self.strmUsePath = try c.decodeIfPresent(Bool.self, forKey: .strmUsePath) ?? false
        self.cache302Request = try c.decodeIfPresent(Bool.self, forKey: .cache302Request) ?? true
        self.movieCount = try c.decodeIfPresent(Int.self, forKey: .movieCount) ?? 0
        self.episodeCount = try c.decodeIfPresent(Int.self, forKey: .episodeCount) ?? 0
        self.selectedLineId = try c.decodeIfPresent(UUID.self, forKey: .selectedLineId)
        self.mainLineLatencyMs = try c.decodeIfPresent(Int.self, forKey: .mainLineLatencyMs)
        self.backupLines = try c.decodeIfPresent([ServerLineInfo].self, forKey: .backupLines) ?? []
        self.lastExtDomainSyncDate = try c.decodeIfPresent(Date.self, forKey: .lastExtDomainSyncDate)
        self.lastWatchedDate = try c.decodeIfPresent(Date.self, forKey: .lastWatchedDate)
        self.isDemoServer = try c.decodeIfPresent(Bool.self, forKey: .isDemoServer) ?? false
        self.keepSignedIn = try c.decodeIfPresent(Bool.self, forKey: .keepSignedIn) ?? true
        self.lastLoginDate = try c.decodeIfPresent(Date.self, forKey: .lastLoginDate)
        self.tokenExpiresAt = try c.decodeIfPresent(String.self, forKey: .tokenExpiresAt)
    }

    public var mainLineURL: String {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.hasPrefix("http://") { cleanHost = String(cleanHost.dropFirst(7)) }
        else if cleanHost.hasPrefix("https://") { cleanHost = String(cleanHost.dropFirst(8)) }
        while cleanHost.hasSuffix("/") { cleanHost.removeLast() }
        let scheme = isHttps ? "https" : "http"
        let defaultPort = isHttps ? 443 : 80
        let portPart = (port == defaultPort || port <= 0) ? "" : ":\(port)"
        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPath.isEmpty && !cleanPath.hasPrefix("/") { cleanPath = "/" + cleanPath }
        return ServerLineInfo.normalizeBaseURL("\(scheme)://\(cleanHost)\(portPart)\(cleanPath)")
    }

    public var activeBaseURL: String {
        if let selectedLineId, let line = backupLines.first(where: { $0.id == selectedLineId }) { return line.url }
        return mainLineURL
    }

    public var activeLineName: String {
        if let selectedLineId, let line = backupLines.first(where: { $0.id == selectedLineId }) { return line.cleanDisplayName }
        return "主线路"
    }

    public var autoSyncedLineCount: Int { backupLines.filter(\.isAutoSynced).count }

    public var relativeWatchTimeText: String {
        guard let date = lastWatchedDate else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 120 { return "刚刚观看" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 30 { return "\(days)天前" }
        let months = days / 30
        if months < 12 { return "\(months)月前" }
        return "\(months / 12)年前"
    }

    public var usesUHDLogo: Bool {
        if type == .uhdNative { return true }
        if iconURL == "emby" { return false }
        return iconURL == "uhd" || name.uppercased().contains("UHD") || host.lowercased().contains("uhd")
    }

    public mutating func mergeExtDomains(_ domains: [EmbyExtDomainItem]) {
        let manualLines = backupLines.filter { !$0.isAutoSynced }
        let existingAutoByURL = Dictionary(uniqueKeysWithValues: backupLines.filter(\.isAutoSynced).map { ($0.url.lowercased(), $0) })
        let manualURLs = Set(manualLines.map { $0.url.lowercased() })
        let mainURL = mainLineURL.lowercased()

        var syncedLines: [ServerLineInfo] = []
        for item in domains {
            let normalizedURL = ServerLineInfo.normalizeBaseURL(item.url)
            guard !normalizedURL.isEmpty else { continue }
            let lower = normalizedURL.lowercased()
            if manualURLs.contains(lower) { continue }
            if let existing = existingAutoByURL[lower] {
                var updated = existing
                updated.name = item.name.isEmpty ? existing.name : item.name
                updated.url = normalizedURL
                updated.isAutoSynced = true
                syncedLines.append(updated)
            } else {
                if lower == mainURL && domains.count == 1 { continue }
                syncedLines.append(ServerLineInfo(name: item.name.isEmpty ? "云端线路 \(syncedLines.count + 1)" : item.name, url: normalizedURL, isAutoSynced: true))
            }
        }
        self.backupLines = manualLines + syncedLines
        self.lastExtDomainSyncDate = Date()
        if let selectedLineId, !self.backupLines.contains(where: { $0.id == selectedLineId }) { self.selectedLineId = nil }
    }
}

public struct EmbyAuthenticateResponse: Codable, Sendable {
    public let user: EmbyUser?
    public let accessToken: String?
    public let serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
    public init(user: EmbyUser? = nil, accessToken: String? = nil, serverId: String? = nil) {
        self.user = user; self.accessToken = accessToken; self.serverId = serverId
    }
}

public struct EmbyUser: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let serverId: String?
    public let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
    }
    public init(id: String, name: String, serverId: String? = nil, primaryImageTag: String? = nil) {
        self.id = id; self.name = name; self.serverId = serverId; self.primaryImageTag = primaryImageTag
    }
}

public struct EmbySystemInfo: Codable, Sendable, Hashable {
    public let id: String?
    public let serverName: String?
    public let version: String?
    public let operatingSystemDisplayName: String?
    public let localAddress: String?
    public let wanAddress: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case operatingSystemDisplayName = "OperatingSystemDisplayName"
        case localAddress = "LocalAddress"
        case wanAddress = "WanAddress"
    }
    public init(id: String? = nil, serverName: String? = nil, version: String? = nil, operatingSystemDisplayName: String? = nil, localAddress: String? = nil, wanAddress: String? = nil) {
        self.id = id; self.serverName = serverName; self.version = version; self.operatingSystemDisplayName = operatingSystemDisplayName; self.localAddress = localAddress; self.wanAddress = wanAddress
    }
}

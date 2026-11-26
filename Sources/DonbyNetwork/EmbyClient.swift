import Foundation
import DonbyCore

public actor RedirectCacheStore {
    public static let shared = RedirectCacheStore()
    private var cache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let maxEntries = 256

    private init() {}

    public func cachedRedirect(for key: String) -> URL? {
        if let entry = cache[key], entry.expiresAt > Date() {
            return entry.url
        }
        cache.removeValue(forKey: key)
        if let warm = NetworkRouteWarmStore.shared.cachedRedirect(for: key) {
            cache[key] = (url: warm, expiresAt: Date().addingTimeInterval(900))
            return warm
        }
        return nil
    }

    public func storeRedirect(_ url: URL, for key: String, ttlSeconds: TimeInterval = 1800) {
        let now = Date()
        if cache.count >= Self.maxEntries {
            cache = cache.filter { $0.value.expiresAt > now }
            if cache.count >= Self.maxEntries,
               let oldestKey = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
        cache[key] = (url: url, expiresAt: now.addingTimeInterval(ttlSeconds))
        NetworkRouteWarmStore.shared.storeRedirect(url, for: key, ttlSeconds: ttlSeconds)
    }

    public func invalidateRedirect(for key: String) {
        cache.removeValue(forKey: key)
        NetworkRouteWarmStore.shared.invalidateRedirect(for: key)
    }
}

private actor EmbyHostWarmCache {
    static let shared = EmbyHostWarmCache()
    private var lastWarmedAt: [String: Date] = [:]

    func shouldWarm(baseURL: String) -> Bool {
        let now = Date()
        if let prev = lastWarmedAt[baseURL], now.timeIntervalSince(prev) < 120 {
            return false
        }
        lastWarmedAt[baseURL] = now
        return true
    }
}

public final class EmbyClient: Sendable {
    public static let shared = EmbyClient()

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public let clientName = "Donby"
    public var appVersion: String {
        DonbyAppInfo.version
    }
    public let deviceName: String
    public let deviceId: String
    let apiSession: URLSession
    let noRedirectSession: URLSession
    let deviceProfilePayloadData: Data?

    private init() {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceName = host.isEmpty ? "Mac" : host

        self.apiSession = TurboStreamingSessionHub.shared.sharedURLSession

        let redirectConfig = URLSessionConfiguration.ephemeral
        redirectConfig.timeoutIntervalForRequest = 4.0
        self.noRedirectSession = URLSession(configuration: redirectConfig, delegate: NoRedirectDelegate(), delegateQueue: nil)

        let profilePayload: [String: Any] = [
            "DeviceProfile": [
                "Name": "Donby-Mac-DirectPlay",
                "MaxStreamingBitrate": 200_000_000,
                "MaxStaticBitrate": 200_000_000,
                "DirectPlayProfiles": [
                    [
                        "Container": "mkv,mp4,mov,m4v,webm,avi,ts,m2ts,flv,wmv,iso",
                        "Type": "Video",
                        "VideoCodec": "hevc,h264,dvhe,dvh1,hev1,av1,vp9,mpeg4",
                        "AudioCodec": "eac3,ac3,aac,flac,truehd,dts,dca,opus,mp3,pcm,alac"
                    ]
                ],
                "SubtitleProfiles": [
                    ["Format": "srt", "Method": "External"],
                    ["Format": "ass", "Method": "External"],
                    ["Format": "subrip", "Method": "Embed"],
                    ["Format": "pgssub", "Method": "Embed"]
                ]
            ]
        ]
        self.deviceProfilePayloadData = try? JSONSerialization.data(withJSONObject: profilePayload)

        if let saved = UserDefaults.standard.string(forKey: "donby.deviceId"), !saved.isEmpty {
            self.deviceId = saved
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: "donby.deviceId")
            self.deviceId = generated
        }
    }

    public func buildAuthorizationHeader(userId: String = "", token: String = "") -> String {
        var parts: [String] = [
            "Client=\"\(clientName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(appVersion)\""
        ]
        if !userId.isEmpty { parts.append("UserId=\"\(userId)\"") }
        if !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    func makeRequest(
        baseURL: String,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        token: String = "",
        userId: String = "",
        includeTokenInQuery: Bool = false,
        bodyData: Data? = nil,
        timeout: TimeInterval = 15
    ) throws -> URLRequest {
        let normalizedBase = ServerLineInfo.normalizeBaseURL(baseURL)
        let prefix = path.hasPrefix("/emby") ? "" : "/emby"
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        let fullURLString = normalizedBase + prefix + cleanPath

        guard var components = URLComponents(string: fullURLString) else {
            throw EmbyClientError.invalidServerURL(fullURLString)
        }

        var allQueryItems = queryItems
        if includeTokenInQuery && !token.isEmpty {
            allQueryItems.append(URLQueryItem(name: "X-Emby-Token", value: token))
            allQueryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        if !allQueryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + allQueryItems
        }

        guard let url = components.url else {
            throw EmbyClientError.invalidServerURL(fullURLString)
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(buildAuthorizationHeader(userId: userId, token: token), forHTTPHeaderField: "X-Emby-Authorization")
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if let bodyData {
            req.httpBody = bodyData
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    func requestJSON<T: Decodable>(
        _ type: T.Type,
        for req: URLRequest,
        priority: APIRequestGate.Priority = .normal
    ) async throws -> T {
        try await APIRequestGate.shared.withPermit(priority: priority) {
            let (data, response) = try await self.apiSession.data(for: req)
            try self.validateResponse(response)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw EmbyClientError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            throw EmbyClientError.httpStatus(http.statusCode, "")
        }
    }

    public func fetchUserDownloadPermission(server: EmbyServerConfig) async -> Bool {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !server.userId.isEmpty,
              let req = try? makeRequest(
                baseURL: server.activeBaseURL,
                path: "/Users/\(server.userId)",
                token: server.accessToken,
                userId: server.userId,
                timeout: 10
              ) else {
            return true
        }
        struct EmbyUserPolicyWrapper: Decodable {
            struct Policy: Decodable {
                let enableContentDownloading: Bool?
                enum CodingKeys: String, CodingKey {
                    case enableContentDownloading = "EnableContentDownloading"
                }
            }
            let policy: Policy?
            enum CodingKeys: String, CodingKey { case policy = "Policy" }
        }
        guard let decoded = try? await requestJSON(EmbyUserPolicyWrapper.self, for: req, priority: .normal) else {
            return true
        }
        return decoded.policy?.enableContentDownloading ?? true
    }

    public func authenticate(
        baseURL: String,
        username: String,
        password: String
    ) async throws -> EmbyAuthenticateResponse {
        let payload = ["Username": username, "Pw": password]
        let body = try JSONEncoder().encode(payload)
        let req = try makeRequest(
            baseURL: baseURL,
            path: "/Users/AuthenticateByName",
            method: "POST",
            bodyData: body,
            timeout: 12
        )
        let (data, response) = try await apiSession.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 { throw EmbyClientError.unauthorized }
            throw EmbyClientError.httpStatus(http.statusCode, "认证失败")
        }
        let decoded = try JSONDecoder().decode(EmbyAuthenticateResponse.self, from: data)
        guard let token = decoded.accessToken, !token.isEmpty else {
            throw EmbyClientError.emptyToken
        }
        return decoded
    }

    public func fetchExtServerDomains(
        baseURL: String,
        token: String,
        userId: String = ""
    ) async -> [EmbyExtDomainItem]? {
        let candidatePaths = [
            "/System/Ext/ServerDomains",
            "/Ext/ServerDomains",
            "/System/ServerDomains",
            "/ServerDomains"
        ]

        for p in candidatePaths {
            do {
                let req = try makeRequest(
                    baseURL: baseURL,
                    path: p,
                    method: "GET",
                    token: token,
                    userId: userId,
                    includeTokenInQuery: true,
                    timeout: 6
                )
                let (data, response) = try await apiSession.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }

                // Format A: {"ok": true, "data": [...]}
                if let decoded = try? JSONDecoder().decode(EmbyExtServerDomainsResponse.self, from: data),
                   let domains = decoded.data, !domains.isEmpty {
                    return domains
                }

                // Format B: Direct array of items [{...}, {...}]
                if let list = try? JSONDecoder().decode([EmbyExtDomainItem].self, from: data), !list.isEmpty {
                    return list
                }

                // Format C: Generic JSON object with nested list under data/domains/lines/items
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let possibleKeys = ["data", "domains", "lines", "items", "servers", "nodes"]
                    for key in possibleKeys {
                        if let arr = obj[key] as? [[String: Any]],
                           let subData = try? JSONSerialization.data(withJSONObject: arr),
                           let items = try? JSONDecoder().decode([EmbyExtDomainItem].self, from: subData),
                           !items.isEmpty {
                            return items
                        }
                    }
                }

                // Format D: Plain text lines of domains/URLs
                if let text = String(data: data, encoding: .utf8) {
                    let lines = text.components(separatedBy: .newlines)
                    var items: [EmbyExtDomainItem] = []
                    for rawLine in lines {
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty && !line.hasPrefix("#") else { continue }
                        let urlStr = line.contains("://") ? line : "https://\(line)"
                        items.append(EmbyExtDomainItem(name: line, url: urlStr))
                    }
                    if !items.isEmpty { return items }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    public func fetchUsersWithToken(
        baseURL: String,
        token: String
    ) async -> [EmbyUser] {
        guard !token.isEmpty else { return [] }
        for path in ["/Users", "/Users/Public"] {
            if let req = try? makeRequest(baseURL: baseURL, path: path, token: token, includeTokenInQuery: true, timeout: 8),
               let (data, response) = try? await apiSession.data(for: req),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let users = try? JSONDecoder().decode([EmbyUser].self, from: data), !users.isEmpty {
                return users
            }
        }
        return []
    }

    public func pingLine(baseURL: String, token: String = "", timeout: TimeInterval = 4.0) async -> Int? {
        let start = DispatchTime.now()
        do {
            let path = token.isEmpty ? "/System/Info/Public" : "/System/Info"
            let req = try makeRequest(
                baseURL: baseURL,
                path: path,
                method: "GET",
                token: token,
                timeout: max(1.0, timeout)
            )
            let (_, response) = try await apiSession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...404).contains(http.statusCode) else {
                return nil
            }
            let elapsedNano = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            return max(1, Int(elapsedNano / 1_000_000))
        } catch {
            return nil
        }
    }

    public func fetchSystemInfo(server: EmbyServerConfig) async throws -> EmbySystemInfo {
        do {
            let req = try makeRequest(
                baseURL: server.activeBaseURL,
                path: "/System/Info",
                token: server.accessToken,
                userId: server.userId,
                includeTokenInQuery: true,
                timeout: 10
            )
            return try await requestJSON(EmbySystemInfo.self, for: req)
        } catch {
            // Fallback for non-admin tokens or public endpoints
            let fallbackReq = try makeRequest(
                baseURL: server.activeBaseURL,
                path: "/System/Info/Public",
                token: server.accessToken,
                includeTokenInQuery: true,
                timeout: 8
            )
            return try await requestJSON(EmbySystemInfo.self, for: fallbackReq)
        }
    }

    public func prewarmConnection(server: EmbyServerConfig) async {
        guard !isUHDNativeExtensionActive(for: server), !server.host.isEmpty else { return }
        let base = server.activeBaseURL
        guard await EmbyHostWarmCache.shared.shouldWarm(baseURL: base) else { return }
        guard let req = try? makeRequest(
            baseURL: base,
            path: "/System/Info/Public",
            token: server.accessToken,
            userId: server.userId,
            timeout: 4
        ) else { return }
        _ = try? await apiSession.data(for: req)
    }

    public static let standardItemFields = "BasicSyncInfo,Overview,CollectionType,PrimaryImageAspectRatio,UserData,CommunityRating,CriticRating,ProviderIds,Genres,Studios,ProductionYear,PremiereDate,RunTimeTicks,OriginalTitle,ChildCount,RecursiveItemCount,Container,OfficialRating,MediaSources,MediaStreams,DateCreated,ParentId,SeriesName,SeriesId,SeasonId,IndexNumber,ParentIndexNumber"
    public static let detailItemFields = "BasicSyncInfo,RunTimeTicks,CommunityRating,CriticRating,ProviderIds,ProductionYear,PremiereDate,EndDate,Status,Container,Overview,Taglines,UserData,MediaSources,MediaStreams,People,DateCreated,Path,ParentId,Studios,Genres,OfficialRating,Chapters,OriginalTitle,SeriesName,SeriesId,SeasonId,IndexNumber,ParentIndexNumber"
    static let standardBrowseQueryItems: [URLQueryItem] = [
        URLQueryItem(name: "Fields", value: standardItemFields),
        URLQueryItem(name: "ImageTypeLimit", value: "1"),
        URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
    ]
}

import Foundation
import DonbyCore

public actor RedirectCacheStore {
    public static let shared = RedirectCacheStore()
    private var cache: [String: (url: URL, expiresAt: Date)] = [:]

    private init() {}

    public func cachedRedirect(for key: String) -> URL? {
        if let entry = cache[key], entry.expiresAt > Date() {
            return entry.url
        }
        cache.removeValue(forKey: key)
        return nil
    }

    public func storeRedirect(_ url: URL, for key: String, ttlSeconds: TimeInterval = 1800) {
        cache[key] = (url: url, expiresAt: Date().addingTimeInterval(ttlSeconds))
    }

    public func clearAll() {
        cache.removeAll()
    }
}

public final class EmbyClient: Sendable {
    public static let shared = EmbyClient()

    public let clientName = "Donby"
    public var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.12"
    }
    public let deviceName: String
    public let deviceId: String

    private init() {
        self.deviceName = Host.current().localizedName ?? "Mac"
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

    private func makeRequest(
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
        let (data, response) = try await URLSession.shared.data(for: req)
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
                let (data, response) = try await URLSession.shared.data(for: req)
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
        // 1. Try /Users
        if let req = try? makeRequest(baseURL: baseURL, path: "/Users", token: token, includeTokenInQuery: true, timeout: 8),
           let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let users = try? JSONDecoder().decode([EmbyUser].self, from: data), !users.isEmpty {
            return users
        }
        // 2. Try /Users/Public
        if let req = try? makeRequest(baseURL: baseURL, path: "/Users/Public", token: token, includeTokenInQuery: true, timeout: 8),
           let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let users = try? JSONDecoder().decode([EmbyUser].self, from: data), !users.isEmpty {
            return users
        }
        return []
    }

    public func pingLine(baseURL: String, token: String = "") async -> Int? {
        let start = DispatchTime.now()
        do {
            let path = token.isEmpty ? "/System/Info/Public" : "/System/Info"
            let req = try makeRequest(
                baseURL: baseURL,
                path: path,
                method: "GET",
                token: token,
                timeout: 4.0
            )
            let (_, response) = try await URLSession.shared.data(for: req)
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
            let (data, response) = try await URLSession.shared.data(for: req)
            try validateResponse(response)
            return try JSONDecoder().decode(EmbySystemInfo.self, from: data)
        } catch {
            // Fallback for non-admin tokens or public endpoints
            let fallbackReq = try makeRequest(
                baseURL: server.activeBaseURL,
                path: "/System/Info/Public",
                token: server.accessToken,
                includeTokenInQuery: true,
                timeout: 8
            )
            let (data, response) = try await URLSession.shared.data(for: fallbackReq)
            try validateResponse(response)
            return try JSONDecoder().decode(EmbySystemInfo.self, from: data)
        }
    }

    public func fetchCounts(server: EmbyServerConfig) async throws -> EmbyCountsResponse {
        let query = server.userId.isEmpty ? [] : [URLQueryItem(name: "UserId", value: server.userId)]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Items/Counts",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId,
            timeout: 10
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyCountsResponse.self, from: data)
    }

    public func fetchViews(server: EmbyServerConfig) async throws -> [EmbyItem] {
        var targetUserId = server.userId
        if targetUserId.isEmpty && !server.accessToken.isEmpty {
            let users = await fetchUsersWithToken(baseURL: server.activeBaseURL, token: server.accessToken)
            if let firstUser = users.first {
                targetUserId = firstUser.id
            }
        }

        let path = targetUserId.isEmpty ? "/Views" : "/Users/\(targetUserId)/Views"
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: path,
            token: server.accessToken,
            userId: targetUserId,
            includeTokenInQuery: true
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data).items
    }

    public func fetchResumeItems(server: EmbyServerConfig, limit: Int = 16) async throws -> [EmbyItem] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: Self.standardItemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "MediaTypes", value: "Video")
        ]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/Items/Resume",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data).items
    }

    public func fetchNextUp(server: EmbyServerConfig, limit: Int = 16) async throws -> [EmbyItem] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.standardItemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
        ]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Shows/NextUp",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data).items
    }

    public func fetchLatestItems(
        server: EmbyServerConfig,
        parentId: String,
        limit: Int = 18,
        hidePlayed: Bool = false
    ) async throws -> [EmbyItem] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.standardItemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "GroupItems", value: "true")
        ]
        if hidePlayed { query.append(URLQueryItem(name: "IsPlayed", value: "false")) }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/Items/Latest",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode([EmbyItem].self, from: data)
    }

    public func fetchItems(
        server: EmbyServerConfig,
        parentId: String? = nil,
        includeItemTypes: String = "Movie,Series,Video",
        sortBy: String = "DateCreated,SortName",
        sortOrder: String = "Descending",
        filters: String? = nil,
        isFavorite: Bool? = nil,
        searchTerm: String? = nil,
        startIndex: Int = 0,
        limit: Int = 60,
        recursive: Bool = true
    ) async throws -> EmbyItemsResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.standardItemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
        ]
        if let parentId, !parentId.isEmpty { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if let filters, !filters.isEmpty { query.append(URLQueryItem(name: "Filters", value: filters)) }
        if let isFavorite { query.append(URLQueryItem(name: "IsFavorite", value: isFavorite ? "true" : "false")) }
        if let searchTerm, !searchTerm.isEmpty { query.append(URLQueryItem(name: "SearchTerm", value: searchTerm)) }

        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/Items",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
    }

    public func fetchItemDetail(server: EmbyServerConfig, itemId: String) async throws -> EmbyItem {
        let query = [URLQueryItem(name: "Fields", value: Self.detailItemFields)]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/Items/\(itemId)",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItem.self, from: data)
    }

    public func fetchSeasons(server: EmbyServerConfig, seriesId: String) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Fields", value: "BasicSyncInfo,Overview,PrimaryImageAspectRatio,UserData,ChildCount")
        ]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Shows/\(seriesId)/Seasons",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data).items
    }

    public func fetchEpisodes(server: EmbyServerConfig, seriesId: String, seasonId: String? = nil) async throws -> [EmbyItem] {
        var query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Fields", value: Self.detailItemFields)
        ]
        if let seasonId, !seasonId.isEmpty { query.append(URLQueryItem(name: "SeasonId", value: seasonId)) }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Shows/\(seriesId)/Episodes",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data).items
    }

    public func fetchSimilarItems(server: EmbyServerConfig, itemId: String, limit: Int = 12) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.standardItemFields)
        ]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Items/\(itemId)/Similar",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data).items
    }

    public func fetchPlaybackInfo(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> EmbyPlaybackInfoResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "AutoOpenLiveStream", value: "true"),
            URLQueryItem(name: "IsPlayback", value: "true")
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId)) }
        if let audioStreamIndex { query.append(URLQueryItem(name: "AudioStreamIndex", value: "\(audioStreamIndex)")) }
        if let subtitleStreamIndex { query.append(URLQueryItem(name: "SubtitleStreamIndex", value: "\(subtitleStreamIndex)")) }

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
        let body = try JSONSerialization.data(withJSONObject: profilePayload)
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Items/\(itemId)/PlaybackInfo",
            method: "POST",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId,
            bodyData: body,
            timeout: 15
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
        return try JSONDecoder().decode(EmbyPlaybackInfoResponse.self, from: data)
    }

    public func resolvePlaybackResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> ResolvedPlaybackResource {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbyClientError.noPlayableStream
        }

        let effectivePreferredId: String? = {
            if let pref = preferredSourceId, !pref.isEmpty { return pref }
            return item.mediaSources?.preferredSource(for: preferredPreset)?.id
        }()

        let playbackInfo = try? await fetchPlaybackInfo(
            server: server,
            itemId: item.id,
            mediaSourceId: effectivePreferredId,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex
        )

        let allSources = playbackInfo?.mediaSources ?? item.mediaSources ?? []
        let resolvedSource: MediaSourceInfo? = {
            if let pref = preferredSourceId, !pref.isEmpty,
               let exact = allSources.first(where: { $0.id == pref }) {
                return exact
            }
            return allSources.preferredSource(for: preferredPreset) ?? allSources.first
        }()
        guard let selectedSource = resolvedSource else {
            throw EmbyClientError.noPlayableStream
        }

        let playSessionId = playbackInfo?.playSessionId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var headers = selectedSource.requiredHttpHeaders ?? [:]
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = "Donby/\(appVersion) (macOS; UHDNow Client)"
        }

        let baseURL = server.activeBaseURL
        var candidateURLString: String?
        var routeNote = "DirectStream (\(server.activeLineName))"

        if server.strmUsePath, let path = selectedSource.path, path.hasPrefix("http") {
            candidateURLString = path
            routeNote = "STRM 原始直链"
        }

        if candidateURLString == nil {
            if let xOrigin = selectedSource.xOriginDirectStreamUrl, !xOrigin.isEmpty {
                candidateURLString = resolveRelativeOrAbsoluteURL(xOrigin, baseURL: baseURL, token: server.accessToken)
                routeNote = "UHD XOrigin (\(selectedSource.xRouteMode ?? server.activeLineName))"
            } else if let direct = selectedSource.directStreamUrl, !direct.isEmpty {
                candidateURLString = resolveRelativeOrAbsoluteURL(direct, baseURL: baseURL, token: server.accessToken)
                if let mode = selectedSource.xRouteMode, !mode.isEmpty { routeNote = "UHD \(mode)" }
            } else if let path = selectedSource.path, path.hasPrefix("http") {
                candidateURLString = path
                routeNote = "远程直连"
            } else if let transcode = selectedSource.transcodingUrl, !transcode.isEmpty {
                candidateURLString = resolveRelativeOrAbsoluteURL(transcode, baseURL: baseURL, token: server.accessToken)
                routeNote = "云端转码流"
            } else {
                let ext = selectedSource.container ?? item.container ?? "mkv"
                candidateURLString = "\(baseURL)/emby/Videos/\(item.id)/stream.\(ext)?Static=true&MediaSourceId=\(selectedSource.id)&PlaySessionId=\(playSessionId)&api_key=\(server.accessToken)"
            }
        }

        guard let finalString = candidateURLString, let initialURL = URL(string: finalString) else {
            throw EmbyClientError.noPlayableStream
        }

        var resolvedURL = initialURL
        let cacheKey = "\(server.id.uuidString)|\(item.id)|\(selectedSource.id)|\(baseURL)"
        if server.cache302Request {
            if let cached = await RedirectCacheStore.shared.cachedRedirect(for: cacheKey) {
                resolvedURL = cached
                routeNote += " · 302缓存命中"
            } else if let redirected = await probe302Redirect(url: initialURL, headers: headers) {
                resolvedURL = redirected
                await RedirectCacheStore.shared.storeRedirect(redirected, for: cacheKey)
                routeNote += " · 302直连"
            }
        }

        var subtitleURLs: [SubtitleResourceItem] = []
        for stream in selectedSource.mediaStreams ?? [] where stream.type?.lowercased() == "subtitle" {
            let lowerCodec = (stream.codec ?? "").lowercased()
            let isBitmapSub = lowerCodec.contains("pgs") || lowerCodec.contains("dvd") || lowerCodec.contains("dvb") || lowerCodec.contains("vobsub")
            if isBitmapSub { continue }
            let isExt = (stream.isExternal == true)
            if let deliv = stream.deliveryUrl, !deliv.isEmpty {
                let lowerDeliv = deliv.lowercased()
                let looksLikeTextSub = isExt || lowerDeliv.contains(".srt") || lowerDeliv.contains(".ass") || lowerDeliv.contains(".ssa") || lowerDeliv.contains(".vtt")
                guard looksLikeTextSub else { continue }
                let fullSub = resolveRelativeOrAbsoluteURL(deliv, baseURL: baseURL, token: server.accessToken)
                if let subURL = URL(string: fullSub) {
                    subtitleURLs.append(SubtitleResourceItem(
                        name: stream.readableLabel,
                        url: subURL,
                        streamIndex: stream.index,
                        codec: stream.codec,
                        isExternal: isExt
                    ))
                }
            }
        }

        return ResolvedPlaybackResource(
            streamURL: resolvedURL,
            headers: headers,
            playSessionId: playSessionId,
            mediaSource: selectedSource,
            subtitleURLs: subtitleURLs,
            isDirectStream: selectedSource.transcodingUrl == nil,
            routeNote: routeNote
        )
    }

    private func resolveRelativeOrAbsoluteURL(_ raw: String, baseURL: String, token: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        let cleanBase = ServerLineInfo.normalizeBaseURL(baseURL)
        let prefix: String
        if raw.hasPrefix("/emby/") || raw.hasPrefix("emby/") {
            prefix = raw.hasPrefix("/") ? "" : "/"
        } else {
            prefix = raw.hasPrefix("/") ? "/emby" : "/emby/"
        }
        var combined = cleanBase + prefix + raw
        if !token.isEmpty && !combined.contains("api_key=") && !combined.contains("X-Emby-Token=") {
            let sep = combined.contains("?") ? "&" : "?"
            combined += "\(sep)api_key=\(token)"
        }
        return combined
    }

    private func probe302Redirect(url: URL, headers: [String: String]) async -> URL? {
        final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, (300...399).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               let redirectURL = URL(string: loc, relativeTo: url)?.absoluteURL {
                return redirectURL
            }
        } catch { return nil }
        return nil
    }

    public func reportPlaybackStart(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionSeconds: Double
    ) async {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !server.accessToken.isEmpty else { return }
        await sendSessionPayload(server: server, path: "/Sessions/Playing", itemId: itemId, mediaSourceId: mediaSourceId, playSessionId: playSessionId, positionSeconds: positionSeconds, isPaused: false)
    }

    public func reportPlaybackProgress(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !server.accessToken.isEmpty else { return }
        await sendSessionPayload(server: server, path: "/Sessions/Playing/Progress", itemId: itemId, mediaSourceId: mediaSourceId, playSessionId: playSessionId, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    public func reportPlaybackStopped(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionSeconds: Double
    ) async {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !server.accessToken.isEmpty else { return }
        await sendSessionPayload(server: server, path: "/Sessions/Playing/Stopped", itemId: itemId, mediaSourceId: mediaSourceId, playSessionId: playSessionId, positionSeconds: positionSeconds, isPaused: false)
    }

    private func sendSessionPayload(
        server: EmbyServerConfig,
        path: String,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        let ticks = Int64(max(0, positionSeconds) * 10_000_000)
        let payload: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PlaySessionId": playSessionId,
            "PositionTicks": ticks,
            "IsPaused": isPaused,
            "PlayMethod": "DirectStream",
            "CanSeek": true
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let req = try? makeRequest(
                baseURL: server.activeBaseURL,
                path: path,
                method: "POST",
                token: server.accessToken,
                userId: server.userId,
                bodyData: body,
                timeout: 8
              ) else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    public func setFavorite(server: EmbyServerConfig, itemId: String, isFavorite: Bool) async throws {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/FavoriteItems/\(itemId)",
            method: isFavorite ? "POST" : "DELETE",
            token: server.accessToken,
            userId: server.userId
        )
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
    }

    public func setPlayed(server: EmbyServerConfig, itemId: String, played: Bool) async throws {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/PlayedItems/\(itemId)",
            method: played ? "POST" : "DELETE",
            token: server.accessToken,
            userId: server.userId
        )
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateResponse(response)
    }

    public func imageURL(
        server: EmbyServerConfig,
        itemId: String,
        kind: EmbyImageKind = .primary,
        maxWidth: Int = 600
    ) -> URL? {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let base = server.activeBaseURL
        let imageTypePath: String
        switch kind {
        case .primary: imageTypePath = "Primary"
        case .backdrop: imageTypePath = "Backdrop/0"
        case .thumb: imageTypePath = "Thumb"
        case .logo: imageTypePath = "Logo"
        }
        var urlStr = "\(base)/emby/Items/\(itemId)/Images/\(imageTypePath)?maxWidth=\(maxWidth)&quality=90"
        if !server.accessToken.isEmpty { urlStr += "&api_key=\(server.accessToken)" }
        return URL(string: urlStr)
    }

    public func imageURL(
        server: EmbyServerConfig,
        item: EmbyItem,
        kind: EmbyImageKind = .primary,
        maxWidth: Int = 600
    ) -> URL? {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let base = server.activeBaseURL
        var targetItemId = item.id
        var tag: String?

        switch kind {
        case .primary:
            if item.isEpisode, let seriesId = item.seriesId, item.imageTags?["Primary"] == nil {
                targetItemId = seriesId
                tag = item.seriesPrimaryImageTag
            } else {
                tag = item.imageTags?["Primary"]
            }
        case .backdrop:
            if let bTag = item.backdropImageTags?.first { tag = bTag }
            else if let pId = item.parentBackdropItemId, let pTag = item.parentBackdropImageTags?.first {
                targetItemId = pId
                tag = pTag
            } else if item.isEpisode, let seriesId = item.seriesId {
                targetItemId = seriesId
                tag = nil
            } else if let pId = item.parentBackdropItemId {
                targetItemId = pId
                tag = nil
            } else {
                tag = nil
            }
        case .thumb:
            if let tTag = item.imageTags?["Thumb"] { tag = tTag }
            else if item.backdropImageTags?.first != nil {
                return imageURL(server: server, item: item, kind: .backdrop, maxWidth: maxWidth)
            } else { tag = item.imageTags?["Primary"] }
        case .logo:
            tag = item.imageTags?["Logo"]
        }

        let imageTypePath: String
        switch kind {
        case .primary: imageTypePath = "Primary"
        case .backdrop: imageTypePath = "Backdrop/0"
        case .thumb: imageTypePath = (item.imageTags?["Thumb"] != nil) ? "Thumb" : "Primary"
        case .logo: imageTypePath = "Logo"
        }

        var urlStr = "\(base)/emby/Items/\(targetItemId)/Images/\(imageTypePath)?maxWidth=\(maxWidth)&quality=90"
        if let tag, !tag.isEmpty { urlStr += "&tag=\(tag)" }
        if !server.accessToken.isEmpty { urlStr += "&api_key=\(server.accessToken)" }
        return URL(string: urlStr)
    }

    /// Builds ordered candidate URLs for an actor/director (`EmbyPerson`) portrait across Emby, Jellyfin, and UHDNow proxies.
    public func personImageURLs(
        server: EmbyServerConfig,
        person: EmbyPerson,
        maxWidth: Int = 260
    ) -> [URL] {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let base = server.activeBaseURL
        let tokenPart = server.accessToken.isEmpty ? "" : "&api_key=\(server.accessToken)"
        var urls: [URL] = []

        if !person.id.isEmpty {
            if let tag = person.primaryImageTag, !tag.isEmpty {
                if let u = URL(string: "\(base)/emby/Items/\(person.id)/Images/Primary?maxWidth=\(maxWidth)&quality=88&tag=\(tag)\(tokenPart)") {
                    urls.append(u)
                }
            }
            if let u = URL(string: "\(base)/emby/Items/\(person.id)/Images/Primary?maxWidth=\(maxWidth)&quality=88\(tokenPart)") {
                urls.append(u)
            }
        }

        if !person.name.isEmpty,
           let encodedName = person.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            var byName = "\(base)/emby/Persons/\(encodedName)/Images/Primary?maxWidth=\(maxWidth)&quality=88\(tokenPart)"
            if let tag = person.primaryImageTag, !tag.isEmpty {
                byName += "&tag=\(tag)"
            }
            if let u = URL(string: byName) {
                urls.append(u)
            }
        }

        return urls
    }

    public func makeImageRequest(url: URL, server: EmbyServerConfig?) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Donby/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        if let server, !server.accessToken.isEmpty {
            req.setValue(server.accessToken, forHTTPHeaderField: "X-Emby-Token")
            req.setValue(buildAuthorizationHeader(userId: server.userId, token: server.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        }
        return req
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw EmbyClientError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            throw EmbyClientError.httpStatus(http.statusCode, "")
        }
    }

    public static let standardItemFields = "BasicSyncInfo,Overview,CollectionType,PrimaryImageAspectRatio,UserData,CommunityRating,CriticRating,ProviderIds,Genres,ProductionYear,ChildCount,RecursiveItemCount,Container,OfficialRating,MediaSources,MediaStreams,DateCreated,ParentId,SeriesName,SeriesId,SeasonId,IndexNumber,ParentIndexNumber"
    public static let detailItemFields = "BasicSyncInfo,RunTimeTicks,CommunityRating,CriticRating,ProviderIds,ProductionYear,PremiereDate,EndDate,Status,Container,Overview,Taglines,UserData,MediaSources,MediaStreams,People,DateCreated,Path,ParentId,Studios,Genres,OfficialRating,Chapters,OriginalTitle,SeriesName,SeriesId,SeasonId,IndexNumber,ParentIndexNumber"
}

public enum EmbyImageKind: String, Sendable {
    case primary
    case backdrop
    case thumb
    case logo
}

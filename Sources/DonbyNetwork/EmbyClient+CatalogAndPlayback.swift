import Foundation
import DonbyCore

private actor EmbyPlaybackInfoCache {
    static let shared = EmbyPlaybackInfoCache()
    private var entries: [String: (response: EmbyPlaybackInfoResponse, expiresAt: Date)] = [:]
    private static let maxEntries = 64

    private func makeKey(serverId: UUID, baseURL: String, itemId: String, mediaSourceId: String?) -> String {
        "\(serverId.uuidString)|\(baseURL)|\(itemId)|\(mediaSourceId ?? "")"
    }

    func get(serverId: UUID, baseURL: String, itemId: String, mediaSourceId: String?) -> EmbyPlaybackInfoResponse? {
        let key = makeKey(serverId: serverId, baseURL: baseURL, itemId: itemId, mediaSourceId: mediaSourceId)
        guard let hit = entries[key], hit.expiresAt > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }
        return hit.response
    }

    func set(_ response: EmbyPlaybackInfoResponse, serverId: UUID, baseURL: String, itemId: String, mediaSourceId: String?, ttlSeconds: TimeInterval = 300) {
        let key = makeKey(serverId: serverId, baseURL: baseURL, itemId: itemId, mediaSourceId: mediaSourceId)
        let now = Date()
        if entries.count >= Self.maxEntries {
            entries = entries.filter { $0.value.expiresAt > now }
            if entries.count >= Self.maxEntries, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = (response, now.addingTimeInterval(ttlSeconds))
    }

    func invalidate(serverId: UUID? = nil) {
        if let serverId {
            let prefix = "\(serverId.uuidString)|"
            entries = entries.filter { !$0.key.hasPrefix(prefix) }
        } else {
            entries.removeAll()
        }
    }
}

extension EmbyClient {
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
        return try await requestJSON(EmbyCountsResponse.self, for: req)
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
        return try await requestJSON(EmbyItemsResponse.self, for: req).items
    }

    public func fetchResumeItems(server: EmbyServerConfig, limit: Int = 16) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "MediaTypes", value: "Video")
        ] + Self.standardBrowseQueryItems
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/Items/Resume",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        return try await requestJSON(EmbyItemsResponse.self, for: req).items
    }

    public func fetchNextUp(server: EmbyServerConfig, limit: Int = 16) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Limit", value: "\(limit)")
        ] + Self.standardBrowseQueryItems
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Shows/NextUp",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        return try await requestJSON(EmbyItemsResponse.self, for: req).items
    }

    public func fetchLatestItems(
        server: EmbyServerConfig,
        parentId: String,
        limit: Int = 18,
        hidePlayed: Bool = false
    ) async throws -> [EmbyItem] {
        var query = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "GroupItems", value: "true")
        ] + Self.standardBrowseQueryItems
        if hidePlayed { query.append(URLQueryItem(name: "IsPlayed", value: "false")) }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/Items/Latest",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        return try await requestJSON([EmbyItem].self, for: req)
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
        var query = [
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)")
        ] + Self.standardBrowseQueryItems
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
        return try await requestJSON(EmbyItemsResponse.self, for: req)
    }

    public func fetchPlaybackInfo(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> EmbyPlaybackInfoResponse {
        let base = server.activeBaseURL
        if let cached = await EmbyPlaybackInfoCache.shared.get(serverId: server.id, baseURL: base, itemId: itemId, mediaSourceId: mediaSourceId),
           (audioStreamIndex == nil && subtitleStreamIndex == nil) || (cached.mediaSources?.allSatisfy { ($0.transcodingUrl ?? "").isEmpty } == true) {
            return cached
        }

        var query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "AutoOpenLiveStream", value: "true"),
            URLQueryItem(name: "IsPlayback", value: "true")
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId)) }
        if let audioStreamIndex { query.append(URLQueryItem(name: "AudioStreamIndex", value: "\(audioStreamIndex)")) }
        if let subtitleStreamIndex { query.append(URLQueryItem(name: "SubtitleStreamIndex", value: "\(subtitleStreamIndex)")) }

        var candidateIds = [itemId]
        if itemId.count == 26 && itemId.hasPrefix("01") {
            candidateIds = ["e\(itemId)", "m\(itemId)", itemId]
        }
        var lastError: Error?
        for cid in candidateIds {
            do {
                let req = try makeRequest(
                    baseURL: base,
                    path: "/Items/\(cid)/PlaybackInfo",
                    method: "POST",
                    queryItems: query,
                    token: server.accessToken,
                    userId: server.userId,
                    bodyData: deviceProfilePayloadData,
                    timeout: 15
                )
                let res = try await requestJSON(EmbyPlaybackInfoResponse.self, for: req, priority: .playback)
                if let sources = res.mediaSources, !sources.isEmpty {
                    await EmbyPlaybackInfoCache.shared.set(res, serverId: server.id, baseURL: base, itemId: itemId, mediaSourceId: mediaSourceId)
                    return res
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw EmbyClientError.noPlayableStream
    }

    public func invalidatePlaybackCaches(serverId: UUID? = nil) async {
        await EmbyPlaybackInfoCache.shared.invalidate(serverId: serverId)
        if let serverId {
            PlaybackIntentCoordinator.shared.invalidateServer(serverId)
        }
    }

    public func prewarmPlaybackInfo(server: EmbyServerConfig, itemId: String, mediaSourceId: String? = nil) async {
        guard !isUHDNativeExtensionActive(for: server), !server.host.isEmpty else { return }
        let base = server.activeBaseURL
        if await EmbyPlaybackInfoCache.shared.get(serverId: server.id, baseURL: base, itemId: itemId, mediaSourceId: mediaSourceId) != nil {
            return
        }
        _ = try? await fetchPlaybackInfo(server: server, itemId: itemId, mediaSourceId: mediaSourceId)
    }

    public static func redirectCacheKey(
        serverId: UUID,
        itemId: String,
        mediaSourceId: String,
        baseURL: String
    ) -> String {
        "\(serverId.uuidString)|\(itemId)|\(mediaSourceId)|\(baseURL)"
    }

    public func resolvePlaybackResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        enable302Cache: Bool = true,
        defer302ProbeWhenTurbo: Bool = false
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
        let cacheKey = Self.redirectCacheKey(
            serverId: server.id,
            itemId: item.id,
            mediaSourceId: selectedSource.id,
            baseURL: baseURL
        )
        if enable302Cache && server.cache302Request {
            if let cached = await RedirectCacheStore.shared.cachedRedirect(for: cacheKey) {
                resolvedURL = cached
                routeNote += " · 302缓存命中"
            } else if !defer302ProbeWhenTurbo,
                      let redirected = await probe302Redirect(url: initialURL, headers: headers) {
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

        let embyDownloadURL = URL(string: "\(baseURL)/emby/Items/\(item.id)/Download?MediaSourceId=\(selectedSource.id)&api_key=\(server.accessToken)")
        return ResolvedPlaybackResource(
            streamURL: resolvedURL,
            originStreamURL: initialURL,
            downloadURL: embyDownloadURL ?? resolvedURL,
            headers: headers,
            playSessionId: playSessionId,
            mediaSource: selectedSource,
            subtitleURLs: subtitleURLs,
            isDirectStream: selectedSource.transcodingUrl == nil,
            routeNote: routeNote
        )
    }

    private func probe302Redirect(url: URL, headers: [String: String]) async -> URL? {
        func makeProbeRequest(target: URL, method: String, rangeHeader: String? = nil) -> URLRequest {
            var req = URLRequest(url: target)
            req.httpMethod = method
            if let rangeHeader { req.setValue(rangeHeader, forHTTPHeaderField: "Range") }
            if target.host == url.host {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            return req
        }
        func redirectTarget(from http: HTTPURLResponse, relativeTo base: URL) -> URL? {
            guard (300...399).contains(http.statusCode),
                  let loc = http.value(forHTTPHeaderField: "Location") else { return nil }
            return URL(string: loc, relativeTo: base)?.absoluteURL
        }

        var currentURL = url
        var hop = 0
        while hop < 3 {
            guard let (_, resp) = try? await noRedirectSession.data(for: makeProbeRequest(target: currentURL, method: "HEAD")),
                  let http = resp as? HTTPURLResponse else {
                break
            }
            if let nextURL = redirectTarget(from: http, relativeTo: currentURL) {
                currentURL = nextURL
                hop += 1
                continue
            }
            if http.statusCode == 405 || http.statusCode == 501,
               let (byteStream, getResp) = try? await noRedirectSession.bytes(
                for: makeProbeRequest(target: currentURL, method: "GET", rangeHeader: "bytes=0-0")
               ),
               let getHttp = getResp as? HTTPURLResponse {
                byteStream.task.cancel()
                if let nextURL = redirectTarget(from: getHttp, relativeTo: currentURL) {
                    currentURL = nextURL
                    hop += 1
                    continue
                }
            }
            break
        }
        return hop > 0 ? currentURL : nil
    }

    public func reportPlaybackStart(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionSeconds: Double
    ) async {
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
        await sendSessionPayload(server: server, path: "/Sessions/Playing/Progress", itemId: itemId, mediaSourceId: mediaSourceId, playSessionId: playSessionId, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    public func reportPlaybackStopped(
        server: EmbyServerConfig,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionSeconds: Double
    ) async {
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
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !server.accessToken.isEmpty else { return }
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
        _ = try? await APIRequestGate.shared.withPermit(priority: .playback) {
            try await self.apiSession.data(for: req)
        }
    }

    public func setFavorite(server: EmbyServerConfig, itemId: String, isFavorite: Bool) async throws {
        try await setUserItemState(server: server, pathSegment: "FavoriteItems", itemId: itemId, enabled: isFavorite)
    }

    public func setPlayed(server: EmbyServerConfig, itemId: String, played: Bool) async throws {
        try await setUserItemState(server: server, pathSegment: "PlayedItems", itemId: itemId, enabled: played)
    }

    private func setUserItemState(server: EmbyServerConfig, pathSegment: String, itemId: String, enabled: Bool) async throws {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Users/\(server.userId)/\(pathSegment)/\(itemId)",
            method: enabled ? "POST" : "DELETE",
            token: server.accessToken,
            userId: server.userId
        )
        let (_, response) = try await apiSession.data(for: req)
        try validateResponse(response)
    }
}

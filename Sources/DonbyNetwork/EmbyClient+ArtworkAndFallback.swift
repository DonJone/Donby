import Foundation
import DonbyCore

extension EmbyClient {
    func isUHDNativeExtensionActive(for server: EmbyServerConfig) -> Bool {
        server.type == .uhdNative && DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)
    }

    func normalizeEmbyItemId(_ rawId: String, server: EmbyServerConfig, defaultPrefix: String = "m") -> String {
        guard !isUHDNativeExtensionActive(for: server),
              rawId.count == 26,
              rawId.hasPrefix("01"),
              (server.type == .uhdNative || server.host.lowercased().contains("uhd")) else {
            return rawId
        }
        return "\(defaultPrefix)\(rawId)"
    }

    func resolveRelativeOrAbsoluteURL(_ raw: String, baseURL: String, token: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        let cleanBase = ServerLineInfo.normalizeBaseURL(baseURL)
        let isRootDirectPath = raw.hasPrefix("/emby/") || raw.hasPrefix("emby/")
            || raw.hasPrefix("/play/") || raw.hasPrefix("play/")
            || raw.hasPrefix("/api/") || raw.hasPrefix("api/")
            || raw.hasPrefix("/stream/") || raw.hasPrefix("stream/")
        let prefix: String
        if isRootDirectPath {
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

    public func fetchItemDetail(server: EmbyServerConfig, itemId: String) async throws -> EmbyItem {
        let query = [URLQueryItem(name: "Fields", value: Self.detailItemFields)]
        let primaryId = normalizeEmbyItemId(itemId, server: server, defaultPrefix: "m")
        do {
            let req = try makeRequest(
                baseURL: server.activeBaseURL,
                path: "/Users/\(server.userId)/Items/\(primaryId)",
                queryItems: query,
                token: server.accessToken,
                userId: server.userId
            )
            return try await requestJSON(EmbyItem.self, for: req)
        } catch {
            if itemId.count == 26 && itemId.hasPrefix("01") {
                for prefix in ["e", "s", "m"] where "\(prefix)\(itemId)" != primaryId {
                    if let req = try? makeRequest(
                        baseURL: server.activeBaseURL,
                        path: "/Users/\(server.userId)/Items/\(prefix)\(itemId)",
                        queryItems: query,
                        token: server.accessToken,
                        userId: server.userId
                    ), let found = try? await requestJSON(EmbyItem.self, for: req) {
                        return found
                    }
                }
            }
            throw error
        }
    }

    public func fetchSeasons(server: EmbyServerConfig, seriesId: String) async throws -> [EmbyItem] {
        let normalizedSeriesId = normalizeEmbyItemId(seriesId, server: server, defaultPrefix: "s")
        let query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Fields", value: "BasicSyncInfo,Overview,PrimaryImageAspectRatio,UserData,ChildCount")
        ]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Shows/\(normalizedSeriesId)/Seasons",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        return try await requestJSON(EmbyItemsResponse.self, for: req).items
    }

    public func fetchEpisodes(server: EmbyServerConfig, seriesId: String, seasonId: String? = nil) async throws -> [EmbyItem] {
        let normalizedSeriesId = normalizeEmbyItemId(seriesId, server: server, defaultPrefix: "s")
        var query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Fields", value: Self.detailItemFields)
        ]
        if let seasonId, !seasonId.isEmpty { query.append(URLQueryItem(name: "SeasonId", value: seasonId)) }
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Shows/\(normalizedSeriesId)/Episodes",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        return try await requestJSON(EmbyItemsResponse.self, for: req).items
    }

    public func fetchSimilarItems(server: EmbyServerConfig, itemId: String, limit: Int = 12) async throws -> [EmbyItem] {
        let normalizedId = normalizeEmbyItemId(itemId, server: server, defaultPrefix: "m")
        let query = [
            URLQueryItem(name: "UserId", value: server.userId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.standardItemFields)
        ]
        let req = try makeRequest(
            baseURL: server.activeBaseURL,
            path: "/Items/\(normalizedId)/Similar",
            queryItems: query,
            token: server.accessToken,
            userId: server.userId
        )
        return try await requestJSON(EmbyItemsResponse.self, for: req).items
    }

    public func imageURL(
        server: EmbyServerConfig,
        itemId: String,
        kind: EmbyImageKind = .primary,
        maxWidth: Int = 600
    ) -> URL? {
        if isUHDNativeExtensionActive(for: server) {
            return nil
        }
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
        let directCandidates: [String?]
        switch kind {
        case .primary:
            directCandidates = [item.uhdPosterURL, item.uhdThumbURL, item.uhdBackdropURL]
        case .backdrop:
            directCandidates = [item.uhdBackdropURL, item.uhdThumbURL, item.uhdPosterURL]
        case .thumb:
            directCandidates = [item.uhdThumbURL, item.uhdBackdropURL, item.uhdPosterURL]
        case .logo:
            directCandidates = [item.uhdLogoURL]
        }
        for candidate in directCandidates {
            if let s = candidate, !s.isEmpty, let u = URL(string: s) {
                return u
            }
        }

        if isUHDNativeExtensionActive(for: server) {
            return nil
        }

        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let base = server.activeBaseURL
        let defaultPref = item.isEpisode ? "e" : (item.isSeries ? "s" : "m")
        var targetItemId = normalizeEmbyItemId(item.id, server: server, defaultPrefix: defaultPref)
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
            if let tTag = item.imageTags?["Thumb"] {
                tag = tTag
            } else if item.isEpisode, let pTag = item.imageTags?["Primary"] {
                tag = pTag
            } else if item.backdropImageTags?.first != nil || (item.isEpisode && item.seriesId != nil) {
                return imageURL(server: server, item: item, kind: .backdrop, maxWidth: maxWidth)
            } else {
                tag = item.imageTags?["Primary"]
            }
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
        if let direct = person.uhdImageURL, let u = URL(string: direct) {
            return [u]
        }
        if isUHDNativeExtensionActive(for: server) {
            return []
        }
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
        if let server, !isUHDNativeExtensionActive(for: server), !server.accessToken.isEmpty {
            req.setValue(server.accessToken, forHTTPHeaderField: "X-Emby-Token")
            req.setValue(buildAuthorizationHeader(userId: server.userId, token: server.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        }
        return req
    }
}

public enum EmbyImageKind: String, Sendable {
    case primary
    case backdrop
    case thumb
    case logo
}

import Foundation
import DonbyCore
import DonbyNetwork

struct UHDMediaDetailDTO: Decodable {
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

struct UHDEpisodeCardDTO: Decodable {
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

struct UHDDolbyVisionDTO: Decodable {
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

struct UHDAudioTrackDTO: Decodable {
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

struct UHDSubtitleTrackDTO: Decodable {
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

struct UHDVideoAssetDTO: Decodable {
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

struct UHDSubtitleAssetDTO: Decodable {
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

struct UHDAssetResponseDTO: Decodable {
    let videos: [UHDVideoAssetDTO]
    let subtitles: [UHDSubtitleAssetDTO]
}

extension UHDStreamClient {
    // MARK: - URL Resolution

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

    func resolveAbsoluteMediaURL(resolvedBase: String, path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let cleanBase = normalizedAPIBase(resolvedBase)
        let cleanPath = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return URL(string: cleanBase + cleanPath)
    }

    // MARK: - Item Details, Seasons, Episodes & Credits

    private func fetchItemDetailByKind(
        server: EmbyServerConfig,
        itemId: String,
        mediaKind: String
    ) async throws -> EmbyItem {
        if mediaKind == "episode" {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/episodes/\(itemId)",
                token: server.accessToken
            )
            let data = try await performRequest(UHDEpisodeDetailDataDTO.self, request: req, priority: .normal)
            return mapEpisode(
                data.episode,
                seriesId: data.series.id,
                seriesName: data.series.title,
                seasonNumber: data.season.seasonNumber,
                posterFallback: data.season.posterURL ?? data.series.posterURL,
                fanartFallback: data.series.fanartURL,
                logoFallback: data.series.logoURL,
                server: server
            )
        } else if mediaKind == "tv" {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/tv/\(itemId)",
                token: server.accessToken
            )
            let dto = try await performRequest(UHDMediaDetailDTO.self, request: req, priority: .normal)
            return mapDetail(dto, server: server)
        } else {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/movies/\(itemId)",
                token: server.accessToken
            )
            let dto = try await performRequest(UHDMediaDetailDTO.self, request: req, priority: .normal)
            return mapDetail(dto, server: server)
        }
    }

    public func fetchItemDetail(server: EmbyServerConfig, item: EmbyItem) async throws -> EmbyItem {
        let explicitKind = item.uhdMediaType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let initialKind = resolveItemType(item)
        do {
            return try await fetchItemDetailByKind(server: server, itemId: item.id, mediaKind: initialKind)
        } catch EmbyClientError.httpStatus(404, let msg) {
            // Only probe alternate endpoints when caller passed an ambiguous stub without explicit uhdMediaType
            guard explicitKind == nil || explicitKind?.isEmpty == true else {
                throw EmbyClientError.httpStatus(404, msg)
            }
            for fallbackKind in ["episode", "movie", "tv"] where fallbackKind != initialKind {
                if let resolved = try? await fetchItemDetailByKind(server: server, itemId: item.id, mediaKind: fallbackKind) {
                    return resolved
                }
            }
            throw EmbyClientError.httpStatus(404, msg)
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
        posterFallback: String? = nil,
        fanartFallback: String? = nil,
        logoFallback: String? = nil,
        page: Int = 1,
        pageSize: Int = 100,
        fetchAllPages: Bool = true
    ) async throws -> (items: [EmbyItem], total: Int) {
        let clampedPage = max(1, page)
        let clampedPageSize = max(1, min(100, pageSize))

        func fetchSinglePage(_ pageNum: Int) async throws -> UHDEpisodePageDTO {
            let req = try makeRequest(
                baseURL: server.mainLineURL,
                path: "/api/v1/stream/tv/\(tvId)/seasons/\(seasonId)/episodes",
                queryItems: [
                    URLQueryItem(name: "page", value: "\(pageNum)"),
                    URLQueryItem(name: "page_size", value: "\(clampedPageSize)")
                ],
                token: server.accessToken
            )
            return try await performRequest(UHDEpisodePageDTO.self, request: req, priority: .normal)
        }

        let firstPage = try await fetchSinglePage(clampedPage)
        var allItems = firstPage.items.map { ep in
            mapEpisode(
                ep,
                seriesId: tvId,
                seriesName: seriesName,
                seasonNumber: seasonNumber,
                posterFallback: posterFallback,
                fanartFallback: fanartFallback,
                logoFallback: logoFallback,
                server: server
            )
        }

        if fetchAllPages && clampedPage == 1 && firstPage.total > allItems.count {
            let totalPages = min(20, (firstPage.total + clampedPageSize - 1) / clampedPageSize)
            if totalPages >= 2 {
                var seenIds = Set(allItems.map(\.id))
                for nextPage in 2...totalPages {
                    let pageData = try await fetchSinglePage(nextPage)
                    if pageData.items.isEmpty { break }
                    let mapped = pageData.items.map { ep in
                        mapEpisode(
                            ep,
                            seriesId: tvId,
                            seriesName: seriesName,
                            seasonNumber: seasonNumber,
                            posterFallback: posterFallback,
                            fanartFallback: fanartFallback,
                            logoFallback: logoFallback,
                            server: server
                        )
                    }
                    for ep in mapped where seenIds.insert(ep.id).inserted {
                        allItems.append(ep)
                    }
                    if allItems.count >= firstPage.total { break }
                }
                allItems.sort { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            }
        }

        return (allItems, firstPage.total)
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
}

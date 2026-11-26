import Foundation
import DonbyCore
import DonbyNetwork

// MARK: - Library Mode & Personal Collection Settings Models

public enum UHDLibraryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal = "normal"
    case anime = "anime"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .normal: return "影视馆"
        case .anime: return "动漫馆"
        }
    }

    public var subtitle: String {
        switch self {
        case .normal: return "全库影视集合、热门与追更排期"
        case .anime: return "连载新番、动漫分区与追番排期"
        }
    }

    public var calendarTitle: String {
        switch self {
        case .normal: return "追更日历"
        case .anime: return "追番日历"
        }
    }

    public var hotTitle: String {
        switch self {
        case .normal: return "热门影视"
        case .anime: return "热门动漫"
        }
    }

    public var systemImage: String {
        switch self {
        case .normal: return "film.stack"
        case .anime: return "sparkles.tv"
        }
    }
}

public struct UHDLibraryPreferences: Codable, Equatable, Sendable {
    public let mode: UHDLibraryMode
    public let normalCollectionIds: [String]?
    public let animeCollectionIds: [String]?

    public init(mode: UHDLibraryMode, normalCollectionIds: [String]?, animeCollectionIds: [String]?) {
        self.mode = mode
        self.normalCollectionIds = normalCollectionIds
        self.animeCollectionIds = animeCollectionIds
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case normalCollectionIds = "normal_collection_ids"
        case animeCollectionIds = "anime_collection_ids"
    }

    public func collectionIds(for targetMode: UHDLibraryMode) -> [String]? {
        switch targetMode {
        case .normal: return normalCollectionIds
        case .anime: return animeCollectionIds
        }
    }
}

public struct UHDLibraryCollectionOption: Codable, Identifiable, Equatable, Sendable {
    public static let animeSystemKeys: Set<String> = [
        "anime_ongoing", "anime_asia", "anime_cn", "anime_other", "anime_movies"
    ]

    public let id: String
    public let name: String
    public let ruleKey: String?
    public let kind: String
    public let systemKey: String?
    public let mediaType: String
    public let ord: Int

    public init(
        id: String,
        name: String,
        ruleKey: String? = nil,
        kind: String = "source",
        systemKey: String? = nil,
        mediaType: String = "tv",
        ord: Int = 0
    ) {
        self.id = id
        self.name = name
        self.ruleKey = ruleKey
        self.kind = kind
        self.systemKey = systemKey
        self.mediaType = mediaType
        self.ord = ord
    }

    public var isAnimeEligible: Bool {
        guard let systemKey else { return false }
        return Self.animeSystemKeys.contains(systemKey)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, ord
        case ruleKey = "rule_key"
        case systemKey = "system_key"
        case mediaType = "media_type"
    }
}

public struct UHDLibrarySettings: Codable, Equatable, Sendable {
    public let preferences: UHDLibraryPreferences
    public let collections: [UHDLibraryCollectionOption]

    public init(preferences: UHDLibraryPreferences, collections: [UHDLibraryCollectionOption]) {
        self.preferences = preferences
        self.collections = collections
    }

    public func candidateCollections(for mode: UHDLibraryMode) -> [UHDLibraryCollectionOption] {
        let base: [UHDLibraryCollectionOption]
        switch mode {
        case .normal:
            base = collections
        case .anime:
            base = collections.filter(\.isAnimeEligible)
        }
        return base.sorted { lhs, rhs in
            if lhs.ord != rhs.ord { return lhs.ord < rhs.ord }
            return lhs.name < rhs.name
        }
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

struct UHDPlaybackItemDTO: Decodable {
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

extension UHDStreamClient {
    // MARK: - Library Mode & Personal Settings

    public func fetchLibrarySettings(server: EmbyServerConfig) async throws -> UHDLibrarySettings {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/me/library",
            token: server.accessToken
        )
        return try await performRequest(UHDLibrarySettings.self, request: req, priority: .normal)
    }

    /// Saves account default library mode and/or visible collection order for that mode.
    /// - Parameter collectionIds: Pass `nil` to keep existing order; pass `[]` to hide all collections in that mode.
    public func saveLibrarySettings(
        server: EmbyServerConfig,
        mode: UHDLibraryMode,
        collectionIds: [String]? = nil
    ) async throws -> UHDLibraryPreferences {
        var payload: [String: Any] = ["mode": mode.rawValue]
        if let collectionIds {
            payload["collection_ids"] = collectionIds
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/me/library",
            method: "PUT",
            token: server.accessToken,
            bodyData: body
        )
        return try await performRequest(UHDLibraryPreferences.self, request: req, priority: .normal)
    }

    // MARK: - Catalog & Discovery

    public func fetchCollections(server: EmbyServerConfig, mode: UHDLibraryMode? = nil) async throws -> [EmbyItem] {
        var query: [URLQueryItem] = []
        if let mode {
            query.append(URLQueryItem(name: "mode", value: mode.rawValue))
        }
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/collections",
            queryItems: query,
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

    public func fetchHot(
        server: EmbyServerConfig,
        mediaType: String? = nil,
        limit: Int = 24,
        mode: UHDLibraryMode? = nil
    ) async throws -> [EmbyItem] {
        var query = [URLQueryItem(name: "limit", value: "\(max(1, min(100, limit)))")]
        if let mode {
            query.append(URLQueryItem(name: "mode", value: mode.rawValue))
        }
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
        try await fetchHot(server: server, mediaType: mediaType, limit: limit, mode: .anime)
    }

    public func fetchAnimeCalendarDays(server: EmbyServerConfig, mode: UHDLibraryMode = .anime) async throws -> [UHDAnimeCalendarDay] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/calendar/days",
            queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)],
            token: server.accessToken
        )
        let data = try await performRequest([UHDAnimeCalendarDayDTO].self, request: req, priority: .normal)
        return data.sorted { $0.weekday < $1.weekday }.map { UHDAnimeCalendarDay(weekday: $0.weekday, total: $0.total) }
    }

    public func fetchAnimeCalendarItems(
        server: EmbyServerConfig,
        weekday: Int,
        mode: UHDLibraryMode = .anime
    ) async throws -> [UHDAnimeCalendarEntry] {
        let clampedDay = max(1, min(7, weekday))
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/library/calendar/items",
            queryItems: [
                URLQueryItem(name: "weekday", value: "\(clampedDay)"),
                URLQueryItem(name: "mode", value: mode.rawValue)
            ],
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
        limit: Int = 60,
        mode: UHDLibraryMode? = nil
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
            if let mode {
                qItems.append(URLQueryItem(name: "mode", value: mode.rawValue))
            }
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

    public func search(
        server: EmbyServerConfig,
        query: String,
        limit: Int = 50,
        mode: UHDLibraryMode? = nil
    ) async throws -> [EmbyItem] {
        try await searchWithMeta(server: server, query: query, limit: limit, mode: mode).items
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

    // MARK: - User State Mutations (Favorites & Played)

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
}

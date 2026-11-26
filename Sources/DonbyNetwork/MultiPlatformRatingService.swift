import Foundation
import DonbyCore

/// Fetches and caches multi-platform ratings (TMDB, IMDb, Rotten Tomatoes Critics/Audience,
/// Trakt, Metacritic, Letterboxd) for home hero curation.
///
/// - Primary mode: MDBList batch API (`POST https://api.mdblist.com/tmdb/{movie|show}/?apikey=...`)
///   when an API key is configured in Settings or `DONBY_MDBLIST_API_KEY`.
/// - Zero-key fallback: Stremio Cinemeta (`https://v3-cinemeta.strem.io/meta/{movie|series}/{imdbId}.json`)
///   for items carrying an `Imdb` provider ID, providing real IMDb scores with zero configuration.
/// - All results are persisted to a `DONBY_HOME`-isolated disk cache (14-day TTL).
public actor MultiPlatformRatingService {
    public static let shared = MultiPlatformRatingService()

    private static let cacheTTL: TimeInterval = 14 * 24 * 3600
    private var memoryCache: [String: MultiPlatformRatings] = [:]
    private var didLoadDiskCache = false

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 8.0
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Cache Keys

    public nonisolated static func canonicalCacheKey(for item: EmbyItem) -> String? {
        if let tmdb = resolvedProviderId(in: item.providerIds, key: "tmdb") {
            let kind = item.isSeries ? "show" : "movie"
            return "tmdb:\(kind):\(tmdb)"
        }
        if let imdb = resolvedProviderId(in: item.providerIds, key: "imdb") {
            return "imdb:\(imdb.lowercased())"
        }
        return nil
    }

    public nonisolated static func resolvedProviderId(in providerIds: [String: String]?, key: String) -> String? {
        guard let providerIds else { return nil }
        let lowerTarget = key.lowercased()
        for (k, v) in providerIds {
            if k.lowercased() == lowerTarget {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    // MARK: - Public API

    /// Returns any already-cached multi-platform ratings mapped by `EmbyItem.id`.
    public func cachedRatingsByItemId(for items: [EmbyItem]) -> [String: MultiPlatformRatings] {
        loadDiskCacheIfNeeded()
        let now = Date()
        var result: [String: MultiPlatformRatings] = [:]
        for item in items {
            guard let key = Self.canonicalCacheKey(for: item),
                  let entry = memoryCache[key],
                  now.timeIntervalSince(entry.fetchedAt) < Self.cacheTTL else { continue }
            result[item.id] = entry
        }
        return result
    }

    /// Enriches uncached hero candidates with multi-platform ratings and returns the combined map keyed by `EmbyItem.id`.
    public func enrichRatings(
        for items: [EmbyItem],
        mdblistAPIKey: String?,
        maxFetchCount: Int = 40
    ) async -> [String: MultiPlatformRatings] {
        loadDiskCacheIfNeeded()
        let now = Date()
        let resolvedKey = resolveAPIKey(mdblistAPIKey)

        var uncachedMovies: [(item: EmbyItem, tmdbId: Int, cacheKey: String)] = []
        var uncachedShows: [(item: EmbyItem, tmdbId: Int, cacheKey: String)] = []
        var uncachedImdbOnly: [(item: EmbyItem, imdbId: String, cacheKey: String)] = []
        var seenKeys = Set<String>()

        for item in items {
            guard let key = Self.canonicalCacheKey(for: item) else { continue }
            if let existing = memoryCache[key], now.timeIntervalSince(existing.fetchedAt) < Self.cacheTTL {
                continue
            }
            guard seenKeys.insert(key).inserted else { continue }
            if (uncachedMovies.count + uncachedShows.count + uncachedImdbOnly.count) >= maxFetchCount {
                break
            }

            if let tmdbStr = Self.resolvedProviderId(in: item.providerIds, key: "tmdb"),
               let tmdbId = Int(tmdbStr) {
                if item.isSeries {
                    uncachedShows.append((item, tmdbId, key))
                } else {
                    uncachedMovies.append((item, tmdbId, key))
                }
            } else if let imdb = Self.resolvedProviderId(in: item.providerIds, key: "imdb"),
                      imdb.lowercased().hasPrefix("tt") {
                uncachedImdbOnly.append((item, imdb.lowercased(), key))
            }
        }

        var didMutate = false

        if let apiKey = resolvedKey {
            // Primary path: MDBList batch API (1 request per media type for up to 40 items)
            if !uncachedMovies.isEmpty {
                let fetched = await fetchMDBListBatch(mediaType: "movie", tmdbIds: uncachedMovies.map(\.tmdbId), apiKey: apiKey)
                for (tmdbId, rating) in fetched {
                    memoryCache["tmdb:movie:\(tmdbId)"] = rating
                    if let imdb = rating.imdbId?.lowercased(), !imdb.isEmpty {
                        memoryCache["imdb:\(imdb)"] = rating
                    }
                    didMutate = true
                }
            }
            if !uncachedShows.isEmpty {
                let fetched = await fetchMDBListBatch(mediaType: "show", tmdbIds: uncachedShows.map(\.tmdbId), apiKey: apiKey)
                for (tmdbId, rating) in fetched {
                    memoryCache["tmdb:show:\(tmdbId)"] = rating
                    if let imdb = rating.imdbId?.lowercased(), !imdb.isEmpty {
                        memoryCache["imdb:\(imdb)"] = rating
                    }
                    didMutate = true
                }
            }
            if !uncachedImdbOnly.isEmpty {
                let fetched = await fetchMDBListImdbBatch(imdbIds: uncachedImdbOnly.map(\.imdbId), apiKey: apiKey)
                for (imdbId, rating) in fetched {
                    memoryCache["imdb:\(imdbId.lowercased())"] = rating
                    didMutate = true
                }
            }
        } else {
            // Zero-key fallback: fetch real IMDb ratings from Stremio Cinemeta for items with IMDb IDs.
            var cinemetaTargets: [(imdbId: String, isSeries: Bool, cacheKeys: [String])] = []
            for item in items {
                guard let imdb = Self.resolvedProviderId(in: item.providerIds, key: "imdb")?.lowercased(),
                      imdb.hasPrefix("tt") else { continue }
                let primaryKey = Self.canonicalCacheKey(for: item) ?? "imdb:\(imdb)"
                if let existing = memoryCache[primaryKey], now.timeIntervalSince(existing.fetchedAt) < Self.cacheTTL {
                    continue
                }
                if cinemetaTargets.contains(where: { $0.imdbId == imdb }) { continue }
                var keys = [primaryKey]
                let imdbKey = "imdb:\(imdb)"
                if !keys.contains(imdbKey) { keys.append(imdbKey) }
                cinemetaTargets.append((imdb, item.isSeries, keys))
                if cinemetaTargets.count >= min(18, maxFetchCount) { break }
            }

            if !cinemetaTargets.isEmpty {
                let fetched = await fetchCinemetaRatings(targets: cinemetaTargets)
                for (keys, rating) in fetched {
                    for k in keys {
                        memoryCache[k] = rating
                    }
                    didMutate = true
                }
            }
        }

        if didMutate {
            saveDiskCache()
        }

        return cachedRatingsByItemId(for: items)
    }

    // MARK: - MDBList Batch Client

    private func fetchMDBListBatch(mediaType: String, tmdbIds: [Int], apiKey: String) async -> [Int: MultiPlatformRatings] {
        guard !tmdbIds.isEmpty,
              let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.mdblist.com/tmdb/\(mediaType)/?apikey=\(encodedKey)") else {
            return [:]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": tmdbIds])

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let entries = try? JSONDecoder().decode([MDBListEntryDTO].self, from: data) else {
            return [:]
        }

        var map: [Int: MultiPlatformRatings] = [:]
        for entry in entries {
            guard let tid = entry.tmdbid ?? entry.ids?.tmdb else { continue }
            map[tid] = entry.toMultiPlatformRatings()
        }
        return map
    }

    private func fetchMDBListImdbBatch(imdbIds: [String], apiKey: String) async -> [String: MultiPlatformRatings] {
        guard !imdbIds.isEmpty,
              let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.mdblist.com/imdb/?apikey=\(encodedKey)") else {
            return [:]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": imdbIds])

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let entries = try? JSONDecoder().decode([MDBListEntryDTO].self, from: data) else {
            return [:]
        }

        var map: [String: MultiPlatformRatings] = [:]
        for entry in entries {
            guard let iid = entry.imdbid ?? entry.ids?.imdb, !iid.isEmpty else { continue }
            map[iid.lowercased()] = entry.toMultiPlatformRatings()
        }
        return map
    }

    // MARK: - Zero-Key Cinemeta Fallback

    private func fetchCinemetaRatings(
        targets: [(imdbId: String, isSeries: Bool, cacheKeys: [String])]
    ) async -> [([String], MultiPlatformRatings)] {
        await withTaskGroup(of: ([String], MultiPlatformRatings)?.self) { group in
            let maxConcurrent = 6
            var nextIdx = 0
            var results: [([String], MultiPlatformRatings)] = []

            func enqueue(_ target: (imdbId: String, isSeries: Bool, cacheKeys: [String])) {
                let sess = self.session
                group.addTask {
                    let kind = target.isSeries ? "series" : "movie"
                    guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(kind)/\(target.imdbId).json") else {
                        return nil
                    }
                    var req = URLRequest(url: url)
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    guard let (data, resp) = try? await sess.data(for: req),
                          let http = resp as? HTTPURLResponse,
                          (200...299).contains(http.statusCode),
                          let parsed = try? JSONDecoder().decode(CinemetaMetaResponseDTO.self, from: data),
                          let ratingStr = parsed.meta?.imdbRating,
                          let imdbScore = Double(ratingStr),
                          imdbScore > 0 && imdbScore <= 10.0 else {
                        return nil
                    }
                    let mp = MultiPlatformRatings(
                        imdb: imdbScore,
                        imdbId: target.imdbId,
                        fetchedAt: Date()
                    )
                    return (target.cacheKeys, mp)
                }
            }

            while nextIdx < min(maxConcurrent, targets.count) {
                enqueue(targets[nextIdx])
                nextIdx += 1
            }

            for await outcome in group {
                if let outcome {
                    results.append(outcome)
                }
                if nextIdx < targets.count {
                    enqueue(targets[nextIdx])
                    nextIdx += 1
                }
            }
            return results
        }
    }

    // MARK: - Helpers & Disk Persistence

    private func resolveAPIKey(_ configured: String?) -> String? {
        if let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        if let env = ProcessInfo.processInfo.environment["DONBY_MDBLIST_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return nil
    }

    private func cacheFileURL() -> URL {
        DonbyStoragePaths.cachesDirectoryURL.appendingPathComponent("multi_platform_ratings_v1.json")
    }

    private func loadDiskCacheIfNeeded() {
        guard !didLoadDiskCache else { return }
        didLoadDiskCache = true
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MultiPlatformRatings].self, from: data) else {
            return
        }
        let now = Date()
        memoryCache = decoded.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.cacheTTL }
    }

    private func saveDiskCache() {
        let url = cacheFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(memoryCache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - DTOs

private struct MDBListEntryDTO: Decodable {
    struct IDsDTO: Decodable {
        let imdb: String?
        let tmdb: Int?
    }

    struct RatingItemDTO: Decodable {
        let source: String
        let value: Double?
        let score: Int?
        let votes: Int?
    }

    let imdbid: String?
    let tmdbid: Int?
    let ids: IDsDTO?
    let score: Int?
    let ratings: [RatingItemDTO]?

    func toMultiPlatformRatings() -> MultiPlatformRatings {
        var result = MultiPlatformRatings(
            mdblistScore: score,
            imdbId: imdbid ?? ids?.imdb,
            fetchedAt: Date()
        )
        for r in ratings ?? [] {
            let src = r.source.lowercased()
            switch src {
            case "imdb":
                if let v = r.value, v > 0 { result.imdb = v }
                if let votes = r.votes, votes > 0 { result.imdbVotes = votes }
            case "tmdb":
                if let v = r.value, v > 0 {
                    result.tmdb = v > 10 ? (v / 10.0) : v
                } else if let s = r.score, s > 0 {
                    result.tmdb = Double(s) / 10.0
                }
                if let votes = r.votes, votes > 0 { result.tmdbVotes = votes }
            case "tomatoes", "rottentomatoes":
                if let v = r.value, v > 0 { result.rottenTomatoesCritics = Int(v.rounded()) }
                else if let s = r.score, s > 0 { result.rottenTomatoesCritics = s }
            case "tomatoesaudience", "popcorn", "rottentomatoesaudience":
                if let v = r.value, v > 0 { result.rottenTomatoesAudience = Int(v.rounded()) }
                else if let s = r.score, s > 0 { result.rottenTomatoesAudience = s }
            case "trakt":
                if let v = r.value, v > 0 { result.trakt = Int(v.rounded()) }
                else if let s = r.score, s > 0 { result.trakt = s }
                if let votes = r.votes, votes > 0 { result.traktVotes = votes }
            case "metacritic":
                if let v = r.value, v > 0 { result.metacritic = Int(v.rounded()) }
                else if let s = r.score, s > 0 { result.metacritic = s }
            case "letterboxd":
                if let v = r.value, v > 0 { result.letterboxd = v }
            default:
                break
            }
        }
        return result
    }
}

private struct CinemetaMetaResponseDTO: Decodable {
    struct MetaDTO: Decodable {
        let imdbRating: String?
    }
    let meta: MetaDTO?
}

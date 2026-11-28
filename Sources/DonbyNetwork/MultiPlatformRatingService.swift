import Foundation
import DonbyCore

/// Fetches and caches multi-platform ratings across professional critic and audience platforms
/// (Metacritic, Rotten Tomatoes Critics/Audience, Letterboxd, RogerEbert, IMDb + exact votes,
/// Trakt + votes, TMDB + votes, plus major awards & production countries) for home hero curation.
///
/// - Primary mode: MDBList batch API (`POST https://api.mdblist.com/tmdb/{movie|show}/?apikey=...`)
///   when an API key is configured in Settings or `DONBY_MDBLIST_API_KEY`.
/// - Zero-key enrichment: IMDb official daily ratings dataset (`IMDbOfficialRatingsStore` for exact
///   `imdb + imdbVotes`) + Stremio Cinemeta (`awards`, `country`, `imdbRating`) for all items with
///   native or bridge-resolved `imdbId`.
/// - All results are persisted to a `DONBY_HOME`-isolated disk cache (14-day TTL).
public actor MultiPlatformRatingService {
    public static let shared = MultiPlatformRatingService()

    private static let cacheTTL: TimeInterval = 14 * 24 * 3600
    private var memoryCache: [String: MultiPlatformRatings] = [:]
    private var didLoadDiskCache = false

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.5
        cfg.timeoutIntervalForResource = 9.0
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Cache Keys

    public nonisolated static func canonicalCacheKey(for item: EmbyItem, resolvedImdbId: String? = nil) -> String? {
        if let tmdb = resolvedProviderId(in: item.providerIds, key: "tmdb") {
            let kind = item.isSeries ? "show" : "movie"
            return "tmdb:\(kind):\(tmdb)"
        }
        if let imdb = resolvedImdbId ?? resolvedProviderId(in: item.providerIds, key: "imdb") {
            let clean = imdb.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean.hasPrefix("tt") { return "imdb:\(clean)" }
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
    public func cachedRatingsByItemId(
        for items: [EmbyItem],
        resolvedImdbIds: [String: String] = [:]
    ) -> [String: MultiPlatformRatings] {
        loadDiskCacheIfNeeded()
        let now = Date()
        var result: [String: MultiPlatformRatings] = [:]
        for item in items {
            let bridgedImdb = resolvedImdbIds[item.id]?.lowercased()
            if let key = Self.canonicalCacheKey(for: item, resolvedImdbId: bridgedImdb),
               let entry = memoryCache[key],
               now.timeIntervalSince(entry.fetchedAt) < Self.cacheTTL {
                result[item.id] = entry
                continue
            }
            if let imdb = bridgedImdb ?? Self.resolvedProviderId(in: item.providerIds, key: "imdb")?.lowercased(),
               imdb.hasPrefix("tt"),
               let entry = memoryCache["imdb:\(imdb)"],
               now.timeIntervalSince(entry.fetchedAt) < Self.cacheTTL {
                result[item.id] = entry
            }
        }
        return result
    }

    /// Returns a single cached rating entry if fresh.
    public func cachedRating(
        for item: EmbyItem,
        resolvedImdbId: String? = nil
    ) -> MultiPlatformRatings? {
        let map = cachedRatingsByItemId(
            for: [item],
            resolvedImdbIds: resolvedImdbId.map { [item.id: $0] } ?? [:]
        )
        return map[item.id]
    }

    /// Enriches a single item (e.g. opened in DetailView or focused in MainCarouselView)
    /// and returns its merged multi-platform ratings.
    public func enrichRating(
        for item: EmbyItem,
        mdblistAPIKey: String?,
        resolvedImdbId: String? = nil
    ) async -> MultiPlatformRatings? {
        let map = await enrichRatings(
            for: [item],
            mdblistAPIKey: mdblistAPIKey,
            resolvedImdbIds: resolvedImdbId.map { [item.id: $0] } ?? [:],
            maxFetchCount: 1
        )
        return map[item.id]
    }

    /// Enriches uncached hero candidates with multi-platform ratings, exact IMDb vote counts,
    /// awards, and production countries, returning the combined map keyed by `EmbyItem.id`.
    public func enrichRatings(
        for items: [EmbyItem],
        mdblistAPIKey: String?,
        resolvedImdbIds: [String: String] = [:],
        maxFetchCount: Int = 40
    ) async -> [String: MultiPlatformRatings] {
        loadDiskCacheIfNeeded()
        let now = Date()
        let resolvedKey = resolveAPIKey(mdblistAPIKey)

        var uncachedMovies: [(item: EmbyItem, tmdbId: Int, cacheKey: String)] = []
        var uncachedShows: [(item: EmbyItem, tmdbId: Int, cacheKey: String)] = []
        var uncachedImdbOnly: [(item: EmbyItem, imdbId: String, cacheKey: String)] = []
        var seenKeys = Set<String>()

        func effectiveImdb(for item: EmbyItem) -> String? {
            if let bridged = resolvedImdbIds[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               bridged.hasPrefix("tt") {
                return bridged
            }
            if let native = Self.resolvedProviderId(in: item.providerIds, key: "imdb")?.lowercased(),
               native.hasPrefix("tt") {
                return native
            }
            return nil
        }

        for item in items {
            let imdb = effectiveImdb(for: item)
            guard let key = Self.canonicalCacheKey(for: item, resolvedImdbId: imdb) else { continue }
            if let existing = memoryCache[key], now.timeIntervalSince(existing.fetchedAt) < Self.cacheTTL {
                let needsMDBListUpgrade = resolvedKey != nil
                    && existing.mdblistFetched != true
                    && existing.rottenTomatoesCritics == nil
                    && existing.rottenTomatoesAudience == nil
                    && existing.metacritic == nil
                    && existing.trakt == nil
                    && existing.letterboxd == nil
                if !needsMDBListUpgrade {
                    continue
                }
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
            } else if let imdb {
                uncachedImdbOnly.append((item, imdb, key))
            }
        }

        var didMutate = false

        // 1. Primary path: MDBList 8-platform batch API when API key is configured.
        if let apiKey = resolvedKey {
            if !uncachedMovies.isEmpty {
                let fetched = await fetchMDBListBatch(mediaType: "movie", tmdbIds: uncachedMovies.map(\.tmdbId), apiKey: apiKey)
                for (tmdbId, rating) in fetched {
                    storeMergedMDBList(rating, keys: ["tmdb:movie:\(tmdbId)", rating.imdbId.map { "imdb:\($0.lowercased())" }])
                    didMutate = true
                }
            }
            if !uncachedShows.isEmpty {
                let fetched = await fetchMDBListBatch(mediaType: "show", tmdbIds: uncachedShows.map(\.tmdbId), apiKey: apiKey)
                for (tmdbId, rating) in fetched {
                    storeMergedMDBList(rating, keys: ["tmdb:show:\(tmdbId)", rating.imdbId.map { "imdb:\($0.lowercased())" }])
                    didMutate = true
                }
            }
            if !uncachedImdbOnly.isEmpty {
                let fetched = await fetchMDBListImdbBatch(imdbIds: uncachedImdbOnly.map(\.imdbId), apiKey: apiKey)
                for (imdbId, rating) in fetched {
                    storeMergedMDBList(rating, keys: ["imdb:\(imdbId.lowercased())"])
                    didMutate = true
                }
            }
        }

        // 2. Zero-key IMDb official vote-depth store + Cinemeta awards/country enrichment.
        var imdbLookupIds: [String] = []
        var imdbToCacheKeys: [String: [String]] = [:]
        var cinemetaTargets: [(imdbId: String, isSeries: Bool, cacheKeys: [String])] = []

        for item in items {
            let bridged = effectiveImdb(for: item)
            let primaryKey = Self.canonicalCacheKey(for: item, resolvedImdbId: bridged)
            let existing = primaryKey.flatMap { memoryCache[$0] }
            guard let imdb = bridged ?? existing?.imdbId?.lowercased(), imdb.hasPrefix("tt") else { continue }

            var keys: [String] = []
            if let primaryKey { keys.append(primaryKey) }
            let imdbKey = "imdb:\(imdb)"
            if !keys.contains(imdbKey) { keys.append(imdbKey) }
            imdbToCacheKeys[imdb] = keys

            let needsOfficialVotes = (existing?.imdbVotes ?? 0) == 0
            if needsOfficialVotes && !imdbLookupIds.contains(imdb) {
                imdbLookupIds.append(imdb)
            }

            let needsCinemetaMeta = existing == nil
                || (existing?.awardsSummary == nil && existing?.countries == nil)
            if needsCinemetaMeta && cinemetaTargets.count < min(20, maxFetchCount)
                && !cinemetaTargets.contains(where: { $0.imdbId == imdb }) {
                cinemetaTargets.append((imdb, item.isSeries, keys))
            }
        }

        let imdbLookupSnapshot = imdbLookupIds
        let cinemetaSnapshot = cinemetaTargets
        async let officialTask = IMDbOfficialRatingsStore.shared.lookup(imdbIds: imdbLookupSnapshot)
        async let cinemetaTask = cinemetaSnapshot.isEmpty
            ? []
            : fetchCinemetaMetadata(targets: cinemetaSnapshot)

        let officialMap = await officialTask
        let cinemetaList = await cinemetaTask

        for (imdbId, entry) in officialMap {
            let keys = imdbToCacheKeys[imdbId] ?? ["imdb:\(imdbId)"]
            var merged = keys.compactMap { memoryCache[$0] }.first ?? MultiPlatformRatings(imdbId: imdbId, fetchedAt: now)
            merged.imdb = entry.rating
            merged.imdbVotes = entry.votes
            merged.imdbId = imdbId
            merged.fetchedAt = now
            store(merged, keys: keys.map(Optional.some))
            didMutate = true
        }

        for (keys, meta) in cinemetaList {
            var merged = keys.compactMap { memoryCache[$0] }.first ?? MultiPlatformRatings(imdbId: meta.imdbId, fetchedAt: now)
            if merged.imdb == nil, let score = meta.imdb { merged.imdb = score }
            if let awards = meta.awardsSummary, !awards.isEmpty { merged.awardsSummary = awards }
            if let countries = meta.countries, !countries.isEmpty { merged.countries = countries }
            if merged.imdbId == nil { merged.imdbId = meta.imdbId }
            merged.fetchedAt = now
            store(merged, keys: keys.map(Optional.some))
            didMutate = true
        }

        if didMutate {
            saveDiskCache()
        }

        return cachedRatingsByItemId(for: items, resolvedImdbIds: resolvedImdbIds)
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

    // MARK: - Zero-Key Cinemeta Metadata (IMDb Rating + Major Awards + Production Country)

    private func fetchCinemetaMetadata(
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
                          let meta = parsed.meta else {
                        return nil
                    }
                    let imdbScore = meta.imdbRating.flatMap(Double.init).flatMap { ($0 > 0 && $0 <= 10.0) ? $0 : nil }
                    let awards = meta.awards?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let countries: [String]? = meta.country.map { raw in
                        raw.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                    guard imdbScore != nil || !(awards ?? "").isEmpty || !(countries ?? []).isEmpty else {
                        return nil
                    }
                    let mp = MultiPlatformRatings(
                        imdb: imdbScore,
                        imdbId: target.imdbId,
                        awardsSummary: (awards?.isEmpty == false) ? awards : nil,
                        countries: (countries?.isEmpty == false) ? countries : nil,
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

    private func store(_ rating: MultiPlatformRatings, keys: [String?]) {
        for case let key? in keys where !key.isEmpty {
            memoryCache[key] = rating
        }
    }

    private func storeMergedMDBList(_ incoming: MultiPlatformRatings, keys: [String?]) {
        let existing = keys.compactMap { $0 }.compactMap { memoryCache[$0] }.first
        var merged = incoming
        if let existing {
            if merged.imdb == nil { merged.imdb = existing.imdb }
            if (merged.imdbVotes ?? 0) == 0 { merged.imdbVotes = existing.imdbVotes }
            if merged.awardsSummary == nil { merged.awardsSummary = existing.awardsSummary }
            if merged.countries == nil { merged.countries = existing.countries }
            if merged.imdbId == nil { merged.imdbId = existing.imdbId }
        }
        merged.mdblistFetched = true
        store(merged, keys: keys)
    }

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
        DonbyStoragePaths.cachesDirectoryURL.appendingPathComponent("multi_platform_ratings_v2.json")
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

    public func diskCacheSizeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFileURL().path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    public func clearCache() {
        memoryCache.removeAll()
        didLoadDiskCache = true
        try? FileManager.default.removeItem(at: cacheFileURL())
    }

    public func pruneIfNeeded(maxBytes: Int64) {
        guard maxBytes > 0, diskCacheSizeBytes() > maxBytes else { return }
        if memoryCache.isEmpty {
            didLoadDiskCache = false
        }
        loadDiskCacheIfNeeded()
        guard !memoryCache.isEmpty else { return }
        let sortedKeys = memoryCache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.map(\.key)
        var removedCount = 0
        let batchSize = max(1, sortedKeys.count / 4)
        for key in sortedKeys {
            memoryCache.removeValue(forKey: key)
            removedCount += 1
            if removedCount % batchSize == 0 || memoryCache.isEmpty {
                saveDiskCache()
                if diskCacheSizeBytes() <= maxBytes { break }
            }
        }
        if memoryCache.isEmpty {
            try? FileManager.default.removeItem(at: cacheFileURL())
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
    let country: String?
    let ratings: [RatingItemDTO]?

    func toMultiPlatformRatings() -> MultiPlatformRatings {
        let parsedCountries = country.map { raw in
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var result = MultiPlatformRatings(
            mdblistScore: score,
            imdbId: imdbid ?? ids?.imdb,
            countries: (parsedCountries?.isEmpty == false) ? parsedCountries : nil,
            mdblistFetched: true,
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
                else if let s = r.score, s > 0 { result.letterboxd = Double(s) / 20.0 }
            case "rogerebert":
                if let v = r.value, v > 0 && v <= 4.0 { result.rogerEbert = v }
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
        let awards: String?
        let country: String?
    }
    let meta: MetaDTO?
}

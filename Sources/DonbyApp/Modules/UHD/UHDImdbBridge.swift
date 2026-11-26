#if canImport(DonbyUHDModule)
import Foundation
import DonbyCore
import DonbyNetwork
import DonbyUHDModule

/// Persistent `tmdbId -> imdbId` bridge for UHDNow summary items (which omit `imdbId` in list responses).
///
/// Lazily hydrates detail metadata for up to `maxCount` uncached hero candidates (max concurrency 4)
/// and caches results permanently inside `DonbyStoragePaths.cachesDirectoryURL` (`DONBY_HOME`-isolated)
/// so UHDNow home hero curation can query IMDb's official vote-count dataset and Cinemeta awards/countries.
actor UHDImdbBridge {
    static let shared = UHDImdbBridge()

    private var tmdbToImdb: [String: String] = [:]
    private var didLoad = false

    func resolveImdbIds(
        for items: [EmbyItem],
        server: EmbyServerConfig,
        maxCount: Int = 14
    ) async -> [String: String] {
        loadIfNeeded()
        var resolved: [String: String] = [:]
        var toFetch: [(item: EmbyItem, cacheKey: String)] = []
        var seenKeys = Set<String>()

        for item in items {
            if let existingImdb = MultiPlatformRatingService.resolvedProviderId(in: item.providerIds, key: "imdb"),
               existingImdb.lowercased().hasPrefix("tt") {
                resolved[item.id] = existingImdb.lowercased()
                continue
            }
            guard let tmdb = MultiPlatformRatingService.resolvedProviderId(in: item.providerIds, key: "tmdb") else {
                continue
            }
            let kind = item.isSeries ? "tv" : "movie"
            let key = "\(kind):\(tmdb)"
            if let cached = tmdbToImdb[key] {
                if cached.hasPrefix("tt") { resolved[item.id] = cached }
                continue
            }
            guard seenKeys.insert(key).inserted else { continue }
            if toFetch.count < maxCount {
                toFetch.append((item, key))
            }
        }

        guard !toFetch.isEmpty else { return resolved }

        let fetched = await withTaskGroup(of: (String, String, String?).self) { group in
            let maxConcurrent = 4
            var nextIdx = 0
            var outcomes: [(String, String, String?)] = []

            func enqueue(_ entry: (item: EmbyItem, cacheKey: String)) {
                group.addTask {
                    let detail = try? await UHDStreamClient.shared.fetchItemDetail(server: server, item: entry.item)
                    let imdb = detail.flatMap { MultiPlatformRatingService.resolvedProviderId(in: $0.providerIds, key: "imdb")?.lowercased() }
                    return (entry.item.id, entry.cacheKey, (imdb?.hasPrefix("tt") == true) ? imdb : nil)
                }
            }

            while nextIdx < min(maxConcurrent, toFetch.count) {
                enqueue(toFetch[nextIdx])
                nextIdx += 1
            }

            for await outcome in group {
                outcomes.append(outcome)
                if nextIdx < toFetch.count {
                    enqueue(toFetch[nextIdx])
                    nextIdx += 1
                }
            }
            return outcomes
        }

        var didMutate = false
        for (itemId, cacheKey, imdb) in fetched {
            if let imdb {
                tmdbToImdb[cacheKey] = imdb
                resolved[itemId] = imdb
            } else {
                tmdbToImdb[cacheKey] = ""
            }
            didMutate = true
        }

        if didMutate { saveToDisk() }
        return resolved
    }

    private func cacheFileURL() -> URL {
        DonbyStoragePaths.cachesDirectoryURL.appendingPathComponent("uhd_tmdb_imdb_map_v1.json")
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let data = try? Data(contentsOf: cacheFileURL()),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            tmdbToImdb = decoded
        }
    }

    private func saveToDisk() {
        let url = cacheFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tmdbToImdb) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif

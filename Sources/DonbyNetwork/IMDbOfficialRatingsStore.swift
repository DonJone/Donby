import Foundation
import zlib
import DonbyCore

/// Zero-key local store backed by IMDb's official daily public dataset (`title.ratings.tsv.gz`, ~8.7 MB).
///
/// Provides authentic `averageRating` and exact `numVotes` for 1.5M+ titles with zero API key and zero rate limit:
/// - Cached inside `DonbyStoragePaths.cachesDirectoryURL` (`DONBY_HOME`-isolated) with a 7-day refresh TTL.
/// - Queries stream-scan the gzipped TSV directly via `libz` (`gzopen`/`gzread`) in ~60–100 ms with < 1 MB RAM.
/// - Automatically skips remote downloads under `DonbyStoragePaths.isIsolatedHome` so tests remain offline & deterministic.
public actor IMDbOfficialRatingsStore {
    public static let shared = IMDbOfficialRatingsStore()

    public struct Entry: Sendable, Equatable {
        public let rating: Double
        public let votes: Int
    }

    private static let datasetURL = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!
    private static let refreshTTL: TimeInterval = 7 * 24 * 3600

    private var lookupCache: [String: Entry] = [:]
    private var missCache = Set<String>()
    private var inFlightRefreshTask: Task<Bool, Never>?
    private var lastFailedRefreshAt: Date?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12.0
        cfg.timeoutIntervalForResource = 45.0
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Looks up exact IMDb `(rating, votes)` for the given lowercase `tt...` IMDb IDs.
    /// Triggers a single non-duplicating background dataset download if missing or stale (> 7 days).
    public func lookup(imdbIds: [String]) async -> [String: Entry] {
        let normalized = Array(Set(imdbIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { $0.hasPrefix("tt") }))
        guard !normalized.isEmpty else { return [:] }

        var result: [String: Entry] = [:]
        var missing = Set<String>()
        for id in normalized {
            if let cached = lookupCache[id] {
                result[id] = cached
            } else if !missCache.contains(id) {
                missing.insert(id)
            }
        }
        guard !missing.isEmpty else { return result }

        let fileURL = datasetFileURL()
        let hasValidLocalFile = isDatasetFresh(at: fileURL)
        let hasAnyLocalFile = FileManager.default.fileExists(atPath: fileURL.path)

        if !hasAnyLocalFile {
            guard !DonbyStoragePaths.isIsolatedHome else { return result }
            let downloaded = await ensureDatasetDownloaded(to: fileURL)
            guard downloaded else { return result }
        } else if !hasValidLocalFile && !DonbyStoragePaths.isIsolatedHome {
            // Serve immediately from existing local file while refreshing in background.
            let targetURL = fileURL
            Task.detached(priority: .utility) {
                _ = await IMDbOfficialRatingsStore.shared.ensureDatasetDownloaded(to: targetURL)
            }
        }

        let scanned = await Task.detached(priority: .utility) {
            Self.scanGzipTSV(at: fileURL, targetIds: missing)
        }.value

        for id in missing {
            if let entry = scanned[id] {
                lookupCache[id] = entry
                result[id] = entry
            } else {
                missCache.insert(id)
            }
        }
        return result
    }

    /// Scans a gzipped `title.ratings.tsv.gz` file on disk for the requested lowercase `tt...` IDs.
    /// Exposed internally for unit testing with synthetic fixtures.
    nonisolated static func scanGzipTSV(at url: URL, targetIds: Set<String>) -> [String: Entry] {
        guard !targetIds.isEmpty else { return [:] }
        guard let gz = gzopen(url.path, "rb") else { return [:] }
        defer { gzclose(gz) }
        gzbuffer(gz, 65_536)

        var found: [String: Entry] = [:]
        found.reserveCapacity(targetIds.count)

        let chunkSize = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var carry = Data()
        carry.reserveCapacity(256)

        func processLine(_ lineBytes: UnsafeBufferPointer<UInt8>) {
            // Format: tt0111161\t9.3\t2950000
            guard lineBytes.count >= 8 else { return }
            // Quick prefix filter: must start with 't', 't'
            if lineBytes[0] != 0x74 || lineBytes[1] != 0x74 { return }

            var firstTab = -1
            var secondTab = -1
            for i in 2..<lineBytes.count {
                if lineBytes[i] == 0x09 {
                    if firstTab == -1 {
                        firstTab = i
                    } else {
                        secondTab = i
                        break
                    }
                }
            }
            guard firstTab > 2, secondTab > firstTab + 1, secondTab + 1 < lineBytes.count else { return }

            let idSlice = UnsafeBufferPointer(rebasing: lineBytes[0..<firstTab])
            let id = String(decoding: idSlice, as: UTF8.self)
            guard targetIds.contains(id) else { return }

            let ratingSlice = UnsafeBufferPointer(rebasing: lineBytes[(firstTab + 1)..<secondTab])
            var endIdx = lineBytes.count
            while endIdx > secondTab + 1 && (lineBytes[endIdx - 1] == 0x0D || lineBytes[endIdx - 1] == 0x0A) {
                endIdx -= 1
            }
            let votesSlice = UnsafeBufferPointer(rebasing: lineBytes[(secondTab + 1)..<endIdx])

            let ratingStr = String(decoding: ratingSlice, as: UTF8.self)
            let votesStr = String(decoding: votesSlice, as: UTF8.self)
            if let rating = Double(ratingStr), let votes = Int(votesStr), rating > 0 && rating <= 10.0 && votes >= 0 {
                found[id] = Entry(rating: rating, votes: votes)
            }
        }

        while found.count < targetIds.count {
            let n = Int(gzread(gz, buffer, UInt32(chunkSize)))
            if n <= 0 { break }

            var lineStart = 0
            for i in 0..<n {
                if buffer[i] == 0x0A { // '\n'
                    if carry.isEmpty {
                        processLine(UnsafeBufferPointer(start: buffer.advanced(by: lineStart), count: i - lineStart))
                    } else {
                        carry.append(buffer.advanced(by: lineStart), count: i - lineStart)
                        carry.withUnsafeBytes { raw in
                            processLine(raw.bindMemory(to: UInt8.self))
                        }
                        carry.removeAll(keepingCapacity: true)
                    }
                    lineStart = i + 1
                    if found.count >= targetIds.count { break }
                }
            }
            if lineStart < n && found.count < targetIds.count {
                carry.append(buffer.advanced(by: lineStart), count: n - lineStart)
            }
        }

        if !carry.isEmpty && found.count < targetIds.count {
            carry.withUnsafeBytes { raw in
                processLine(raw.bindMemory(to: UInt8.self))
            }
        }

        return found
    }

    // MARK: - Private Download & Cache Management

    private func datasetFileURL() -> URL {
        DonbyStoragePaths.cachesDirectoryURL.appendingPathComponent("imdb_official_ratings.tsv.gz")
    }

    private func isDatasetFresh(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64,
              size > 1_000_000 else {
            return false
        }
        return Date().timeIntervalSince(modDate) < Self.refreshTTL
    }

    private func ensureDatasetDownloaded(to destination: URL) async -> Bool {
        if let lastFail = lastFailedRefreshAt, Date().timeIntervalSince(lastFail) < 600 {
            return false
        }
        if let existing = inFlightRefreshTask {
            return await existing.value
        }

        let sess = self.session
        let task = Task<Bool, Never> {
            var req = URLRequest(url: Self.datasetURL)
            req.setValue("Donby/2.0", forHTTPHeaderField: "User-Agent")
            guard let (tempURL, resp) = try? await sess.download(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return false
            }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staging = destination.appendingPathExtension("tmp")
                try? fm.removeItem(at: staging)
                try fm.moveItem(at: tempURL, to: staging)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: destination)
                }
                return true
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
        }

        inFlightRefreshTask = task
        let ok = await task.value
        inFlightRefreshTask = nil
        if ok {
            missCache.removeAll()
        } else {
            lastFailedRefreshAt = Date()
        }
        return ok
    }
}

import Foundation
import DonbyCore

// MARK: - Task C & D: Global Turbo Cache Engine & Disk LRU Manager

public struct CachedMediaSummary: Identifiable, Equatable, Sendable {
    public var id: String { assetKey }
    public let assetKey: String
    public let serverId: UUID?
    public let itemId: String?
    public let mediaSourceId: String?
    public let displayTitle: String
    public let subtitle: String?
    public let posterURLString: String?
    public let sourceURLString: String
    public let cachedBytes: Int64
    public let totalBytes: Int64
    public let lastAccess: Date
    public let isFullyCached: Bool
    public let itemSnapshot: EmbyItem?
    public let mediaSourceSnapshot: MediaSourceInfo?

    public init(
        assetKey: String,
        serverId: UUID?,
        itemId: String?,
        mediaSourceId: String?,
        displayTitle: String,
        subtitle: String?,
        posterURLString: String?,
        sourceURLString: String,
        cachedBytes: Int64,
        totalBytes: Int64,
        lastAccess: Date,
        isFullyCached: Bool,
        itemSnapshot: EmbyItem?,
        mediaSourceSnapshot: MediaSourceInfo?
    ) {
        self.assetKey = assetKey
        self.serverId = serverId
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.posterURLString = posterURLString
        self.sourceURLString = sourceURLString
        self.cachedBytes = cachedBytes
        self.totalBytes = totalBytes
        self.lastAccess = lastAccess
        self.isFullyCached = isFullyCached
        self.itemSnapshot = itemSnapshot
        self.mediaSourceSnapshot = mediaSourceSnapshot
    }

    public var progressFraction: Double {
        guard totalBytes > 0 else { return isFullyCached ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(cachedBytes) / Double(totalBytes)))
    }
}

public final class DonbyTurboCacheEngine: @unchecked Sendable {
    public static let shared = DonbyTurboCacheEngine()

    public let cacheRootDirectory: URL
    private let lock = NSLock()
    private var activeStores: [String: TieredAssetChunkStore] = [:]
    private var fullCacheHandler: (@Sendable (ChunkStoreMeta) -> Void)?
    private var activeDetailPreloadTask: Task<Void, Never>?
    private var activeDetailPreloadKey: String?

    public func setOnAssetFullyCached(_ handler: (@Sendable (ChunkStoreMeta) -> Void)?) {
        lock.lock()
        fullCacheHandler = handler
        lock.unlock()
    }

    internal func notifyAssetFullyCached(_ meta: ChunkStoreMeta) {
        lock.lock()
        let handler = fullCacheHandler
        lock.unlock()
        handler?(meta)
    }

    private init() {
        let cachesDir = DonbyStoragePaths.cachesDirectoryURL
        self.cacheRootDirectory = cachesDir.appendingPathComponent("DonbyMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRootDirectory, withIntermediateDirectories: true)
    }

    internal static func canonicalAssetIdComponent(_ raw: String) -> String {
        if raw.count == 27, let first = raw.first, first == "e" || first == "m" || first == "s" {
            let tail = raw.dropFirst()
            if tail.hasPrefix("01"), tail.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                return String(tail)
            }
        }
        return raw
    }

    public static func makeAssetKey(serverId: UUID, itemId: String, mediaSourceId: String) -> String {
        let raw = "\(serverId.uuidString)_\(canonicalAssetIdComponent(itemId))_\(canonicalAssetIdComponent(mediaSourceId))"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    public func store(
        for assetKey: String,
        maxMemoryBytes: Int = 524_288_000,
        persistDisk: Bool = true
    ) -> TieredAssetChunkStore {
        lock.lock()
        defer { lock.unlock() }
        if let existing = activeStores[assetKey] {
            existing.updateConfiguration(maxMemoryBytes: maxMemoryBytes, persistDisk: persistDisk)
            return existing
        }
        let created = TieredAssetChunkStore(
            assetKey: assetKey,
            rootDirectory: cacheRootDirectory,
            chunkSize: 524_288,
            maxMemoryBytes: maxMemoryBytes,
            persistDisk: persistDisk
        )
        activeStores[assetKey] = created
        return created
    }

    public func removeAsset(assetKey: String, forceIncludePinned: Bool = false) {
        var storeToClose: TieredAssetChunkStore? = nil
        lock.lock()
        if let st = activeStores[assetKey] {
            if st.currentMeta().pinned && !forceIncludePinned {
                lock.unlock()
                return
            }
            storeToClose = activeStores.removeValue(forKey: assetKey)
        }
        lock.unlock()
        storeToClose?.invalidateForRemoval()
        let dir = cacheRootDirectory.appendingPathComponent(assetKey, isDirectory: true)
        if !forceIncludePinned, let meta = loadMeta(in: dir), meta.pinned {
            return
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func cacheAssetDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: cacheRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func loadMeta(in dir: URL, using decoder: JSONDecoder = JSONDecoder()) -> ChunkStoreMeta? {
        let metaURL = dir.appendingPathComponent("meta.json")
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        return try? decoder.decode(ChunkStoreMeta.self, from: d)
    }

    private static func physicalOrCachedBytes(for dataURL: URL, meta: ChunkStoreMeta?) -> Int64 {
        let fm = FileManager.default
        let hasMediaBin = fm.fileExists(atPath: dataURL.path)
        let chunksDir = dataURL.deletingLastPathComponent().appendingPathComponent("chunks", isDirectory: true)
        let hasSpillChunks = fm.fileExists(atPath: chunksDir.path)
        guard hasMediaBin || hasSpillChunks else {
            return 0
        }
        if let meta, !meta.completedChunks.isEmpty {
            return meta.cachedBytes
        }
        if let vals = try? dataURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
           let alloc = vals.totalFileAllocatedSize ?? vals.fileAllocatedSize, alloc > 0 {
            return Int64(alloc)
        }
        if let attrs = try? fm.attributesOfItem(atPath: dataURL.path),
           let sz = attrs[.size] as? NSNumber {
            return sz.int64Value
        }
        return 0
    }

    /// Computes total disk bytes used by unpinned cache vs pinned offline downloads (including ~/Movies/Donby).
    public func calculateDiskUsage() -> (unpinnedCacheBytes: Int64, pinnedDownloadBytes: Int64) {
        var unpinned: Int64 = 0
        var pinned: Int64 = 0
        let decoder = JSONDecoder()

        for dir in cacheAssetDirectories() {
            let parsedMeta = loadMeta(in: dir, using: decoder)
            let dataURL = dir.appendingPathComponent("media.bin")
            let fileSize = Self.physicalOrCachedBytes(for: dataURL, meta: parsedMeta)
            if parsedMeta?.pinned == true {
                pinned += fileSize
            } else {
                unpinned += fileSize
            }
        }

        let moviesRoot = DonbyOfflineLibraryStorage.moviesDonbyRootURL
        if let enumerator = FileManager.default.enumerator(
            at: moviesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   vals.isRegularFile == true,
                   let sz = vals.fileSize {
                    pinned += Int64(sz)
                }
            }
        }

        return (unpinned, pinned)
    }

    /// LRU sweeps unpinned cache directories to keep unpinned disk usage within `maxDiskBytes`.
    public func enforceDiskBudget(maxDiskBytes: Int64) {
        let clampedBudget = max(128 * 1024 * 1024, maxDiskBytes)
        let decoder = JSONDecoder()
        var unpinnedEntries: [(key: String, lastAccess: Date, size: Int64)] = []
        var totalUnpinned: Int64 = 0

        for dir in cacheAssetDirectories() {
            guard let m = loadMeta(in: dir, using: decoder), !m.pinned else { continue }
            let sz = Self.physicalOrCachedBytes(for: dir.appendingPathComponent("media.bin"), meta: m)
            totalUnpinned += sz
            unpinnedEntries.append((key: m.assetKey, lastAccess: m.lastAccess, size: sz))
        }

        guard totalUnpinned > clampedBudget else { return }
        unpinnedEntries.sort { $0.lastAccess < $1.lastAccess }
        for entry in unpinnedEntries {
            if totalUnpinned <= clampedBudget { break }
            removeAsset(assetKey: entry.key, forceIncludePinned: false)
            totalUnpinned -= entry.size
        }
    }

    public func clearAllUnpinnedCache() {
        for dir in cacheAssetDirectories() {
            removeAsset(assetKey: dir.lastPathComponent, forceIncludePinned: false)
        }
    }

    public func cachedProgress(
        forItemId itemId: String,
        serverId: UUID? = nil,
        mediaSourceId: String? = nil
    ) -> CachedMediaSummary? {
        let assets = listUnpinnedCachedAssets()
        if let serverId, let mediaSourceId, !mediaSourceId.isEmpty {
            let exactKey = Self.makeAssetKey(serverId: serverId, itemId: itemId, mediaSourceId: mediaSourceId)
            if let hit = assets.first(where: { $0.assetKey == exactKey }) {
                return hit
            }
        }
        let normTarget = Self.canonicalAssetIdComponent(itemId)
        let normSource = mediaSourceId.map { Self.canonicalAssetIdComponent($0) }
        return assets.first { summary in
            Self.canonicalAssetIdComponent(summary.itemId ?? "") == normTarget &&
            (serverId == nil || summary.serverId == serverId) &&
            (normSource == nil || normSource?.isEmpty == true || Self.canonicalAssetIdComponent(summary.mediaSourceId ?? "") == normSource)
        }
    }

    public func listUnpinnedCachedAssets(excludingAssetKeys: Set<String> = []) -> [CachedMediaSummary] {
        let decoder = JSONDecoder()
        var results: [CachedMediaSummary] = []

        for dir in cacheAssetDirectories() {
            let key = dir.lastPathComponent
            if excludingAssetKeys.contains(key) { continue }
            guard let meta = loadMeta(in: dir, using: decoder), !meta.pinned else { continue }
            let cachedBytes = Self.physicalOrCachedBytes(for: dir.appendingPathComponent("media.bin"), meta: meta)
            guard cachedBytes > 0 else { continue }

            let fallbackTitle = meta.itemSnapshot?.name
                ?? URL(string: meta.sourceURLString)?.lastPathComponent
                ?? "未命名流媒体缓存"
            let title = (meta.displayTitle?.isEmpty == false ? meta.displayTitle : nil) ?? fallbackTitle

            results.append(CachedMediaSummary(
                assetKey: meta.assetKey,
                serverId: meta.serverId,
                itemId: meta.itemId ?? meta.itemSnapshot?.id,
                mediaSourceId: meta.mediaSourceId ?? meta.mediaSourceSnapshot?.id,
                displayTitle: title,
                subtitle: meta.subtitle,
                posterURLString: meta.posterURLString,
                sourceURLString: meta.sourceURLString,
                cachedBytes: cachedBytes,
                totalBytes: meta.totalSize,
                lastAccess: meta.lastAccess,
                isFullyCached: meta.isFullyCached,
                itemSnapshot: meta.itemSnapshot,
                mediaSourceSnapshot: meta.mediaSourceSnapshot
            ))
        }

        return results.sorted { $0.lastAccess > $1.lastAccess }
    }

    private func clearDetailPreloadIfMatching(_ signature: String) {
        lock.lock()
        if activeDetailPreloadKey == signature {
            activeDetailPreloadTask = nil
            activeDetailPreloadKey = nil
        }
        lock.unlock()
    }

    public func cancelDetailPreload() {
        lock.lock()
        let task = activeDetailPreloadTask
        activeDetailPreloadTask = nil
        activeDetailPreloadKey = nil
        lock.unlock()
        task?.cancel()
    }

    /// Background detail-page preloader: writes Chunk 0..3, EOF Cues, and target playhead duration
    /// directly into the shared TieredAssetChunkStore so clicking Play starts from warm cache.
    public func startDetailPreload(
        assetKey: String,
        streamURL: URL,
        cachedRedirectURL: URL?,
        headers: [String: String],
        knownTotalSize: Int64?,
        durationSeconds: Double,
        resumePositionSeconds: Double,
        preloadSeconds: Int,
        maxMemoryBytes: Int = 524_288_000,
        onResolvedRedirectURL: (@Sendable (URL) -> Void)? = nil
    ) {
        let clampedSeconds = max(15, min(300, preloadSeconds))
        let preloadSignature = "\(assetKey)|\(Int(resumePositionSeconds))|\(clampedSeconds)"

        lock.lock()
        if activeDetailPreloadKey == preloadSignature && activeDetailPreloadTask != nil {
            lock.unlock()
            return
        }
        let previous = activeDetailPreloadTask
        activeDetailPreloadTask = nil
        activeDetailPreloadKey = preloadSignature
        lock.unlock()
        previous?.cancel()

        let store = self.store(for: assetKey, maxMemoryBytes: max(64 * 1024 * 1024, maxMemoryBytes), persistDisk: true)
        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                self?.clearDetailPreloadIfMatching(preloadSignature)
            }

            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.waitsForConnectivity = false
            sessionConfig.timeoutIntervalForRequest = 12
            sessionConfig.timeoutIntervalForResource = 60
            let session = URLSession(configuration: sessionConfig)
            defer { session.finishTasksAndInvalidate() }

            var activeURL = cachedRedirectURL ?? streamURL
            var totalSize = max(knownTotalSize ?? 0, store.currentMeta().totalSize)
            let chunkSize = Int64(store.currentMeta().chunkSize)
            guard chunkSize > 0 else { return }

            func makeRangeRequest(url: URL, startByte: Int64, endByte: Int64) -> URLRequest {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                req.httpMethod = "GET"
                req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")
                for (k, v) in headers where k.lowercased() != "range" {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                return req
            }

            func record206Metadata(resp: URLResponse, startByte: Int64, dataCount: Int) {
                if let finalURL = resp.url, finalURL != activeURL {
                    activeURL = finalURL
                    onResolvedRedirectURL?(finalURL)
                }
                if let http = resp as? HTTPURLResponse,
                   let parsedTotal = TurboStreamByteHandle.parseTotalSize(from: http, startByte: startByte, dataCount: dataCount),
                   parsedTotal > 0 {
                    totalSize = parsedTotal
                    store.setTotalSize(parsedTotal, sourceURL: streamURL.absoluteString)
                }
            }

            func fetchRange(startByte: Int64, endByte: Int64) async -> (data: Data, status: Int)? {
                guard !Task.isCancelled, endByte >= startByte else { return nil }
                do {
                    let (data, resp) = try await session.data(for: makeRangeRequest(url: activeURL, startByte: startByte, endByte: endByte))
                    guard !Task.isCancelled, let http = resp as? HTTPURLResponse else { return nil }
                    if http.statusCode == 206 {
                        record206Metadata(resp: resp, startByte: startByte, dataCount: data.count)
                        return (data, 206)
                    }
                    // If cached redirect expired, retry once against origin URL
                    if activeURL != streamURL && (http.statusCode == 403 || http.statusCode == 404 || http.statusCode == 410 || http.statusCode == 200) {
                        activeURL = streamURL
                        let (retryData, retryResp) = try await session.data(for: makeRangeRequest(url: streamURL, startByte: startByte, endByte: endByte))
                        guard !Task.isCancelled, let retryHttp = retryResp as? HTTPURLResponse, retryHttp.statusCode == 206 else {
                            return nil
                        }
                        record206Metadata(resp: retryResp, startByte: startByte, dataCount: retryData.count)
                        return (retryData, 206)
                    }
                    return (Data(), http.statusCode)
                } catch {
                    return nil
                }
            }

            func storeAlignedRange(startChunk: Int, chunkCount: Int) async -> Bool {
                var idx = startChunk
                let endExcl = startChunk + chunkCount
                while idx < endExcl {
                    if Task.isCancelled { return false }
                    let metaNow = store.currentMeta()
                    if metaNow.totalChunks > 0 && idx >= metaNow.totalChunks { break }
                    if store.hasChunk(idx) {
                        idx += 1
                        continue
                    }
                    // Batch up to 4 contiguous missing chunks (2 MiB) per Range request
                    var batchEnd = idx + 1
                    let maxBatch = min(endExcl, idx + 4)
                    while batchEnd < maxBatch {
                        if metaNow.totalChunks > 0 && batchEnd >= metaNow.totalChunks { break }
                        if store.hasChunk(batchEnd) { break }
                        batchEnd += 1
                    }
                    let startByte = Int64(idx) * chunkSize
                    var endByte = Int64(batchEnd) * chunkSize - 1
                    if totalSize > 0 {
                        endByte = min(endByte, totalSize - 1)
                    }
                    guard endByte >= startByte else { break }
                    guard let res = await fetchRange(startByte: startByte, endByte: endByte), res.status == 206, !res.data.isEmpty else {
                        return false
                    }
                    var cursor = 0
                    var cIdx = idx
                    while cursor < res.data.count && cIdx < batchEnd {
                        let expected = store.expectedChunkLength(for: cIdx)
                        let take = expected > 0 ? min(expected, res.data.count - cursor) : min(Int(chunkSize), res.data.count - cursor)
                        if take <= 0 { break }
                        if expected == 0 || take == expected {
                            store.storeChunk(index: cIdx, data: Data(res.data[cursor..<(cursor + take)]))
                        }
                        cursor += take
                        cIdx += 1
                    }
                    idx = batchEnd
                }
                return true
            }

            // 1. Always ensure container header is cached. When starting at 0s, fetch Chunks 0..3 (2 MiB)
            // in a single Range RTT so interrupting preload right after step 1 never leaves a Chunk-0-only trap.
            let initialHeadChunks = (resumePositionSeconds <= 0.5) ? 4 : 1
            if (0..<initialHeadChunks).contains(where: { !store.hasChunk($0) }) {
                guard await storeAlignedRange(startChunk: 0, chunkCount: initialHeadChunks) else { return }
            }
            guard !Task.isCancelled else { return }

            // 2. Always ensure final 2 EOF chunks (MKV Cues / MP4 moov) are cached when totalSize is known
            let metaAfterHead = store.currentMeta()
            if metaAfterHead.totalChunks >= 3 {
                let tailStart = metaAfterHead.totalChunks - 2
                if !store.hasChunk(tailStart) || !store.hasChunk(tailStart + 1) {
                    _ = await storeAlignedRange(startChunk: tailStart, chunkCount: 2)
                }
            }
            guard !Task.isCancelled else { return }

            // 3. Preload target duration window anchored at the exact Play-button start position
            let bytesPerSec: Double = (totalSize > 0 && durationSeconds > 10)
                ? (Double(totalSize) / durationSeconds)
                : 2_500_000.0
            let rawTargetBytes = Int64(Double(clampedSeconds) * bytesPerSec)
            let maxBudgetBytes = min(Int64(maxMemoryBytes / 2), 384 * 1024 * 1024)
            let clampedBytes = max(4 * 1024 * 1024, min(maxBudgetBytes, rawTargetBytes))
            let targetChunkCount = max(8, Int((clampedBytes + chunkSize - 1) / chunkSize))

            var playheadChunk = 0
            var preloadChunks = targetChunkCount
            if resumePositionSeconds > 0.5, totalSize > 0, durationSeconds > 10 {
                let frac = max(0.0, min(0.98, resumePositionSeconds / durationSeconds))
                let estByte = Int64(frac * Double(totalSize))
                let estChunk = Int(estByte / chunkSize)
                if estChunk > 4 {
                    playheadChunk = estChunk - 4
                    preloadChunks = targetChunkCount + 4
                }
            }

            let ok = await storeAlignedRange(startChunk: playheadChunk, chunkCount: preloadChunks)
            if ok && !Task.isCancelled {
                DonbyLogger.shared.log(
                    "详情页预加载完成: 起点 \(String(format: "%.0fs", resumePositionSeconds)), 预读 \(clampedSeconds)s (\(preloadChunks) 分片 / 约 \(clampedBytes / (1024 * 1024)) MB, 起点分片 #\(playheadChunk))",
                    level: .info,
                    subsystem: "Turbo"
                )
            }
        }

        lock.lock()
        activeDetailPreloadTask = task
        lock.unlock()
    }
}

// MARK: - Task D: Offline Download Models (Shared Pinned ChunkStore)

public enum DownloadTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued = "queued"
    case downloading = "downloading"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"

    public var displayTitle: String {
        switch self {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
}

public struct OfflineSubtitleAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: String { localFileName }
    public let name: String
    public let localFileName: String
    public let streamIndex: Int?
    public let codec: String?

    public init(name: String, localFileName: String, streamIndex: Int?, codec: String?) {
        self.name = name
        self.localFileName = localFileName
        self.streamIndex = streamIndex
        self.codec = codec
    }
}

public enum DownloadOrigin: String, Codable, Sendable {
    case manualDownload = "manual"
    case autoArchivedFromCache = "autoArchived"
}

public struct DownloadEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { assetKey }
    public let assetKey: String
    public let serverId: UUID
    public let serverName: String
    public let itemId: String
    public let mediaSourceId: String
    public let title: String
    public let subtitle: String?
    public let posterURLString: String?
    public let resolutionBadge: String?
    public var streamURLString: String
    public var downloadURLString: String
    public var headers: [String: String]
    public var itemSnapshot: EmbyItem
    public var mediaSourceSnapshot: MediaSourceInfo
    public var offlineSubtitles: [OfflineSubtitleAsset]
    public var localVideoFilePath: String?
    public var localFolderPath: String?
    public var localSeriesFolderPath: String?
    public var localPosterPath: String?
    public var localBackdropPath: String?
    public var localThumbPath: String?
    public var localLogoPath: String?
    public var status: DownloadTaskStatus
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var speedMBs: Double
    public var errorMessage: String?
    public var origin: DownloadOrigin
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case assetKey, serverId, serverName, itemId, mediaSourceId, title, subtitle, posterURLString
        case resolutionBadge, streamURLString, downloadURLString, headers, itemSnapshot, mediaSourceSnapshot
        case offlineSubtitles, localVideoFilePath, localFolderPath, localSeriesFolderPath
        case localPosterPath, localBackdropPath, localThumbPath, localLogoPath
        case status, totalBytes, downloadedBytes, speedMBs, errorMessage, origin, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetKey = try c.decode(String.self, forKey: .assetKey)
        serverId = try c.decode(UUID.self, forKey: .serverId)
        serverName = try c.decode(String.self, forKey: .serverName)
        itemId = try c.decode(String.self, forKey: .itemId)
        mediaSourceId = try c.decode(String.self, forKey: .mediaSourceId)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        posterURLString = try c.decodeIfPresent(String.self, forKey: .posterURLString)
        resolutionBadge = try c.decodeIfPresent(String.self, forKey: .resolutionBadge)
        streamURLString = try c.decode(String.self, forKey: .streamURLString)
        downloadURLString = try c.decode(String.self, forKey: .downloadURLString)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        itemSnapshot = try c.decode(EmbyItem.self, forKey: .itemSnapshot)
        mediaSourceSnapshot = try c.decode(MediaSourceInfo.self, forKey: .mediaSourceSnapshot)
        offlineSubtitles = try c.decodeIfPresent([OfflineSubtitleAsset].self, forKey: .offlineSubtitles) ?? []
        localVideoFilePath = try c.decodeIfPresent(String.self, forKey: .localVideoFilePath)
        localFolderPath = try c.decodeIfPresent(String.self, forKey: .localFolderPath)
        localSeriesFolderPath = try c.decodeIfPresent(String.self, forKey: .localSeriesFolderPath)
        localPosterPath = try c.decodeIfPresent(String.self, forKey: .localPosterPath)
        localBackdropPath = try c.decodeIfPresent(String.self, forKey: .localBackdropPath)
        localThumbPath = try c.decodeIfPresent(String.self, forKey: .localThumbPath)
        localLogoPath = try c.decodeIfPresent(String.self, forKey: .localLogoPath)
        status = try c.decode(DownloadTaskStatus.self, forKey: .status)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        downloadedBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        speedMBs = try c.decodeIfPresent(Double.self, forKey: .speedMBs) ?? 0
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        origin = try c.decodeIfPresent(DownloadOrigin.self, forKey: .origin) ?? .manualDownload
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public init(
        assetKey: String,
        serverId: UUID,
        serverName: String,
        itemId: String,
        mediaSourceId: String,
        title: String,
        subtitle: String?,
        posterURLString: String?,
        resolutionBadge: String?,
        streamURLString: String,
        downloadURLString: String,
        headers: [String: String],
        itemSnapshot: EmbyItem,
        mediaSourceSnapshot: MediaSourceInfo,
        offlineSubtitles: [OfflineSubtitleAsset] = [],
        localVideoFilePath: String? = nil,
        localFolderPath: String? = nil,
        localSeriesFolderPath: String? = nil,
        localPosterPath: String? = nil,
        localBackdropPath: String? = nil,
        localThumbPath: String? = nil,
        localLogoPath: String? = nil,
        status: DownloadTaskStatus = .queued,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        speedMBs: Double = 0.0,
        errorMessage: String? = nil,
        origin: DownloadOrigin = .manualDownload,
        createdAt: Date = Date()
    ) {
        self.assetKey = assetKey
        self.serverId = serverId
        self.serverName = serverName
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.title = title
        self.subtitle = subtitle
        self.posterURLString = posterURLString
        self.resolutionBadge = resolutionBadge
        self.streamURLString = streamURLString
        self.downloadURLString = downloadURLString
        self.headers = headers
        self.itemSnapshot = itemSnapshot
        self.mediaSourceSnapshot = mediaSourceSnapshot
        self.offlineSubtitles = offlineSubtitles
        self.localVideoFilePath = localVideoFilePath
        self.localFolderPath = localFolderPath
        self.localSeriesFolderPath = localSeriesFolderPath
        self.localPosterPath = localPosterPath
        self.localBackdropPath = localBackdropPath
        self.localThumbPath = localThumbPath
        self.localLogoPath = localLogoPath
        self.status = status
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.speedMBs = speedMBs
        self.errorMessage = errorMessage
        self.origin = origin
        self.createdAt = createdAt
    }

    mutating func applyLayoutPaths(_ layout: OfflineLibraryPaths) {
        localVideoFilePath = layout.videoFileURL.path
        localFolderPath = layout.itemFolderURL.path
        localSeriesFolderPath = layout.seriesFolderURL?.path
        localPosterPath = layout.primaryPosterFileURL.path
        localBackdropPath = layout.backdropFileURL.path
        localThumbPath = layout.thumbFileURL.path
        localLogoPath = layout.clearLogoFileURL.path
    }

    public var progressFraction: Double {
        guard totalBytes > 0 else { return status == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public var hydratedItemSnapshot: EmbyItem {
        DonbyOfflineLibraryStorage.hydrateArtworkURLs(
            for: itemSnapshot,
            posterURL: localPosterPath.map { URL(fileURLWithPath: $0) },
            backdropURL: localBackdropPath.map { URL(fileURLWithPath: $0) },
            thumbURL: localThumbPath.map { URL(fileURLWithPath: $0) },
            logoURL: localLogoPath.map { URL(fileURLWithPath: $0) }
        )
    }

    /// Converts UHD `/play/video/{assetId}` -> `/download/video/{assetId}` and `/play/subtitle/{assetId}` -> `/download/subtitle/{assetId}`.
    public static func derivePreferredDownloadURL(from playURL: URL) -> URL {
        let raw = playURL.absoluteString
        if raw.contains("/play/video/") {
            let converted = raw.replacingOccurrences(of: "/play/video/", with: "/download/video/")
            if let u = URL(string: converted) { return u }
        }
        if raw.contains("/play/subtitle/") {
            let converted = raw.replacingOccurrences(of: "/play/subtitle/", with: "/download/subtitle/")
            if let u = URL(string: converted) { return u }
        }
        return playURL
    }
}

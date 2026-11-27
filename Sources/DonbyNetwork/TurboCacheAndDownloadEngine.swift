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
    let lock = NSLock()
    private var activeStores: [String: TieredAssetChunkStore] = [:]
    private var fullCacheHandler: (@Sendable (ChunkStoreMeta) -> Void)?
    var activeDetailPreloadTask: Task<Void, Never>?
    var activeDetailPreloadKey: String?
    var activeMicroStageTask: Task<Void, Never>?
    var activeMicroStageKey: String?

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

    /// Async off-main-actor snapshot of disk usage via `.utility` detached task.
    public func calculateDiskUsageAsync() async -> (unpinnedCacheBytes: Int64, pinnedDownloadBytes: Int64) {
        await Task.detached(priority: .utility) { [self] in
            self.calculateDiskUsage()
        }.value
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

    /// Async off-main-actor removal of all unpinned cache directories via `.utility` detached task.
    public func clearAllUnpinnedCacheAsync() async {
        await Task.detached(priority: .utility) { [self] in
            self.clearAllUnpinnedCache()
        }.value
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

    /// Async off-main-actor snapshot of unpinned cached media summaries via `.utility` detached task.
    public func listUnpinnedCachedAssetsAsync(excludingAssetKeys: Set<String> = []) async -> [CachedMediaSummary] {
        await Task.detached(priority: .utility) { [self] in
            self.listUnpinnedCachedAssets(excludingAssetKeys: excludingAssetKeys)
        }.value
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

import Foundation
import DonbyCore

// MARK: - Task D: Offline Download Coordinator (Shares Pinned ChunkStore & ~/Movies/Donby Library)

@MainActor
public final class DonbyDownloadManager: ObservableObject {
    public static let shared = DonbyDownloadManager()

    @Published public internal(set) var entries: [DownloadEntry] = []
    @Published public private(set) var statusIndex: DonbyDownloadStatusIndex = .empty
    @Published public var maxConcurrentDownloads: Int = 2

    var workerTasks: [String: Task<Void, Never>] = [:]
    private var connectionBudgetByAssetKey: [String: Int] = [:]
    private let storageFileURL: URL
    private var statusRevision: Int = 0
    private var lastProgressStatusSync: TimeInterval = 0

    private init() {
        DonbyOfflineLibraryStorage.ensureRootDirectories()
        let appSupport = DonbyStoragePaths.applicationSupportDirectoryURL
        let dir = appSupport.appendingPathComponent("Donby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageFileURL = dir.appendingPathComponent("downloads_v1.json")
        loadFromDisk()
    }

    public func entry(for assetKey: String) -> DownloadEntry? {
        entries.first { $0.assetKey == assetKey }
    }

    public func entry(forItemId itemId: String, serverId: UUID? = nil) -> DownloadEntry? {
        entries.first { entry in
            entry.itemId == itemId && (serverId == nil || entry.serverId == serverId)
        }
    }

    public func cleanupRedundantCacheIfMaterialized(assetKey: String) {
        guard let existing = entry(for: assetKey),
              existing.status == .completed,
              let localPath = existing.localVideoFilePath,
              FileManager.default.fileExists(atPath: localPath) else {
            return
        }
        DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
    }

    public func updateOfflinePlaybackProgress(
        itemId: String,
        played: Bool? = nil,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        persistDiskNow: Bool = true
    ) {
        var didChange = false
        for idx in entries.indices where entries[idx].itemId == itemId {
            var snapshot = entries[idx].itemSnapshot
            var ud = snapshot.userData ?? EmbyUserData()
            if let played {
                ud.played = played
                if played {
                    ud.playedPercentage = 100.0
                    ud.playbackPositionTicks = 0
                }
            }
            if let pos = positionSeconds, pos >= 0 {
                ud.playbackPositionTicks = Int64(pos * 10_000_000.0)
                if let dur = durationSeconds, dur > 0 {
                    let pct = min(100.0, max(0.0, (pos / dur) * 100.0))
                    ud.playedPercentage = pct
                    if pct >= 92.0 {
                        ud.played = true
                    }
                }
            }
            snapshot.userData = ud
            entries[idx].itemSnapshot = snapshot
            didChange = true

            if persistDiskNow, let localPath = entries[idx].localVideoFilePath {
                let videoURL = URL(fileURLWithPath: localPath)
                let stem = videoURL.deletingPathExtension().lastPathComponent
                let sidecarURL = videoURL.deletingLastPathComponent().appendingPathComponent("\(stem).meta.json")
                if let d = try? Data(contentsOf: sidecarURL),
                   var sidecar = try? JSONDecoder().decode(OfflineEpisodeOrMovieSidecar.self, from: d) {
                    sidecar.item = snapshot
                    if let encoded = try? JSONEncoder().encode(sidecar) {
                        try? encoded.write(to: sidecarURL, options: .atomic)
                    }
                }
            }
        }
        if didChange && persistDiskNow {
            saveToDisk()
        }
    }

    public func completedEntry(for itemId: String, serverId: UUID? = nil, mediaSourceId: String? = nil) -> DownloadEntry? {
        entries.first { entry in
            entry.itemId == itemId &&
            entry.status == .completed &&
            (serverId == nil || entry.serverId == serverId) &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || entry.mediaSourceId == mediaSourceId) &&
            hasPlayableBackingFile(for: entry)
        }
    }

    public func activeOrCompletedEntry(for itemId: String, serverId: UUID? = nil, mediaSourceId: String? = nil) -> DownloadEntry? {
        if let done = completedEntry(for: itemId, serverId: serverId, mediaSourceId: mediaSourceId) {
            return done
        }
        return entries.first { entry in
            entry.itemId == itemId &&
            (serverId == nil || entry.serverId == serverId) &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || entry.mediaSourceId == mediaSourceId)
        }
    }

    private func hasPlayableBackingFile(for entry: DownloadEntry) -> Bool {
        if let localPath = entry.localVideoFilePath,
           FileManager.default.fileExists(atPath: localPath) {
            return true
        }
        let store = DonbyTurboCacheEngine.shared.store(for: entry.assetKey, persistDisk: true)
        return store.currentMeta().isFullyCached && FileManager.default.fileExists(atPath: store.dataFileURL.path)
    }

    public func offlinePlayableResource(for entry: DownloadEntry) -> ResolvedPlaybackResource? {
        let store = DonbyTurboCacheEngine.shared.store(for: entry.assetKey, persistDisk: true)
        let videoURL: URL
        if let localPath = entry.localVideoFilePath, FileManager.default.fileExists(atPath: localPath) {
            videoURL = URL(fileURLWithPath: localPath)
        } else {
            let meta = store.currentMeta()
            guard meta.isFullyCached && FileManager.default.fileExists(atPath: store.dataFileURL.path) else {
                return nil
            }
            videoURL = store.dataFileURL
        }

        let legacySubDir = store.assetDirectory.appendingPathComponent("subtitles", isDirectory: true)
        let localDir = entry.localFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var resolvedSubs: [SubtitleResourceItem] = []
        for sub in entry.offlineSubtitles {
            if let localDir {
                let candidate = localDir.appendingPathComponent(sub.localFileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    resolvedSubs.append(SubtitleResourceItem(
                        name: sub.name,
                        url: candidate,
                        streamIndex: sub.streamIndex,
                        codec: sub.codec,
                        isExternal: true
                    ))
                    continue
                }
            }
            let legacyCandidate = legacySubDir.appendingPathComponent(sub.localFileName)
            if FileManager.default.fileExists(atPath: legacyCandidate.path) {
                resolvedSubs.append(SubtitleResourceItem(
                    name: sub.name,
                    url: legacyCandidate,
                    streamIndex: sub.streamIndex,
                    codec: sub.codec,
                    isExternal: true
                ))
            }
        }
        return ResolvedPlaybackResource(
            streamURL: videoURL,
            headers: [:],
            playSessionId: "offline-\(entry.assetKey)",
            mediaSource: entry.mediaSourceSnapshot,
            subtitleURLs: resolvedSubs,
            isDirectStream: true,
            routeNote: entry.localVideoFilePath != nil ? "离线媒体库 (~/Movies/Donby)" : "本地离线缓存 (Pinned ChunkStore)"
        )
    }

    public func enqueueDownload(
        server: EmbyServerConfig,
        item: EmbyItem,
        seriesItem: EmbyItem? = nil,
        resource: ResolvedPlaybackResource,
        title: String,
        subtitle: String?,
        posterURLString: String?,
        itemArtworkURLs: (poster: URL?, backdrop: URL?, thumb: URL?, logo: URL?, seasonPoster: URL?) = (nil, nil, nil, nil, nil),
        seriesArtworkURLs: (poster: URL?, backdrop: URL?, logo: URL?) = (nil, nil, nil),
        connectionBudgetPerTask: Int = 3,
        origin: DownloadOrigin = .manualDownload
    ) {
        let assetKey = DonbyTurboCacheEngine.makeAssetKey(
            serverId: server.id,
            itemId: item.id,
            mediaSourceId: resource.mediaSource.id
        )
        let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
        store.setPinned(true)
        if let knownSize = resource.mediaSource.size, knownSize > 0 {
            store.setTotalSize(knownSize, sourceURL: resource.streamURL.absoluteString)
        }

        let layout = DonbyOfflineLibraryStorage.makeLayoutPaths(
            item: item,
            seriesItem: seriesItem,
            mediaSource: resource.mediaSource,
            streamURL: resource.streamURL
        )
        try? FileManager.default.createDirectory(at: layout.itemFolderURL, withIntermediateDirectories: true)
        if let seriesDir = layout.seriesFolderURL {
            try? FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)
        }

        let preferredDownloadURL = resource.downloadURL ?? DownloadEntry.derivePreferredDownloadURL(from: resource.streamURL)
        let existingMeta = store.currentMeta()
        let alreadyOnDisk = FileManager.default.fileExists(atPath: layout.videoFileURL.path)

        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].streamURLString = resource.streamURL.absoluteString
            entries[idx].downloadURLString = preferredDownloadURL.absoluteString
            entries[idx].headers = resource.headers
            entries[idx].applyLayoutPaths(layout)
            if origin == .manualDownload {
                entries[idx].origin = .manualDownload
            }
            if entries[idx].status == .paused || entries[idx].status == .failed {
                entries[idx].status = alreadyOnDisk ? .completed : .queued
                entries[idx].errorMessage = nil
            }
        } else {
            var newEntry = DownloadEntry(
                assetKey: assetKey,
                serverId: server.id,
                serverName: server.name,
                itemId: item.id,
                mediaSourceId: resource.mediaSource.id,
                title: title,
                subtitle: subtitle,
                posterURLString: posterURLString,
                resolutionBadge: item.resolutionBadge,
                streamURLString: resource.streamURL.absoluteString,
                downloadURLString: preferredDownloadURL.absoluteString,
                headers: resource.headers,
                itemSnapshot: item,
                mediaSourceSnapshot: resource.mediaSource,
                status: (alreadyOnDisk || existingMeta.isFullyCached) ? .completed : .queued,
                totalBytes: max(existingMeta.totalSize, resource.mediaSource.size ?? 0),
                downloadedBytes: existingMeta.cachedBytes,
                speedMBs: 0.0,
                errorMessage: nil,
                origin: origin
            )
            newEntry.applyLayoutPaths(layout)
            entries.insert(newEntry, at: 0)
        }
        saveToDisk()

        Task {
            await downloadMetadataAndArtwork(
                assetKey: assetKey,
                server: server,
                item: item,
                seriesItem: seriesItem,
                mediaSource: resource.mediaSource,
                layout: layout,
                headers: resource.headers,
                itemArtworkURLs: itemArtworkURLs,
                seriesArtworkURLs: seriesArtworkURLs
            )
            await downloadExternalSubtitles(
                assetKey: assetKey,
                subtitles: resource.subtitleURLs,
                headers: resource.headers,
                layout: layout,
                server: server,
                item: item,
                mediaSource: resource.mediaSource
            )
        }

        connectionBudgetByAssetKey[assetKey] = max(1, min(6, connectionBudgetPerTask))
        if existingMeta.isFullyCached && !alreadyOnDisk {
            Task.detached(priority: .utility) {
                let total = max(existingMeta.totalSize, 0)
                Self.materializeAndCleanupIfIdle(store: store, assetKey: assetKey, destinationURL: layout.videoFileURL, expectedSize: total)
                await MainActor.run {
                    DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: total)
                }
            }
        } else {
            scheduleQueue(connectionBudgetPerTask: connectionBudgetPerTask)
        }
    }

    public func pauseDownload(assetKey: String) {
        workerTasks[assetKey]?.cancel()
        workerTasks.removeValue(forKey: assetKey)
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            if entries[idx].status == .downloading || entries[idx].status == .queued {
                let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
                let persistedBytes = store.cachedBytesFast()
                if persistedBytes > 0 || entries[idx].downloadedBytes > 0 {
                    entries[idx].downloadedBytes = persistedBytes > 0 ? persistedBytes : entries[idx].downloadedBytes
                }
                entries[idx].status = .paused
                entries[idx].speedMBs = 0.0
                saveToDisk()
            }
        }
        scheduleQueue()
    }

    public func resumeDownload(assetKey: String, connectionBudgetPerTask: Int = 3) {
        connectionBudgetByAssetKey[assetKey] = max(1, min(6, connectionBudgetPerTask))
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            if entries[idx].status != .completed {
                entries[idx].status = .queued
                entries[idx].errorMessage = nil
                saveToDisk()
            }
        }
        scheduleQueue(connectionBudgetPerTask: connectionBudgetPerTask)
    }

    public func promoteToManualDownload(assetKey: String) {
        guard let idx = entries.firstIndex(where: { $0.assetKey == assetKey }),
              entries[idx].origin != .manualDownload else { return }
        entries[idx].origin = .manualDownload
        saveToDisk()
    }

    @discardableResult
    public func removeAutoArchivedAfterPlayback(itemId: String, mediaSourceId: String? = nil) -> DownloadEntry? {
        guard let target = entries.first(where: { entry in
            entry.origin == .autoArchivedFromCache &&
            entry.itemId == itemId &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || entry.mediaSourceId == mediaSourceId)
        }) else {
            return nil
        }
        removeDownload(assetKey: target.assetKey, deleteCachedData: true)
        return target
    }

    public func removeDownload(assetKey: String, deleteCachedData: Bool = true) {
        workerTasks[assetKey]?.cancel()
        workerTasks.removeValue(forKey: assetKey)
        let removedEntry = entries.first { $0.assetKey == assetKey }
        entries.removeAll { $0.assetKey == assetKey }
        saveToDisk()
        let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
        store.setPinned(false)
        if deleteCachedData {
            store.closeFileHandles()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
            if let removedEntry {
                cleanupOfflineMediaFiles(for: removedEntry)
            }
        }
        scheduleQueue()
    }

    private func cleanupOfflineMediaFiles(for entry: DownloadEntry) {
        let fm = FileManager.default
        if let videoPath = entry.localVideoFilePath {
            let videoURL = URL(fileURLWithPath: videoPath)
            let stem = videoURL.deletingPathExtension().lastPathComponent
            let folder = videoURL.deletingLastPathComponent()
            try? fm.removeItem(at: videoURL)
            try? fm.removeItem(at: folder.appendingPathComponent("\(stem).meta.json"))
            try? fm.removeItem(at: folder.appendingPathComponent("\(stem)-thumb.jpg"))
            for sub in entry.offlineSubtitles {
                try? fm.removeItem(at: folder.appendingPathComponent(sub.localFileName))
            }
            pruneEmptyFolderArtworkAndDirs(startingAt: folder, seriesFolder: entry.localSeriesFolderPath.map { URL(fileURLWithPath: $0) })
        }
    }

    private func pruneEmptyFolderArtworkAndDirs(startingAt folder: URL, seriesFolder: URL?) {
        let fm = FileManager.default
        let videoExts: Set<String> = ["mkv", "mp4", "mov", "m4v", "webm", "avi", "ts", "m2ts", "flv"]

        func directoryHasVideos(_ dir: URL) -> Bool {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return false
            }
            for case let file as URL in enumerator {
                if videoExts.contains(file.pathExtension.lowercased()) {
                    return true
                }
            }
            return false
        }

        if !directoryHasVideos(folder) {
            try? fm.removeItem(at: folder)
        }
        if let seriesFolder, seriesFolder != folder, !directoryHasVideos(seriesFolder) {
            try? fm.removeItem(at: seriesFolder)
        }
    }

    private func scheduleQueue(connectionBudgetPerTask: Int? = nil) {
        let activeCount = entries.filter { $0.status == .downloading }.count
        guard activeCount < maxConcurrentDownloads else { return }

        for idx in entries.indices where entries[idx].status == .queued {
            let currentlyActive = entries.filter { $0.status == .downloading }.count
            if currentlyActive >= maxConcurrentDownloads { break }
            entries[idx].status = .downloading
            entries[idx].errorMessage = nil
            saveToDisk()
            let budget = connectionBudgetByAssetKey[entries[idx].assetKey] ?? connectionBudgetPerTask ?? 3
            startDownloadWorker(for: entries[idx], connectionBudget: budget)
        }
    }

    @discardableResult
    nonisolated static func materializeAndCleanupIfIdle(
        store: TieredAssetChunkStore,
        assetKey: String,
        destinationURL: URL,
        expectedSize: Int64
    ) -> Bool {
        let res = materializeCompletedVideoFile(store: store, destinationURL: destinationURL, expectedSize: expectedSize)
        if res.success && !res.keptCacheForActiveReader {
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
        }
        return res.success
    }

    nonisolated private static func materializeCompletedVideoFile(
        store: TieredAssetChunkStore,
        destinationURL: URL,
        expectedSize: Int64
    ) -> (success: Bool, keptCacheForActiveReader: Bool) {
        let fm = FileManager.default
        let dir = destinationURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        store.prepareContiguousMediaBinForMaterialization()
        let src = store.dataFileURL
        guard fm.fileExists(atPath: src.path) else {
            return (fm.fileExists(atPath: destinationURL.path), false)
        }

        // If PlayerView is currently streaming from this ChunkStore, use APFS CoW copy instead of moving media.bin out from under the reader.
        let hasActiveReaders = store.activeReaderCount > 0
        if !hasActiveReaders {
            store.closeFileHandles()
        } else {
            store.flushMeta()
        }

        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            if hasActiveReaders {
                try fm.copyItem(at: src, to: destinationURL)
            } else {
                try fm.moveItem(at: src, to: destinationURL)
            }
            if expectedSize > 0 {
                let handle = try FileHandle(forUpdating: destinationURL)
                try handle.truncate(atOffset: UInt64(expectedSize))
                try handle.close()
            }
            return (true, hasActiveReaders)
        } catch {
            return (false, hasActiveReaders)
        }
    }

    func updateProgress(assetKey: String, downloadedBytes: Int64, totalBytes: Int64, speedMBs: Double) {
        guard let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) else { return }
        entries[idx].downloadedBytes = downloadedBytes
        if totalBytes > 0 { entries[idx].totalBytes = totalBytes }
        entries[idx].speedMBs = speedMBs
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressStatusSync >= 1.0 {
            lastProgressStatusSync = now
            rebuildStatusIndex()
        }
    }

    func markCompleted(assetKey: String, totalBytes: Int64) {
        workerTasks.removeValue(forKey: assetKey)
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].status = .completed
            if totalBytes > 0 {
                entries[idx].totalBytes = totalBytes
                entries[idx].downloadedBytes = totalBytes
            }
            entries[idx].speedMBs = 0.0
            entries[idx].errorMessage = nil
            DonbyLogger.shared.log("离线下载完成: \(entries[idx].title)", level: .info, subsystem: "Download")
        }
        saveToDisk()
        scheduleQueue()
    }

    func markFailed(assetKey: String, message: String) {
        workerTasks.removeValue(forKey: assetKey)
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].status = .failed
            entries[idx].speedMBs = 0.0
            entries[idx].errorMessage = message
            DonbyLogger.shared.log("离线下载失败 (\(entries[idx].title)): \(message)", level: .error, subsystem: "Download")
        }
        saveToDisk()
        scheduleQueue()
    }

    private func rebuildStatusIndex() {
        var completedIds = Set<String>()
        var inProgress: [String: Double] = [:]
        var seriesIdCounts: [String: Int] = [:]
        var seriesNameCounts: [String: Int] = [:]
        var seenSeriesEpisodes = Set<String>()

        for entry in entries {
            if entry.status == .completed && hasPlayableBackingFile(for: entry) {
                completedIds.insert(entry.itemId)
                if entry.itemSnapshot.isEpisode {
                    let uniqueEpKey = entry.itemId
                    if seenSeriesEpisodes.insert(uniqueEpKey).inserted {
                        if let sId = entry.itemSnapshot.seriesId, !sId.isEmpty {
                            seriesIdCounts[sId, default: 0] += 1
                        }
                        if let sName = entry.itemSnapshot.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                           !sName.isEmpty {
                            seriesNameCounts[sName, default: 0] += 1
                        }
                    }
                }
            } else if entry.status == .downloading || entry.status == .queued {
                inProgress[entry.itemId] = max(inProgress[entry.itemId] ?? 0, entry.progressFraction)
            }
        }

        statusRevision &+= 1
        statusIndex = DonbyDownloadStatusIndex(
            revision: statusRevision,
            completedItemIds: completedIds,
            inProgressByItemId: inProgress,
            completedCountBySeriesId: seriesIdCounts,
            completedCountBySeriesName: seriesNameCounts
        )
    }

    private func loadFromDisk() {
        defer { rebuildStatusIndex() }
        guard let data = try? Data(contentsOf: storageFileURL),
              let decoded = try? JSONDecoder().decode([DownloadEntry].self, from: data) else {
            return
        }
        self.entries = decoded.map { item in
            var copy = item
            if copy.status == .downloading {
                copy.status = .paused
                copy.speedMBs = 0.0
            }
            return copy
        }
    }

    func saveToDisk() {
        rebuildStatusIndex()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storageFileURL, options: .atomic)
        }
    }

    private func writeEpisodeOrMovieSidecar(
        assetKey: String,
        server: EmbyServerConfig,
        item: EmbyItem,
        mediaSource: MediaSourceInfo,
        layout: OfflineLibraryPaths,
        subtitles: [OfflineSubtitleAsset]
    ) {
        let sidecar = OfflineEpisodeOrMovieSidecar(
            assetKey: assetKey,
            serverId: server.id,
            serverName: server.name,
            item: item,
            mediaSource: mediaSource,
            videoFileName: layout.videoFileURL.lastPathComponent,
            thumbFileName: layout.thumbFileURL.lastPathComponent,
            posterFileName: layout.primaryPosterFileURL.lastPathComponent,
            backdropFileName: layout.backdropFileURL.lastPathComponent,
            clearLogoFileName: layout.clearLogoFileURL.lastPathComponent,
            subtitles: subtitles
        )
        if let encoded = try? JSONEncoder().encode(sidecar) {
            try? encoded.write(to: layout.metadataFileURL, options: .atomic)
        }
    }

    func downloadMetadataAndArtwork(
        assetKey: String,
        server: EmbyServerConfig,
        item: EmbyItem,
        seriesItem: EmbyItem?,
        mediaSource: MediaSourceInfo,
        layout: OfflineLibraryPaths,
        headers: [String: String],
        itemArtworkURLs: (poster: URL?, backdrop: URL?, thumb: URL?, logo: URL?, seasonPoster: URL?),
        seriesArtworkURLs: (poster: URL?, backdrop: URL?, logo: URL?)
    ) async {
        func fetchAndWriteArtwork(_ url: URL?, to fileURL: URL) async {
            guard let url else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) { return }
            if url.isFileURL {
                if let data = try? Data(contentsOf: url), data.count > 128 {
                    try? data.write(to: fileURL, options: .atomic)
                }
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               data.count > 128 {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        if let seriesMetaURL = layout.seriesMetadataFileURL {
            let resolvedSeries = seriesItem ?? EmbyItem(
                id: item.seriesId ?? item.id,
                name: item.seriesName ?? "未命名剧集",
                serverId: server.id.uuidString,
                type: "Series",
                overview: item.overview,
                genres: item.genres,
                communityRating: item.communityRating,
                productionYear: item.productionYear,
                people: item.people
            )
            let seriesSidecar = OfflineSeriesSidecar(
                serverId: server.id,
                serverName: server.name,
                seriesItem: resolvedSeries
            )
            if let encoded = try? JSONEncoder().encode(seriesSidecar) {
                try? encoded.write(to: seriesMetaURL, options: .atomic)
            }
            await fetchAndWriteArtwork(seriesArtworkURLs.poster ?? itemArtworkURLs.poster, to: layout.primaryPosterFileURL)
            await fetchAndWriteArtwork(seriesArtworkURLs.backdrop ?? itemArtworkURLs.backdrop, to: layout.backdropFileURL)
            await fetchAndWriteArtwork(seriesArtworkURLs.logo ?? itemArtworkURLs.logo, to: layout.clearLogoFileURL)
            if let seasonPosterURL = layout.seasonPosterFileURL {
                await fetchAndWriteArtwork(itemArtworkURLs.seasonPoster ?? seriesArtworkURLs.poster, to: seasonPosterURL)
            }
        } else {
            await fetchAndWriteArtwork(itemArtworkURLs.poster, to: layout.primaryPosterFileURL)
            await fetchAndWriteArtwork(itemArtworkURLs.backdrop, to: layout.backdropFileURL)
            await fetchAndWriteArtwork(itemArtworkURLs.logo, to: layout.clearLogoFileURL)
        }

        await fetchAndWriteArtwork(itemArtworkURLs.thumb ?? itemArtworkURLs.backdrop ?? itemArtworkURLs.poster, to: layout.thumbFileURL)
        writeEpisodeOrMovieSidecar(
            assetKey: assetKey,
            server: server,
            item: item,
            mediaSource: mediaSource,
            layout: layout,
            subtitles: entry(for: assetKey)?.offlineSubtitles ?? []
        )
    }

    func downloadExternalSubtitles(
        assetKey: String,
        subtitles: [SubtitleResourceItem],
        headers: [String: String],
        layout: OfflineLibraryPaths,
        server: EmbyServerConfig,
        item: EmbyItem,
        mediaSource: MediaSourceInfo
    ) async {
        guard !subtitles.isEmpty else { return }
        let subDir = layout.itemFolderURL
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let videoStem = layout.videoFileURL.deletingPathExtension().lastPathComponent

        var savedSubs: [OfflineSubtitleAsset] = []
        for (ord, sub) in subtitles.enumerated() {
            let dlURL = DownloadEntry.derivePreferredDownloadURL(from: sub.url)
            var req = URLRequest(url: dlURL, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            var fetchedData: Data?
            if let (d, r) = try? await URLSession.shared.data(for: req),
               let http = r as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               !d.isEmpty {
                fetchedData = d
            } else if dlURL != sub.url {
                var fbReq = URLRequest(url: sub.url, timeoutInterval: 15)
                for (k, v) in headers { fbReq.setValue(v, forHTTPHeaderField: k) }
                if let (d, _) = try? await URLSession.shared.data(for: fbReq), !d.isEmpty {
                    fetchedData = d
                }
            }
            guard let data = fetchedData else { continue }
            let ext = sub.url.pathExtension.isEmpty ? (sub.codec?.lowercased() == "ass" ? "ass" : "srt") : sub.url.pathExtension
            let cleanLabel = DonbyOfflineLibraryStorage.sanitizeFileName(sub.name, fallback: "sub\(ord)")
            let fileName = "\(videoStem).\(ord + 1).\(cleanLabel).\(ext)"
            try? data.write(to: subDir.appendingPathComponent(fileName), options: .atomic)
            savedSubs.append(OfflineSubtitleAsset(
                name: sub.name,
                localFileName: fileName,
                streamIndex: sub.streamIndex,
                codec: sub.codec
            ))
        }

        if !savedSubs.isEmpty, let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].offlineSubtitles = savedSubs
            saveToDisk()
            writeEpisodeOrMovieSidecar(
                assetKey: assetKey,
                server: server,
                item: item,
                mediaSource: mediaSource,
                layout: layout,
                subtitles: savedSubs
            )
        }
    }
}

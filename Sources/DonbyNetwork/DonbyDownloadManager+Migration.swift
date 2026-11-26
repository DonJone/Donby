import Foundation
import DonbyCore

// MARK: - Legacy Completed Offline Download Migration

extension DonbyDownloadManager {
    func cleanupOfflineMediaFiles(for entry: DownloadEntry) {
        let fm = FileManager.default
        guard let videoPath = entry.localVideoFilePath else { return }
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

    private func pruneEmptyFolderArtworkAndDirs(startingAt folder: URL, seriesFolder: URL?) {
        let fm = FileManager.default
        let videoExts: Set<String> = ["mkv", "mp4", "mov", "m4v", "webm", "avi", "ts", "m2ts", "flv"]
        func directoryHasVideos(_ dir: URL) -> Bool {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
            for case let file as URL in enumerator where videoExts.contains(file.pathExtension.lowercased()) { return true }
            return false
        }
        if !directoryHasVideos(folder) { try? fm.removeItem(at: folder) }
        if let seriesFolder, seriesFolder != folder, !directoryHasVideos(seriesFolder) { try? fm.removeItem(at: seriesFolder) }
    }

    /// Migrates previously completed downloads from cache bins (`ChunkStore`) or legacy split folders
    /// into the unified `~/Movies/Donby` hierarchy along with artwork, subtitles, and metadata sidecars.
    public func migrateLegacyCompletedDownloads(servers: [EmbyServerConfig]) async {
        DonbyOfflineLibraryStorage.ensureRootDirectories()
        let fm = FileManager.default
        var didMutate = false

        let snapshotEntries = entries
        for entry in snapshotEntries where entry.status == .completed {
            let server = servers.first(where: { $0.id == entry.serverId })
            let fallbackServer = server ?? EmbyServerConfig(
                id: entry.serverId,
                name: entry.serverName,
                host: "",
                username: ""
            )

            var resolvedSeries: EmbyItem? = nil
            if entry.itemSnapshot.isEpisode, let sid = entry.itemSnapshot.seriesId, !sid.isEmpty {
                if let existingSeriesFolder = entry.localSeriesFolderPath {
                    let sMeta = URL(fileURLWithPath: existingSeriesFolder).appendingPathComponent("donby.series.json")
                    if let d = try? Data(contentsOf: sMeta),
                       let decoded = try? JSONDecoder().decode(OfflineSeriesSidecar.self, from: d) {
                        resolvedSeries = decoded.seriesItem
                    }
                }
                if resolvedSeries == nil, let server {
                    if let extProvider = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                        resolvedSeries = try? await extProvider.fetchItemDetail(
                            server: server,
                            item: EmbyItem(
                                id: sid,
                                name: entry.itemSnapshot.seriesName ?? "",
                                type: "Series",
                                uhdMediaType: "tv"
                            )
                        )
                    } else if !(server.type == .uhdNative && DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)) {
                        resolvedSeries = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                    }
                }
            }

            let streamURL = URL(string: entry.streamURLString)
                ?? URL(fileURLWithPath: entry.localVideoFilePath ?? "/tmp/video.mkv")
            let layout = DonbyOfflineLibraryStorage.makeLayoutPaths(
                item: entry.itemSnapshot,
                seriesItem: resolvedSeries,
                mediaSource: entry.mediaSourceSnapshot,
                streamURL: streamURL
            )

            var hasVideoOnDisk = fm.fileExists(atPath: layout.videoFileURL.path)

            if !hasVideoOnDisk, let oldPath = entry.localVideoFilePath, fm.fileExists(atPath: oldPath) {
                let oldVideoURL = URL(fileURLWithPath: oldPath)
                let oldItemDir = oldVideoURL.deletingLastPathComponent()
                if oldVideoURL.standardizedFileURL.path != layout.videoFileURL.standardizedFileURL.path {
                    try? fm.createDirectory(at: layout.itemFolderURL, withIntermediateDirectories: true)
                    if let seriesDir = layout.seriesFolderURL {
                        try? fm.createDirectory(at: seriesDir, withIntermediateDirectories: true)
                    }
                    if (try? fm.moveItem(at: oldVideoURL, to: layout.videoFileURL)) != nil {
                        hasVideoOnDisk = true
                        didMutate = true
                    }
                    if let oldFiles = try? fm.contentsOfDirectory(at: oldItemDir, includingPropertiesForKeys: nil) {
                        for srcFile in oldFiles {
                            let dstFile = layout.itemFolderURL.appendingPathComponent(srcFile.lastPathComponent)
                            if !fm.fileExists(atPath: dstFile.path) {
                                try? fm.moveItem(at: srcFile, to: dstFile)
                            }
                        }
                    }
                    if let oldSeriesPath = entry.localSeriesFolderPath,
                       let newSeriesDir = layout.seriesFolderURL {
                        let oldSeriesURL = URL(fileURLWithPath: oldSeriesPath)
                        if oldSeriesURL.standardizedFileURL.path != newSeriesDir.standardizedFileURL.path {
                            for name in ["poster.jpg", "backdrop.jpg", "clearlogo.png", "donby.series.json"] {
                                let src = oldSeriesURL.appendingPathComponent(name)
                                let dst = newSeriesDir.appendingPathComponent(name)
                                if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                                    try? fm.moveItem(at: src, to: dst)
                                }
                            }
                            if let rem = try? fm.contentsOfDirectory(atPath: oldItemDir.path),
                               rem.filter({ $0 != ".DS_Store" }).isEmpty {
                                try? fm.removeItem(at: oldItemDir)
                            }
                            if let remSeries = try? fm.contentsOfDirectory(atPath: oldSeriesURL.path),
                               remSeries.filter({ $0 != ".DS_Store" }).isEmpty {
                                try? fm.removeItem(at: oldSeriesURL)
                            }
                        }
                    } else if let rem = try? fm.contentsOfDirectory(atPath: oldItemDir.path),
                              rem.filter({ $0 != ".DS_Store" }).isEmpty {
                        try? fm.removeItem(at: oldItemDir)
                    }
                }
            }

            if !hasVideoOnDisk {
                let store = DonbyTurboCacheEngine.shared.store(for: entry.assetKey, persistDisk: true)
                let meta = store.currentMeta()
                let isCompleteInStore = meta.isFullyCached ||
                    (entry.totalBytes > 0 && entry.downloadedBytes >= entry.totalBytes && fm.fileExists(atPath: store.dataFileURL.path))
                if isCompleteInStore && fm.fileExists(atPath: store.dataFileURL.path) {
                    let expectedSize = max(meta.totalSize, entry.totalBytes)
                    try? fm.createDirectory(at: layout.itemFolderURL, withIntermediateDirectories: true)
                    if let seriesDir = layout.seriesFolderURL {
                        try? fm.createDirectory(at: seriesDir, withIntermediateDirectories: true)
                    }
                    let legacySubDir = store.assetDirectory.appendingPathComponent("subtitles", isDirectory: true)
                    if let subFiles = try? fm.contentsOfDirectory(at: legacySubDir, includingPropertiesForKeys: nil) {
                        for srcSub in subFiles {
                            let dstSub = layout.itemFolderURL.appendingPathComponent(srcSub.lastPathComponent)
                            if !fm.fileExists(atPath: dstSub.path) {
                                try? fm.moveItem(at: srcSub, to: dstSub)
                            }
                        }
                    }
                    if Self.materializeAndCleanupIfIdle(store: store, assetKey: entry.assetKey, destinationURL: layout.videoFileURL, expectedSize: expectedSize) {
                        hasVideoOnDisk = true
                        didMutate = true
                    }
                }
            }

            guard hasVideoOnDisk else { continue }

            let needsPathUpdate = entry.localVideoFilePath != layout.videoFileURL.path ||
                entry.localFolderPath != layout.itemFolderURL.path ||
                entry.localSeriesFolderPath != layout.seriesFolderURL?.path ||
                entry.localPosterPath != layout.primaryPosterFileURL.path
            let needsMetadataOrArtwork = !fm.fileExists(atPath: layout.metadataFileURL.path) ||
                !fm.fileExists(atPath: layout.primaryPosterFileURL.path) ||
                (layout.seriesMetadataFileURL.map { !fm.fileExists(atPath: $0.path) } ?? false)

            if needsPathUpdate, let idx = entries.firstIndex(where: { $0.assetKey == entry.assetKey }) {
                entries[idx].applyLayoutPaths(layout)
                didMutate = true
            }

            if needsMetadataOrArtwork {
                let targetItem = entry.itemSnapshot
                let itemPoster: URL?
                let itemBackdrop: URL?
                let itemThumb: URL?
                let itemLogo: URL?
                let seasonPoster: URL?
                let seriesPoster: URL?
                let seriesBackdrop: URL?
                let seriesLogo: URL?

                if let server {
                    let isUHD = (server.type == .uhdNative && DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative))
                    let p = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 800)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .primary, maxWidth: 800))
                        ?? entry.posterURLString.flatMap { URL(string: $0) }
                    itemPoster = p
                    itemBackdrop = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .backdrop, maxWidth: 1920)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .backdrop, maxWidth: 1920))
                    itemThumb = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .thumb, maxWidth: 800)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .thumb, maxWidth: 800))
                    itemLogo = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .logo, maxWidth: 800)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .logo, maxWidth: 800))
                    seasonPoster = isUHD ? nil : targetItem.seasonId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 600) }

                    seriesPoster = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .primary, maxWidth: 800) }
                        ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 800) })
                        ?? p
                    seriesBackdrop = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .backdrop, maxWidth: 1920) }
                        ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .backdrop, maxWidth: 1920) })
                    seriesLogo = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .logo, maxWidth: 800) }
                        ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .logo, maxWidth: 800) })
                } else {
                    let p = entry.posterURLString.flatMap { URL(string: $0) }
                    itemPoster = p
                    itemBackdrop = targetItem.uhdBackdropURL.flatMap { URL(string: $0) }
                    itemThumb = targetItem.uhdThumbURL.flatMap { URL(string: $0) }
                    itemLogo = targetItem.uhdLogoURL.flatMap { URL(string: $0) }
                    seasonPoster = nil
                    seriesPoster = resolvedSeries?.uhdPosterURL.flatMap { URL(string: $0) } ?? p
                    seriesBackdrop = resolvedSeries?.uhdBackdropURL.flatMap { URL(string: $0) }
                    seriesLogo = resolvedSeries?.uhdLogoURL.flatMap { URL(string: $0) }
                }

                await downloadMetadataAndArtwork(
                    assetKey: entry.assetKey,
                    server: fallbackServer,
                    item: targetItem,
                    seriesItem: resolvedSeries,
                    mediaSource: entry.mediaSourceSnapshot,
                    layout: layout,
                    headers: entry.headers,
                    itemArtworkURLs: (poster: itemPoster, backdrop: itemBackdrop, thumb: itemThumb, logo: itemLogo, seasonPoster: seasonPoster),
                    seriesArtworkURLs: (poster: seriesPoster, backdrop: seriesBackdrop, logo: seriesLogo)
                )
                didMutate = true
            }
        }

        DonbyOfflineLibraryStorage.ensureRootDirectories()
        if didMutate {
            saveToDisk()
        }
    }
}

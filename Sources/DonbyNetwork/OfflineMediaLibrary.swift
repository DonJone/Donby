import Foundation
import DonbyCore

/// Standardized local offline library layout inside `~/Movies/Donby`,
/// mirroring server Show -> Season -> Episode / Movie directory trees with artwork and JSON sidecars.
public struct OfflineLibraryPaths: Sendable {
    public let rootDirectory: URL
    public let seriesFolderURL: URL?
    public let seasonFolderURL: URL?
    public let itemFolderURL: URL
    public let videoFileURL: URL
    public let metadataFileURL: URL
    public let thumbFileURL: URL
    public let primaryPosterFileURL: URL
    public let backdropFileURL: URL
    public let clearLogoFileURL: URL
    public let seasonPosterFileURL: URL?
    public let seriesMetadataFileURL: URL?

    public init(
        rootDirectory: URL,
        seriesFolderURL: URL?,
        seasonFolderURL: URL?,
        itemFolderURL: URL,
        videoFileURL: URL,
        metadataFileURL: URL,
        thumbFileURL: URL,
        primaryPosterFileURL: URL,
        backdropFileURL: URL,
        clearLogoFileURL: URL,
        seasonPosterFileURL: URL?,
        seriesMetadataFileURL: URL?
    ) {
        self.rootDirectory = rootDirectory
        self.seriesFolderURL = seriesFolderURL
        self.seasonFolderURL = seasonFolderURL
        self.itemFolderURL = itemFolderURL
        self.videoFileURL = videoFileURL
        self.metadataFileURL = metadataFileURL
        self.thumbFileURL = thumbFileURL
        self.primaryPosterFileURL = primaryPosterFileURL
        self.backdropFileURL = backdropFileURL
        self.clearLogoFileURL = clearLogoFileURL
        self.seasonPosterFileURL = seasonPosterFileURL
        self.seriesMetadataFileURL = seriesMetadataFileURL
    }
}

public struct OfflineSeriesSidecar: Codable, Sendable {
    public var serverId: UUID
    public var serverName: String
    public var seriesItem: EmbyItem
    public var posterFileName: String?
    public var backdropFileName: String?
    public var clearLogoFileName: String?
    public var updatedAt: Date

    public init(
        serverId: UUID,
        serverName: String,
        seriesItem: EmbyItem,
        posterFileName: String? = "poster.jpg",
        backdropFileName: String? = "backdrop.jpg",
        clearLogoFileName: String? = "clearlogo.png",
        updatedAt: Date = Date()
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.seriesItem = seriesItem
        self.posterFileName = posterFileName
        self.backdropFileName = backdropFileName
        self.clearLogoFileName = clearLogoFileName
        self.updatedAt = updatedAt
    }
}

public struct OfflineEpisodeOrMovieSidecar: Codable, Sendable {
    public var assetKey: String
    public var serverId: UUID
    public var serverName: String
    public var item: EmbyItem
    public var mediaSource: MediaSourceInfo
    public var videoFileName: String
    public var thumbFileName: String?
    public var posterFileName: String?
    public var backdropFileName: String?
    public var clearLogoFileName: String?
    public var subtitles: [OfflineSubtitleAsset]
    public var savedAt: Date

    public init(
        assetKey: String,
        serverId: UUID,
        serverName: String,
        item: EmbyItem,
        mediaSource: MediaSourceInfo,
        videoFileName: String,
        thumbFileName: String? = nil,
        posterFileName: String? = "poster.jpg",
        backdropFileName: String? = "backdrop.jpg",
        clearLogoFileName: String? = "clearlogo.png",
        subtitles: [OfflineSubtitleAsset] = [],
        savedAt: Date = Date()
    ) {
        self.assetKey = assetKey
        self.serverId = serverId
        self.serverName = serverName
        self.item = item
        self.mediaSource = mediaSource
        self.videoFileName = videoFileName
        self.thumbFileName = thumbFileName
        self.posterFileName = posterFileName
        self.backdropFileName = backdropFileName
        self.clearLogoFileName = clearLogoFileName
        self.subtitles = subtitles
        self.savedAt = savedAt
    }
}

public struct OfflineLibraryGroup: Identifiable, Hashable, Sendable {
    public var id: String { displayItem.id }
    public let displayItem: EmbyItem
    public let serverId: UUID?
    public let serverName: String
    public let folderURL: URL
    public let totalSizeBytes: Int64
    public let episodesBySeason: [Int: [EmbyItem]]
    public let seasonItems: [EmbyItem]

    public var isSeries: Bool { displayItem.isSeries }
    public var downloadedEpisodeCount: Int {
        episodesBySeason.values.reduce(0) { $0 + $1.count }
    }
}

public enum DonbyOfflineLibraryStorage {
    private static let supportedVideoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "webm", "avi", "ts", "m2ts", "flv"
    ]

    public static var moviesDonbyRootURL: URL {
        return DonbyStoragePaths.moviesDirectoryURL.appendingPathComponent("Donby", isDirectory: true)
    }

    public static func ensureRootDirectories() {
        let root = moviesDonbyRootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for legacyName in ["剧集", "电影"] {
            let legacyURL = root.appendingPathComponent(legacyName, isDirectory: true)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: legacyURL.path),
               contents.filter({ $0 != ".DS_Store" }).isEmpty {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }
    }

    public static func sanitizeFileName(_ raw: String, fallback: String = "Media") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t")
        let replaced = raw.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return collapsed.isEmpty ? fallback : String(collapsed.prefix(120))
    }

    public static func resolveVideoExtension(
        item: EmbyItem,
        mediaSource: MediaSourceInfo,
        streamURL: URL
    ) -> String {
        let candidates = [
            mediaSource.container,
            item.container,
            URL(fileURLWithPath: mediaSource.path ?? "").pathExtension,
            streamURL.pathExtension
        ]
        for raw in candidates {
            let ext = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if supportedVideoExtensions.contains(ext) {
                return ext
            }
        }
        return "mkv"
    }

    public static func makeLayoutPaths(
        item: EmbyItem,
        seriesItem: EmbyItem?,
        mediaSource: MediaSourceInfo,
        streamURL: URL
    ) -> OfflineLibraryPaths {
        ensureRootDirectories()
        let root = moviesDonbyRootURL
        let ext = resolveVideoExtension(item: item, mediaSource: mediaSource, streamURL: streamURL)

        let isEpisodeItem = item.isEpisode || (item.seriesId?.isEmpty == false) || (item.seriesName?.isEmpty == false)
        if isEpisodeItem {
            let rawSeriesTitle = seriesItem?.name ?? item.seriesName ?? "未命名剧集"
            let seriesYear = seriesItem?.productionYear ?? item.productionYear
            let seriesFolderTitle: String = {
                let base = sanitizeFileName(rawSeriesTitle, fallback: "未命名剧集")
                if let year = seriesYear, year > 1880 && !base.contains("\(year)") {
                    return "\(base) (\(year))"
                }
                return base
            }()

            let seasonNumber = item.parentIndexNumber ?? 1
            let seasonFolderTitle = seasonNumber == 0 ? "Specials" : String(format: "Season %02d", seasonNumber)

            let seriesDir = root.appendingPathComponent(seriesFolderTitle, isDirectory: true)
            let seasonDir = seriesDir.appendingPathComponent(seasonFolderTitle, isDirectory: true)

            let epNumber = item.indexNumber ?? 1
            let epCode = String(format: "S%02dE%02d", max(0, seasonNumber), max(0, epNumber))
            let cleanEpName = sanitizeFileName(item.name, fallback: epCode)
            let stemTitle: String = {
                let seriesShort = sanitizeFileName(rawSeriesTitle, fallback: "Series")
                if cleanEpName.lowercased() == epCode.lowercased() {
                    return "\(seriesShort) - \(epCode)"
                }
                return sanitizeFileName("\(seriesShort) - \(epCode) - \(cleanEpName)")
            }()

            let videoURL = seasonDir.appendingPathComponent("\(stemTitle).\(ext)")
            return OfflineLibraryPaths(
                rootDirectory: root,
                seriesFolderURL: seriesDir,
                seasonFolderURL: seasonDir,
                itemFolderURL: seasonDir,
                videoFileURL: videoURL,
                metadataFileURL: seasonDir.appendingPathComponent("\(stemTitle).meta.json"),
                thumbFileURL: seasonDir.appendingPathComponent("\(stemTitle)-thumb.jpg"),
                primaryPosterFileURL: seriesDir.appendingPathComponent("poster.jpg"),
                backdropFileURL: seriesDir.appendingPathComponent("backdrop.jpg"),
                clearLogoFileURL: seriesDir.appendingPathComponent("clearlogo.png"),
                seasonPosterFileURL: seasonDir.appendingPathComponent("poster.jpg"),
                seriesMetadataFileURL: seriesDir.appendingPathComponent("donby.series.json")
            )
        } else {
            let base = sanitizeFileName(item.name, fallback: "未命名影片")
            let movieFolderTitle: String = {
                if let year = item.productionYear, year > 1880 && !base.contains("\(year)") {
                    return "\(base) (\(year))"
                }
                return base
            }()
            let movieDir = root.appendingPathComponent(movieFolderTitle, isDirectory: true)

            let videoURL = movieDir.appendingPathComponent("\(movieFolderTitle).\(ext)")
            return OfflineLibraryPaths(
                rootDirectory: root,
                seriesFolderURL: nil,
                seasonFolderURL: nil,
                itemFolderURL: movieDir,
                videoFileURL: videoURL,
                metadataFileURL: movieDir.appendingPathComponent("\(movieFolderTitle).meta.json"),
                thumbFileURL: movieDir.appendingPathComponent("\(movieFolderTitle)-thumb.jpg"),
                primaryPosterFileURL: movieDir.appendingPathComponent("poster.jpg"),
                backdropFileURL: movieDir.appendingPathComponent("backdrop.jpg"),
                clearLogoFileURL: movieDir.appendingPathComponent("clearlogo.png"),
                seasonPosterFileURL: nil,
                seriesMetadataFileURL: nil
            )
        }
    }

    public static func hydrateArtworkURLs(
        for item: EmbyItem,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        thumbURL: URL? = nil,
        logoURL: URL? = nil
    ) -> EmbyItem {
        let fm = FileManager.default
        let resolvedPoster = (posterURL.map { fm.fileExists(atPath: $0.path) ? $0.absoluteString : nil } ?? nil) ?? item.uhdPosterURL
        let resolvedBackdrop = (backdropURL.map { fm.fileExists(atPath: $0.path) ? $0.absoluteString : nil } ?? nil) ?? item.uhdBackdropURL
        let resolvedThumb = (thumbURL.map { fm.fileExists(atPath: $0.path) ? $0.absoluteString : nil } ?? nil) ?? item.uhdThumbURL
        let resolvedLogo = (logoURL.map { fm.fileExists(atPath: $0.path) ? $0.absoluteString : nil } ?? nil) ?? item.uhdLogoURL

        return EmbyItem(
            id: item.id,
            name: item.name,
            originalTitle: item.originalTitle,
            serverId: item.serverId,
            type: item.type,
            collectionType: item.collectionType,
            overview: item.overview,
            taglines: item.taglines,
            genres: item.genres,
            communityRating: item.communityRating,
            criticRating: item.criticRating,
            officialRating: item.officialRating,
            productionYear: item.productionYear,
            premiereDate: item.premiereDate,
            endDate: item.endDate,
            status: item.status,
            runTimeTicks: item.runTimeTicks,
            container: item.container,
            path: item.path,
            isFolder: item.isFolder,
            parentId: item.parentId,
            seriesId: item.seriesId,
            seriesName: item.seriesName,
            seasonId: item.seasonId,
            seasonName: item.seasonName,
            indexNumber: item.indexNumber,
            parentIndexNumber: item.parentIndexNumber,
            childCount: item.childCount,
            recursiveItemCount: item.recursiveItemCount,
            imageTags: item.imageTags,
            backdropImageTags: item.backdropImageTags,
            parentBackdropItemId: item.parentBackdropItemId,
            parentBackdropImageTags: item.parentBackdropImageTags,
            seriesPrimaryImageTag: item.seriesPrimaryImageTag,
            primaryImageAspectRatio: item.primaryImageAspectRatio,
            userData: item.userData,
            mediaSources: item.mediaSources,
            mediaStreams: item.mediaStreams,
            people: item.people,
            studios: item.studios,
            providerIds: item.providerIds,
            chapters: item.chapters,
            dateCreated: item.dateCreated,
            uhdPosterURL: resolvedPoster,
            uhdBackdropURL: resolvedBackdrop,
            uhdLogoURL: resolvedLogo,
            uhdThumbURL: resolvedThumb,
            uhdMediaType: item.uhdMediaType
        )
    }

    /// Scans `~/Movies/Donby` (and falls back to completed `DownloadEntry` snapshots) to construct
    /// rich series/season/movie objects suitable for the Search-style poster grid and offline DetailView.
    public static func scanOfflineLibrary(entries: [DownloadEntry]) -> [OfflineLibraryGroup] {
        let fm = FileManager.default
        let root = moviesDonbyRootURL
        let decoder = JSONDecoder()

        struct EpisodeAccum {
            let item: EmbyItem
            let seasonNumber: Int
            let fileSize: Int64
            let serverId: UUID?
            let serverName: String
            let seriesFolderURL: URL
            let seriesMeta: OfflineSeriesSidecar?
        }

        var movieGroups: [OfflineLibraryGroup] = []
        var seriesBuckets: [String: [EpisodeAccum]] = [:]
        var seenVideoPaths = Set<String>()

        // 1. Scan ~/Movies/Donby recursively for *.meta.json sidecars paired with real playable videos
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasSuffix(".meta.json") else { continue }
                guard let data = try? Data(contentsOf: fileURL),
                      let sidecar = try? decoder.decode(OfflineEpisodeOrMovieSidecar.self, from: data) else {
                    continue
                }
                let itemDir = fileURL.deletingLastPathComponent()
                let videoURL = itemDir.appendingPathComponent(sidecar.videoFileName)
                guard fm.fileExists(atPath: videoURL.path) else { continue }
                seenVideoPaths.insert(videoURL.path)

                let fileSize = ((try? fm.attributesOfItem(atPath: videoURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let localSource = MediaSourceInfo(
                    id: sidecar.mediaSource.id,
                    name: sidecar.mediaSource.name ?? videoURL.pathExtension.uppercased(),
                    path: videoURL.path,
                    container: videoURL.pathExtension,
                    size: fileSize > 0 ? fileSize : sidecar.mediaSource.size,
                    bitrate: sidecar.mediaSource.bitrate,
                    mediaStreams: sidecar.mediaSource.mediaStreams
                )

                let parentName = itemDir.lastPathComponent
                let isInsideSeasonDir = parentName.lowercased().hasPrefix("season ") || parentName == "Specials"
                let isSeriesEpisode = sidecar.item.isEpisode || sidecar.item.seriesId != nil || isInsideSeasonDir
                if isSeriesEpisode {
                    let seriesDir = isInsideSeasonDir ? itemDir.deletingLastPathComponent() : itemDir
                    let seriesSidecarURL = seriesDir.appendingPathComponent("donby.series.json")
                    let seriesSidecar = (try? Data(contentsOf: seriesSidecarURL)).flatMap { try? decoder.decode(OfflineSeriesSidecar.self, from: $0) }

                    let seriesPoster = seriesDir.appendingPathComponent("poster.jpg")
                    let seriesBackdrop = seriesDir.appendingPathComponent("backdrop.jpg")
                    let seriesLogo = seriesDir.appendingPathComponent("clearlogo.png")
                    let epThumb = sidecar.thumbFileName.map { itemDir.appendingPathComponent($0) }
                        ?? itemDir.appendingPathComponent("thumb.jpg")

                    let hydratedEp = hydrateArtworkURLs(
                        for: sidecar.item.withDetailEnrichment(mediaSources: [localSource]),
                        posterURL: fm.fileExists(atPath: epThumb.path) ? epThumb : seriesPoster,
                        backdropURL: seriesBackdrop,
                        thumbURL: fm.fileExists(atPath: epThumb.path) ? epThumb : seriesBackdrop,
                        logoURL: seriesLogo
                    )
                    let key = seriesSidecar?.seriesItem.id ?? sidecar.item.seriesId ?? seriesDir.path
                    let seasonNum = sidecar.item.parentIndexNumber ?? 1
                    seriesBuckets[key, default: []].append(EpisodeAccum(
                        item: hydratedEp,
                        seasonNumber: seasonNum,
                        fileSize: fileSize,
                        serverId: sidecar.serverId,
                        serverName: sidecar.serverName,
                        seriesFolderURL: seriesDir,
                        seriesMeta: seriesSidecar
                    ))
                } else {
                    let poster = sidecar.posterFileName.map { itemDir.appendingPathComponent($0) } ?? itemDir.appendingPathComponent("poster.jpg")
                    let backdrop = sidecar.backdropFileName.map { itemDir.appendingPathComponent($0) } ?? itemDir.appendingPathComponent("backdrop.jpg")
                    let logo = sidecar.clearLogoFileName.map { itemDir.appendingPathComponent($0) } ?? itemDir.appendingPathComponent("clearlogo.png")
                    let hydratedMovie = hydrateArtworkURLs(
                        for: sidecar.item.withDetailEnrichment(mediaSources: [localSource]),
                        posterURL: poster,
                        backdropURL: backdrop,
                        thumbURL: backdrop,
                        logoURL: logo
                    )
                    movieGroups.append(OfflineLibraryGroup(
                        displayItem: hydratedMovie,
                        serverId: sidecar.serverId,
                        serverName: sidecar.serverName,
                        folderURL: itemDir,
                        totalSizeBytes: fileSize,
                        episodesBySeason: [:],
                        seasonItems: []
                    ))
                }
            }
        }

        // 2. Include any legacy completed DownloadEntries not already backed by ~/Movies/Donby sidecar
        for entry in entries where entry.status == .completed {
            if let path = entry.localVideoFilePath, seenVideoPaths.contains(path) { continue }
            if entry.itemSnapshot.isEpisode {
                let sId = entry.itemSnapshot.seriesId ?? entry.itemSnapshot.seriesName ?? entry.itemId
                let folder = entry.localSeriesFolderPath.map { URL(fileURLWithPath: $0) }
                    ?? entry.localFolderPath.map { URL(fileURLWithPath: $0) }
                    ?? moviesDonbyRootURL
                let hydratedEp = hydrateArtworkURLs(
                    for: entry.itemSnapshot,
                    posterURL: entry.localPosterPath.map { URL(fileURLWithPath: $0) },
                    backdropURL: entry.localBackdropPath.map { URL(fileURLWithPath: $0) },
                    thumbURL: entry.localThumbPath.map { URL(fileURLWithPath: $0) },
                    logoURL: entry.localLogoPath.map { URL(fileURLWithPath: $0) }
                )
                seriesBuckets[sId, default: []].append(EpisodeAccum(
                    item: hydratedEp,
                    seasonNumber: entry.itemSnapshot.parentIndexNumber ?? 1,
                    fileSize: entry.totalBytes,
                    serverId: entry.serverId,
                    serverName: entry.serverName,
                    seriesFolderURL: folder,
                    seriesMeta: nil
                ))
            } else {
                let folder = entry.localFolderPath.map { URL(fileURLWithPath: $0) } ?? moviesDonbyRootURL
                let hydrated = hydrateArtworkURLs(
                    for: entry.itemSnapshot,
                    posterURL: entry.localPosterPath.map { URL(fileURLWithPath: $0) },
                    backdropURL: entry.localBackdropPath.map { URL(fileURLWithPath: $0) },
                    thumbURL: entry.localThumbPath.map { URL(fileURLWithPath: $0) },
                    logoURL: entry.localLogoPath.map { URL(fileURLWithPath: $0) }
                )
                movieGroups.append(OfflineLibraryGroup(
                    displayItem: hydrated,
                    serverId: entry.serverId,
                    serverName: entry.serverName,
                    folderURL: folder,
                    totalSizeBytes: entry.totalBytes,
                    episodesBySeason: [:],
                    seasonItems: []
                ))
            }
        }

        // 3. Build Series OfflineLibraryGroup objects
        var seriesGroups: [OfflineLibraryGroup] = []
        for (bucketKey, accums) in seriesBuckets {
            guard let first = accums.first else { continue }
            var bySeason: [Int: [EmbyItem]] = [:]
            var totalBytes: Int64 = 0
            for acc in accums {
                bySeason[acc.seasonNumber, default: []].append(acc.item)
                totalBytes += acc.fileSize
            }
            for sNum in bySeason.keys {
                bySeason[sNum]?.sort { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            }

            let baseSeriesItem: EmbyItem = first.seriesMeta?.seriesItem ?? EmbyItem(
                id: first.item.seriesId ?? bucketKey,
                name: first.item.seriesName ?? first.seriesFolderURL.lastPathComponent,
                serverId: first.serverId?.uuidString,
                type: "Series",
                overview: first.item.overview,
                genres: first.item.genres,
                communityRating: first.item.communityRating,
                productionYear: first.item.productionYear,
                mediaSources: first.item.mediaSources
            )

            let sPoster = first.seriesFolderURL.appendingPathComponent("poster.jpg")
            let sBackdrop = first.seriesFolderURL.appendingPathComponent("backdrop.jpg")
            let sLogo = first.seriesFolderURL.appendingPathComponent("clearlogo.png")
            var hydratedSeries = hydrateArtworkURLs(
                for: baseSeriesItem,
                posterURL: sPoster,
                backdropURL: sBackdrop,
                thumbURL: sBackdrop,
                logoURL: sLogo
            )
            if hydratedSeries.uhdPosterURL == nil,
               let fallbackEntry = entries.first(where: {
                   $0.status == .completed &&
                   ($0.itemSnapshot.seriesId == hydratedSeries.id || $0.itemSnapshot.seriesName == hydratedSeries.name)
               }),
               let fallbackPoster = fallbackEntry.posterURLString {
                hydratedSeries = EmbyItem(
                    id: hydratedSeries.id,
                    name: hydratedSeries.name,
                    originalTitle: hydratedSeries.originalTitle,
                    serverId: hydratedSeries.serverId,
                    type: hydratedSeries.type,
                    collectionType: hydratedSeries.collectionType,
                    overview: hydratedSeries.overview,
                    genres: hydratedSeries.genres,
                    communityRating: hydratedSeries.communityRating,
                    productionYear: hydratedSeries.productionYear,
                    userData: hydratedSeries.userData,
                    mediaSources: hydratedSeries.mediaSources,
                    people: hydratedSeries.people,
                    uhdPosterURL: fallbackPoster,
                    uhdBackdropURL: hydratedSeries.uhdBackdropURL,
                    uhdLogoURL: hydratedSeries.uhdLogoURL,
                    uhdThumbURL: hydratedSeries.uhdThumbURL,
                    uhdMediaType: hydratedSeries.uhdMediaType
                )
            }

            let sortedSeasons = bySeason.keys.sorted().map { sNum in
                EmbyItem(
                    id: "\(hydratedSeries.id)_local_s\(sNum)",
                    name: sNum == 0 ? "特别篇" : "第 \(sNum) 季",
                    type: "Season",
                    seriesId: hydratedSeries.id,
                    seriesName: hydratedSeries.name,
                    indexNumber: sNum,
                    uhdPosterURL: hydratedSeries.uhdPosterURL
                )
            }

            seriesGroups.append(OfflineLibraryGroup(
                displayItem: hydratedSeries,
                serverId: first.serverId,
                serverName: first.serverName,
                folderURL: first.seriesFolderURL,
                totalSizeBytes: totalBytes,
                episodesBySeason: bySeason,
                seasonItems: sortedSeasons
            ))
        }

        return (seriesGroups + movieGroups).sorted {
            $0.displayItem.name.localizedStandardCompare($1.displayItem.name) == .orderedAscending
        }
    }
}

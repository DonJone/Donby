import Foundation
import DonbyCore
import DonbyNetwork

extension UHDStreamClient {
    // MARK: - DTO Mapping

    func resolveItemType(_ item: EmbyItem) -> String {
        if let explicit = item.uhdMediaType?.lowercased(), !explicit.isEmpty {
            return explicit
        }
        let t = item.type?.lowercased() ?? ""
        if t == "episode" { return "episode" }
        if t == "series" || t == "show" || t == "tv" { return "tv" }
        if t == "season" { return "season" }
        return "movie"
    }

    func resolveStateType(_ item: EmbyItem, allowed: [String]) -> String? {
        let resolved = resolveItemType(item)
        if allowed.contains(resolved) { return resolved }
        return allowed.first
    }

    func mapSummary(_ dto: UHDMediaSummaryDTO, server: EmbyServerConfig) -> EmbyItem {
        let apiBase = server.mainLineURL
        let embyType = dto.type.lowercased() == "tv" ? "Series" : "Movie"
        let runtimeTicks = dto.duration.map { $0 * 10_000_000 }
        let posTicks = (dto.userState?.positionMs ?? 0) * 10_000
        let userData = dto.userState.map {
            EmbyUserData(
                playbackPositionTicks: posTicks,
                isFavorite: $0.favorite,
                played: $0.played,
                playedPercentage: $0.progressPct.map(Double.init),
                lastPlayedDate: $0.lastPlayedAt
            )
        }
        return EmbyItem(
            id: dto.id,
            name: dto.title,
            originalTitle: dto.originTitle,
            serverId: server.serverId,
            type: embyType,
            genres: dto.genres?.map(\.name),
            communityRating: UHDRatingNormalizer.normalize(dto.rating),
            productionYear: dto.releaseYear,
            premiereDate: dto.releaseDate,
            runTimeTicks: runtimeTicks,
            childCount: dto.totalSeasons,
            recursiveItemCount: dto.versionCount,
            userData: userData,
            providerIds: dto.tmdbId.map { ["Tmdb": "\($0)"] },
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.posterURL),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.fanartURL),
            uhdLogoURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.logoURL),
            uhdMediaType: dto.type.lowercased()
        )
    }

    func mapDetail(_ dto: UHDMediaDetailDTO, server: EmbyServerConfig) -> EmbyItem {
        let apiBase = server.mainLineURL
        let embyType = dto.type.lowercased() == "tv" ? "Series" : "Movie"
        let runtimeTicks = dto.duration.map { $0 * 10_000_000 }
        let posTicks = (dto.userState?.positionMs ?? 0) * 10_000
        let userData = dto.userState.map {
            EmbyUserData(
                playbackPositionTicks: posTicks,
                isFavorite: $0.favorite,
                played: $0.played,
                playedPercentage: $0.progressPct.map(Double.init),
                lastPlayedDate: $0.lastPlayedAt
            )
        }
        var providers: [String: String] = [:]
        if let tmdb = dto.tmdbId { providers["Tmdb"] = "\(tmdb)" }
        if let imdb = dto.imdbId, !imdb.isEmpty { providers["Imdb"] = imdb }
        if let douban = dto.doubanId, !douban.isEmpty { providers["Douban"] = douban }
        return EmbyItem(
            id: dto.id,
            name: dto.title,
            originalTitle: dto.originTitle,
            serverId: server.serverId,
            type: embyType,
            overview: dto.description,
            taglines: dto.tagline.map { [$0] },
            genres: dto.genres?.map(\.name),
            communityRating: UHDRatingNormalizer.normalize(dto.rating),
            productionYear: dto.releaseYear,
            premiereDate: dto.releaseDate,
            status: dto.status,
            runTimeTicks: runtimeTicks,
            childCount: dto.totalSeasons,
            recursiveItemCount: dto.versionCount,
            userData: userData,
            providerIds: providers.isEmpty ? nil : providers,
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.posterURL),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.fanartURL),
            uhdLogoURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: dto.logoURL),
            uhdMediaType: dto.type.lowercased()
        )
    }

    func mapEpisode(
        _ ep: UHDEpisodeCardDTO,
        seriesId: String,
        seriesName: String?,
        seasonNumber: Int?,
        posterFallback: String?,
        fanartFallback: String?,
        logoFallback: String? = nil,
        server: EmbyServerConfig
    ) -> EmbyItem {
        let apiBase = server.mainLineURL
        let runtimeTicks = ep.duration > 0 ? ep.duration * 10_000_000 : nil
        let posTicks = (ep.userState.positionMs ?? 0) * 10_000
        let userData = EmbyUserData(
            playbackPositionTicks: posTicks,
            isFavorite: ep.userState.favorite,
            played: ep.userState.played,
            playedPercentage: ep.userState.progressPct.map(Double.init),
            lastPlayedDate: ep.userState.lastPlayedAt
        )
        return EmbyItem(
            id: ep.id,
            name: ep.title?.isEmpty == false ? ep.title! : "第 \(ep.episodeNumber) 集",
            serverId: server.serverId,
            type: "Episode",
            overview: ep.description,
            premiereDate: ep.airDate,
            runTimeTicks: runtimeTicks,
            seriesId: seriesId,
            seriesName: seriesName,
            seasonId: ep.seasonId,
            indexNumber: ep.episodeNumber,
            parentIndexNumber: seasonNumber,
            userData: userData,
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: posterFallback),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: fanartFallback),
            uhdLogoURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: logoFallback),
            uhdThumbURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: ep.thumbURL),
            uhdMediaType: "episode"
        )
    }

    func mapPlaybackItem(_ item: UHDPlaybackItemDTO, server: EmbyServerConfig) -> EmbyItem {
        let apiBase = server.mainLineURL
        let isEpisode = item.itemType.lowercased() == "episode"
        let embyType = isEpisode ? "Episode" : "Movie"
        let runtimeTicks = item.duration > 0 ? item.duration * 10_000_000 : nil
        let posTicks = item.positionMs * 10_000
        return EmbyItem(
            id: item.itemId,
            name: item.title,
            serverId: server.serverId,
            type: embyType,
            runTimeTicks: runtimeTicks,
            seriesId: isEpisode ? item.mediaId : nil,
            seriesName: item.seriesTitle,
            seasonId: item.seasonId,
            indexNumber: item.episodeNumber,
            parentIndexNumber: item.seasonNumber,
            userData: EmbyUserData(
                playbackPositionTicks: posTicks,
                played: false,
                playedPercentage: Double(item.progressPct),
                lastPlayedDate: item.lastPlayedAt
            ),
            uhdPosterURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: item.posterURL),
            uhdBackdropURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: item.fanartURL),
            uhdThumbURL: resolveAbsoluteImageURL(apiBase: apiBase, relativeOrAbsolute: item.thumbURL),
            uhdMediaType: item.itemType.lowercased()
        )
    }

    func mapVideoAsset(_ video: UHDVideoAssetDTO, resolvedBase: String) -> MediaSourceInfo {
        var streams: [MediaStream] = []
        let parsedFPS: Double? = {
            guard let raw = video.frameRate else { return nil }
            if raw.contains("/") {
                let parts = raw.split(separator: "/")
                if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                    return num / den
                }
            }
            return Double(raw)
        }()
        streams.append(
            MediaStream(
                index: 0,
                type: "Video",
                codec: video.encoding,
                displayTitle: "\(video.resolution > 0 ? "\(video.resolution)P" : "") \(video.encoding.uppercased()) \(video.videoRange)",
                width: video.width,
                height: video.height,
                bitRate: video.videoBitRate.map(Int.init) ?? Int(video.bitRate),
                bitDepth: video.bitDepth,
                averageFrameRate: parsedFPS,
                realFrameRate: parsedFPS,
                profile: video.profile,
                videoRange: video.videoRange,
                videoDoViTitle: video.dolbyVision != nil ? "Dolby Vision P\(video.dolbyVision?.profile ?? 0)" : nil,
                dvProfile: video.dolbyVision?.profile,
                colorSpace: video.colorSpace,
                colorTransfer: video.colorTransfer,
                colorPrimaries: video.colorPrimaries,
                pixelFormat: video.pixFmt
            )
        )
        for audio in video.audioTracks {
            streams.append(
                MediaStream(
                    index: audio.index,
                    type: "Audio",
                    codec: audio.codecName,
                    language: audio.language,
                    displayTitle: audio.title,
                    title: audio.title,
                    isDefault: audio.isDefault,
                    bitRate: audio.bitRate.map(Int.init),
                    channels: audio.channels,
                    channelLayout: audio.channelLayout,
                    sampleRate: audio.sampleRate.flatMap { Int($0) }
                )
            )
        }
        for sub in video.subtitleTracks {
            streams.append(
                MediaStream(
                    index: sub.index,
                    type: "Subtitle",
                    codec: sub.codecName,
                    language: sub.language,
                    displayTitle: sub.title,
                    title: sub.title,
                    isDefault: sub.isDefault,
                    isForced: sub.isForced,
                    isExternal: false
                )
            )
        }
        return MediaSourceInfo(
            id: video.assetId,
            name: video.displayName.isEmpty ? video.name : video.displayName,
            container: video.container,
            size: video.fileSize,
            bitrate: Int(video.bitRate),
            runTimeTicks: video.duration * 10_000_000,
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: false,
            directStreamUrl: resolveAbsoluteMediaURL(resolvedBase: resolvedBase, path: video.playURL)?.absoluteString,
            mediaStreams: streams
        )
    }
}

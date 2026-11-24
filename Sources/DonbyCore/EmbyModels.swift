import Foundation

public struct EmbyItemsResponse: Codable, Sendable {
    public let items: [EmbyItem]
    public let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
    public init(items: [EmbyItem], totalRecordCount: Int? = nil) { self.items = items; self.totalRecordCount = totalRecordCount }
}

public struct EmbyItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let originalTitle: String?
    public let serverId: String?
    public let type: String?
    public let collectionType: String?
    public let overview: String?
    public let taglines: [String]?
    public let genres: [String]?
    public let communityRating: Double?
    public let criticRating: Double?
    public let officialRating: String?
    public let productionYear: Int?
    public let premiereDate: String?
    public let endDate: String?
    public let status: String?
    public let runTimeTicks: Int64?
    public let container: String?
    public let path: String?
    public let isFolder: Bool?
    public let parentId: String?
    public let seriesId: String?
    public let seriesName: String?
    public let seasonId: String?
    public let seasonName: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let childCount: Int?
    public let recursiveItemCount: Int?
    public let imageTags: [String: String]?
    public let backdropImageTags: [String]?
    public let parentBackdropItemId: String?
    public let parentBackdropImageTags: [String]?
    public let seriesPrimaryImageTag: String?
    public let primaryImageAspectRatio: Double?
    public var userData: EmbyUserData?
    public let mediaSources: [MediaSourceInfo]?
    public let mediaStreams: [MediaStream]?
    public let people: [EmbyPerson]?
    public let studios: [EmbyNameIdPair]?
    public let providerIds: [String: String]?
    public let chapters: [EmbyChapterInfo]?
    public let dateCreated: String?
    public let uhdPosterURL: String?
    public let uhdBackdropURL: String?
    public let uhdLogoURL: String?
    public let uhdThumbURL: String?
    public let uhdMediaType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"; case name = "Name"; case originalTitle = "OriginalTitle"; case serverId = "ServerId"; case type = "Type"; case collectionType = "CollectionType"; case overview = "Overview"; case taglines = "Taglines"; case genres = "Genres"; case communityRating = "CommunityRating"; case criticRating = "CriticRating"; case officialRating = "OfficialRating"; case productionYear = "ProductionYear"; case premiereDate = "PremiereDate"; case endDate = "EndDate"; case status = "Status"; case runTimeTicks = "RunTimeTicks"; case container = "Container"; case path = "Path"; case isFolder = "IsFolder"; case parentId = "ParentId"; case seriesId = "SeriesId"; case seriesName = "SeriesName"; case seasonId = "SeasonId"; case seasonName = "SeasonName"; case indexNumber = "IndexNumber"; case parentIndexNumber = "ParentIndexNumber"; case childCount = "ChildCount"; case recursiveItemCount = "RecursiveItemCount"; case imageTags = "ImageTags"; case backdropImageTags = "BackdropImageTags"; case parentBackdropItemId = "ParentBackdropItemId"; case parentBackdropImageTags = "ParentBackdropImageTags"; case seriesPrimaryImageTag = "SeriesPrimaryImageTag"; case primaryImageAspectRatio = "PrimaryImageAspectRatio"; case userData = "UserData"; case mediaSources = "MediaSources"; case mediaStreams = "MediaStreams"; case people = "People"; case studios = "Studios"; case providerIds = "ProviderIds"; case chapters = "Chapters"; case dateCreated = "DateCreated"; case uhdPosterURL = "UhdPosterURL"; case uhdBackdropURL = "UhdBackdropURL"; case uhdLogoURL = "UhdLogoURL"; case uhdThumbURL = "UhdThumbURL"; case uhdMediaType = "UhdMediaType"
    }

    public init(
        id: String, name: String, originalTitle: String? = nil, serverId: String? = nil, type: String? = nil, collectionType: String? = nil, overview: String? = nil, taglines: [String]? = nil, genres: [String]? = nil, communityRating: Double? = nil, criticRating: Double? = nil, officialRating: String? = nil, productionYear: Int? = nil, premiereDate: String? = nil, endDate: String? = nil, status: String? = nil, runTimeTicks: Int64? = nil, container: String? = nil, path: String? = nil, isFolder: Bool? = nil, parentId: String? = nil, seriesId: String? = nil, seriesName: String? = nil, seasonId: String? = nil, seasonName: String? = nil, indexNumber: Int? = nil, parentIndexNumber: Int? = nil, childCount: Int? = nil, recursiveItemCount: Int? = nil, imageTags: [String: String]? = nil, backdropImageTags: [String]? = nil, parentBackdropItemId: String? = nil, parentBackdropImageTags: [String]? = nil, seriesPrimaryImageTag: String? = nil, primaryImageAspectRatio: Double? = nil, userData: EmbyUserData? = nil, mediaSources: [MediaSourceInfo]? = nil, mediaStreams: [MediaStream]? = nil, people: [EmbyPerson]? = nil, studios: [EmbyNameIdPair]? = nil, providerIds: [String: String]? = nil, chapters: [EmbyChapterInfo]? = nil, dateCreated: String? = nil, uhdPosterURL: String? = nil, uhdBackdropURL: String? = nil, uhdLogoURL: String? = nil, uhdThumbURL: String? = nil, uhdMediaType: String? = nil
    ) {
        self.id = id; self.name = name; self.originalTitle = originalTitle; self.serverId = serverId; self.type = type; self.collectionType = collectionType; self.overview = overview; self.taglines = taglines; self.genres = genres; self.communityRating = communityRating; self.criticRating = criticRating; self.officialRating = officialRating; self.productionYear = productionYear; self.premiereDate = premiereDate; self.endDate = endDate; self.status = status; self.runTimeTicks = runTimeTicks; self.container = container; self.path = path; self.isFolder = isFolder; self.parentId = parentId; self.seriesId = seriesId; self.seriesName = seriesName; self.seasonId = seasonId; self.seasonName = seasonName; self.indexNumber = indexNumber; self.parentIndexNumber = parentIndexNumber; self.childCount = childCount; self.recursiveItemCount = recursiveItemCount; self.imageTags = imageTags; self.backdropImageTags = backdropImageTags; self.parentBackdropItemId = parentBackdropItemId; self.parentBackdropImageTags = parentBackdropImageTags; self.seriesPrimaryImageTag = seriesPrimaryImageTag; self.primaryImageAspectRatio = primaryImageAspectRatio; self.userData = userData; self.mediaSources = mediaSources; self.mediaStreams = mediaStreams; self.people = people; self.studios = studios; self.providerIds = providerIds; self.chapters = chapters; self.dateCreated = dateCreated; self.uhdPosterURL = uhdPosterURL; self.uhdBackdropURL = uhdBackdropURL; self.uhdLogoURL = uhdLogoURL; self.uhdThumbURL = uhdThumbURL; self.uhdMediaType = uhdMediaType
    }

    public var isSeries: Bool {
        let t = type?.lowercased() ?? ""
        return t == "series" || t == "show" || t == "season"
    }
    public var isEpisode: Bool { type?.lowercased() == "episode" }

    public func withSeriesName(_ newSeriesName: String) -> EmbyItem {
        let resolvedSeriesName = (seriesName != nil && !seriesName!.isEmpty) ? seriesName : newSeriesName
        return EmbyItem(
            id: id, name: name, originalTitle: originalTitle, serverId: serverId, type: type, collectionType: collectionType, overview: overview, taglines: taglines, genres: genres, communityRating: communityRating, criticRating: criticRating, officialRating: officialRating, productionYear: productionYear, premiereDate: premiereDate, endDate: endDate, status: status, runTimeTicks: runTimeTicks, container: container, path: path, isFolder: isFolder, parentId: parentId, seriesId: seriesId, seriesName: resolvedSeriesName, seasonId: seasonId, seasonName: seasonName, indexNumber: indexNumber, parentIndexNumber: parentIndexNumber, childCount: childCount, recursiveItemCount: recursiveItemCount, imageTags: imageTags, backdropImageTags: backdropImageTags, parentBackdropItemId: parentBackdropItemId, parentBackdropImageTags: parentBackdropImageTags, seriesPrimaryImageTag: seriesPrimaryImageTag, primaryImageAspectRatio: primaryImageAspectRatio, userData: userData, mediaSources: mediaSources, mediaStreams: mediaStreams, people: people, studios: studios, providerIds: providerIds, chapters: chapters, dateCreated: dateCreated, uhdPosterURL: uhdPosterURL, uhdBackdropURL: uhdBackdropURL, uhdLogoURL: uhdLogoURL, uhdThumbURL: uhdThumbURL, uhdMediaType: uhdMediaType
        )
    }

    public func withDetailEnrichment(mediaSources: [MediaSourceInfo]? = nil, people: [EmbyPerson]? = nil) -> EmbyItem {
        EmbyItem(
            id: id, name: name, originalTitle: originalTitle, serverId: serverId, type: type, collectionType: collectionType, overview: overview, taglines: taglines, genres: genres, communityRating: communityRating, criticRating: criticRating, officialRating: officialRating, productionYear: productionYear, premiereDate: premiereDate, endDate: endDate, status: status, runTimeTicks: runTimeTicks, container: container, path: path, isFolder: isFolder, parentId: parentId, seriesId: seriesId, seriesName: seriesName, seasonId: seasonId, seasonName: seasonName, indexNumber: indexNumber, parentIndexNumber: parentIndexNumber, childCount: childCount, recursiveItemCount: recursiveItemCount, imageTags: imageTags, backdropImageTags: backdropImageTags, parentBackdropItemId: parentBackdropItemId, parentBackdropImageTags: parentBackdropImageTags, seriesPrimaryImageTag: seriesPrimaryImageTag, primaryImageAspectRatio: primaryImageAspectRatio, userData: userData, mediaSources: mediaSources ?? self.mediaSources, mediaStreams: mediaStreams, people: people ?? self.people, studios: studios, providerIds: providerIds, chapters: chapters, dateCreated: dateCreated, uhdPosterURL: uhdPosterURL, uhdBackdropURL: uhdBackdropURL, uhdLogoURL: uhdLogoURL, uhdThumbURL: uhdThumbURL, uhdMediaType: uhdMediaType
        )
    }

    public func withInheritedArtworkFallback(
        posterURL: String? = nil,
        backdropURL: String? = nil,
        logoURL: String? = nil
    ) -> EmbyItem {
        let resolvedPoster = (uhdPosterURL?.isEmpty == false) ? uhdPosterURL : posterURL
        let resolvedBackdrop = (uhdBackdropURL?.isEmpty == false) ? uhdBackdropURL : backdropURL
        let resolvedLogo = (uhdLogoURL?.isEmpty == false) ? uhdLogoURL : logoURL
        if resolvedPoster == uhdPosterURL && resolvedBackdrop == uhdBackdropURL && resolvedLogo == uhdLogoURL {
            return self
        }
        return EmbyItem(
            id: id, name: name, originalTitle: originalTitle, serverId: serverId, type: type, collectionType: collectionType, overview: overview, taglines: taglines, genres: genres, communityRating: communityRating, criticRating: criticRating, officialRating: officialRating, productionYear: productionYear, premiereDate: premiereDate, endDate: endDate, status: status, runTimeTicks: runTimeTicks, container: container, path: path, isFolder: isFolder, parentId: parentId, seriesId: seriesId, seriesName: seriesName, seasonId: seasonId, seasonName: seasonName, indexNumber: indexNumber, parentIndexNumber: parentIndexNumber, childCount: childCount, recursiveItemCount: recursiveItemCount, imageTags: imageTags, backdropImageTags: backdropImageTags, parentBackdropItemId: parentBackdropItemId, parentBackdropImageTags: parentBackdropImageTags, seriesPrimaryImageTag: seriesPrimaryImageTag, primaryImageAspectRatio: primaryImageAspectRatio, userData: userData, mediaSources: mediaSources, mediaStreams: mediaStreams, people: people, studios: studios, providerIds: providerIds, chapters: chapters, dateCreated: dateCreated, uhdPosterURL: resolvedPoster, uhdBackdropURL: resolvedBackdrop, uhdLogoURL: resolvedLogo, uhdThumbURL: uhdThumbURL, uhdMediaType: uhdMediaType
        )
    }

    public var episodeCodeString: String? {
        if let s = parentIndexNumber, let e = indexNumber { return String(format: "S%02dE%02d", s, e) }
        else if let e = indexNumber, isEpisode { return "第\(e)集" }
        return nil
    }

    public var displaySubtitle: String {
        if isEpisode {
            if let seriesName, let code = episodeCodeString { return "\(seriesName) · \(code)" }
            return seriesName ?? episodeCodeString ?? ""
        }
        if let year = productionYear {
            if let genres, let first = genres.first { return "\(year) · \(first)" }
            return "\(year)"
        }
        return genres?.first ?? ""
    }

    public var runtimeMinutesString: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        let totalSeconds = Int(ticks / 10_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return "\(hours)小时\(minutes)分钟" }
        return "\(max(1, minutes))分钟"
    }

    public var durationSeconds: Double {
        guard let ticks = runTimeTicks, ticks > 0 else { return 0 }
        return Double(ticks) / 10_000_000.0
    }

    public var resumePositionSeconds: Double {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return 0 }
        return Double(ticks) / 10_000_000.0
    }

    public var resumePositionString: String {
        let total = Int(resumePositionSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    public var premiereDateString: String? {
        guard let premiereDate, premiereDate.count >= 10 else {
            return productionYear.map { "\($0)年" }
        }
        let ymd = String(premiereDate.prefix(10))
        let parts = ymd.split(separator: "-")
        if parts.count == 3 {
            return "\(parts[0])年\(Int(parts[1]) ?? 1)月\(Int(parts[2]) ?? 1)日"
        }
        return ymd
    }

    public var progressFraction: Double {
        if let pct = userData?.playedPercentage, pct > 0 { return min(1.0, max(0.0, pct / 100.0)) }
        let dur = durationSeconds
        guard dur > 0 else { return 0 }
        return min(1.0, max(0.0, resumePositionSeconds / dur))
    }

    public var allStreams: [MediaStream] {
        if let streams = mediaStreams, !streams.isEmpty { return streams }
        return mediaSources?.first?.mediaStreams ?? []
    }

    public var primaryVideoStream: MediaStream? { allStreams.first { $0.type?.lowercased() == "video" } }
    public var audioStreams: [MediaStream] { allStreams.filter { $0.type?.lowercased() == "audio" } }
    public var subtitleStreams: [MediaStream] { allStreams.filter { $0.type?.lowercased() == "subtitle" } }

    public var resolutionBadge: String? {
        guard let v = primaryVideoStream else { return nil }
        let w = v.width ?? 0; let h = v.height ?? 0
        var res = ""
        if w >= 3800 || h >= 2100 { res = "4K" }
        else if w >= 2500 || h >= 1400 { res = "2K" }
        else if w >= 1900 || h >= 1000 { res = "1080P" }
        else if w >= 1200 || h >= 700 { res = "720P" }

        let range = (v.videoRange ?? v.videoDoViTitle ?? v.displayTitle ?? "").uppercased()
        if range.contains("DOVI") || range.contains("DOLBY") || v.dvProfile != nil {
            return res.isEmpty ? "DV" : "\(res) DV"
        } else if range.contains("HDR") {
            return res.isEmpty ? "HDR" : "\(res) HDR"
        }
        return res.isEmpty ? nil : res
    }

    public var dynamicRangeTag: String? {
        guard let v = primaryVideoStream else { return nil }
        if let dovi = v.videoDoViTitle, !dovi.isEmpty { return dovi }
        if let dvProfile = v.dvProfile { return "Dolby Vision P\(dvProfile)" }
        if let range = v.videoRange, range.uppercased() != "SDR" { return range }
        return nil
    }

    public var videoCodecTag: String? {
        guard let codec = primaryVideoStream?.codec?.uppercased() else { return nil }
        switch codec {
        case "HEVC", "H265": return "HEVC"
        case "H264", "AVC": return "H.264"
        case "AV1": return "AV1"
        case "VP9": return "VP9"
        default: return codec
        }
    }

    public var audioSummaryTag: String? {
        guard let a = audioStreams.first else { return nil }
        let title = (a.displayTitle ?? a.profile ?? a.codec ?? "").uppercased()
        if title.contains("ATMOS") { return "Dolby Atmos" }
        if title.contains("TRUEHD") { return "TrueHD" }
        if title.contains("DTS") { return "DTS-HD" }
        if title.contains("EAC3") || title.contains("DD+") { return "Dolby Digital+" }
        if let ch = a.channels {
            if ch >= 8 { return "7.1ch" }
            if ch >= 6 { return "5.1ch" }
            if ch == 2 { return "2.0ch" }
        }
        return a.codec?.uppercased()
    }
}

public struct EmbyUserData: Codable, Hashable, Sendable {
    public var playbackPositionTicks: Int64?
    public var playCount: Int?
    public var isFavorite: Bool?
    public var played: Bool?
    public var playedPercentage: Double?
    public var unplayedItemCount: Int?
    public var lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"; case playCount = "PlayCount"; case isFavorite = "IsFavorite"; case played = "Played"; case playedPercentage = "PlayedPercentage"; case unplayedItemCount = "UnplayedItemCount"; case lastPlayedDate = "LastPlayedDate"
    }
    public init(playbackPositionTicks: Int64? = nil, playCount: Int? = nil, isFavorite: Bool? = nil, played: Bool? = nil, playedPercentage: Double? = nil, unplayedItemCount: Int? = nil, lastPlayedDate: String? = nil) {
        self.playbackPositionTicks = playbackPositionTicks; self.playCount = playCount; self.isFavorite = isFavorite; self.played = played; self.playedPercentage = playedPercentage; self.unplayedItemCount = unplayedItemCount; self.lastPlayedDate = lastPlayedDate
    }
}

public struct MediaSourceInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let path: String?
    public let sourceProtocol: String?
    public let container: String?
    public let size: Int64?
    public let bitrate: Int?
    public let runTimeTicks: Int64?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let supportsTranscoding: Bool?
    public let isRemote: Bool?
    public let directStreamUrl: String?
    public let transcodingUrl: String?
    public let xRouteMode: String?
    public let xOriginDirectStreamUrl: String?
    public let requiredHttpHeaders: [String: String]?
    public let defaultAudioStreamIndex: Int?
    public let defaultSubtitleStreamIndex: Int?
    public let mediaStreams: [MediaStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"; case name = "Name"; case path = "Path"; case sourceProtocol = "Protocol"; case container = "Container"; case size = "Size"; case bitrate = "Bitrate"; case runTimeTicks = "RunTimeTicks"; case supportsDirectPlay = "SupportsDirectPlay"; case supportsDirectStream = "SupportsDirectStream"; case supportsTranscoding = "SupportsTranscoding"; case isRemote = "IsRemote"; case directStreamUrl = "DirectStreamUrl"; case transcodingUrl = "TranscodingUrl"; case xRouteMode = "XRouteMode"; case xOriginDirectStreamUrl = "XOriginDirectStreamUrl"; case requiredHttpHeaders = "RequiredHttpHeaders"; case defaultAudioStreamIndex = "DefaultAudioStreamIndex"; case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"; case mediaStreams = "MediaStreams"
    }

    public init(id: String, name: String? = nil, path: String? = nil, sourceProtocol: String? = nil, container: String? = nil, size: Int64? = nil, bitrate: Int? = nil, runTimeTicks: Int64? = nil, supportsDirectPlay: Bool? = true, supportsDirectStream: Bool? = true, supportsTranscoding: Bool? = true, isRemote: Bool? = false, directStreamUrl: String? = nil, transcodingUrl: String? = nil, xRouteMode: String? = nil, xOriginDirectStreamUrl: String? = nil, requiredHttpHeaders: [String: String]? = nil, defaultAudioStreamIndex: Int? = nil, defaultSubtitleStreamIndex: Int? = nil, mediaStreams: [MediaStream]? = nil) {
        self.id = id; self.name = name; self.path = path; self.sourceProtocol = sourceProtocol; self.container = container; self.size = size; self.bitrate = bitrate; self.runTimeTicks = runTimeTicks; self.supportsDirectPlay = supportsDirectPlay; self.supportsDirectStream = supportsDirectStream; self.supportsTranscoding = supportsTranscoding; self.isRemote = isRemote; self.directStreamUrl = directStreamUrl; self.transcodingUrl = transcodingUrl; self.xRouteMode = xRouteMode; self.xOriginDirectStreamUrl = xOriginDirectStreamUrl; self.requiredHttpHeaders = requiredHttpHeaders; self.defaultAudioStreamIndex = defaultAudioStreamIndex; self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex; self.mediaStreams = mediaStreams
    }

    public var formattedFileSize: String? {
        guard let size, size > 0 else { return nil }
        Self.fileSizeFormatterLock.lock()
        defer { Self.fileSizeFormatterLock.unlock() }
        return Self.fileSizeFormatter.string(fromByteCount: size)
    }

    private static let fileSizeFormatterLock = NSLock()
    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    public var formattedBitrate: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let mbps = Double(bitrate) / 1_000_000.0
        if mbps >= 1.0 { return String(format: "%.1f Mbps", mbps) }
        return String(format: "%d kbps", bitrate / 1000)
    }

    public var displayVersionName: String {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name) }
        else if let container { parts.append(container.uppercased()) }
        if let sizeStr = formattedFileSize { parts.append(sizeStr) }
        if let brStr = formattedBitrate { parts.append(brStr) }
        return parts.isEmpty ? "默认版本" : parts.joined(separator: " · ")
    }

    /// Composite bitrate / specification score (in estimated bps) used for automatic version selection.
    public var estimatedQualityScore: Int64 {
        if let bitrate, bitrate > 0 {
            return Int64(bitrate)
        }
        if let size, size > 0, let ticks = runTimeTicks, ticks > 0 {
            return (size * 8 * 10_000_000) / max(1, ticks)
        }
        var score: Int64 = 0
        if let vStream = mediaStreams?.first(where: { $0.type?.lowercased() == "video" }) {
            if let br = vStream.bitRate, br > 0 {
                return Int64(br)
            }
            let w = vStream.width ?? 0
            if w >= 3800 { score += 40_000_000 }
            else if w >= 2500 { score += 20_000_000 }
            else if w >= 1900 { score += 12_000_000 }
            else if w >= 1200 { score += 5_000_000 }
            else if w > 0 { score += 2_000_000 }
        }
        let label = ((name ?? "") + " " + (path ?? "")).lowercased()
        if label.contains("remux") || label.contains("bdmv") || label.contains("bluray") || label.contains("iso") {
            score += 35_000_000
        }
        if label.contains("2160p") || label.contains("4k") || label.contains("uhd") {
            score = max(score, 28_000_000)
        } else if label.contains("1080p") {
            score = max(score, 10_000_000)
        } else if label.contains("720p") {
            score = max(score, 4_000_000)
        }
        if label.contains("dovi") || label.contains("dolby") || label.contains("dv") || label.contains("hdr") {
            score += 4_000_000
        }
        if let size, size > 0 {
            score += min(10_000_000, size / (1024 * 1024))
        }
        return score
    }
}

public extension Array where Element == MediaSourceInfo {
    func preferredSource(for preset: PreferredVersionPreset) -> MediaSourceInfo? {
        guard !isEmpty else { return nil }
        if count == 1 { return first }
        switch preset {
        case .higherBitrate:
            return self.max { $0.estimatedQualityScore < $1.estimatedQualityScore }
        case .lowerBitrate:
            return self.min { $0.estimatedQualityScore < $1.estimatedQualityScore }
        }
    }
}

public struct MediaStream: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(type ?? "stream")-\(index ?? 0)-\(displayTitle ?? "")" }
    public let index: Int?
    public let type: String?
    public let codec: String?
    public let language: String?
    public let displayTitle: String?
    public let displayLanguage: String?
    public let title: String?
    public let isDefault: Bool?
    public let isForced: Bool?
    public let isExternal: Bool?
    public let deliveryUrl: String?
    public let width: Int?
    public let height: Int?
    public let bitRate: Int?
    public let bitDepth: Int?
    public let averageFrameRate: Double?
    public let realFrameRate: Double?
    public let profile: String?
    public let videoRange: String?
    public let videoDoViTitle: String?
    public let dvProfile: Int?
    public let colorSpace: String?
    public let colorTransfer: String?
    public let colorPrimaries: String?
    public let pixelFormat: String?
    public let channels: Int?
    public let channelLayout: String?
    public let sampleRate: Int?

    enum CodingKeys: String, CodingKey {
        case index = "Index"; case type = "Type"; case codec = "Codec"; case language = "Language"; case displayTitle = "DisplayTitle"; case displayLanguage = "DisplayLanguage"; case title = "Title"; case isDefault = "IsDefault"; case isForced = "IsForced"; case isExternal = "IsExternal"; case deliveryUrl = "DeliveryUrl"; case width = "Width"; case height = "Height"; case bitRate = "BitRate"; case bitDepth = "BitDepth"; case averageFrameRate = "AverageFrameRate"; case realFrameRate = "RealFrameRate"; case profile = "Profile"; case videoRange = "VideoRange"; case videoDoViTitle = "VideoDoViTitle"; case dvProfile = "DvProfile"; case colorSpace = "ColorSpace"; case colorTransfer = "ColorTransfer"; case colorPrimaries = "ColorPrimaries"; case pixelFormat = "PixelFormat"; case channels = "Channels"; case channelLayout = "ChannelLayout"; case sampleRate = "SampleRate"
    }

    public init(index: Int? = nil, type: String? = nil, codec: String? = nil, language: String? = nil, displayTitle: String? = nil, displayLanguage: String? = nil, title: String? = nil, isDefault: Bool? = nil, isForced: Bool? = nil, isExternal: Bool? = nil, deliveryUrl: String? = nil, width: Int? = nil, height: Int? = nil, bitRate: Int? = nil, bitDepth: Int? = nil, averageFrameRate: Double? = nil, realFrameRate: Double? = nil, profile: String? = nil, videoRange: String? = nil, videoDoViTitle: String? = nil, dvProfile: Int? = nil, colorSpace: String? = nil, colorTransfer: String? = nil, colorPrimaries: String? = nil, pixelFormat: String? = nil, channels: Int? = nil, channelLayout: String? = nil, sampleRate: Int? = nil) {
        self.index = index; self.type = type; self.codec = codec; self.language = language; self.displayTitle = displayTitle; self.displayLanguage = displayLanguage; self.title = title; self.isDefault = isDefault; self.isForced = isForced; self.isExternal = isExternal; self.deliveryUrl = deliveryUrl; self.width = width; self.height = height; self.bitRate = bitRate; self.bitDepth = bitDepth; self.averageFrameRate = averageFrameRate; self.realFrameRate = realFrameRate; self.profile = profile; self.videoRange = videoRange; self.videoDoViTitle = videoDoViTitle; self.dvProfile = dvProfile; self.colorSpace = colorSpace; self.colorTransfer = colorTransfer; self.colorPrimaries = colorPrimaries; self.pixelFormat = pixelFormat; self.channels = channels; self.channelLayout = channelLayout; self.sampleRate = sampleRate
    }

    public var readableLabel: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        var parts: [String] = []
        if let displayLanguage, !displayLanguage.isEmpty { parts.append(displayLanguage) }
        else if let language, !language.isEmpty { parts.append(language) }
        if let title, !title.isEmpty { parts.append(title) }
        if let codec { parts.append(codec.uppercased()) }
        if let channelLayout { parts.append(channelLayout) }
        return parts.isEmpty ? "轨道 #\(index ?? 0)" : parts.joined(separator: " · ")
    }
}

public struct EmbyPerson: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let type: String?
    public let primaryImageTag: String?
    public let uhdImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"; case name = "Name"; case role = "Role"; case type = "Type"; case primaryImageTag = "PrimaryImageTag"; case uhdImageURL = "UhdImageURL"
    }
    public init(id: String, name: String, role: String? = nil, type: String? = "Actor", primaryImageTag: String? = nil, uhdImageURL: String? = nil) {
        self.id = id; self.name = name; self.role = role; self.type = type; self.primaryImageTag = primaryImageTag; self.uhdImageURL = uhdImageURL
    }
}

public struct EmbyNameIdPair: Codable, Hashable, Sendable {
    public let id: String?
    public let name: String?

    enum CodingKeys: String, CodingKey { case id = "Id"; case name = "Name" }
    public init(id: String? = nil, name: String? = nil) { self.id = id; self.name = name }
}

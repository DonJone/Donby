import Foundation

public enum MainNavigationTab: String, CaseIterable, Identifiable, Sendable {
    case files = "files"
    case servers = "servers"
    case iptv = "iptv"
    case records = "records"
    case search = "search"
    case settings = "settings"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .files: return "文件"
        case .servers: return "服务器"
        case .iptv: return "IPTV"
        case .records: return "记录"
        case .search: return "搜索"
        case .settings: return "设置"
        }
    }

    public var icon: String {
        switch self {
        case .files: return "folder"
        case .servers: return "externaldrive.connected.to.line.below"
        case .iptv: return "sparkles.tv"
        case .records: return "play.rectangle"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

public struct ToastMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let icon: String
    public let text: String
    public let isError: Bool

    public init(id: UUID = UUID(), icon: String, text: String, isError: Bool = false) {
        self.id = id; self.icon = icon; self.text = text; self.isError = isError
    }
}

public struct ActivePlaybackSession: Identifiable, Equatable, Sendable {
    public var id: String { "\(server.id.uuidString)|\(item.id)|\(resource.mediaSource.id)" }
    public let server: EmbyServerConfig
    public let item: EmbyItem
    public let episodesQueue: [EmbyItem]
    public let resource: ResolvedPlaybackResource
    public let startPositionSeconds: Double
    public let selectedAudioIndex: Int?
    public let selectedSubtitleIndex: Int?

    public init(server: EmbyServerConfig, item: EmbyItem, episodesQueue: [EmbyItem], resource: ResolvedPlaybackResource, startPositionSeconds: Double, selectedAudioIndex: Int? = nil, selectedSubtitleIndex: Int? = nil) {
        self.server = server; self.item = item; self.episodesQueue = episodesQueue; self.resource = resource; self.startPositionSeconds = startPositionSeconds; self.selectedAudioIndex = selectedAudioIndex; self.selectedSubtitleIndex = selectedSubtitleIndex
    }
}

public struct LocalOrURLMediaItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var urlString: String
    public var userAgent: String = ""
    public var isLocalFile: Bool = false
    public var addedAt: Date = Date()

    public init(name: String, urlString: String, userAgent: String = "", isLocalFile: Bool = false, addedAt: Date = Date()) {
        self.name = name; self.urlString = urlString; self.userAgent = userAgent; self.isLocalFile = isLocalFile; self.addedAt = addedAt
    }
}

public struct IPTVChannelItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var group: String
    public var urlString: String

    public init(name: String, group: String, urlString: String) {
        self.name = name; self.group = group; self.urlString = urlString
    }
}

public struct WatchRecordItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var posterKey: String?
    public var posterURL: String?
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var lastWatchedAt: Date
    public var sourceType: String // "Emby", "Local", "Network"
    public var streamURLString: String?
    public var embyItemId: String?
    public var resolutionTag: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        posterKey: String? = nil,
        posterURL: String? = nil,
        positionSeconds: Double = 0,
        durationSeconds: Double = 0,
        lastWatchedAt: Date = Date(),
        sourceType: String = "Emby",
        streamURLString: String? = nil,
        embyItemId: String? = nil,
        resolutionTag: String? = "4K UHD"
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.posterKey = posterKey
        self.posterURL = posterURL
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.lastWatchedAt = lastWatchedAt
        self.sourceType = sourceType
        self.streamURLString = streamURLString
        self.embyItemId = embyItemId
        self.resolutionTag = resolutionTag
    }

    public var progressRatio: Double {
        guard durationSeconds > 0 else { return 0 }
        return max(0, min(1.0, positionSeconds / durationSeconds))
    }

    public var progressPercentageString: String {
        "\(Int(progressRatio * 100))%"
    }

    public var remainingMinutesString: String {
        guard durationSeconds > positionSeconds else { return "已看完" }
        let remain = max(1, Int((durationSeconds - positionSeconds) / 60))
        return "还剩 \(remain) 分钟"
    }
}

public struct IconLibrarySet: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let icons: [IconLibraryEntry]

    public init(name: String, description: String? = nil, icons: [IconLibraryEntry] = []) {
        self.name = name; self.description = description; self.icons = icons
    }
}

public struct IconLibraryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(name)|\(url)" }
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name; self.url = url
    }
}

public enum AppThemeColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue = "blue"
    case cyan = "cyan"
    case green = "green"
    case purple = "purple"
    case orange = "orange"
    case pink = "pink"
    case indigo = "indigo"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .blue: return "经典蓝"
        case .cyan: return "极光青"
        case .green: return "翡翠绿"
        case .purple: return "霓虹紫"
        case .orange: return "活力橙"
        case .pink: return "樱花粉"
        case .indigo: return "深空靛"
        }
    }
}

public struct ThemeColorPalette {
    public static func color(for theme: AppThemeColor) -> (r: Double, g: Double, b: Double) {
        switch theme {
        case .blue: return (0.16, 0.49, 0.96)
        case .cyan: return (0.12, 0.78, 0.92)
        case .green: return (0.18, 0.80, 0.45)
        case .purple: return (0.62, 0.36, 0.98)
        case .orange: return (1.0, 0.55, 0.16)
        case .pink: return (0.96, 0.34, 0.58)
        case .indigo: return (0.38, 0.42, 0.96)
        }
    }
}

public enum ControlBarPositionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case float = "float"
    case bottom = "bottom"
    public var id: String { rawValue }
    public var title: String { self == .float ? "悬浮" : "底部" }
}

public enum EmbySortField: String, CaseIterable, Identifiable, Sendable {
    case dateCreated = "DateCreated,SortName"
    case premiereDate = "PremiereDate,SortName"
    case communityRating = "CommunityRating,SortName"
    case sortName = "SortName"
    case datePlayed = "DatePlayed,SortName"
    case random = "Random"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dateCreated: return "添加日期"
        case .premiereDate: return "发行日期"
        case .communityRating: return "IMDb评分"
        case .sortName: return "名称"
        case .datePlayed: return "播放日期"
        case .random: return "随机"
        }
    }
}

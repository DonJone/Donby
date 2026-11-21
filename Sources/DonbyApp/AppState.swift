import Foundation
import SwiftUI
import Combine
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyStorage
import DonbyKernelC
import DonbyMetalRenderer

@MainActor
public final class AppState: ObservableObject {
    public static weak var sharedInstance: AppState?

    @Published public var selectedTab: MainNavigationTab = .servers
    @Published public var openedServerId: UUID? = nil
    @Published public var selectedLibrary: EmbyItem? = nil
    @Published public var detailStack: [EmbyItem] = []
    @Published public var detailOfflineFocusIds: Set<String> = []
    @Published public var activePlayback: ActivePlaybackSession? = nil
    @Published public var preferredSettingsTabRaw: String = "基础设置"
    @Published public var isSidebarCollapsed: Bool = false

    @Published public var showAddServerSheet: Bool = false
    @Published public var editingServer: EmbyServerConfig? = nil
    @Published public var linePickerServer: EmbyServerConfig? = nil
    @Published public var toastMessage: ToastMessage? = nil
    @Published public var showLogViewer: Bool = false
    @Published public var isStartingPlayback: Bool = false

    @Published public var servers: [EmbyServerConfig] = [] {
        didSet { if !isLoadingFromDisk { saveServersToDisk() } }
    }
    @Published public var activeServerId: UUID? = nil {
        didSet {
            if !isLoadingFromDisk, let id = activeServerId {
                UserDefaults.standard.set(id.uuidString, forKey: "donby.activeServerId")
            }
        }
    }
    @Published public var isSyncingDomains: Bool = false
    @Published public var isPingingLines: Bool = false
    private var homeLoadGeneration: UInt64 = 0
    private var playbackStartGeneration: UInt64 = 0
    private var pendingPlaybackKey: String? = nil
    private var pendingPlaybackTimestamp: TimeInterval = 0
    private var lastCompletedPlaybackKey: String? = nil
    private var lastCompletedPlaybackTimestamp: TimeInterval = 0
    private var detailFocusedEpisodeMemory: [String: (seasonNumber: Int?, episodeId: String)] = [:]

    @Published public var isLoadingHome: Bool = false
    @Published public var homeErrorMessage: String? = nil
    @Published public var libraryViews: [EmbyItem] = []
    @Published public var carouselItems: [EmbyItem] = []
    @Published public var resumeItems: [EmbyItem] = []
    @Published public var nextUpItems: [EmbyItem] = []
    @Published public var latestByLibrary: [String: [EmbyItem]] = [:]
    @Published public var favoriteItems: [EmbyItem] = []
    @Published public var iconSets: [IconLibrarySet] = []

    @Published public var urlMediaItems: [LocalOrURLMediaItem] = [] {
        didSet { if !isLoadingFromDisk { saveURLMediaToDisk() } }
    }

    private let localFoldersStorageKey = "donby.localFolders.v1"
    @Published public var localFolders: [LocalMediaFolder] = [] {
        didSet { if !isLoadingFromDisk { saveLocalFoldersToDisk() } }
    }
    @Published public var browsingFolder: LocalMediaFolder? = nil

    @AppStorage("donby.defaultStartupModule") public var defaultStartupModule: String = "servers"
    @AppStorage("donby.defaultStartupServerId") public var defaultStartupServerId: String = ""
    @AppStorage("donby.defaultFilesFolderId") public var defaultFilesFolderId: String = ""

    @Published public var iptvChannels: [IPTVChannelItem] = [] {
        didSet { if !isLoadingFromDisk { saveIPTVChannelsToDisk() } }
    }
    private var isLoadingFromDisk: Bool = false

    @Published public var watchHistory: [WatchRecordItem] = []
    private var saveWatchHistoryTask: Task<Void, Never>? = nil
    private var lastRecordedWatchItemId: String? = nil
    private var lastRecordedWatchPosition: Double = -1.0
    private var lastRecordedWatchDate: Date = .distantPast
    private var inFlightSeriesNameTasks: [String: Task<String?, Never>] = [:]
    private var activeSyncDomainsCount: Int = 0
    private var activePingLinesCount: Int = 0
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private static let maxWatchHistoryCount = 300

    @AppStorage("donby.displayConnectStatus") public var displayConnectionStatus: Bool = true
    @AppStorage("donby.displayMediaStats") public var displayMediaStatistics: Bool = true
    @AppStorage("donby.displayServerIcon") public var displayServerIcon: Bool = true
    @AppStorage("donby.displayWatchTime") public var displayWatchTime: Bool = true
    @AppStorage("donby.displaySearchBox") public var displaySearchBox: Bool = true
    @AppStorage("donby.displayAeroGlass") public var displayAeroGlass: Bool = true
    @AppStorage("donby.hideEncryptedServers") public var hideEncryptedServers: Bool = false

    @AppStorage("donby.themeColor.v2") public var themeColorRaw: String = AppThemeColor.appleMusicRed.rawValue
    @AppStorage("donby.appearanceMode.v2") public var appearanceModeRaw: String = AppAppearanceMode.light.rawValue
    @AppStorage("donby.showCarousel") public var showCarousel: Bool = true
    @AppStorage("donby.showMyMedia") public var showMyMedia: Bool = true
    @AppStorage("donby.showContinueWatching") public var showContinueWatching: Bool = true
    @AppStorage("donby.showNextUp") public var showNextUp: Bool = true
    @AppStorage("donby.hideWatchedInLatest") public var hideWatchedInLatest: Bool = false
    @AppStorage("donby.showResolutionBadge") public var showResolutionBadge: Bool = true
    @AppStorage("donby.showRatingBadge") public var showRatingBadge: Bool = true
    @AppStorage("donby.controlBarStyle") public var controlBarStyleRaw: String = ControlBarPositionStyle.float.rawValue
    @AppStorage("donby.defaultPlaySpeed") public var defaultPlaySpeed: Double = 1.0
    @AppStorage("donby.opSeconds") public var opSeconds: Int = 90
    @AppStorage("donby.edSeconds") public var edSeconds: Int = 90
    @AppStorage("donby.enableDanmaku") public var enableDanmaku: Bool = true
    @AppStorage("donby.enableHardwareDecode") public var enableHardwareDecode: Bool = true
    @AppStorage("donby.preferredVersionPreset") public var preferredVersionPresetRaw: String = PreferredVersionPreset.higherBitrate.rawValue

    // 线路与网络设置
    @AppStorage("donby.autoSyncDomains") public var autoSyncDomains: Bool = true
    @AppStorage("donby.enable302Cache") public var enable302Cache: Bool = true
    @AppStorage("donby.pingTimeoutSeconds") public var pingTimeoutSeconds: Int = 5
    @AppStorage("donby.cachePoolSizeMB") public var cachePoolSizeMB: Int = 256
    @AppStorage("donby.defaultSidebarCollapsed") public var defaultSidebarCollapsed: Bool = false

    // 字幕、跳过与 Turbo 多连接分片缓存配置
    @Published public var subtitleStyle: SubtitleStyleConfiguration = SubtitleStyleConfiguration() {
        didSet {
            if !isLoadingFromDisk, let data = try? jsonEncoder.encode(subtitleStyle) {
                UserDefaults.standard.set(data, forKey: "donby.subtitleStyle.v1")
            }
        }
    }
    @Published public var seasonSkipPreferences: [String: SeasonSkipPreference] = [:] {
        didSet {
            if !isLoadingFromDisk, let data = try? jsonEncoder.encode(seasonSkipPreferences) {
                UserDefaults.standard.set(data, forKey: "donby.seasonSkipPreferences.v1")
            }
        }
    }
    @AppStorage("donby.rememberSubtitleSelection") public var rememberSubtitleSelection: Bool = true
    @Published public var subtitleMemoryByScope: [String: SeriesSubtitleMemory] = [:] {
        didSet {
            if !isLoadingFromDisk, let data = try? jsonEncoder.encode(subtitleMemoryByScope) {
                UserDefaults.standard.set(data, forKey: "donby.subtitleMemory.v1")
            }
        }
    }
    @Published public var globalPreferredSubtitle: SubtitleTrackPreference? = nil {
        didSet {
            if !isLoadingFromDisk {
                if let pref = globalPreferredSubtitle, let data = try? jsonEncoder.encode(pref) {
                    UserDefaults.standard.set(data, forKey: "donby.globalPreferredSubtitle.v1")
                } else {
                    UserDefaults.standard.removeObject(forKey: "donby.globalPreferredSubtitle.v1")
                }
            }
        }
    }
    @Published public var globalPreferredSecondarySubtitle: SubtitleTrackPreference? = nil {
        didSet {
            if !isLoadingFromDisk {
                if let pref = globalPreferredSecondarySubtitle, let data = try? jsonEncoder.encode(pref) {
                    UserDefaults.standard.set(data, forKey: "donby.globalPreferredSecondarySubtitle.v1")
                } else {
                    UserDefaults.standard.removeObject(forKey: "donby.globalPreferredSecondarySubtitle.v1")
                }
            }
        }
    }
    private var downloadStatusCancellable: AnyCancellable? = nil
    @Published public private(set) var downloadStatusIndex: DonbyDownloadStatusIndex = .empty
    @AppStorage("donby.turboEnabled") public var turboEnabled: Bool = true
    @AppStorage("donby.turboConnectionBudget") public var turboConnectionBudget: Int = 4
    @AppStorage("donby.turboMemoryCacheMB") public var turboMemoryCacheMB: Int = 500
    @AppStorage("donby.turboDiskCacheMB") public var turboDiskCacheMB: Int = 2048
    @AppStorage("donby.turboPrefetchSeconds") public var turboPrefetchSeconds: Double = 60.0
    @AppStorage("donby.detailPreloadEnabled") public var detailPreloadEnabled: Bool = false
    @AppStorage("donby.detailPreloadSeconds") public var detailPreloadSeconds: Int = 15
    @AppStorage("donby.autoSkipIntroOutro") public var autoSkipIntroOutro: Bool = false
    @AppStorage("donby.autoNextEpisode") public var autoNextEpisode: Bool = true
    @AppStorage("donby.autoSaveFullCacheToOffline") public var autoSaveFullCacheToOffline: Bool = false
    @AppStorage("donby.autoDeleteAutoArchivedAfterPlayback") public var autoDeleteAutoArchivedAfterPlayback: Bool = false
    @Published public var serverCapabilities: [UUID: ServerDeliveryCapabilities] = [:]

    public static var appleMusicRed: Color {
        let rgb = ThemeColorPalette.appleMusicRedRGB
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    public var appearanceMode: AppAppearanceMode {
        get { AppAppearanceMode(rawValue: appearanceModeRaw) ?? .light }
        set {
            appearanceModeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    public var isLightMode: Bool {
        switch appearanceMode {
        case .light: return true
        case .dark: return false
        case .auto:
            return NSApp.effectiveAppearance.name.rawValue.lowercased().contains("dark") == false
        }
    }

    public var colorScheme: ColorScheme? {
        switch appearanceMode {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }

    public var accentColor: Color {
        let theme = AppThemeColor(rawValue: themeColorRaw) ?? .appleMusicRed
        if theme == .monochrome {
            return isLightMode ? Color(white: 0.12) : Color.white
        }
        let rgb = ThemeColorPalette.color(for: theme)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    public var isMonochromeTheme: Bool {
        themeColorRaw == AppThemeColor.monochrome.rawValue
    }

    public var accentTextColor: Color {
        if isMonochromeTheme && !isLightMode {
            return .black
        }
        return .white
    }

    public var preferredVersionPreset: PreferredVersionPreset {
        get { PreferredVersionPreset(rawValue: preferredVersionPresetRaw) ?? .higherBitrate }
        set { preferredVersionPresetRaw = newValue.rawValue }
    }

    public var controlBarStyle: ControlBarPositionStyle {
        ControlBarPositionStyle(rawValue: controlBarStyleRaw) ?? .float
    }

    public var activeServer: EmbyServerConfig? {
        if let openedServerId, let found = servers.first(where: { $0.id == openedServerId }) { return found }
        if let activeServerId, let found = servers.first(where: { $0.id == activeServerId }) { return found }
        return servers.first(where: \.isDefaultHome) ?? servers.first
    }

    public var cardAppearance: DonbyCardAppearance {
        DonbyCardAppearance(
            server: activeServer,
            isLightMode: isLightMode,
            accentColor: accentColor,
            accentTextColor: accentTextColor,
            showResolutionBadge: showResolutionBadge,
            showRatingBadge: showRatingBadge,
            isMonochromeTheme: isMonochromeTheme,
            downloadStatusIndex: downloadStatusIndex
        )
    }

    public var currentDetailItem: EmbyItem? { detailStack.last }

    public var allLoadedMediaItems: [EmbyItem] {
        var seen = Set<String>()
        var result: [EmbyItem] = []
        let sources = [carouselItems, resumeItems, nextUpItems, favoriteItems] + Array(latestByLibrary.values)
        for list in sources {
            for item in list where !seen.contains(item.id) {
                seen.insert(item.id)
                result.append(item)
            }
        }
        return result
    }

    private let serversStorageKey = "donby.servers.v2"
    private let urlMediaStorageKey = "donby.urlMedia.v3"
    private let iptvChannelsStorageKey = "donby.iptvChannels.v3"
    private let watchHistoryStorageKey = "donby.watchHistory.v3"
    private let cachedSeriesNamesStorageKey = "donby.cachedSeriesNames.v1"
    private let searchHistoryStorageKey = "donby.searchHistory.v1"
    @Published public var cachedSeriesNames: [String: String] = [:]

    // Persistent search state (survives navigating into DetailView and returning) & Search History
    @Published public var searchHistory: [String] = []
    @Published public var globalSearchQuery: String = ""
    @Published public var globalSearchFilterChip: String = "全部"
    @Published public var globalSearchRemoteResults: [EmbyItem] = []
    public var globalSearchLastServerId: UUID? = nil
    public var globalSearchLastFetchedQuery: String = ""

    @Published public var embyInlineSearchQuery: String = ""
    @Published public var embyInlineSearchResults: [EmbyItem] = []
    public var embyInlineSearchLastServerId: UUID? = nil
    public var embyInlineSearchLastFetchedQuery: String = ""
    @Published public var librarySearchQueryById: [String: String] = [:]

    public init() {
        AppState.sharedInstance = self
        self.isSidebarCollapsed = UserDefaults.standard.bool(forKey: "donby.defaultSidebarCollapsed")
        self.searchHistory = UserDefaults.standard.stringArray(forKey: searchHistoryStorageKey) ?? []
        isLoadingFromDisk = true
        loadServersFromDisk()
        loadURLMediaFromDisk()
        loadLocalFoldersFromDisk()
        loadCachedSeriesNamesFromDisk()
        loadIPTVChannelsFromDisk()
        loadWatchHistoryFromDisk()
        if let subData = UserDefaults.standard.data(forKey: "donby.subtitleStyle.v1"),
           let decodedStyle = try? jsonDecoder.decode(SubtitleStyleConfiguration.self, from: subData) {
            self.subtitleStyle = decodedStyle
        }
        if let skipData = UserDefaults.standard.data(forKey: "donby.seasonSkipPreferences.v1"),
           let decodedSkip = try? jsonDecoder.decode([String: SeasonSkipPreference].self, from: skipData) {
            self.seasonSkipPreferences = decodedSkip
        }
        if let subMemData = UserDefaults.standard.data(forKey: "donby.subtitleMemory.v1"),
           let decodedSubMem = try? jsonDecoder.decode([String: SeriesSubtitleMemory].self, from: subMemData) {
            self.subtitleMemoryByScope = decodedSubMem
        }
        if let globalSubData = UserDefaults.standard.data(forKey: "donby.globalPreferredSubtitle.v1"),
           let decodedGlobalSub = try? jsonDecoder.decode(SubtitleTrackPreference.self, from: globalSubData) {
            self.globalPreferredSubtitle = decodedGlobalSub
        }
        if let globalSecData = UserDefaults.standard.data(forKey: "donby.globalPreferredSecondarySubtitle.v1"),
           let decodedGlobalSec = try? jsonDecoder.decode(SubtitleTrackPreference.self, from: globalSecData) {
            self.globalPreferredSecondarySubtitle = decodedGlobalSec
        }
        isLoadingFromDisk = false

        DonbyOfflineLibraryStorage.ensureRootDirectories()
        let moviesDonbyPath = DonbyOfflineLibraryStorage.moviesDonbyRootURL.path
        if !UserDefaults.standard.bool(forKey: "donby.didAutoRegisterMoviesDonby.v1") {
            UserDefaults.standard.set(true, forKey: "donby.didAutoRegisterMoviesDonby.v1")
            if !localFolders.contains(where: { $0.path == moviesDonbyPath }) {
                localFolders.insert(
                    LocalMediaFolder(name: "Donby 离线影视库", path: moviesDonbyPath),
                    at: 0
                )
            }
        }
        self.downloadStatusIndex = DonbyDownloadManager.shared.statusIndex
        self.downloadStatusCancellable = DonbyDownloadManager.shared.$statusIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] nextIdx in
                self?.downloadStatusIndex = nextIdx
            }

        Task {
            let maxBytes = Int64(max(128, turboDiskCacheMB)) * 1024 * 1024
            DonbyTurboCacheEngine.shared.enforceDiskBudget(maxDiskBytes: maxBytes)
            await DonbyDownloadManager.shared.migrateLegacyCompletedDownloads(servers: self.servers)
        }

        DonbyTurboCacheEngine.shared.setOnAssetFullyCached { meta in
            Task { @MainActor in
                AppState.sharedInstance?.handleFullyCachedAssetNotification(meta)
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await AppUpdateManager.shared.checkForUpdatesIfAutoEnabled()
        }

        AppUpdateManager.shared.onBeforeTerminationForUpdate = { [weak self] in
            self?.prepareForTermination()
        }

        dk_set_log_callback { level, message in
            guard let message = message else { return }
            let msg = String(cString: message)
            DonbyLogger.shared.logFromKernel(level: level, message: msg)
        }
        DonbyLogger.shared.log("Donby App 初始化完成，日志系统已就绪", level: .info, subsystem: "App")

        if servers.isEmpty {
            let uhdDefault = DemoServerData.makeDefaultUHDServer()
            servers = [uhdDefault]
            activeServerId = uhdDefault.id
        } else if activeServerId == nil {
            activeServerId = (servers.first(where: \.isDefaultHome) ?? servers.first)?.id
        }

        // Apply default startup navigation preference
        switch defaultStartupModule {
        case "servers":
            selectedTab = .servers
            if !defaultStartupServerId.isEmpty, let target = servers.first(where: { $0.id.uuidString == defaultStartupServerId && !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                openedServerId = target.id
            } else if defaultStartupServerId.isEmpty {
                // Default to server selection overview when user chose "全部服务器列表"
                openedServerId = nil
            } else if let defaultHome = servers.first(where: { $0.isDefaultHome && !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                openedServerId = defaultHome.id
            } else {
                openedServerId = nil
            }
        case "files":
            selectedTab = .files
            openedServerId = nil
            if !defaultFilesFolderId.isEmpty, let folder = localFolders.first(where: { $0.id.uuidString == defaultFilesFolderId }) {
                browsingFolder = folder
            }
        case "iptv":
            selectedTab = .iptv
            openedServerId = nil
        case "records":
            selectedTab = .records
            openedServerId = nil
        default:
            selectedTab = .servers
            openedServerId = nil
        }

        if openedServerId != nil {
            Task { await loadActiveServerHome(syncDomains: true) }
        }
    }

    public func prepareForTermination() {
        flushWatchHistory()
        if activePlayback != nil {
            activePlayback = nil
        }
    }

    private func loadServersFromDisk() {
        if let savedIdStr = UserDefaults.standard.string(forKey: "donby.activeServerId"),
           let uuid = UUID(uuidString: savedIdStr) {
            self.activeServerId = uuid
        }
        guard let data = UserDefaults.standard.data(forKey: serversStorageKey),
              let decoded = try? jsonDecoder.decode([EmbyServerConfig].self, from: data) else {
            return
        }
        self.servers = decoded.filter { !$0.isDemoServer }
    }

    private func saveServersToDisk() {
        if let data = try? jsonEncoder.encode(servers) {
            UserDefaults.standard.set(data, forKey: serversStorageKey)
        }
    }

    private func loadURLMediaFromDisk() {
        if let data = UserDefaults.standard.data(forKey: urlMediaStorageKey),
           let decoded = try? jsonDecoder.decode([LocalOrURLMediaItem].self, from: data) {
            self.urlMediaItems = decoded
        } else {
            self.urlMediaItems = []
        }
    }

    private func saveURLMediaToDisk() {
        if let data = try? jsonEncoder.encode(urlMediaItems) {
            UserDefaults.standard.set(data, forKey: urlMediaStorageKey)
        }
    }

    private func loadLocalFoldersFromDisk() {
        if let data = UserDefaults.standard.data(forKey: localFoldersStorageKey),
           let decoded = try? jsonDecoder.decode([LocalMediaFolder].self, from: data) {
            self.localFolders = decoded
        } else {
            self.localFolders = []
        }
    }

    private func saveLocalFoldersToDisk() {
        if let data = try? jsonEncoder.encode(localFolders) {
            UserDefaults.standard.set(data, forKey: localFoldersStorageKey)
        }
    }

    private func loadIPTVChannelsFromDisk() {
        if let data = UserDefaults.standard.data(forKey: iptvChannelsStorageKey),
           let decoded = try? jsonDecoder.decode([IPTVChannelItem].self, from: data) {
            self.iptvChannels = decoded
        } else {
            self.iptvChannels = []
        }
    }

    private func saveIPTVChannelsToDisk() {
        if let data = try? jsonEncoder.encode(iptvChannels) {
            UserDefaults.standard.set(data, forKey: iptvChannelsStorageKey)
        }
    }

    private func loadWatchHistoryFromDisk() {
        if let data = UserDefaults.standard.data(forKey: watchHistoryStorageKey),
           let decoded = try? jsonDecoder.decode([WatchRecordItem].self, from: data) {
            var sanitizedMap: [String: WatchRecordItem] = [:]
            var order: [String] = []

            for var item in decoded {
                let isLocal = item.sourceType == "本地文件" ||
                              item.sourceType == "Local" ||
                              (item.streamURLString?.hasPrefix("/") == true) ||
                              (item.streamURLString?.hasPrefix("file://") == true) ||
                              (item.sourceType == "原画直链" && item.embyItemId == nil && (item.title.contains(".mkv") || item.title.contains(".mp4")))

                if isLocal {
                    item.sourceType = "本地文件"
                    item.embyItemId = nil
                    if let s = item.streamURLString, s.hasPrefix("file://") {
                        item.streamURLString = URL(string: s)?.path ?? s
                    }
                    let parsed = MediaTitleParser.parse(rawName: item.title)
                    if parsed.mainTitle != item.title {
                        item.title = parsed.mainTitle
                        item.subtitle = parsed.subTitle
                    }
                } else if item.sourceType == "原画直链" || item.embyItemId != nil {
                    item.sourceType = "Emby"
                    if item.title.hasPrefix("第") && (item.title.hasSuffix("集") || item.title.contains("集")),
                       let itemId = item.embyItemId, let sName = cachedSeriesNames[itemId], !sName.isEmpty {
                        let epSub = (item.subtitle != nil && !item.subtitle!.isEmpty) ? "\(item.subtitle!) · \(item.title)" : item.title
                        item.title = sName
                        item.subtitle = epSub
                    }
                }

                let dedupKey: String
                if item.sourceType == "本地文件" {
                    let normPath = item.streamURLString ?? item.title
                    dedupKey = "local:\(normPath)"
                } else if let embyId = item.embyItemId, !embyId.isEmpty {
                    dedupKey = "emby:\(embyId)"
                } else {
                    dedupKey = "url:\(item.streamURLString ?? item.title)"
                }
                item.id = dedupKey

                if let existing = sanitizedMap[dedupKey] {
                    var merged = existing
                    if item.positionSeconds > existing.positionSeconds {
                        merged.positionSeconds = item.positionSeconds
                    }
                    if item.lastWatchedAt > existing.lastWatchedAt {
                        merged.lastWatchedAt = item.lastWatchedAt
                    }
                    if merged.subtitle == nil || merged.subtitle?.isEmpty == true {
                        merged.subtitle = item.subtitle
                    }
                    sanitizedMap[dedupKey] = merged
                } else {
                    sanitizedMap[dedupKey] = item
                    order.append(dedupKey)
                }
            }
            self.watchHistory = Array(order.compactMap { sanitizedMap[$0] }.prefix(Self.maxWatchHistoryCount))
        } else {
            self.watchHistory = []
        }
    }

    private func saveWatchHistoryToDisk() {
        if let data = try? jsonEncoder.encode(watchHistory) {
            UserDefaults.standard.set(data, forKey: watchHistoryStorageKey)
        }
    }

    private func loadCachedSeriesNamesFromDisk() {
        if let dict = UserDefaults.standard.dictionary(forKey: cachedSeriesNamesStorageKey) as? [String: String] {
            self.cachedSeriesNames = dict
        } else {
            self.cachedSeriesNames = [:]
        }
    }

    private func saveCachedSeriesNamesToDisk() {
        UserDefaults.standard.set(cachedSeriesNames, forKey: cachedSeriesNamesStorageKey)
    }

    private func findLoadedSeriesName(for itemId: String) -> String? {
        let topLists = [carouselItems, resumeItems, nextUpItems, favoriteItems]
        for list in topLists {
            if let s = list.first(where: { $0.id == itemId })?.seriesName, !s.isEmpty {
                return s
            }
        }
        for list in latestByLibrary.values {
            if let s = list.first(where: { $0.id == itemId })?.seriesName, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    public func resolveSeriesName(for itemId: String) async -> String? {
        if let cached = cachedSeriesNames[itemId], !cached.isEmpty {
            return cached
        }
        if let found = findLoadedSeriesName(for: itemId) {
            cachedSeriesNames[itemId] = found
            saveCachedSeriesNamesToDisk()
            return found
        }
        if let existingTask = inFlightSeriesNameTasks[itemId] {
            return await existingTask.value
        }
        guard let server = activeServer, !server.host.isEmpty else { return nil }
        let task = Task<String?, Never> {
            guard let fetched = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId),
                  let s = fetched.seriesName, !s.isEmpty else {
                return nil
            }
            return s
        }
        inFlightSeriesNameTasks[itemId] = task
        let resolved = await task.value
        inFlightSeriesNameTasks.removeValue(forKey: itemId)
        if let resolved, !resolved.isEmpty {
            cachedSeriesNames[itemId] = resolved
            saveCachedSeriesNamesToDisk()
        }
        return resolved
    }

    public func updateRecordTitles(id: String, newTitle: String, newSubtitle: String?) {
        guard let idx = watchHistory.firstIndex(where: { $0.id == id }) else { return }
        watchHistory[idx].title = newTitle
        if let newSubtitle {
            watchHistory[idx].subtitle = newSubtitle
        }
        scheduleSaveWatchHistory(immediate: true)
    }

    public func formattedWatchRecordMetadata(
        for item: EmbyItem,
        resolvedSeriesName: String? = nil
    ) -> (title: String, subtitle: String?) {
        if item.isEpisode {
            let seriesName = [
                resolvedSeriesName,
                item.seriesName,
                cachedSeriesNames[item.id],
                item.seriesId.flatMap { cachedSeriesNames[$0] }
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

            let recTitle = seriesName ?? item.name
            var subParts: [String] = []
            if let code = item.episodeCodeString, !code.isEmpty {
                subParts.append(code)
            }
            if !item.name.isEmpty && !subParts.contains(item.name) && item.name != recTitle {
                subParts.append(item.name)
            }
            let recSubtitle = subParts.isEmpty ? item.resolutionBadge : subParts.joined(separator: " · ")
            return (recTitle, recSubtitle)
        }
        let recSubtitle = item.displaySubtitle.isEmpty ? item.resolutionBadge : item.displaySubtitle
        return (item.name, recSubtitle)
    }

    public func flushWatchHistory() {
        saveWatchHistoryTask?.cancel()
        saveWatchHistoryTask = nil
        saveWatchHistoryToDisk()
    }

    public func scheduleSaveWatchHistory(immediate: Bool = false) {
        if immediate {
            flushWatchHistory()
            return
        }
        if saveWatchHistoryTask != nil { return }
        saveWatchHistoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await MainActor.run {
                self.flushWatchHistory()
            }
        }
    }

    public func addRecentMedia(name: String, urlString: String, isLocal: Bool) {
        urlMediaItems.removeAll { $0.urlString == urlString }
        let newItem = LocalOrURLMediaItem(name: name, urlString: urlString, isLocalFile: isLocal, addedAt: Date())
        urlMediaItems.insert(newItem, at: 0)
        showToast("已加入播放列表: \(name)", icon: isLocal ? "film" : "link")
    }

    public func deleteRecentMedia(id: UUID) {
        urlMediaItems.removeAll { $0.id == id }
    }

    public func addIPTVChannel(name: String, group: String, urlString: String) {
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let newChannel = IPTVChannelItem(name: name, group: cleanGroup.isEmpty ? "自定义" : cleanGroup, urlString: urlString)
        iptvChannels.append(newChannel)
        showToast("已添加频道: \(name)", icon: "sparkles.tv")
    }

    public func deleteIPTVChannel(id: UUID) {
        iptvChannels.removeAll { $0.id == id }
    }

    public func importM3UContent(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        var existingURLs = Set(iptvChannels.map(\.urlString))
        var newChannels: [IPTVChannelItem] = []
        var currentName: String? = nil
        var currentGroup = "导入频道"

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                // Extract group-title
                if let groupRange = line.range(of: "group-title=\"") {
                    let sub = line[groupRange.upperBound...]
                    if let endQuote = sub.firstIndex(of: "\"") {
                        currentGroup = String(sub[..<endQuote])
                    }
                }
                // Extract channel name after comma
                if let commaIdx = line.lastIndex(of: ",") {
                    let nameSub = line[line.index(after: commaIdx)...].trimmingCharacters(in: .whitespaces)
                    if !nameSub.isEmpty { currentName = nameSub }
                }
            } else if !line.hasPrefix("#") {
                // This is stream URL
                let name = currentName ?? "未知频道 \(newChannels.count + 1)"
                if existingURLs.insert(line).inserted {
                    newChannels.append(IPTVChannelItem(name: name, group: currentGroup, urlString: line))
                }
                currentName = nil
            }
        }

        if !newChannels.isEmpty {
            iptvChannels.append(contentsOf: newChannels)
            showToast("成功导入 \(newChannels.count) 个 IPTV 频道", icon: "sparkles.tv")
        } else {
            showToast("未检测到有效 M3U 频道，请检查文件格式", icon: "exclamationmark.triangle", isError: true)
        }
    }

    public func recordWatch(
        title: String,
        subtitle: String? = nil,
        posterKey: String? = nil,
        posterURL: String? = nil,
        position: Double,
        duration: Double,
        sourceType: String = "Emby",
        streamURLString: String? = nil,
        embyItemId: String? = nil,
        resolutionTag: String? = "4K UHD"
    ) {
        guard duration > 0 || position > 0 else { return }

        let isLocal = (sourceType == "本地文件" || sourceType == "Local") ||
                      (streamURLString?.hasPrefix("/") == true) ||
                      (streamURLString?.hasPrefix("file://") == true)

        let normStreamPath: String? = {
            guard let s = streamURLString else { return nil }
            if s.hasPrefix("file://") { return URL(string: s)?.path ?? s }
            return s
        }()

        let cleanSourceType = isLocal ? "本地文件" : (sourceType == "原画直链" ? "Emby" : sourceType)
        let cleanEmbyId = isLocal ? nil : embyItemId

        let recId: String
        if isLocal {
            recId = "local:\(normStreamPath ?? title)"
        } else if let eId = cleanEmbyId, !eId.isEmpty {
            recId = "emby:\(eId)"
        } else {
            recId = "url:\(normStreamPath ?? title)"
        }

        let now = Date()
        if lastRecordedWatchItemId == recId,
           abs(position - lastRecordedWatchPosition) < 3.0,
           now.timeIntervalSince(lastRecordedWatchDate) < 4.0 {
            return
        }
        lastRecordedWatchItemId = recId
        lastRecordedWatchPosition = position
        lastRecordedWatchDate = now

        watchHistory.removeAll { existing in
            if existing.id == recId { return true }
            if isLocal {
                if let exStream = existing.streamURLString {
                    let exNorm = exStream.hasPrefix("file://") ? (URL(string: exStream)?.path ?? exStream) : exStream
                    return exNorm == normStreamPath
                }
                return existing.sourceType == "本地文件" && existing.title == title && existing.subtitle == subtitle
            } else if let eId = cleanEmbyId {
                if existing.embyItemId == eId { return true }
            } else if let normStreamPath, !normStreamPath.isEmpty, let exStream = existing.streamURLString {
                if exStream == normStreamPath { return true }
            }
            return false
        }

        let record = WatchRecordItem(
            id: recId,
            title: title,
            subtitle: subtitle,
            posterKey: posterKey,
            posterURL: posterURL,
            positionSeconds: position,
            durationSeconds: duration,
            lastWatchedAt: now,
            sourceType: cleanSourceType,
            streamURLString: normStreamPath,
            embyItemId: cleanEmbyId,
            resolutionTag: resolutionTag
        )
        watchHistory.insert(record, at: 0)
        if watchHistory.count > Self.maxWatchHistoryCount {
            watchHistory.removeLast(watchHistory.count - Self.maxWatchHistoryCount)
        }
        scheduleSaveWatchHistory(immediate: false)
        let thumbKey = "record_thumb_\(recId)_\(posterURL ?? "")"
        if ArtworkImageCache.shared.imageFromMemory(for: thumbKey) == nil {
            if let posterURL, !posterURL.isEmpty {
                ArtworkImageCache.shared.aliasKeys([thumbKey], to: posterURL)
            } else if let embyItemId, !embyItemId.isEmpty {
                ArtworkImageCache.shared.aliasKeys([thumbKey], to: "item_\(embyItemId)_primary")
            }
        }
    }

    public func clearWatchHistory() {
        watchHistory.removeAll()
        flushWatchHistory()
        showToast("已清空全部观看记录", icon: "trash.fill")
    }

    public func deleteWatchRecord(id: String) {
        watchHistory.removeAll { $0.id == id }
        scheduleSaveWatchHistory(immediate: true)
    }

    public func resumePlaybackFromRecord(_ record: WatchRecordItem) {
        if let itemId = record.embyItemId, let server = activeServer, !server.host.isEmpty {
            if let cached = allLoadedMediaItems.first(where: { $0.id == itemId }) {
                var resumingItem = cached
                var uData = resumingItem.userData ?? EmbyUserData()
                uData.playbackPositionTicks = Int64(record.positionSeconds * 10_000_000.0)
                resumingItem.userData = uData
                Task { await startPlayback(item: resumingItem) }
                return
            }
            Task {
                let fetchedItem: EmbyItem? = if server.type == .uhdNative {
                    try? await UHDStreamClient.shared.fetchItemDetail(server: server, item: EmbyItem(id: itemId, name: record.title, type: "Movie"))
                } else {
                    try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId)
                }
                if var fetched = fetchedItem {
                    var uData = fetched.userData ?? EmbyUserData()
                    uData.playbackPositionTicks = Int64(record.positionSeconds * 10_000_000.0)
                    fetched.userData = uData
                    await startPlayback(item: fetched)
                } else if let urlStr = record.streamURLString {
                    let url = Self.resolveMediaURL(from: urlStr)
                    playDirectURL(url: url, title: record.title, startSeconds: record.positionSeconds)
                }
            }
            return
        }
        if let urlStr = record.streamURLString {
            let url = Self.resolveMediaURL(from: urlStr)
            playDirectURL(url: url, title: record.title, startSeconds: record.positionSeconds)
            return
        }
    }

    public func playFromBeginning(_ record: WatchRecordItem) {
        if let itemId = record.embyItemId, let server = activeServer, !server.host.isEmpty {
            if let cached = allLoadedMediaItems.first(where: { $0.id == itemId }) {
                Task { await startPlayback(item: cached, fromBeginning: true) }
                return
            }
            Task {
                let fetchedItem: EmbyItem? = if server.type == .uhdNative {
                    try? await UHDStreamClient.shared.fetchItemDetail(server: server, item: EmbyItem(id: itemId, name: record.title, type: "Movie"))
                } else {
                    try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId)
                }
                if let fetched = fetchedItem {
                    await startPlayback(item: fetched, fromBeginning: true)
                } else if let urlStr = record.streamURLString {
                    let url = Self.resolveMediaURL(from: urlStr)
                    playDirectURL(url: url, title: record.title, startSeconds: 0)
                }
            }
            return
        }
        if let urlStr = record.streamURLString {
            let url = Self.resolveMediaURL(from: urlStr)
            playDirectURL(url: url, title: record.title, startSeconds: 0)
            return
        }
    }

    public static func resolveMediaURL(from string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://") {
            let withoutScheme = String(trimmed.dropFirst(7))
            let path = withoutScheme.removingPercentEncoding ?? withoutScheme
            return URL(fileURLWithPath: path)
        } else if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        } else if let parsed = URL(string: trimmed), parsed.scheme != nil {
            return parsed
        } else {
            return URL(fileURLWithPath: trimmed)
        }
    }

    public func showToast(_ text: String, icon: String = "checkmark.circle.fill", isError: Bool = false) {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            toastMessage = ToastMessage(icon: icon, text: text, isError: isError)
        }
        let currentId = toastMessage?.id
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toastMessage?.id == currentId {
                withAnimation(.easeOut(duration: 0.22)) { toastMessage = nil }
            }
        }
    }

    public func cancelPendingPlaybackStart() {
        guard isStartingPlayback else { return }
        playbackStartGeneration &+= 1
        pendingPlaybackKey = nil
        isStartingPlayback = false
    }

    public func recordSearchHistory(_ rawQuery: String) {
        let cleaned = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        searchHistory.removeAll { $0.compare(cleaned, options: .caseInsensitive) == .orderedSame }
        searchHistory.insert(cleaned, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: searchHistoryStorageKey)
    }

    public func removeSearchHistoryItem(_ term: String) {
        searchHistory.removeAll { $0 == term }
        UserDefaults.standard.set(searchHistory, forKey: searchHistoryStorageKey)
    }

    public func clearSearchHistory() {
        searchHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: searchHistoryStorageKey)
    }

    public func openServer(_ server: EmbyServerConfig) {
        cancelPendingPlaybackStart()
        let isSwitchingServer = (openedServerId != server.id)
        activeServerId = server.id
        openedServerId = server.id
        selectedLibrary = nil
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()
        homeErrorMessage = nil
        inFlightSeriesNameTasks.removeAll()
        if isSwitchingServer {
            embyInlineSearchQuery = ""
            embyInlineSearchResults = []
            embyInlineSearchLastServerId = nil
            embyInlineSearchLastFetchedQuery = ""
            librarySearchQueryById.removeAll()
        }

        // Instantaneous switch from memory/disk snapshot
        if let snap = ServerHomeCacheStore.shared.snapshot(for: server.id), !snap.libraryViews.isEmpty {
            self.libraryViews = snap.libraryViews
            self.resumeItems = snap.resumeItems
            self.nextUpItems = snap.nextUpItems
            self.favoriteItems = snap.favoriteItems
            self.latestByLibrary = snap.latestByLibrary
            self.carouselItems = snap.carouselItems
            self.isLoadingHome = false
        } else {
            self.libraryViews = []
            self.resumeItems = []
            self.nextUpItems = []
            self.favoriteItems = []
            self.latestByLibrary = [:]
            self.carouselItems = []
            self.isLoadingHome = !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        Task { await loadActiveServerHome(syncDomains: true) }
    }

    public func selectSidebarModule(_ tab: MainNavigationTab) {
        cancelPendingPlaybackStart()
        openedServerId = nil
        selectedLibrary = nil
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()
        selectedTab = tab

        if tab == .files {
            if !defaultFilesFolderId.isEmpty, let folder = localFolders.first(where: { $0.id.uuidString == defaultFilesFolderId }) {
                browsingFolder = folder
            } else {
                browsingFolder = nil
            }
        }
    }

    public func addLocalFolder(url: URL) {
        let path = url.path
        if localFolders.contains(where: { $0.path == path }) {
            showToast("该文件夹已在列表中", icon: "folder")
            return
        }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = url.lastPathComponent
        let isFirst = localFolders.isEmpty
        let folder = LocalMediaFolder(name: name, path: path, bookmarkData: bookmark, isPresetDefault: isFirst)
        localFolders.append(folder)
        if isFirst && defaultFilesFolderId.isEmpty {
            defaultFilesFolderId = folder.id.uuidString
        }
        showToast("已添加本地文件夹: \(name)", icon: "folder.badge.plus")
    }

    public func removeLocalFolder(id: UUID) {
        if browsingFolder?.id == id {
            browsingFolder = nil
        }
        if defaultFilesFolderId == id.uuidString {
            defaultFilesFolderId = ""
        }
        localFolders.removeAll { $0.id == id }
        showToast("已移除该文件夹", icon: "trash")
    }

    public func setPresetDefaultFolder(id: UUID) {
        if defaultFilesFolderId == id.uuidString {
            defaultFilesFolderId = ""
            for i in 0..<localFolders.count {
                localFolders[i].isPresetDefault = false
            }
            showToast("已取消默认打开文件夹", icon: "folder")
        } else {
            defaultFilesFolderId = id.uuidString
            for i in 0..<localFolders.count {
                localFolders[i].isPresetDefault = (localFolders[i].id == id)
            }
            showToast("已设为默认打开文件夹", icon: "star.fill")
        }
    }

    nonisolated private static let supportedVideoExtensions: Set<String> = ["mp4", "mkv", "mov", "webm", "avi", "m4v", "flv", "ts", "m2ts", "wmv", "iso", "rmvb"]

    nonisolated public static func countFolderVideos(path: String) -> Int {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var count = 0
        for case let fileURL as URL in enumerator where supportedVideoExtensions.contains(fileURL.pathExtension.lowercased()) {
            count += 1
        }
        return count
    }

    nonisolated public static func scanFolderHierarchy(path: String) -> (subfolders: [LocalMediaFolder], videos: [LocalVideoFileInfo]) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }
        var folders: [LocalMediaFolder] = []
        var videos: [LocalVideoFileInfo] = []
        for entryURL in items {
            let res = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if res?.isDirectory == true {
                folders.append(LocalMediaFolder(name: entryURL.lastPathComponent, path: entryURL.path))
                continue
            }
            let ext = entryURL.pathExtension.lowercased()
            if supportedVideoExtensions.contains(ext) {
                let size = Int64(res?.fileSize ?? 0)
                let date = res?.contentModificationDate ?? Date()
                videos.append(LocalVideoFileInfo(name: entryURL.lastPathComponent, path: entryURL.path, fileSizeBytes: size, fileExtension: ext.uppercased(), modifiedDate: date))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        videos.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (folders, videos)
    }

    nonisolated public static func scanFolderVideos(path: String) -> [LocalVideoFileInfo] {
        scanFolderHierarchy(path: path).videos
    }

    public func updateServerInList(_ updated: EmbyServerConfig) {
        if let idx = servers.firstIndex(where: { $0.id == updated.id }) {
            servers[idx] = updated
        } else {
            servers.append(updated)
        }
    }

    public func deleteServer(_ server: EmbyServerConfig) {
        servers.removeAll { $0.id == server.id }
        if servers.isEmpty {
            let emptySlot = DemoServerData.makeDefaultUHDServer()
            servers = [emptySlot]
            activeServerId = emptySlot.id
        }
        if openedServerId == server.id { openedServerId = nil }
        if activeServerId == server.id { activeServerId = servers.first?.id }
        showToast("已删除服务器 \(server.name)", icon: "trash.fill")
    }

    public func importServerFromClipboard(into existingSlot: EmbyServerConfig? = nil) {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let parsed = ServerTextParser.parseClipboardText(raw) else {
            showToast("剪贴板中未识别到服务器地址", icon: "exclamationmark.circle.fill", isError: true)
            return
        }
        let targetSlot = existingSlot ?? servers.first(where: { $0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        var draft = targetSlot ?? EmbyServerConfig(name: "UHDNow", host: "", port: 443, isHttps: true, username: "", iconURL: "uhd")
        draft.apply(parsed: parsed, overwriteName: true)
        editingServer = draft
        showAddServerSheet = true
        showToast("已识别服务器「\(draft.name)」", icon: "wand.and.stars")
    }

    public func setDefaultHomeServer(_ server: EmbyServerConfig) {
        let wasDefault = server.isDefaultHome
        for i in servers.indices {
            servers[i].isDefaultHome = wasDefault ? false : (servers[i].id == server.id)
        }
        showToast(wasDefault ? "已取消默认首页" : "已设为默认首页", icon: "house.fill")
    }

    public func connectAndSaveServer(_ draft: EmbyServerConfig) async throws {
        var server = draft
        server.isDemoServer = false
        if server.note == "待配置服务器地址与账号" {
            server.note = ""
        }

        let hasToken = !server.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !server.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if server.type == .uhdNative {
            if hasUsername && hasPassword {
                let auth = try await UHDStreamClient.shared.login(
                    baseURL: server.activeBaseURL,
                    username: server.username,
                    password: server.password
                )
                server.accessToken = auth.token
                if server.userId.isEmpty { server.userId = server.username }
                if server.serverId.isEmpty { server.serverId = server.host }
                if server.name.isEmpty { server.name = "UHDNow · \(server.username)" }
                server.serverName = "UHDNow Streaming API"
            }
            if !server.accessToken.isEmpty {
                if let cap = try? await UHDStreamClient.shared.fetchSubscription(server: server) {
                    serverCapabilities[server.id] = cap
                }
                if autoSyncDomains,
                   let uhdLines = try? await UHDStreamClient.shared.fetchPlaybackDomains(server: server) {
                    let manual = server.backupLines.filter { !$0.isAutoSynced }
                    server.backupLines = manual + uhdLines
                    server.lastExtDomainSyncDate = Date()
                    if server.selectedLineId == nil, let first = uhdLines.first {
                        server.selectedLineId = first.id
                    }
                }
            }
        } else {
            if hasUsername && hasPassword {
                let auth = try await EmbyClient.shared.authenticate(
                    baseURL: server.activeBaseURL,
                    username: server.username,
                    password: server.password
                )
                server.accessToken = auth.accessToken ?? server.accessToken
                if let uid = auth.user?.id, !uid.isEmpty { server.userId = uid }
                if let sId = auth.serverId ?? auth.user?.serverId, !sId.isEmpty { server.serverId = sId }
            } else if hasToken {
                let users = await EmbyClient.shared.fetchUsersWithToken(
                    baseURL: server.activeBaseURL,
                    token: server.accessToken
                )
                if let matched = users.first(where: { !server.username.isEmpty && $0.name.lowercased() == server.username.lowercased() }) ?? users.first {
                    server.userId = matched.id
                    if server.username.isEmpty { server.username = matched.name }
                    if let sId = matched.serverId, !sId.isEmpty { server.serverId = sId }
                }
            } else if hasUsername && !hasPassword {
                if let auth = try? await EmbyClient.shared.authenticate(baseURL: server.activeBaseURL, username: server.username, password: "") {
                    server.accessToken = auth.accessToken ?? ""
                    if let uid = auth.user?.id { server.userId = uid }
                    if let sId = auth.serverId ?? auth.user?.serverId { server.serverId = sId }
                }
            }

            if let sysInfo = try? await EmbyClient.shared.fetchSystemInfo(server: server) {
                server.serverName = sysInfo.serverName ?? server.name
                server.serverVersion = sysInfo.version ?? ""
                if let sId = sysInfo.id, !sId.isEmpty && server.serverId.isEmpty { server.serverId = sId }
                if server.name.isEmpty { server.name = sysInfo.serverName ?? server.host }
            }
            if autoSyncDomains,
               let domains = await EmbyClient.shared.fetchExtServerDomains(
                baseURL: server.activeBaseURL,
                token: server.accessToken,
                userId: server.userId
               ) {
                server.mergeExtDomains(domains)
            }
        }

        server.lastWatchedDate = Date()
        updateServerInList(server)
        activeServerId = server.id
        openedServerId = server.id
        selectedLibrary = nil
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()

        let syncedCount = server.autoSyncedLineCount
        if syncedCount > 0 {
            showToast("登录成功，已自动同步 \(syncedCount) 条云端线路", icon: "icloud.and.arrow.down.fill")
        } else {
            showToast("登录成功：\(server.name)", icon: "checkmark.circle.fill")
        }

        await loadActiveServerHome(syncDomains: false)
    }

    public func syncExtDomains(for serverId: UUID, showFeedback: Bool = false) async {
        guard let idx = servers.firstIndex(where: { $0.id == serverId }) else { return }
        var server = servers[idx]
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if showFeedback { showToast("请先填写服务器地址与账号", icon: "exclamationmark.triangle.fill", isError: true) }
            return
        }
        activeSyncDomainsCount += 1
        isSyncingDomains = true
        defer {
            activeSyncDomainsCount = max(0, activeSyncDomainsCount - 1)
            isSyncingDomains = activeSyncDomainsCount > 0
        }

        if server.type == .uhdNative {
            if server.accessToken.isEmpty && !server.username.isEmpty && !server.password.isEmpty {
                if let auth = try? await UHDStreamClient.shared.login(baseURL: server.activeBaseURL, username: server.username, password: server.password) {
                    server.accessToken = auth.token
                    if let currentIdx = servers.firstIndex(where: { $0.id == serverId }) {
                        servers[currentIdx].accessToken = auth.token
                    }
                }
            }
            guard !server.accessToken.isEmpty else {
                if showFeedback { showToast("请先登录 UHD 服务器后再同步线路", icon: "exclamationmark.triangle.fill", isError: true) }
                return
            }
            if let uhdLines = try? await UHDStreamClient.shared.fetchPlaybackDomains(server: server) {
                if let currentIdx = servers.firstIndex(where: { $0.id == serverId }) {
                    let manual = servers[currentIdx].backupLines.filter { !$0.isAutoSynced }
                    servers[currentIdx].backupLines = manual + uhdLines
                    servers[currentIdx].lastExtDomainSyncDate = Date()
                    if servers[currentIdx].selectedLineId == nil, let first = uhdLines.first {
                        servers[currentIdx].selectedLineId = first.id
                    }
                }
                if showFeedback { showToast("已同步 \(uhdLines.count) 条 UHD 原生线路", icon: "icloud.and.arrow.down.fill") }
                await pingAllLines(for: serverId)
            } else if showFeedback {
                showToast("获取 UHD 线路列表失败", icon: "exclamationmark.triangle.fill", isError: true)
            }
            return
        }

        if server.accessToken.isEmpty && !server.username.isEmpty && !server.password.isEmpty {
            if let auth = try? await EmbyClient.shared.authenticate(baseURL: server.activeBaseURL, username: server.username, password: server.password) {
                server.accessToken = auth.accessToken ?? ""
                if let uid = auth.user?.id { server.userId = uid }
                if let currentIdx = servers.firstIndex(where: { $0.id == serverId }) {
                    servers[currentIdx].accessToken = server.accessToken
                    if !server.userId.isEmpty { servers[currentIdx].userId = server.userId }
                }
            }
        }

        guard !server.accessToken.isEmpty else {
            if showFeedback { showToast("请先登录服务器后再同步线路", icon: "exclamationmark.triangle.fill", isError: true) }
            return
        }

        if let domains = await EmbyClient.shared.fetchExtServerDomains(
            baseURL: server.activeBaseURL,
            token: server.accessToken,
            userId: server.userId
        ) {
            if let currentIdx = servers.firstIndex(where: { $0.id == serverId }) {
                servers[currentIdx].mergeExtDomains(domains)
            }
            if showFeedback { showToast("已同步 \(domains.count) 条 UHD 云端线路", icon: "icloud.and.arrow.down.fill") }
            await pingAllLines(for: serverId)
        } else if showFeedback {
            showToast("当前服务端未部署 ServerDomains 扩展，保持现有线路", icon: "info.circle.fill")
        }
    }

    public func switchLine(to lineId: UUID?, for serverId: UUID) async {
        switchLineImmediate(to: lineId, for: serverId, triggerReload: false)
        if activeServer?.id == serverId {
            await loadActiveServerHome(syncDomains: false)
        }
    }

    public func switchLineImmediate(to lineId: UUID?, for serverId: UUID, triggerReload: Bool = true) {
        guard let idx = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[idx].selectedLineId = lineId
        Task { await UHDStreamClient.shared.invalidateResolvedDomainCache(serverId: serverId) }
        let newLineName = servers[idx].activeLineName
        showToast("已切换至线路：\(newLineName)", icon: "checkmark.circle.fill")

        if triggerReload, activeServer?.id == serverId {
            Task { await loadActiveServerHome(syncDomains: false) }
        }
    }

    public func pingAllLines(for serverId: UUID) async {
        guard let idx = servers.firstIndex(where: { $0.id == serverId }) else { return }
        let server = servers[idx]
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        activePingLinesCount += 1
        isPingingLines = true
        defer {
            activePingLinesCount = max(0, activePingLinesCount - 1)
            isPingingLines = activePingLinesCount > 0
        }

        let mainURL = server.mainLineURL
        let token = server.accessToken
        let backupSnapshot = server.backupLines
        let pingTimeout = TimeInterval(max(1, pingTimeoutSeconds))

        if server.type == .uhdNative {
            async let mainPing = UHDStreamClient.shared.pingLine(server: server, line: nil)
            var linePings: [UUID: Int?] = [:]
            await withTaskGroup(of: (UUID, Int?).self) { group in
                for line in backupSnapshot {
                    group.addTask {
                        let ms = await UHDStreamClient.shared.pingLine(server: server, line: line)
                        return (line.id, ms)
                    }
                }
                for await (id, ms) in group { linePings[id] = ms }
            }
            let resolvedMainPing = await mainPing
            guard let currentIdx = servers.firstIndex(where: { $0.id == serverId }) else { return }
            servers[currentIdx].mainLineLatencyMs = resolvedMainPing
            for i in servers[currentIdx].backupLines.indices {
                let lineId = servers[currentIdx].backupLines[i].id
                if let pingVal = linePings[lineId] {
                    servers[currentIdx].backupLines[i].latencyMs = pingVal
                    servers[currentIdx].backupLines[i].lastCheckedAt = Date()
                }
            }
            return
        }

        async let mainPing = EmbyClient.shared.pingLine(baseURL: mainURL, token: token, timeout: pingTimeout)
        var linePings: [UUID: Int?] = [:]
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for line in backupSnapshot {
                group.addTask {
                    let ms = await EmbyClient.shared.pingLine(baseURL: line.url, token: token, timeout: pingTimeout)
                    return (line.id, ms)
                }
            }
            for await (id, ms) in group { linePings[id] = ms }
        }

        let resolvedMainPing = await mainPing
        guard let currentIdx = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[currentIdx].mainLineLatencyMs = resolvedMainPing
        for i in servers[currentIdx].backupLines.indices {
            let lineId = servers[currentIdx].backupLines[i].id
            if let pingVal = linePings[lineId] {
                servers[currentIdx].backupLines[i].latencyMs = pingVal
                servers[currentIdx].backupLines[i].lastCheckedAt = Date()
            }
        }
    }

    public func selectFastestLine(for serverId: UUID) async {
        await pingAllLines(for: serverId)
        guard let server = servers.first(where: { $0.id == serverId }) else { return }

        var bestLineId: UUID? = nil
        var bestMs: Int = server.mainLineLatencyMs ?? Int.max

        for line in server.backupLines {
            if let ms = line.latencyMs, ms < bestMs {
                bestMs = ms
                bestLineId = line.id
            }
        }

        if bestMs < Int.max {
            switchLineImmediate(to: bestLineId, for: serverId, triggerReload: true)
        } else {
            showToast("暂未测出有效延迟，请检查网络", icon: "wifi.exclamationmark", isError: true)
        }
    }

    public func loadActiveServerHome(syncDomains: Bool = false) async {
        guard let server = activeServer else { return }
        homeLoadGeneration &+= 1
        let currentGen = homeLoadGeneration

        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.libraryViews = []
            self.carouselItems = []
            self.resumeItems = []
            self.nextUpItems = []
            self.latestByLibrary = [:]
            self.favoriteItems = []
            self.homeErrorMessage = nil
            self.isLoadingHome = false
            return
        }

        if self.libraryViews.isEmpty {
            isLoadingHome = true
        }
        homeErrorMessage = nil

        if syncDomains && autoSyncDomains {
            Task { await syncExtDomains(for: server.id, showFeedback: false) }
        }
        Task { await refreshServerCapabilities(for: server) }
        Task.detached(priority: .utility) { DKMetalLayerView.prewarmPipelines() }
        if server.type == .uhdNative {
            Task { await UHDStreamClient.shared.prewarmPlaybackDomain(server: server) }
        } else {
            Task { await EmbyClient.shared.prewarmConnection(server: server) }
        }

        if server.type == .uhdNative {
            do {
                async let collectionsTask = UHDStreamClient.shared.fetchCollections(server: server)
                async let statesTask = UHDStreamClient.shared.fetchPlaybackStates(server: server, limit: 16)
                async let favTask = UHDStreamClient.shared.fetchFavorites(server: server, limit: 24)
                async let hotTask = UHDStreamClient.shared.fetchHot(server: server, limit: 12)

                let views = try await collectionsTask
                guard currentGen == homeLoadGeneration else { return }
                if self.libraryViews != views { self.libraryViews = views }

                let states = (try? await statesTask) ?? (resume: [], nextUp: [])
                let favs = (try? await favTask)?.items ?? []
                let hotItems = (try? await hotTask) ?? []

                guard currentGen == homeLoadGeneration else { return }
                if self.resumeItems != states.resume { self.resumeItems = states.resume }
                if self.nextUpItems != states.nextUp { self.nextUpItems = states.nextUp }
                if self.favoriteItems != favs { self.favoriteItems = favs }

                // Silently prewarm top continue-watching / next-up asset metadata so clicking from Home resolves in 0ms
                let homePrewarmTargets = Array((states.resume + states.nextUp).filter { !$0.isSeries }.prefix(3))
                if !homePrewarmTargets.isEmpty {
                    Task.detached(priority: .utility) {
                        for target in homePrewarmTargets {
                            _ = try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: target)
                        }
                    }
                }

                var latestMap: [String: [EmbyItem]] = [:]
                var heroCandidates: [EmbyItem] = hotItems
                let hadCachedLatest = !self.latestByLibrary.isEmpty

                await withTaskGroup(of: (String, [EmbyItem]).self) { group in
                    for view in views {
                        group.addTask { [hideWatchedInLatest] in
                            let fetched = (try? await UHDStreamClient.shared.fetchCollectionItems(
                                server: server,
                                collectionId: view.id,
                                mediaType: nil,
                                sortBy: "asset_updated_at",
                                sortOrder: "desc",
                                limit: 16
                            ).items) ?? []
                            let filtered = hideWatchedInLatest ? fetched.filter { $0.userData?.played != true } : fetched
                            return (view.id, filtered)
                        }
                    }
                    for await (viewId, items) in group {
                        guard currentGen == self.homeLoadGeneration else { return }
                        latestMap[viewId] = items
                        if !hadCachedLatest && self.latestByLibrary[viewId] != items {
                            self.latestByLibrary[viewId] = items
                        }
                        for item in items.prefix(3) where !heroCandidates.contains(where: { $0.id == item.id }) {
                            heroCandidates.append(item)
                        }
                    }
                }

                guard currentGen == homeLoadGeneration else { return }
                if self.latestByLibrary != latestMap { self.latestByLibrary = latestMap }
                let nextCarousel = Array((heroCandidates.isEmpty ? states.resume : heroCandidates).prefix(8))
                if self.carouselItems != nextCarousel { self.carouselItems = nextCarousel }

                let snapshot = ServerHomeCacheStore.ServerHomeSnapshot(
                    libraryViews: views,
                    resumeItems: states.resume,
                    nextUpItems: states.nextUp,
                    favoriteItems: favs,
                    latestByLibrary: latestMap,
                    carouselItems: self.carouselItems,
                    cachedAt: Date()
                )
                ServerHomeCacheStore.shared.save(snapshot, for: server.id)
                self.isLoadingHome = false
            } catch {
                guard currentGen == homeLoadGeneration else { return }
                self.homeErrorMessage = error.localizedDescription
                self.isLoadingHome = false
            }
            return
        }

        // Update library item counts in background so large servers (400k+ episodes) never block homepage UI
        Task {
            if let counts = try? await EmbyClient.shared.fetchCounts(server: server),
               let idx = self.servers.firstIndex(where: { $0.id == server.id }) {
                let newMovies = counts.movieCount ?? self.servers[idx].movieCount
                let newEpisodes = counts.episodeCount ?? counts.seriesCount ?? self.servers[idx].episodeCount
                if self.servers[idx].movieCount != newMovies || self.servers[idx].episodeCount != newEpisodes {
                    self.servers[idx].movieCount = newMovies
                    self.servers[idx].episodeCount = newEpisodes
                }
            }
        }

        do {
            async let viewsTask = EmbyClient.shared.fetchViews(server: server)
            async let resumeTask = EmbyClient.shared.fetchResumeItems(server: server, limit: 16)
            async let nextUpTask = EmbyClient.shared.fetchNextUp(server: server, limit: 16)
            async let favTask = EmbyClient.shared.fetchItems(server: server, isFavorite: true, limit: 24)

            let views = try await viewsTask
            guard currentGen == homeLoadGeneration else { return }
            if self.libraryViews != views {
                self.libraryViews = views
            }

            let resumes = (try? await resumeTask) ?? []
            let nextUps = (try? await nextUpTask) ?? []
            let favs = (try? await favTask)?.items ?? []

            guard currentGen == homeLoadGeneration else { return }
            if self.resumeItems != resumes { self.resumeItems = resumes }
            if self.nextUpItems != nextUps { self.nextUpItems = nextUps }
            if self.favoriteItems != favs { self.favoriteItems = favs }

            // Silently prewarm top continue-watching / next-up PlaybackInfo so clicking from Home resolves in 0ms
            let embyPrewarmTargets = Array((resumes + nextUps).filter { !$0.isSeries }.prefix(3))
            if !embyPrewarmTargets.isEmpty {
                Task.detached(priority: .utility) {
                    for target in embyPrewarmTargets {
                        await EmbyClient.shared.prewarmPlaybackInfo(server: server, itemId: target.id)
                    }
                }
            }

            var latestMap: [String: [EmbyItem]] = [:]
            var heroCandidates: [EmbyItem] = []
            let hadCachedLatest = !self.latestByLibrary.isEmpty

            await withTaskGroup(of: (String, [EmbyItem]).self) { group in
                for view in views {
                    group.addTask { [hideWatchedInLatest] in
                        let items = (try? await EmbyClient.shared.fetchLatestItems(
                            server: server,
                            parentId: view.id,
                            limit: 16,
                            hidePlayed: hideWatchedInLatest
                        )) ?? []
                        return (view.id, items)
                    }
                }
                for await (viewId, items) in group {
                    guard currentGen == self.homeLoadGeneration else { return }
                    latestMap[viewId] = items
                    if !hadCachedLatest && self.latestByLibrary[viewId] != items {
                        self.latestByLibrary[viewId] = items
                    }
                    for item in items.prefix(3) where !heroCandidates.contains(where: { $0.id == item.id }) {
                        heroCandidates.append(item)
                    }
                }
            }

            guard currentGen == homeLoadGeneration else { return }
            if self.latestByLibrary != latestMap {
                self.latestByLibrary = latestMap
            }
            let nextCarousel = Array((heroCandidates.isEmpty ? resumes : heroCandidates).prefix(8))
            if self.carouselItems != nextCarousel {
                self.carouselItems = nextCarousel
            }

            let snapshot = ServerHomeCacheStore.ServerHomeSnapshot(
                libraryViews: views,
                resumeItems: resumes,
                nextUpItems: nextUps,
                favoriteItems: favs,
                latestByLibrary: latestMap,
                carouselItems: self.carouselItems,
                cachedAt: Date()
            )
            ServerHomeCacheStore.shared.save(snapshot, for: server.id)
            self.isLoadingHome = false
        } catch {
            guard currentGen == homeLoadGeneration else { return }
            self.homeErrorMessage = error.localizedDescription
            self.isLoadingHome = false
        }
    }

    public static func detailSeriesKey(for item: EmbyItem) -> String {
        item.isSeries ? item.id : (item.seriesId ?? item.id)
    }

    public func rememberDetailFocusedEpisode(seriesKey: String, seasonNumber: Int?, episodeId: String) {
        guard !seriesKey.isEmpty, !episodeId.isEmpty else { return }
        detailFocusedEpisodeMemory[seriesKey] = (seasonNumber: seasonNumber, episodeId: episodeId)
    }

    public func detailFocusedEpisode(forSeriesKey seriesKey: String) -> (seasonNumber: Int?, episodeId: String)? {
        detailFocusedEpisodeMemory[seriesKey]
    }

    public func updateDetailFocusedEpisodeIfActive(forItem item: EmbyItem) {
        let key = Self.detailSeriesKey(for: item)
        let hasActiveSeriesDetail = detailStack.contains { Self.detailSeriesKey(for: $0) == key }
        guard hasActiveSeriesDetail, item.isEpisode else { return }
        detailFocusedEpisodeMemory[key] = (seasonNumber: item.parentIndexNumber, episodeId: item.id)
    }

    public func openDetail(for item: EmbyItem, preferOfflineFocus: Bool = false) {
        cancelPendingPlaybackStart()
        if preferOfflineFocus {
            detailOfflineFocusIds.insert(item.id)
        } else {
            detailOfflineFocusIds.remove(item.id)
        }
        if let last = detailStack.last, last.id == item.id { return }
        let key = Self.detailSeriesKey(for: item)
        if item.isEpisode {
            detailFocusedEpisodeMemory[key] = (seasonNumber: item.parentIndexNumber, episodeId: item.id)
        } else {
            detailFocusedEpisodeMemory.removeValue(forKey: key)
        }
        detailStack.append(item)
    }

    public func popDetail() {
        cancelPendingPlaybackStart()
        if let popped = detailStack.popLast() {
            detailOfflineFocusIds.remove(popped.id)
            detailFocusedEpisodeMemory.removeValue(forKey: Self.detailSeriesKey(for: popped))
        }
    }

    public func popToRootDetail() {
        cancelPendingPlaybackStart()
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()
    }

    public func isItemWatchedOfflineOrLocal(_ item: EmbyItem, localVideoPath: String? = nil) -> Bool {
        if item.userData?.played == true { return true }
        if item.progressFraction >= 0.90 { return true }

        let matchingEntry = DonbyDownloadManager.shared.entry(forItemId: item.id)
        if let dlSnapshot = matchingEntry?.itemSnapshot {
            if dlSnapshot.userData?.played == true || dlSnapshot.progressFraction >= 0.90 {
                return true
            }
        }

        let resolvedLocalPath = localVideoPath ?? matchingEntry?.localVideoFilePath
        if let record = watchHistory.first(where: { rec in
            if rec.embyItemId == item.id { return true }
            if let lp = resolvedLocalPath, !lp.isEmpty,
               let recURL = rec.streamURLString {
                let norm = recURL.hasPrefix("file://") ? (URL(string: recURL)?.path ?? recURL) : recURL
                if norm == lp { return true }
            }
            return false
        }) {
            return record.progressRatio >= 0.90
        }
        return false
    }

    public func startPlayback(
        item: EmbyItem,
        episodesQueue: [EmbyItem] = [],
        preferredSourceId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        subtitleExplicitlyOff: Bool = false,
        fromBeginning: Bool = false,
        preferOffline: Bool = false
    ) async {
        let directOfflineMatch = DonbyDownloadManager.shared.completedEntry(
            for: item.id,
            serverId: activeServer?.id,
            mediaSourceId: preferredSourceId
        ) ?? DonbyDownloadManager.shared.completedEntry(for: item.id, mediaSourceId: preferredSourceId)

        let resolvedServer: EmbyServerConfig
        if let active = activeServer, !active.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedServer = active
        } else if let dl = directOfflineMatch,
                  let dlSrv = servers.first(where: { $0.id == dl.serverId }) {
            resolvedServer = dlSrv
        } else if directOfflineMatch != nil {
            resolvedServer = DemoServerData.makeDefaultUHDServer()
        } else {
            showToast("请先配置服务器信息", icon: "exclamationmark.triangle.fill", isError: true)
            return
        }
        var server = resolvedServer
        let startKey = "\(server.id.uuidString)|\(item.id)|\(preferredSourceId ?? "")|\(fromBeginning)"
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if isStartingPlayback,
           pendingPlaybackKey == startKey,
           nowUptime - pendingPlaybackTimestamp < 2.5 {
            return
        }
        if activePlayback != nil,
           lastCompletedPlaybackKey == startKey,
           nowUptime - lastCompletedPlaybackTimestamp < 1.5 {
            return
        }

        playbackStartGeneration &+= 1
        let currentStartGen = playbackStartGeneration
        pendingPlaybackKey = startKey
        pendingPlaybackTimestamp = nowUptime
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            server.lastWatchedDate = Date()
            updateServerInList(server)
        }

        isStartingPlayback = true
        defer {
            if currentStartGen == playbackStartGeneration {
                isStartingPlayback = false
                pendingPlaybackKey = nil
            }
        }

        DonbyLogger.shared.log("准备播放媒体: \(item.name) (ID: \(item.id))", level: .info, subsystem: "Playback")

        do {
            var targetItem = item
            var resolvedQueue = episodesQueue
            if item.isSeries {
                let offlineLibraryGroup = DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: DonbyDownloadManager.shared.entries)
                    .first(where: { $0.displayItem.id == item.id || $0.displayItem.name == item.name })

                let eps: [EmbyItem]
                if (preferOffline || server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                   let offlineGroup = offlineLibraryGroup {
                    let allOfflineEps = offlineGroup.episodesBySeason.keys.sorted().flatMap { seasonKey in
                        (offlineGroup.episodesBySeason[seasonKey] ?? []).sorted {
                            ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0)
                        }
                    }
                    eps = allOfflineEps
                    if !allOfflineEps.isEmpty {
                        resolvedQueue = allOfflineEps
                        targetItem = allOfflineEps.first(where: { !isItemWatchedOfflineOrLocal($0) }) ?? allOfflineEps[0]
                    }
                } else if server.type == .uhdNative {
                    let seasons = try await UHDStreamClient.shared.fetchSeasons(server: server, tvId: item.id)
                    let preferredSeason = seasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? seasons.first
                    if let season = preferredSeason {
                        eps = try await UHDStreamClient.shared.fetchSeasonEpisodes(
                            server: server,
                            tvId: item.id,
                            seasonId: season.id,
                            seasonNumber: season.indexNumber,
                            seriesName: item.name
                        ).items
                    } else {
                        eps = []
                    }
                } else {
                    eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id)
                }
                guard currentStartGen == playbackStartGeneration else { return }
                if resolvedQueue.isEmpty && !eps.isEmpty {
                    resolvedQueue = eps
                }
                if !preferOffline || targetItem.id == item.id {
                    if let firstUnwatched = eps.first(where: { !isItemWatchedOfflineOrLocal($0) }) ?? eps.first {
                        targetItem = firstUnwatched
                    }
                }
            }

            DonbyLogger.shared.log("解析播放资源地址 (目标: \(targetItem.name))", level: .info, subsystem: "Playback")
            let resource: ResolvedPlaybackResource
            if let offlineEntry = DonbyDownloadManager.shared.completedEntry(
                for: targetItem.id,
                serverId: server.id,
                mediaSourceId: preferredSourceId
            ) ?? DonbyDownloadManager.shared.completedEntry(for: targetItem.id, mediaSourceId: preferredSourceId),
               let offlineRes = DonbyDownloadManager.shared.offlinePlayableResource(for: offlineEntry) {
                resource = offlineRes
            } else if server.type == .uhdNative {
                resource = try await UHDStreamClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache && server.cache302Request
                )
            } else {
                resource = try await EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    audioStreamIndex: audioStreamIndex,
                    subtitleStreamIndex: subtitleStreamIndex,
                    enable302Cache: enable302Cache,
                    defer302ProbeWhenTurbo: turboEnabled
                )
            }
            guard currentStartGen == playbackStartGeneration else { return }

            let startSec = fromBeginning ? 0 : targetItem.resumePositionSeconds
            let remotePoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 320)?.absoluteString

            let recTitle: String
            let recSubtitle: String?
            if targetItem.isEpisode {
                var sName = targetItem.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines)
                if sName == nil || sName!.isEmpty {
                    sName = cachedSeriesNames[targetItem.id] ?? cachedSeriesNames[targetItem.seriesId ?? ""]
                }
                if (sName == nil || sName!.isEmpty), let sid = targetItem.seriesId, !sid.isEmpty {
                    let capturedTarget = targetItem
                    let capturedServer = server
                    Task { [weak self] in
                        if let seriesDetail = capturedServer.type == .uhdNative
                            ? (try? await UHDStreamClient.shared.fetchItemDetail(server: capturedServer, item: EmbyItem(id: sid, name: "", type: "Series", uhdMediaType: "tv")))
                            : (try? await EmbyClient.shared.fetchItemDetail(server: capturedServer, itemId: sid)),
                           !seriesDetail.name.isEmpty {
                            await MainActor.run {
                                self?.cachedSeriesNames[capturedTarget.id] = seriesDetail.name
                                self?.cachedSeriesNames[sid] = seriesDetail.name
                                self?.saveCachedSeriesNamesToDisk()
                            }
                        }
                    }
                } else if let s = sName, !s.isEmpty {
                    cachedSeriesNames[targetItem.id] = s
                    if let sid = targetItem.seriesId { cachedSeriesNames[sid] = s }
                    saveCachedSeriesNamesToDisk()
                }
                let meta = formattedWatchRecordMetadata(for: targetItem, resolvedSeriesName: sName)
                recTitle = meta.title
                recSubtitle = meta.subtitle
            } else {
                let meta = formattedWatchRecordMetadata(for: targetItem)
                recTitle = meta.title
                recSubtitle = meta.subtitle
            }

            recordWatch(
                title: recTitle,
                subtitle: recSubtitle,
                posterKey: nil,
                posterURL: remotePoster,
                position: startSec,
                duration: targetItem.durationSeconds > 0 ? targetItem.durationSeconds : 7200,
                sourceType: "Emby",
                embyItemId: targetItem.id,
                resolutionTag: targetItem.resolutionBadge ?? "4K UHD"
            )
            DonbyLogger.shared.log("媒体流解析成功: \(PlaybackDiagnosticsRedactor.redact(resource.streamURL.absoluteString))", level: .info, subsystem: "Playback")
            lastCompletedPlaybackKey = startKey
            lastCompletedPlaybackTimestamp = ProcessInfo.processInfo.systemUptime
            self.activePlayback = ActivePlaybackSession(
                server: server,
                item: targetItem,
                episodesQueue: resolvedQueue.isEmpty ? [targetItem] : resolvedQueue,
                resource: resource,
                startPositionSeconds: startSec,
                selectedAudioIndex: audioStreamIndex,
                selectedSubtitleIndex: subtitleStreamIndex,
                subtitleExplicitlyOff: subtitleExplicitlyOff
            )
        } catch {
            guard currentStartGen == playbackStartGeneration else { return }
            DonbyLogger.shared.log("获取播放流失败: \(error.localizedDescription)", level: .error, subsystem: "Playback")
            showToast("获取播放流失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func playDirectURL(url: URL, title: String, startSeconds: Double = 0) {
        playbackStartGeneration &+= 1
        let isLocal = url.isFileURL || url.scheme == "file" || url.path.hasPrefix("/")
        let parsed = MediaTitleParser.parse(rawName: title)
        let resolvedTitle = isLocal ? parsed.mainTitle : title
        let resolvedSubtitle = isLocal ? parsed.subTitle : (url.isFileURL ? "本地文件" : "网络链接")

        let server = activeServer ?? DemoServerData.makeDefaultUHDServer()
        let dummySource = MediaSourceInfo(
            id: UUID().uuidString,
            name: url.pathExtension.isEmpty ? "Direct Stream" : url.pathExtension.uppercased(),
            path: isLocal ? url.path : url.absoluteString,
            container: url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        )
        let dummyItem = EmbyItem(
            id: UUID().uuidString,
            name: resolvedTitle,
            type: "Video",
            container: dummySource.container,
            mediaSources: [dummySource]
        )
        let resource = ResolvedPlaybackResource(
            streamURL: url,
            headers: [:],
            playSessionId: UUID().uuidString,
            mediaSource: dummySource,
            subtitleURLs: [],
            isDirectStream: true,
            routeNote: isLocal ? "本地文件" : "网络链接"
        )
        addRecentMedia(name: resolvedTitle, urlString: isLocal ? url.path : url.absoluteString, isLocal: isLocal)
        recordWatch(
            title: resolvedTitle,
            subtitle: resolvedSubtitle,
            posterKey: nil,
            position: startSeconds,
            duration: 3600,
            sourceType: isLocal ? "本地文件" : "网络直链",
            streamURLString: isLocal ? url.path : url.absoluteString,
            resolutionTag: isLocal ? "本地 4K" : "在线原画"
        )
        self.activePlayback = ActivePlaybackSession(
            server: server,
            item: dummyItem,
            episodesQueue: [dummyItem],
            resource: resource,
            startPositionSeconds: startSeconds,
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil
        )
    }

    public func copyStreamDirectURL(
        item: EmbyItem,
        preferredSourceId: String? = nil
    ) async {
        guard let server = activeServer else { return }
        do {
            let resource: ResolvedPlaybackResource = if server.type == .uhdNative {
                try await UHDStreamClient.shared.resolvePlaybackResource(
                    server: server,
                    item: item,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset
                )
            } else {
                try await EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: item,
                    preferredSourceId: preferredSourceId,
                    enable302Cache: enable302Cache
                )
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resource.streamURL.absoluteString, forType: .string)
            showToast("已复制媒体直链", icon: "doc.on.doc.fill")
        } catch {
            showToast("解析播放链接失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func toggleFavorite(for item: EmbyItem) async -> EmbyItem {
        guard let server = activeServer else { return item }
        var updated = item
        let newFav = !(item.userData?.isFavorite ?? false)
        var uData = updated.userData ?? EmbyUserData()
        uData.isFavorite = newFav
        updated.userData = uData

        if server.type == .uhdNative {
            try? await UHDStreamClient.shared.setFavorite(server: server, item: item, isFavorite: newFav)
        } else {
            try? await EmbyClient.shared.setFavorite(server: server, itemId: item.id, isFavorite: newFav)
        }
        if newFav {
            if !favoriteItems.contains(where: { $0.id == updated.id }) { favoriteItems.insert(updated, at: 0) }
            showToast("已添加到收藏夹", icon: "heart.fill")
        } else {
            favoriteItems.removeAll { $0.id == updated.id }
            showToast("已从收藏夹移除", icon: "heart.slash")
        }
        return updated
    }

    public func togglePlayed(for item: EmbyItem) async -> EmbyItem {
        var updated = item
        let newPlayed = !(item.userData?.played ?? false)
        var uData = updated.userData ?? EmbyUserData()
        uData.played = newPlayed
        if newPlayed { uData.playbackPositionTicks = 0 }
        updated.userData = uData

        DonbyDownloadManager.shared.updateOfflinePlaybackProgress(
            itemId: item.id,
            played: newPlayed,
            positionSeconds: newPlayed ? nil : 0,
            durationSeconds: nil,
            persistDiskNow: true
        )

        if let server = activeServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if server.type == .uhdNative {
                try? await UHDStreamClient.shared.setPlayed(server: server, item: item, isPlayed: newPlayed)
            } else {
                try? await EmbyClient.shared.setPlayed(server: server, itemId: item.id, played: newPlayed)
            }
        }
        showToast(newPlayed ? "已标记为已观看" : "已标记为未观看", icon: "checkmark.circle.fill")
        return updated
    }

    // MARK: - Subtitle Track Memory (Per-Item, Per-Series & Global Preferred)

    private func subtitleScopeKeys(serverId: UUID, item: EmbyItem) -> (itemKey: String, seriesKey: String?) {
        let srvPart = serverId.uuidString
        let itemKey = "\(srvPart)|item:\(item.id)"
        let seriesKey: String? = {
            if let sid = item.seriesId, !sid.isEmpty {
                return "\(srvPart)|series:\(sid)"
            }
            if item.isSeries {
                return "\(srvPart)|series:\(item.id)"
            }
            if let sName = item.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines), !sName.isEmpty {
                return "\(srvPart)|seriesName:\(sName.lowercased())"
            }
            return nil
        }()
        return (itemKey, seriesKey)
    }

    public func resolvedPrimarySubtitleMemory(serverId: UUID, item: EmbyItem) -> SubtitleTrackPreference? {
        guard rememberSubtitleSelection else { return nil }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        if let exact = subtitleMemoryByScope[keys.itemKey]?.primary {
            return exact
        }
        if let sKey = keys.seriesKey, let seriesPref = subtitleMemoryByScope[sKey]?.primary {
            // Avoid applying another episode's local external file path to sibling episodes
            var copy = seriesPref
            copy.localFilePath = nil
            return copy
        }
        if let global = globalPreferredSubtitle {
            var copy = global
            copy.localFilePath = nil
            copy.embyStreamIndex = nil
            return copy
        }
        return nil
    }

    public func resolvedSecondarySubtitleMemory(serverId: UUID, item: EmbyItem) -> SubtitleTrackPreference? {
        guard rememberSubtitleSelection else { return nil }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        if let exact = subtitleMemoryByScope[keys.itemKey]?.secondary {
            return exact
        }
        if let sKey = keys.seriesKey, let seriesPref = subtitleMemoryByScope[sKey]?.secondary {
            var copy = seriesPref
            copy.localFilePath = nil
            return copy
        }
        if let global = globalPreferredSecondarySubtitle {
            var copy = global
            copy.localFilePath = nil
            copy.embyStreamIndex = nil
            return copy
        }
        return nil
    }

    public func recordPrimarySubtitleChoice(
        serverId: UUID,
        item: EmbyItem,
        preference: SubtitleTrackPreference,
        updateGlobal: Bool = true
    ) {
        guard rememberSubtitleSelection else { return }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        var itemMem = subtitleMemoryByScope[keys.itemKey] ?? SeriesSubtitleMemory()
        itemMem.primary = preference
        itemMem.updatedAt = Date()
        subtitleMemoryByScope[keys.itemKey] = itemMem

        if let sKey = keys.seriesKey {
            var seriesMem = subtitleMemoryByScope[sKey] ?? SeriesSubtitleMemory()
            var seriesPref = preference
            seriesPref.localFilePath = nil
            seriesMem.primary = seriesPref
            seriesMem.updatedAt = Date()
            subtitleMemoryByScope[sKey] = seriesMem
        }

        if updateGlobal && !preference.isDisabled && preference.localFilePath == nil {
            var globalPref = preference
            globalPref.embyStreamIndex = nil
            globalPreferredSubtitle = globalPref
        }
    }

    public func recordSecondarySubtitleChoice(
        serverId: UUID,
        item: EmbyItem,
        preference: SubtitleTrackPreference,
        updateGlobal: Bool = true
    ) {
        guard rememberSubtitleSelection else { return }
        let keys = subtitleScopeKeys(serverId: serverId, item: item)
        var itemMem = subtitleMemoryByScope[keys.itemKey] ?? SeriesSubtitleMemory()
        itemMem.secondary = preference
        itemMem.updatedAt = Date()
        subtitleMemoryByScope[keys.itemKey] = itemMem

        if let sKey = keys.seriesKey {
            var seriesMem = subtitleMemoryByScope[sKey] ?? SeriesSubtitleMemory()
            var seriesPref = preference
            seriesPref.localFilePath = nil
            seriesMem.secondary = seriesPref
            seriesMem.updatedAt = Date()
            subtitleMemoryByScope[sKey] = seriesMem
        }

        if updateGlobal && preference.localFilePath == nil {
            var globalPref = preference
            globalPref.embyStreamIndex = nil
            globalPreferredSecondarySubtitle = globalPref
        }
    }

    // MARK: - Per-Season Skip, Turbo Constraints & Offline Download Coordination

    public func seasonSkipKey(serverId: UUID, item: EmbyItem) -> String {
        let seriesPart = item.seriesId ?? item.id
        let seasonPart = item.seasonId ?? "s\(item.parentIndexNumber ?? 0)"
        return "\(serverId.uuidString)|\(seriesPart)|\(seasonPart)"
    }

    public func effectiveSkipPreference(serverId: UUID, item: EmbyItem) -> SeasonSkipPreference {
        let key = seasonSkipKey(serverId: serverId, item: item)
        if let saved = seasonSkipPreferences[key] {
            return saved
        }
        return SeasonSkipPreference(
            introSeconds: Double(opSeconds),
            outroSeconds: Double(edSeconds),
            mode: autoSkipIntroOutro ? .automatic : .manual
        )
    }

    public func updateSeasonSkipPreference(serverId: UUID, item: EmbyItem, mutate: (inout SeasonSkipPreference) -> Void) {
        let key = seasonSkipKey(serverId: serverId, item: item)
        var pref = effectiveSkipPreference(serverId: serverId, item: item)
        mutate(&pref)
        seasonSkipPreferences[key] = pref
    }

    public func effectiveConnectionBudget(for server: EmbyServerConfig) -> Int {
        let configured = max(1, min(8, turboConnectionBudget))
        if let cap = serverCapabilities[server.id] {
            return max(1, min(configured, cap.activeVideoDeliveryLimit))
        }
        return configured
    }

    public func canDownload(from server: EmbyServerConfig) -> Bool {
        serverCapabilities[server.id]?.allowDownload ?? true
    }

    public func refreshServerCapabilities(for server: EmbyServerConfig) async {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if server.type == .uhdNative {
            if let cap = try? await UHDStreamClient.shared.fetchSubscription(server: server) {
                serverCapabilities[server.id] = cap
            }
        } else {
            let allowDl = await EmbyClient.shared.fetchUserDownloadPermission(server: server)
            serverCapabilities[server.id] = ServerDeliveryCapabilities(allowDownload: allowDl)
        }
    }

    public func enqueueDownload(
        server: EmbyServerConfig,
        item: EmbyItem,
        seriesItemHint: EmbyItem? = nil,
        preferredSourceId: String? = nil
    ) async {
        await refreshServerCapabilities(for: server)
        guard canDownload(from: server) else {
            showToast("当前账号或订阅套餐不允许下载", icon: "lock.fill", isError: true)
            return
        }
        do {
            var targetItem = item
            var resolvedSeries: EmbyItem? = seriesItemHint ?? (item.isSeries ? item : nil)
            if item.isSeries {
                let eps: [EmbyItem]
                if server.type == .uhdNative {
                    let seasons = try await UHDStreamClient.shared.fetchSeasons(server: server, tvId: item.id)
                    let preferredSeason = seasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? seasons.first
                    if let s = preferredSeason {
                        eps = try await UHDStreamClient.shared.fetchSeasonEpisodes(
                            server: server, tvId: item.id, seasonId: s.id, seasonNumber: s.indexNumber, seriesName: item.name
                        ).items
                    } else { eps = [] }
                } else {
                    eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id)
                }
                if let first = eps.first(where: { $0.userData?.played != true }) ?? eps.first {
                    targetItem = first
                }
            }

            if targetItem.isEpisode && resolvedSeries == nil, let sid = targetItem.seriesId, !sid.isEmpty {
                resolvedSeries = allLoadedMediaItems.first(where: { $0.id == sid })
                if resolvedSeries == nil {
                    resolvedSeries = if server.type == .uhdNative {
                        try? await UHDStreamClient.shared.fetchItemDetail(
                            server: server,
                            item: EmbyItem(id: sid, name: targetItem.seriesName ?? "", type: "Series", uhdMediaType: "tv")
                        )
                    } else {
                        try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                    }
                }
            }

            let resource: ResolvedPlaybackResource = if server.type == .uhdNative {
                try await UHDStreamClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset
                )
            } else {
                try await EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: preferredSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache
                )
            }

            let itemPoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 800)
            let itemBackdrop = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .backdrop, maxWidth: 1920)
            let itemThumb = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .thumb, maxWidth: 800)
            let itemLogo = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .logo, maxWidth: 800)
            let seasonPoster = targetItem.seasonId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 600) }

            let seriesPoster = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .primary, maxWidth: 800) }
                ?? targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 800) }
            let seriesBackdrop = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .backdrop, maxWidth: 1920) }
                ?? targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .backdrop, maxWidth: 1920) }
            let seriesLogo = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .logo, maxWidth: 800) }
                ?? targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .logo, maxWidth: 800) }

            let poster = (seriesPoster ?? itemPoster)?.absoluteString
            let meta = formattedWatchRecordMetadata(for: targetItem, resolvedSeriesName: resolvedSeries?.name ?? targetItem.seriesName)
            let budget = min(4, effectiveConnectionBudget(for: server))
            DonbyDownloadManager.shared.enqueueDownload(
                server: server,
                item: targetItem,
                seriesItem: resolvedSeries,
                resource: resource,
                title: meta.title,
                subtitle: meta.subtitle,
                posterURLString: poster,
                itemArtworkURLs: (poster: itemPoster, backdrop: itemBackdrop, thumb: itemThumb, logo: itemLogo, seasonPoster: seasonPoster),
                seriesArtworkURLs: (poster: seriesPoster, backdrop: seriesBackdrop, logo: seriesLogo),
                connectionBudgetPerTask: budget
            )
            showToast("已加入下载队列：\(meta.title)", icon: "arrow.down.circle.fill")
        } catch {
            showToast("添加下载失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func playOfflineDownload(_ entry: DownloadEntry) {
        guard let resource = DonbyDownloadManager.shared.offlinePlayableResource(for: entry) else {
            showToast("离线文件尚未下载完成或已损坏", icon: "exclamationmark.triangle.fill", isError: true)
            return
        }
        let targetServer = servers.first(where: { $0.id == entry.serverId }) ?? DemoServerData.makeDefaultUHDServer()
        let startSec = entry.itemSnapshot.resumePositionSeconds
        self.activePlayback = ActivePlaybackSession(
            server: targetServer,
            item: entry.hydratedItemSnapshot,
            episodesQueue: [entry.hydratedItemSnapshot],
            resource: resource,
            startPositionSeconds: startSec,
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil
        )
    }

    public func handleFullyCachedAssetNotification(_ meta: ChunkStoreMeta) {
        guard autoSaveFullCacheToOffline else { return }
        guard DonbyDownloadManager.shared.entry(for: meta.assetKey) == nil else { return }
        guard !meta.pinned, meta.isFullyCached else { return }
        if let serverId = meta.serverId,
           let srv = servers.first(where: { $0.id == serverId }),
           !canDownload(from: srv) {
            return
        }
        let summary = CachedMediaSummary(
            assetKey: meta.assetKey,
            serverId: meta.serverId,
            itemId: meta.itemId ?? meta.itemSnapshot?.id,
            mediaSourceId: meta.mediaSourceId ?? meta.mediaSourceSnapshot?.id,
            displayTitle: meta.displayTitle ?? meta.itemSnapshot?.name ?? "已缓存媒体",
            subtitle: meta.subtitle,
            posterURLString: meta.posterURLString,
            sourceURLString: meta.sourceURLString,
            cachedBytes: meta.cachedBytes,
            totalBytes: meta.totalSize,
            lastAccess: meta.lastAccess,
            isFullyCached: true,
            itemSnapshot: meta.itemSnapshot,
            mediaSourceSnapshot: meta.mediaSourceSnapshot
        )
        Task {
            await promoteCachedAssetToOffline(summary, isAutoSave: true)
        }
    }

    public func promoteCachedAssetToOffline(_ summary: CachedMediaSummary, isAutoSave: Bool = false) async {
        let store = DonbyTurboCacheEngine.shared.store(for: summary.assetKey, persistDisk: true)
        store.setPinned(true)

        let server = servers.first(where: { $0.id == summary.serverId })
            ?? activeServer
            ?? DemoServerData.makeDefaultUHDServer()
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await refreshServerCapabilities(for: server)
            guard canDownload(from: server) else {
                store.setPinned(false)
                if !isAutoSave {
                    showToast("当前账户订阅不允许转存下载", icon: "lock.fill", isError: true)
                }
                return
            }
        }

        let targetItem = summary.itemSnapshot ?? EmbyItem(
            id: summary.itemId ?? summary.assetKey,
            name: summary.displayTitle,
            serverId: server.id.uuidString,
            type: "Movie",
            uhdPosterURL: summary.posterURLString
        )

        var resolvedSeries: EmbyItem? = nil
        if targetItem.isEpisode, let sid = targetItem.seriesId, !sid.isEmpty {
            resolvedSeries = allLoadedMediaItems.first(where: { $0.id == sid })
            if resolvedSeries == nil && !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvedSeries = if server.type == .uhdNative {
                    try? await UHDStreamClient.shared.fetchItemDetail(
                        server: server,
                        item: EmbyItem(id: sid, name: targetItem.seriesName ?? "", type: "Series", uhdMediaType: "tv")
                    )
                } else {
                    try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                }
            }
        }

        let resolvedResource: ResolvedPlaybackResource
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           summary.itemSnapshot != nil,
           let fresh = try? await (
                server.type == .uhdNative
                ? UHDStreamClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: summary.mediaSourceId,
                    preferredPreset: preferredVersionPreset
                )
                : EmbyClient.shared.resolvePlaybackResource(
                    server: server,
                    item: targetItem,
                    preferredSourceId: summary.mediaSourceId,
                    preferredPreset: preferredVersionPreset,
                    enable302Cache: enable302Cache
                )
           ) {
            resolvedResource = fresh
        } else if let streamURL = URL(string: summary.sourceURLString) {
            let ms = summary.mediaSourceSnapshot ?? MediaSourceInfo(
                id: summary.mediaSourceId ?? summary.assetKey,
                name: streamURL.pathExtension.isEmpty ? "Cached" : streamURL.pathExtension.uppercased(),
                path: summary.sourceURLString,
                container: streamURL.pathExtension.isEmpty ? "mkv" : streamURL.pathExtension,
                size: summary.totalBytes > 0 ? summary.totalBytes : summary.cachedBytes
            )
            resolvedResource = ResolvedPlaybackResource(
                streamURL: streamURL,
                downloadURL: DownloadEntry.derivePreferredDownloadURL(from: streamURL),
                headers: [:],
                playSessionId: UUID().uuidString,
                mediaSource: ms,
                subtitleURLs: [],
                isDirectStream: true,
                routeNote: "从 Turbo 缓存转存"
            )
        } else {
            store.setPinned(false)
            if !isAutoSave {
                showToast("缓存元数据缺少媒体链接，无法转存", icon: "exclamationmark.triangle.fill", isError: true)
            }
            return
        }

        let isUHD = server.type == .uhdNative
        let itemPoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 800)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .primary, maxWidth: 800))
            ?? summary.posterURLString.flatMap { URL(string: $0) }
        let itemBackdrop = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .backdrop, maxWidth: 1920)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .backdrop, maxWidth: 1920))
        let itemThumb = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .thumb, maxWidth: 800)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .thumb, maxWidth: 800))
        let itemLogo = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .logo, maxWidth: 800)
            ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .logo, maxWidth: 800))
        let seasonPoster = isUHD ? nil : targetItem.seasonId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 600) }
        let seriesPoster = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .primary, maxWidth: 800) }
            ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 800) })
            ?? itemPoster
        let seriesBackdrop = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .backdrop, maxWidth: 1920) }
            ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .backdrop, maxWidth: 1920) })
        let seriesLogo = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .logo, maxWidth: 800) }
            ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .logo, maxWidth: 800) })

        let meta = formattedWatchRecordMetadata(for: targetItem, resolvedSeriesName: resolvedSeries?.name ?? targetItem.seriesName)
        let budget = min(4, effectiveConnectionBudget(for: server))
        DonbyDownloadManager.shared.enqueueDownload(
            server: server,
            item: targetItem,
            seriesItem: resolvedSeries,
            resource: resolvedResource,
            title: meta.title,
            subtitle: meta.subtitle,
            posterURLString: (seriesPoster ?? itemPoster)?.absoluteString,
            itemArtworkURLs: (poster: itemPoster, backdrop: itemBackdrop, thumb: itemThumb, logo: itemLogo, seasonPoster: seasonPoster),
            seriesArtworkURLs: (poster: seriesPoster, backdrop: seriesBackdrop, logo: seriesLogo),
            connectionBudgetPerTask: budget,
            origin: isAutoSave ? .autoArchivedFromCache : .manualDownload
        )
        showToast(
            isAutoSave
                ? "已将完整播放缓存自动归档：\(meta.title)"
                : (summary.isFullyCached ? "已将完整缓存保存至离线库：\(meta.title)" : "已从缓存继续下载 (\(Int(summary.progressFraction * 100))%)：\(meta.title)"),
            icon: "arrow.down.circle.fill"
        )
    }

    public func cleanupAutoArchivedEntryIfFinished(itemId: String, mediaSourceId: String?) {
        guard autoSaveFullCacheToOffline && autoDeleteAutoArchivedAfterPlayback else { return }
        if let removed = DonbyDownloadManager.shared.removeAutoArchivedAfterPlayback(itemId: itemId, mediaSourceId: mediaSourceId) {
            DonbyLogger.shared.log("播放完毕已自动删除缓存自动归档文件（手动下载保留）: \(removed.title)", level: .info, subsystem: "Cache")
            showToast("播放完毕，已清理自动归档：\(removed.title)", icon: "trash.circle.fill")
        }
    }

    public func handleIncomingURL(_ url: URL) {
        if url.host?.lowercased() == "open",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let viewName = comps.queryItems?.first(where: { $0.name == "view" })?.value {
            if viewName == "emby", let first = servers.first { openServer(first) }
            else if viewName == "servers" { selectSidebarModule(.servers) }
            else if viewName == "files" { selectSidebarModule(.files) }
            else if viewName == "records" { selectSidebarModule(.records) }
            else if viewName == "downloads" { selectSidebarModule(.downloads) }
            else if viewName == "iptv" { selectSidebarModule(.iptv) }
            else if viewName == "search" { selectSidebarModule(.search) }
            else if viewName == "settings" { selectSidebarModule(.settings) }
            else if viewName == "detail" {
                if let item = allLoadedMediaItems.first ?? resumeItems.first {
                    openDetail(for: item)
                }
            }
            return
        }

        if let parsed = ServerTextParser.parseURLScheme(url) {
            let newServer = EmbyServerConfig(
                name: parsed.name,
                note: parsed.note,
                type: parsed.type,
                host: parsed.host,
                port: parsed.port,
                isHttps: parsed.isHttps,
                path: parsed.path,
                username: parsed.username,
                password: parsed.password,
                iconURL: parsed.iconURL.isEmpty ? "uhd" : parsed.iconURL,
                backupLines: parsed.backupLines
            )
            Task {
                do {
                    try await connectAndSaveServer(newServer)
                } catch {
                    updateServerInList(newServer)
                    showToast("成功导入服务器 \(newServer.name)", icon: "server.rack")
                }
            }
            return
        }

        if url.host?.lowercased() == "importicon",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let iconsetURLStr = comps.queryItems?.first(where: { $0.name == "iconset" })?.value,
           let iconsetURL = URL(string: iconsetURLStr) {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: iconsetURL),
                   let iconSet = try? JSONDecoder().decode(IconLibrarySet.self, from: data) {
                    if !iconSets.contains(where: { $0.name == iconSet.name }) { iconSets.append(iconSet) }
                    showToast("成功导入图标库 \(iconSet.name)", icon: "photo.on.rectangle.angled")
                }
            }
        }
    }
}

// MARK: - Multi-Tier Server Home Cache Store
public final class ServerHomeCacheStore {
    public static let shared = ServerHomeCacheStore()
    private var inMemorySnapshots: [UUID: ServerHomeSnapshot] = [:]
    private let cacheDirectoryURL: URL

    public struct ServerHomeSnapshot: Codable {
        public var libraryViews: [EmbyItem]
        public var resumeItems: [EmbyItem]
        public var nextUpItems: [EmbyItem]
        public var favoriteItems: [EmbyItem]
        public var latestByLibrary: [String: [EmbyItem]]
        public var carouselItems: [EmbyItem]
        public var cachedAt: Date
    }

    private init() {
        let base = DonbyStoragePaths.cachesDirectoryURL
        let dir = base.appendingPathComponent("com.don.Donby/ServerHomeCache", isDirectory: true)
        self.cacheDirectoryURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }

    public func snapshot(for serverId: UUID) -> ServerHomeSnapshot? {
        if let mem = inMemorySnapshots[serverId] {
            return mem
        }
        let file = cacheDirectoryURL.appendingPathComponent("home_\(serverId.uuidString).json")
        if let data = try? Data(contentsOf: file),
           let snap = try? JSONDecoder().decode(ServerHomeSnapshot.self, from: data) {
            inMemorySnapshots[serverId] = snap
            return snap
        }
        return nil
    }

    public func save(_ snapshot: ServerHomeSnapshot, for serverId: UUID) {
        inMemorySnapshots[serverId] = snapshot
        DispatchQueue.global(qos: .utility).async { [cacheDirectoryURL] in
            let file = cacheDirectoryURL.appendingPathComponent("home_\(serverId.uuidString).json")
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

import Foundation
import SwiftUI
import Combine
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

public struct ServerEditorRequest: Identifiable {
    public let id = UUID()
    public let existingServer: EmbyServerConfig?
    public let preferredType: ServerType?

    public init(existingServer: EmbyServerConfig? = nil, preferredType: ServerType? = nil) {
        self.existingServer = existingServer
        self.preferredType = preferredType
    }
}

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
    @Published public var isWindowFullScreen: Bool = false

    public var collapsedSidebarLeadingPadding: CGFloat {
        isWindowFullScreen ? 0 : 58
    }

    @Published public var serverEditorRequest: ServerEditorRequest? = nil
    @Published public var linePickerServer: EmbyServerConfig? = nil
    @Published public var toastMessage: ToastMessage? = nil
    @Published public var showLogViewer: Bool = false
    @Published public var isStartingPlayback: Bool = false

    public func presentServerEditor(for server: EmbyServerConfig? = nil, preferredType: ServerType? = nil) {
        serverEditorRequest = ServerEditorRequest(existingServer: server, preferredType: preferredType)
    }

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
    var homeLoadGeneration: UInt64 = 0
    var playbackStartGeneration: UInt64 = 0
    var pendingPlaybackKey: String? = nil
    var pendingPlaybackTimestamp: TimeInterval = 0
    var lastCompletedPlaybackKey: String? = nil
    var lastCompletedPlaybackTimestamp: TimeInterval = 0
    var detailFocusedEpisodeMemory: [String: (seasonNumber: Int?, episodeId: String)] = [:]

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
    var saveWatchHistoryTask: Task<Void, Never>? = nil
    var lastRecordedWatchItemId: String? = nil
    var lastRecordedWatchPosition: Double = -1.0
    var lastRecordedWatchDate: Date = .distantPast
    var inFlightSeriesNameTasks: [String: Task<String?, Never>] = [:]
    var activeSyncDomainsCount: Int = 0
    var activePingLinesCount: Int = 0
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()
    static let maxWatchHistoryCount = 300

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
    @AppStorage("donby.showFavorites") public var showFavorites: Bool = true
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
            if !isLoadingFromDisk {
                // Delays are per-file playback state; never persist them globally across unrelated movies/episodes.
                var persisted = subtitleStyle
                persisted.primaryDelaySeconds = 0
                persisted.secondaryDelaySeconds = 0
                if let data = try? jsonEncoder.encode(persisted) {
                    UserDefaults.standard.set(data, forKey: "donby.subtitleStyle.v1")
                }
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

    private let serversStorageKey = "donby.servers.v2"
    private let urlMediaStorageKey = "donby.urlMedia.v3"
    private let iptvChannelsStorageKey = "donby.iptvChannels.v3"
    let watchHistoryStorageKey = "donby.watchHistory.v3"
    let cachedSeriesNamesStorageKey = "donby.cachedSeriesNames.v1"
    let searchHistoryStorageKey = "donby.searchHistory.v1"
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
    @Published public var embyInlineSearchTruncated: Bool = false
    public var embyInlineSearchLastServerId: UUID? = nil
    public var embyInlineSearchLastFetchedQuery: String = ""
    @Published public var librarySearchQueryById: [String: String] = [:]

    public init() {
        AppState.sharedInstance = self
        DonbyAppExtensionCenter.shared.installCompiledExtensionsIfNeeded()
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
           var decodedStyle = try? jsonDecoder.decode(SubtitleStyleConfiguration.self, from: subData) {
            decodedStyle.primaryDelaySeconds = 0
            decodedStyle.secondaryDelaySeconds = 0
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
        let filtered = decoded.filter { !$0.isDemoServer }
        let (hydrated, needsMigration) = ServerCredentialStore.shared.hydrate(filtered)
        var migrated = hydrated
        var didMigratePlaceholder = false
        let uhdRegistered = DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)
        for i in migrated.indices {
            if migrated[i].host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if migrated[i].note == "待配置服务器地址与账号" {
                    migrated[i].note = ""
                    didMigratePlaceholder = true
                }
                if uhdRegistered && migrated[i].type == .emby && migrated[i].usesUHDLogo {
                    migrated[i].type = .uhdNative
                    didMigratePlaceholder = true
                }
            }
        }
        self.servers = migrated
        if needsMigration || didMigratePlaceholder {
            saveServersToDisk()
            if needsMigration {
                DonbyLogger.shared.log("已完成服务器凭证向本地 AES-256-GCM 加密凭证库的自动迁移", level: .info, subsystem: "Credentials")
            }
        }
    }

    private func saveServersToDisk() {
        let sanitized = ServerCredentialStore.shared.persistSecretsAndSanitizeForDefaults(servers)
        if let data = try? jsonEncoder.encode(sanitized) {
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
            embyInlineSearchTruncated = false
            embyInlineSearchLastServerId = nil
            embyInlineSearchLastFetchedQuery = ""
            librarySearchQueryById.removeAll()
            DonbyAppExtensionCenter.shared.plugin?.resetHomeShelves()
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
}

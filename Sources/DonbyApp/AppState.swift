import Foundation
import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyStorage
import DonbyKernelC

@MainActor
public final class AppState: ObservableObject {
    public static weak var sharedInstance: AppState?

    @Published public var selectedTab: MainNavigationTab = .servers
    @Published public var openedServerId: UUID? = nil
    @Published public var selectedLibrary: EmbyItem? = nil
    @Published public var detailStack: [EmbyItem] = []
    @Published public var activePlayback: ActivePlaybackSession? = nil
    @Published public var isSidebarCollapsed: Bool = false

    @Published public var showAddServerSheet: Bool = false
    @Published public var editingServer: EmbyServerConfig? = nil
    @Published public var linePickerServer: EmbyServerConfig? = nil
    @Published public var toastMessage: ToastMessage? = nil
    @Published public var showLogViewer: Bool = false
    @Published public var isStartingPlayback: Bool = false

    @Published public var servers: [EmbyServerConfig] = [] {
        didSet { saveServersToDisk() }
    }
    @Published public var activeServerId: UUID? = nil {
        didSet {
            if let id = activeServerId {
                UserDefaults.standard.set(id.uuidString, forKey: "donby.activeServerId")
            }
        }
    }
    @Published public var isSyncingDomains: Bool = false
    @Published public var isPingingLines: Bool = false
    private var homeLoadGeneration: UInt64 = 0

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
        didSet { saveURLMediaToDisk() }
    }

    @Published public var iptvChannels: [IPTVChannelItem] = [] {
        didSet { saveIPTVChannelsToDisk() }
    }

    @Published public var watchHistory: [WatchRecordItem] = []
    private var saveWatchHistoryTask: Task<Void, Never>? = nil
    private var lastRecordedWatchItemId: String? = nil
    private var lastRecordedWatchPosition: Double = -1.0
    private var lastRecordedWatchDate: Date = .distantPast

    @AppStorage("donby.displayConnectStatus") public var displayConnectionStatus: Bool = true
    @AppStorage("donby.displayMediaStats") public var displayMediaStatistics: Bool = true
    @AppStorage("donby.displayServerIcon") public var displayServerIcon: Bool = true
    @AppStorage("donby.displayWatchTime") public var displayWatchTime: Bool = true
    @AppStorage("donby.displaySearchBox") public var displaySearchBox: Bool = true
    @AppStorage("donby.displayAeroGlass") public var displayAeroGlass: Bool = true
    @AppStorage("donby.hideEncryptedServers") public var hideEncryptedServers: Bool = false

    @AppStorage("donby.themeColor") public var themeColorRaw: String = AppThemeColor.blue.rawValue
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

    // 线路与网络设置
    @AppStorage("donby.autoSyncDomains") public var autoSyncDomains: Bool = true
    @AppStorage("donby.enable302Cache") public var enable302Cache: Bool = true
    @AppStorage("donby.pingTimeoutSeconds") public var pingTimeoutSeconds: Int = 5
    @AppStorage("donby.cachePoolSizeMB") public var cachePoolSizeMB: Int = 256
    @AppStorage("donby.defaultSidebarCollapsed") public var defaultSidebarCollapsed: Bool = false

    public var accentColor: Color {
        let theme = AppThemeColor(rawValue: themeColorRaw) ?? .blue
        let rgb = ThemeColorPalette.color(for: theme)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    public var controlBarStyle: ControlBarPositionStyle {
        ControlBarPositionStyle(rawValue: controlBarStyleRaw) ?? .float
    }

    public var activeServer: EmbyServerConfig? {
        if let openedServerId, let found = servers.first(where: { $0.id == openedServerId }) { return found }
        if let activeServerId, let found = servers.first(where: { $0.id == activeServerId }) { return found }
        return servers.first(where: \.isDefaultHome) ?? servers.first
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

    public init() {
        AppState.sharedInstance = self
        self.isSidebarCollapsed = UserDefaults.standard.bool(forKey: "donby.defaultSidebarCollapsed")
        loadServersFromDisk()
        loadURLMediaFromDisk()
        loadIPTVChannelsFromDisk()
        loadWatchHistoryFromDisk()

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

        if let defaultHome = servers.first(where: { $0.isDefaultHome && !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            openedServerId = defaultHome.id
        } else if let first = servers.first(where: { !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            openedServerId = first.id
        } else {
            openedServerId = nil
            selectedTab = .servers
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
              let decoded = try? JSONDecoder().decode([EmbyServerConfig].self, from: data) else {
            return
        }
        self.servers = decoded.filter { !$0.isDemoServer }
    }

    private func saveServersToDisk() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversStorageKey)
        }
    }

    private func loadURLMediaFromDisk() {
        if let data = UserDefaults.standard.data(forKey: urlMediaStorageKey),
           let decoded = try? JSONDecoder().decode([LocalOrURLMediaItem].self, from: data) {
            self.urlMediaItems = decoded
        } else {
            self.urlMediaItems = []
        }
    }

    private func saveURLMediaToDisk() {
        if let data = try? JSONEncoder().encode(urlMediaItems) {
            UserDefaults.standard.set(data, forKey: urlMediaStorageKey)
        }
    }

    private func loadIPTVChannelsFromDisk() {
        if let data = UserDefaults.standard.data(forKey: iptvChannelsStorageKey),
           let decoded = try? JSONDecoder().decode([IPTVChannelItem].self, from: data) {
            self.iptvChannels = decoded
        } else {
            self.iptvChannels = []
        }
    }

    private func saveIPTVChannelsToDisk() {
        if let data = try? JSONEncoder().encode(iptvChannels) {
            UserDefaults.standard.set(data, forKey: iptvChannelsStorageKey)
        }
    }

    private func loadWatchHistoryFromDisk() {
        if let data = UserDefaults.standard.data(forKey: watchHistoryStorageKey),
           let decoded = try? JSONDecoder().decode([WatchRecordItem].self, from: data) {
            self.watchHistory = decoded
        } else {
            self.watchHistory = []
        }
    }

    private func saveWatchHistoryToDisk() {
        if let data = try? JSONEncoder().encode(watchHistory) {
            UserDefaults.standard.set(data, forKey: watchHistoryStorageKey)
        }
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
        var addedCount = 0
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
                let name = currentName ?? "未知频道 \(addedCount + 1)"
                if !iptvChannels.contains(where: { $0.urlString == line }) {
                    iptvChannels.append(IPTVChannelItem(name: name, group: currentGroup, urlString: line))
                    addedCount += 1
                }
                currentName = nil
            }
        }

        if addedCount > 0 {
            showToast("成功导入 \(addedCount) 个 IPTV 频道", icon: "sparkles.tv")
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
        guard duration > 0 else { return }
        let recId = embyItemId ?? streamURLString ?? title
        let now = Date()

        if lastRecordedWatchItemId == recId,
           abs(position - lastRecordedWatchPosition) < 3.0,
           now.timeIntervalSince(lastRecordedWatchDate) < 4.0 {
            return
        }
        lastRecordedWatchItemId = recId
        lastRecordedWatchPosition = position
        lastRecordedWatchDate = now

        watchHistory.removeAll { $0.id == recId }
        let record = WatchRecordItem(
            id: recId,
            title: title,
            subtitle: subtitle,
            posterKey: posterKey,
            posterURL: posterURL,
            positionSeconds: position,
            durationSeconds: duration,
            lastWatchedAt: now,
            sourceType: sourceType,
            streamURLString: streamURLString,
            embyItemId: embyItemId,
            resolutionTag: resolutionTag
        )
        watchHistory.insert(record, at: 0)
        scheduleSaveWatchHistory(immediate: false)
    }

    public func clearWatchHistory() {
        watchHistory.removeAll()
        flushWatchHistory()
        showToast("已清空全部观看记录", icon: "trash.fill")
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
                if var fetched = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId) {
                    var uData = fetched.userData ?? EmbyUserData()
                    uData.playbackPositionTicks = Int64(record.positionSeconds * 10_000_000.0)
                    fetched.userData = uData
                    await startPlayback(item: fetched)
                } else if let urlStr = record.streamURLString, let url = URL(string: urlStr) {
                    playDirectURL(url: url, title: record.title, startSeconds: record.positionSeconds)
                }
            }
            return
        }
        if let urlStr = record.streamURLString, let url = URL(string: urlStr) {
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
                if let fetched = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId) {
                    await startPlayback(item: fetched, fromBeginning: true)
                } else if let urlStr = record.streamURLString, let url = URL(string: urlStr) {
                    playDirectURL(url: url, title: record.title, startSeconds: 0)
                }
            }
            return
        }
        if let urlStr = record.streamURLString, let url = URL(string: urlStr) {
            playDirectURL(url: url, title: record.title, startSeconds: 0)
            return
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
        activeServerId = server.id
        openedServerId = server.id
        selectedLibrary = nil
        detailStack.removeAll()
        Task { await loadActiveServerHome(syncDomains: true) }
    }

    public func selectSidebarModule(_ tab: MainNavigationTab) {
        openedServerId = nil
        selectedLibrary = nil
        detailStack.removeAll()
        selectedTab = tab
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
        draft.isDemoServer = false
        if !parsed.name.isEmpty { draft.name = parsed.name }
        draft.note = parsed.note
        draft.type = parsed.type
        draft.host = parsed.host
        draft.port = parsed.port
        draft.isHttps = parsed.isHttps
        draft.path = parsed.path
        if !parsed.username.isEmpty { draft.username = parsed.username }
        if !parsed.password.isEmpty { draft.password = parsed.password }
        if !parsed.iconURL.isEmpty { draft.iconURL = parsed.iconURL }
        if !parsed.backupLines.isEmpty {
            let existingManual = draft.backupLines.filter { !$0.isAutoSynced }
            draft.backupLines = existingManual + parsed.backupLines
        }
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
        if server.accessToken.isEmpty || !server.username.isEmpty {
            let auth = try await EmbyClient.shared.authenticate(
                baseURL: server.activeBaseURL,
                username: server.username,
                password: server.password
            )
            server.accessToken = auth.accessToken ?? ""
            server.userId = auth.user?.id ?? ""
            server.serverId = auth.serverId ?? auth.user?.serverId ?? ""
        }
        if let sysInfo = try? await EmbyClient.shared.fetchSystemInfo(server: server) {
            server.serverName = sysInfo.serverName ?? server.name
            server.serverVersion = sysInfo.version ?? ""
            if server.name.isEmpty { server.name = sysInfo.serverName ?? server.host }
        }
        if let domains = await EmbyClient.shared.fetchExtServerDomains(
            baseURL: server.activeBaseURL,
            token: server.accessToken,
            userId: server.userId
        ) {
            server.mergeExtDomains(domains)
        }

        server.lastWatchedDate = Date()
        updateServerInList(server)
        activeServerId = server.id
        openedServerId = server.id
        selectedLibrary = nil
        detailStack.removeAll()

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
        isSyncingDomains = true
        defer { isSyncingDomains = false }

        guard !server.accessToken.isEmpty else {
            if showFeedback { showToast("请先登录服务器后再同步线路", icon: "exclamationmark.triangle.fill", isError: true) }
            return
        }

        if let domains = await EmbyClient.shared.fetchExtServerDomains(
            baseURL: server.activeBaseURL,
            token: server.accessToken,
            userId: server.userId
        ) {
            server.mergeExtDomains(domains)
            servers[idx] = server
            if showFeedback { showToast("已同步 \(domains.count) 条 UHD 云端线路", icon: "icloud.and.arrow.down.fill") }
            await pingAllLines(for: server.id)
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
        isPingingLines = true
        defer { isPingingLines = false }

        let mainURL = server.mainLineURL
        let token = server.accessToken
        let backupSnapshot = server.backupLines

        async let mainPing = EmbyClient.shared.pingLine(baseURL: mainURL, token: token)
        var linePings: [UUID: Int?] = [:]
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for line in backupSnapshot {
                group.addTask {
                    let ms = await EmbyClient.shared.pingLine(baseURL: line.url, token: token)
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

        isLoadingHome = true
        homeErrorMessage = nil

        if syncDomains {
            Task { await syncExtDomains(for: server.id, showFeedback: false) }
        }

        // Update library item counts in background so large servers (400k+ episodes) never block homepage UI
        Task {
            if let counts = try? await EmbyClient.shared.fetchCounts(server: server),
               let idx = self.servers.firstIndex(where: { $0.id == server.id }) {
                self.servers[idx].movieCount = counts.movieCount ?? self.servers[idx].movieCount
                self.servers[idx].episodeCount = counts.episodeCount ?? counts.seriesCount ?? self.servers[idx].episodeCount
            }
        }

        do {
            async let viewsTask = EmbyClient.shared.fetchViews(server: server)
            async let resumeTask = EmbyClient.shared.fetchResumeItems(server: server, limit: 16)
            async let nextUpTask = EmbyClient.shared.fetchNextUp(server: server, limit: 16)
            async let favTask = EmbyClient.shared.fetchItems(server: server, isFavorite: true, limit: 24)

            let views = try await viewsTask
            guard currentGen == homeLoadGeneration else { return }
            self.libraryViews = views

            let resumes = (try? await resumeTask) ?? []
            let nextUps = (try? await nextUpTask) ?? []
            let favs = (try? await favTask)?.items ?? []

            guard currentGen == homeLoadGeneration else { return }
            self.resumeItems = resumes
            self.nextUpItems = nextUps
            self.favoriteItems = favs

            var latestMap: [String: [EmbyItem]] = self.latestByLibrary
            var heroCandidates: [EmbyItem] = []

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
                    self.latestByLibrary[viewId] = items
                    for item in items.prefix(3) where !heroCandidates.contains(where: { $0.id == item.id }) {
                        heroCandidates.append(item)
                    }
                }
            }

            guard currentGen == homeLoadGeneration else { return }
            self.latestByLibrary = latestMap
            self.carouselItems = Array((heroCandidates.isEmpty ? resumes : heroCandidates).prefix(8))
            self.isLoadingHome = false
        } catch {
            guard currentGen == homeLoadGeneration else { return }
            self.homeErrorMessage = error.localizedDescription
            self.isLoadingHome = false
        }
    }

    public func openDetail(for item: EmbyItem) {
        if let last = detailStack.last, last.id == item.id { return }
        detailStack.append(item)
    }

    public func popDetail() {
        if !detailStack.isEmpty { detailStack.removeLast() }
    }

    public func startPlayback(
        item: EmbyItem,
        episodesQueue: [EmbyItem] = [],
        preferredSourceId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        fromBeginning: Bool = false
    ) async {
        guard var server = activeServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("请先配置服务器信息", icon: "exclamationmark.triangle.fill", isError: true)
            return
        }
        server.lastWatchedDate = Date()
        updateServerInList(server)

        isStartingPlayback = true
        defer { isStartingPlayback = false }

        DonbyLogger.shared.log("准备播放媒体: \(item.name) (ID: \(item.id))", level: .info, subsystem: "Playback")

        do {
            var targetItem = item
            if item.isSeries {
                let eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id)
                if let firstUnwatched = eps.first(where: { $0.userData?.played != true }) ?? eps.first {
                    targetItem = firstUnwatched
                }
            }

            DonbyLogger.shared.log("解析播放资源地址 (目标: \(targetItem.name))", level: .info, subsystem: "Playback")
            let resource = try await EmbyClient.shared.resolvePlaybackResource(
                server: server,
                item: targetItem,
                preferredSourceId: preferredSourceId,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex
            )

            let startSec = fromBeginning ? 0 : targetItem.resumePositionSeconds
            let remotePoster = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 320)?.absoluteString
            recordWatch(
                title: targetItem.name,
                subtitle: targetItem.isEpisode ? "\(targetItem.seriesName ?? "") · \(targetItem.episodeCodeString ?? "")" : targetItem.resolutionBadge,
                posterKey: nil,
                posterURL: remotePoster,
                position: startSec,
                duration: targetItem.durationSeconds > 0 ? targetItem.durationSeconds : 7200,
                sourceType: "Emby",
                embyItemId: targetItem.id,
                resolutionTag: targetItem.resolutionBadge ?? "4K UHD"
            )
            DonbyLogger.shared.log("媒体流解析成功: \(resource.streamURL.absoluteString)", level: .info, subsystem: "Playback")
            self.activePlayback = ActivePlaybackSession(
                server: server,
                item: targetItem,
                episodesQueue: episodesQueue.isEmpty ? [targetItem] : episodesQueue,
                resource: resource,
                startPositionSeconds: startSec,
                selectedAudioIndex: audioStreamIndex,
                selectedSubtitleIndex: subtitleStreamIndex
            )
        } catch {
            DonbyLogger.shared.log("获取播放流失败: \(error.localizedDescription)", level: .error, subsystem: "Playback")
            showToast("获取播放流失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func playDirectURL(url: URL, title: String, startSeconds: Double = 0) {
        let server = activeServer ?? DemoServerData.makeDefaultUHDServer()
        let dummySource = MediaSourceInfo(
            id: UUID().uuidString,
            name: url.pathExtension.isEmpty ? "Direct Stream" : url.pathExtension.uppercased(),
            path: url.absoluteString,
            container: url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        )
        let dummyItem = EmbyItem(
            id: UUID().uuidString,
            name: title,
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
            routeNote: url.isFileURL ? "本地文件直解" : "网络直链播放"
        )
        addRecentMedia(name: title, urlString: url.absoluteString, isLocal: url.isFileURL)
        recordWatch(
            title: title,
            subtitle: url.isFileURL ? "本地文件直解 (\(dummySource.container?.uppercased() ?? "FILE"))" : "网络直链播放 (\(dummySource.container?.uppercased() ?? "STREAM"))",
            posterKey: nil,
            position: startSeconds,
            duration: 3600,
            sourceType: url.isFileURL ? "本地文件" : "网络直链",
            streamURLString: url.absoluteString,
            resolutionTag: url.isFileURL ? "本地 4K" : "在线原画"
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
            let resource = try await EmbyClient.shared.resolvePlaybackResource(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId
            )
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

        try? await EmbyClient.shared.setFavorite(server: server, itemId: item.id, isFavorite: newFav)
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
        guard let server = activeServer else { return item }
        var updated = item
        let newPlayed = !(item.userData?.played ?? false)
        var uData = updated.userData ?? EmbyUserData()
        uData.played = newPlayed
        if newPlayed { uData.playbackPositionTicks = 0 }
        updated.userData = uData

        try? await EmbyClient.shared.setPlayed(server: server, itemId: item.id, played: newPlayed)
        showToast(newPlayed ? "已标记为已观看" : "已标记为未观看", icon: "checkmark.circle.fill")
        return updated
    }

    public func handleIncomingURL(_ url: URL) {
        if url.host?.lowercased() == "open",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let viewName = comps.queryItems?.first(where: { $0.name == "view" })?.value {
            if viewName == "emby", let first = servers.first { openServer(first) }
            else if viewName == "servers" { selectSidebarModule(.servers) }
            else if viewName == "files" { selectSidebarModule(.files) }
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

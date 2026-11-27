#if canImport(DonbyUHDModule)
import SwiftUI
import Combine
import DonbyCore
import DonbyNetwork
import DonbyUHDModule

// MARK: - Thin, Decoupled UI Mount Points for Core Donby Views

/// Attaches all optional UHD module sheets in a single clean modifier on MainWindowView.
public struct DonbyUHDModuleSheetsModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared

    public init() {}

    public func body(content: Content) -> some View {
        content
            .sheet(item: $uhd.accountSheetServer) { server in
                UHDAccountSheet(serverId: server.id)
                    .environmentObject(appState)
                    .preferredColorScheme(appState.colorScheme)
                    .tint(appState.accentColor)
            }
            .sheet(isPresented: $uhd.showLibraryHubSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDLibraryHubSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                        .tint(appState.accentColor)
                }
            }
            .sheet(isPresented: $uhd.showAnimeCalendarSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDAnimeCalendarSheet(
                        server: server,
                        initialMode: uhd.currentLibraryMode(for: server.id)
                    )
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                        .tint(appState.accentColor)
                }
            }
            .sheet(isPresented: $uhd.showWatchPartyJoinSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDWatchPartyJoinSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                        .tint(appState.accentColor)
                }
            }
            .sheet(item: $uhd.activePersonSheet) { target in
                UHDPersonDetailSheet(target: target)
                    .environmentObject(appState)
                    .preferredColorScheme(appState.colorScheme)
                    .tint(appState.accentColor)
            }
    }
}

public extension View {
    func donbyUHDModuleSheets() -> some View {
        modifier(DonbyUHDModuleSheetsModifier())
    }
}

/// Direct Donby Liquid Glass toolbar actions for optional UHD capabilities (Library Hall, Calendar, Watch Party & Account).
public struct UHDEmbyToolbarButtons: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    public let server: EmbyServerConfig

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    private func standardIconColor(hovered: Bool) -> Color {
        appState.isLightMode
            ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28))
            : (hovered ? .white : Color(white: 0.88))
    }

    public var body: some View {
        if uhd.isActive(for: server), !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let activeMode = uhd.currentLibraryMode(for: server.id)

            ToolbarVectorButton(
                tooltip: "馆别 · \(activeMode.displayTitle)",
                action: { uhd.showLibraryHubSheet = true }
            ) { hovered in
                let iconColor = activeMode == .anime ? appState.accentColor : standardIconColor(hovered: hovered)
                UHDLibraryModeIcon(mode: activeMode, size: 15.5, color: iconColor)
            }

            ToolbarVectorButton(
                tooltip: activeMode.calendarTitle,
                action: { uhd.showAnimeCalendarSheet = true }
            ) { hovered in
                Image(systemName: "calendar")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(standardIconColor(hovered: hovered))
            }

            ToolbarVectorButton(
                tooltip: "加入同看",
                action: { uhd.showWatchPartyJoinSheet = true }
            ) { hovered in
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(standardIconColor(hovered: hovered))
            }

            ToolbarVectorButton(
                tooltip: "账户与流量",
                action: { uhd.accountSheetServer = server }
            ) { hovered in
                UHDAccountVectorIcon(size: 15.5, color: standardIconColor(hovered: hovered))
            }
        }
    }
}

/// Optional Extension Module management card rendered inside SettingsView -> 基础设置.
public struct UHDSettingsModuleCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扩展模块")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

            HStack(spacing: 12) {
                UHDNowVectorLogo(size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("UHDNow 服务扩展")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("独立可选模块，提供免地址优选登录、线路测速、追番日历与同看")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                Toggle("", isOn: $uhd.isEnabled)
                    .labelsHidden()
                    .toggleStyle(
                        DonbySwitchToggleStyle(
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor
                        )
                    )
                    .donbyOnChange(of: uhd.isEnabled) { _ in
                        appState.reloadAfterModuleToggle()
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }
}

// MARK: - Server Context Menu & Enhanced Route/Speed-Test Sheet Slots

private struct UHDServerContextMenuExtraItems: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    let server: EmbyServerConfig

    var body: some View {
        if uhd.isActive(for: server) {
            Button { uhd.accountSheetServer = server } label: {
                Label("账户与流量", systemImage: "person.crop.circle")
            }
            Button {
                appState.activeServerId = server.id
                uhd.showWatchPartyJoinSheet = true
            } label: {
                Label("加入同看", systemImage: "person.2.wave.2")
            }
        }
    }
}

private struct UHDServerLogoutMenuItem: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    let server: EmbyServerConfig

    var body: some View {
        if uhd.isActive(for: server) && !server.accessToken.isEmpty {
            Button {
                Task { await uhd.logoutServer(server, appState: appState) }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

private struct UHDLineAndAccountSheetView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    @StateObject private var speedModel = UHDSpeedTestSessionModel()

    let serverId: UUID
    let onDismiss: () -> Void

    private var server: EmbyServerConfig? {
        appState.servers.first(where: { $0.id == serverId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("线路与测速")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("\(server.name) · 当前：\(server.activeLineName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }

                    Spacer()

                    ToolbarVectorButton(tooltip: "关闭", action: {
                        speedModel.cancel()
                        onDismiss()
                    }) { hovered in
                        let iconCol = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconCol)
                    }
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                linesBody(server: server)
            }
        }
        .padding(22)
        .frame(width: 610)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .onDisappear {
            speedModel.cancel()
        }
    }

    @ViewBuilder
    private func linesBody(server: EmbyServerConfig) -> some View {
        UHDCapabilitySummaryStrip(server: server)

        let rowCount = !server.backupLines.isEmpty ? server.backupLines.count : 1
        let listHeight = min(max(CGFloat(rowCount) * 60, 124), 260)

        ScrollView {
            VStack(spacing: 8) {
                if server.backupLines.isEmpty {
                    ServerLineOptionRow(
                        title: "默认主线路",
                        url: ServerLineInfo(name: "默认主线路", url: server.mainLineURL).cleanDisplayHost,
                        lastSpeedMbps: nil,
                        isSelected: server.selectedLineId == nil,
                        isTesting: false,
                        onRunSpeedTest: nil
                    ) {
                        appState.switchLineImmediate(to: nil, for: server.id)
                        onDismiss()
                    }
                }

                ForEach(server.backupLines) { line in
                    let canSpeedTest = (line.domainId?.isEmpty == false)
                    let isTestingLine = speedModel.isSpeedTesting && speedModel.testingDomainId == line.domainId
                    let speedAction: (() -> Void)? = canSpeedTest ? {
                        if let did = line.domainId, !speedModel.isSpeedTesting {
                            speedModel.launchSingle(server: server, domainId: did, appState: appState)
                        }
                    } : nil

                    ServerLineOptionRow(
                        title: line.cleanDisplayName,
                        url: line.cleanDisplayHost,
                        lastSpeedMbps: line.lastSpeedMbps,
                        isSelected: server.selectedLineId == line.id,
                        isTesting: isTestingLine,
                        onRunSpeedTest: speedAction
                    ) {
                        appState.switchLineImmediate(to: line.id, for: server.id)
                        onDismiss()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: listHeight)

        UHDSpeedTestConsoleView(model: speedModel, server: server)

        Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

        HStack(spacing: 10) {
            Button {
                guard !appState.isSyncingDomains else { return }
                Task { await appState.syncExtDomains(for: server.id, showFeedback: true) }
            } label: {
                HStack(spacing: 6) {
                    RefreshVectorIcon(
                        size: 13,
                        color: appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(white: 0.90),
                        isSpinning: appState.isSyncingDomains
                    )
                    Text("同步线路")
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7.5)
                .donbyLiquidGlassCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            UHDProxyRulesPopoverButton()

            Spacer()

            Button {
                speedModel.cancel()
                onDismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7.5)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .task(id: server.id) {
            await appState.refreshServerCapabilities(for: server)
        }
    }
}

// MARK: - Registered UI Extension Plugin Bridge

@MainActor
public final class UHDAppExtensionPlugin: DonbyAppUIExtensionPlugin {
    public static let shared = UHDAppExtensionPlugin()

    private init() {}

    public static func registerIfNeeded() {
        _ = UHDModuleManager.shared
        DonbyAppExtensionCenter.shared.register(shared)
    }

    public var isEnabled: Bool {
        UHDModuleManager.shared.isEnabled
    }

    public func isActive(for server: EmbyServerConfig?) -> Bool {
        UHDModuleManager.shared.isActive(for: server)
    }

    public func extraHomeItemLists() -> [[EmbyItem]] {
        guard UHDModuleManager.shared.isEnabled else { return [] }
        return [UHDModuleManager.shared.hotItems, UHDModuleManager.shared.animeHotItems]
    }

    public func resetHomeShelves() {
        UHDModuleManager.shared.resetHomeShelves()
    }

    public func isAnimeModeActive(for server: EmbyServerConfig) -> Bool? {
        let uhd = UHDModuleManager.shared
        guard uhd.isActive(for: server) else { return nil }
        return uhd.currentLibraryMode(for: server.id) == .anime
    }

    public func resolveImdbIds(for items: [EmbyItem], server: EmbyServerConfig, maxCount: Int) async -> [String: String] {
        guard UHDModuleManager.shared.isActive(for: server) else { return [:] }
        return await UHDImdbBridge.shared.resolveImdbIds(for: items, server: server, maxCount: maxCount)
    }

    public func authenticateAndConfigureServer(
        draft: EmbyServerConfig,
        loginCode: String?,
        customEndpointOverride: String?,
        autoSyncDomains: Bool,
        appState: AppState
    ) async throws -> (server: EmbyServerConfig, usedChinaOptimizedLine: Bool) {
        try await UHDModuleManager.shared.authenticateAndConfigureServer(
            draft: draft,
            uhdLoginCode: loginCode,
            customEndpointOverride: customEndpointOverride,
            autoSyncDomains: autoSyncDomains,
            appState: appState
        )
    }

    public func syncPlaybackDomains(for serverId: UUID, appState: AppState, showFeedback: Bool) async {
        await UHDModuleManager.shared.syncPlaybackDomains(for: serverId, appState: appState, showFeedback: showFeedback)
    }

    public func loadHomeContent(
        for server: EmbyServerConfig,
        appState: AppState,
        isCurrentGeneration: @escaping () -> Bool
    ) async {
        await UHDModuleManager.shared.loadHomeContent(
            for: server,
            appState: appState,
            isCurrentGeneration: isCurrentGeneration
        )
    }

    public func resolveSeriesStartEpisode(
        server: EmbyServerConfig,
        seriesItem: EmbyItem
    ) async throws -> (episodes: [EmbyItem], preferredTarget: EmbyItem?) {
        try await UHDModuleManager.shared.resolveSeriesStartEpisode(server: server, seriesItem: seriesItem)
    }

    public func refreshAccountSnapshot(for server: EmbyServerConfig, appState: AppState) async {
        await UHDModuleManager.shared.refreshAccountSnapshot(for: server, appState: appState)
    }

    public func refreshMissingAccountSnapshots(servers: [EmbyServerConfig], appState: AppState) async {
        let uhd = UHDModuleManager.shared
        guard uhd.isEnabled else { return }
        for srv in servers where srv.type == .uhdNative && !srv.host.isEmpty && !srv.accessToken.isEmpty {
            if uhd.accountSnapshots[srv.id] == nil {
                await uhd.refreshAccountSnapshot(for: srv, appState: appState)
            }
        }
    }

    public func serverCardBadgeText(for server: EmbyServerConfig) -> String? {
        let uhd = UHDModuleManager.shared
        guard uhd.isActive(for: server),
              let traffic = uhd.accountSnapshots[server.id]?.traffic else { return nil }
        return traffic.shortToolbarBadgeText
    }

    public func preferredEditorType(forUnconfigured server: EmbyServerConfig) -> ServerType? {
        (UHDModuleManager.shared.isEnabled && server.usesUHDLogo) ? .uhdNative : nil
    }

    public func initialCustomEndpoint(for server: EmbyServerConfig) -> String {
        guard server.type == .uhdNative else { return "" }
        let hostLower = server.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !hostLower.isEmpty
            && hostLower != UHDModuleEndpoints.primaryChinaOptimizedHost
            && hostLower != UHDModuleEndpoints.fallbackStandardHost {
            return server.mainLineURL
        }
        return ""
    }

    public func applyCustomEndpointOnSaveOnly(_ customEndpoint: String, to draft: inout EmbyServerConfig) {
        let trimmed = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = UHDModuleEndpoints.parseEndpointComponents(from: trimmed)
        draft.host = parsed.host
        draft.isHttps = parsed.isHttps
        draft.port = parsed.port
    }

    public func formatLoginCodeDisplay(_ raw: String) -> String {
        UHDLoginCodeNormalizer.formattedDisplay(raw)
    }

    public func isValidLoginCode(_ raw: String) -> Bool {
        UHDLoginCodeNormalizer.normalize(raw) != nil
    }

    public func homeShelves(for server: EmbyServerConfig?) -> [HomeShelfSection] {
        let uhd = UHDModuleManager.shared
        guard let server, uhd.isActive(for: server) else { return [] }
        let activeMode = uhd.currentLibraryMode(for: server.id)
        var result: [HomeShelfSection] = []
        let filteredHot = activeMode == .normal
            ? uhd.hotItems.filter { !HomeHeroCurator.isAnimeOrAnimation($0) }
            : uhd.hotItems
        if !filteredHot.isEmpty {
            result.append(HomeShelfSection(id: "uhd_hot", title: activeMode.hotTitle, kind: .poster, items: filteredHot))
        }
        return result
    }

    public func fetchAvailableGenres(for server: EmbyServerConfig) async -> [String]? {
        guard UHDModuleManager.shared.isActive(for: server),
              let genres = try? await UHDStreamClient.shared.fetchGenres(server: server) else { return nil }
        return genres.map(\.name)
    }

    public func fetchLibraryPage(
        server: EmbyServerConfig,
        library: EmbyItem,
        query: String,
        sortField: EmbySortField,
        ascending: Bool,
        filterUnwatchedOnly: Bool,
        filterFavoritesOnly: Bool,
        selectedGenreFilter: String,
        cursor: String?
    ) async throws -> DonbyExtensionLibraryPage {
        if !query.isEmpty {
            let mode = UHDModuleManager.shared.currentLibraryMode(for: server.id)
            let found = try await UHDStreamClient.shared.search(server: server, query: query, limit: 50, mode: mode)
            return DonbyExtensionLibraryPage(items: found, nextCursor: nil, hasMore: false, totalOverride: found.count)
        }
        if filterFavoritesOnly {
            let libType: String? = {
                let lower = library.name.lowercased()
                if lower.contains("电影") || lower.contains("movie") { return "movie" }
                if lower.contains("剧") || lower.contains("动漫") || lower.contains("综艺") || lower.contains("tv") || lower.contains("series") { return "tv" }
                return nil
            }()
            let favPage = try await UHDStreamClient.shared.fetchFavorites(
                server: server,
                type: libType,
                limit: 50,
                cursor: cursor
            )
            var fetched = favPage.items
            if filterUnwatchedOnly { fetched = fetched.filter { $0.userData?.played != true } }
            if !selectedGenreFilter.isEmpty {
                fetched = fetched.filter { $0.genres?.contains(selectedGenreFilter) == true }
            }
            return DonbyExtensionLibraryPage(
                items: fetched,
                nextCursor: favPage.nextCursor,
                hasMore: favPage.nextCursor != nil,
                totalOverride: favPage.total
            )
        }
        let uhdSortBy: String = switch sortField {
        case .premiereDate: "release_date"
        case .communityRating: "rating"
        case .hot: "hot"
        case .sortName: "title"
        default: "asset_updated_at"
        }
        let pageRes = try await UHDStreamClient.shared.fetchCollectionItems(
            server: server,
            collectionId: library.id,
            sortBy: uhdSortBy,
            sortOrder: ascending ? "asc" : "desc",
            limit: 50,
            cursor: cursor
        )
        var fetched = pageRes.items
        if filterUnwatchedOnly { fetched = fetched.filter { $0.userData?.played != true } }
        if filterFavoritesOnly { fetched = fetched.filter { $0.userData?.isFavorite == true } }
        if !selectedGenreFilter.isEmpty {
            fetched = fetched.filter { $0.genres?.contains(selectedGenreFilter) == true }
        }
        return DonbyExtensionLibraryPage(
            items: fetched,
            nextCursor: pageRes.nextCursor,
            hasMore: pageRes.nextCursor != nil,
            totalOverride: library.childCount
        )
    }

    public func loadDetailPayload(
        server: EmbyServerConfig,
        initialItem: EmbyItem,
        targetSeriesId: String?
    ) async -> DonbyExtensionDetailPayload {
        let trimmedTargetSeries = targetSeriesId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedItemSeries = initialItem.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialSeriesId: String? = if let sid = trimmedTargetSeries, !sid.isEmpty {
            sid
        } else if initialItem.isSeries {
            initialItem.id
        } else if initialItem.isEpisode, let sid = trimmedItemSeries, !sid.isEmpty {
            sid
        } else {
            nil
        }

        let explicitKind = initialItem.uhdMediaType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let needsDetailFirstForSeriesContext = initialSeriesId == nil
            && !initialItem.isSeries
            && (initialItem.isEpisode || explicitKind == nil || explicitKind?.isEmpty == true)

        if !needsDetailFirstForSeriesContext {
            let detailTarget: EmbyItem = if initialItem.isEpisode, let sid = initialSeriesId, !sid.isEmpty {
                EmbyItem(
                    id: sid,
                    name: (initialItem.seriesName?.isEmpty == false) ? initialItem.seriesName! : initialItem.name,
                    serverId: initialItem.serverId,
                    type: "Series",
                    uhdMediaType: "tv"
                )
            } else {
                initialItem
            }
            let creditMediaId = detailTarget.id
            async let detailTask = try? UHDStreamClient.shared.fetchItemDetail(server: server, item: detailTarget)
            async let creditsTask = try? UHDStreamClient.shared.fetchCredits(server: server, mediaId: creditMediaId)
            async let assetsTask: [MediaSourceInfo]? = {
                guard !detailTarget.isSeries else { return nil }
                return try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: detailTarget)
            }()
            async let seasonsTask: [EmbyItem]? = {
                guard let sid = initialSeriesId, !sid.isEmpty else { return nil }
                return try? await UHDStreamClient.shared.fetchSeasons(server: server, tvId: sid)
            }()
            async let tvPlaybackStateTask: UHDTVPlaybackState? = {
                guard let sid = initialSeriesId, !sid.isEmpty else { return nil }
                return try? await UHDStreamClient.shared.fetchTVPlaybackState(server: server, tvId: sid)
            }()

            var enriched: EmbyItem? = nil
            if let detailed = await detailTask {
                let loadedSources = await assetsTask
                let loadedPeople = await creditsTask
                enriched = detailed.withDetailEnrichment(mediaSources: loadedSources, people: loadedPeople)
            }
            let seasons = await seasonsTask
            let preferredTuple: (seasonId: String, seasonNumber: Int?, episodeId: String)?
            if initialItem.isEpisode {
                preferredTuple = (seasonId: initialItem.seasonId ?? "", seasonNumber: initialItem.parentIndexNumber, episodeId: initialItem.id)
            } else {
                let prefEp = await tvPlaybackStateTask?.preferredEpisode
                preferredTuple = prefEp.map { ($0.seasonId, $0.seasonNumber, $0.episodeId) }
            }
            return DonbyExtensionDetailPayload(enrichedItem: enriched, seasons: seasons, preferredEpisode: preferredTuple)
        }

        // Stub entry path (e.g. Watch Party invite or Watch Record lacking seriesId / resolved type):
        // resolve detail first so episode seriesId and true media type drive credits, seasons, and playback state.
        let preflightTask: Task<[MediaSourceInfo]?, Never>? = (explicitKind == "episode" || explicitKind == "movie")
            ? Task { try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: initialItem) }
            : nil
        defer { if Task.isCancelled { preflightTask?.cancel() } }
        async let detailTask = try? UHDStreamClient.shared.fetchItemDetail(server: server, item: initialItem)

        guard let detailed = await detailTask else {
            let fallbackSources = await preflightTask?.value
            return DonbyExtensionDetailPayload(
                enrichedItem: fallbackSources != nil ? initialItem.withDetailEnrichment(mediaSources: fallbackSources, people: nil) : nil,
                seasons: nil,
                preferredEpisode: nil
            )
        }

        let resolvedSeriesId: String? = if detailed.isSeries {
            detailed.id
        } else if detailed.isEpisode, let sid = detailed.seriesId, !sid.isEmpty {
            sid
        } else {
            nil
        }
        let creditMediaId = detailed.isEpisode ? (resolvedSeriesId ?? detailed.id) : detailed.id

        async let upgradedSeriesTask: EmbyItem? = {
            guard detailed.isEpisode, let sid = resolvedSeriesId, !sid.isEmpty else { return nil }
            let seriesStub = EmbyItem(
                id: sid,
                name: (detailed.seriesName?.isEmpty == false) ? detailed.seriesName! : detailed.name,
                serverId: detailed.serverId,
                type: "Series",
                uhdMediaType: "tv"
            )
            return try? await UHDStreamClient.shared.fetchItemDetail(server: server, item: seriesStub)
        }()
        async let creditsTask = try? UHDStreamClient.shared.fetchCredits(server: server, mediaId: creditMediaId)
        async let fallbackAssetsTask: [MediaSourceInfo]? = {
            if let preloaded = await preflightTask?.value { return preloaded }
            guard !detailed.isSeries else { return nil }
            return try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: detailed)
        }()
        async let seasonsTask: [EmbyItem]? = {
            guard let sid = resolvedSeriesId, !sid.isEmpty else { return nil }
            return try? await UHDStreamClient.shared.fetchSeasons(server: server, tvId: sid)
        }()
        async let tvPlaybackStateTask: UHDTVPlaybackState? = {
            guard let sid = resolvedSeriesId, !sid.isEmpty else { return nil }
            return try? await UHDStreamClient.shared.fetchTVPlaybackState(server: server, tvId: sid)
        }()

        let loadedPeople = await creditsTask
        let seasons = await seasonsTask
        let enriched: EmbyItem
        let preferredTuple: (seasonId: String, seasonNumber: Int?, episodeId: String)?
        if let upgradedSeries = await upgradedSeriesTask {
            enriched = upgradedSeries.withDetailEnrichment(people: loadedPeople)
            preferredTuple = (seasonId: detailed.seasonId ?? "", seasonNumber: detailed.parentIndexNumber, episodeId: detailed.id)
        } else {
            let loadedSources = await fallbackAssetsTask
            enriched = detailed.withDetailEnrichment(mediaSources: loadedSources, people: loadedPeople)
            let prefEp = await tvPlaybackStateTask?.preferredEpisode
            preferredTuple = prefEp.map { ($0.seasonId, $0.seasonNumber, $0.episodeId) }
        }
        return DonbyExtensionDetailPayload(enrichedItem: enriched, seasons: seasons, preferredEpisode: preferredTuple)
    }

    public func openPersonSheet(server: EmbyServerConfig, person: EmbyPerson) {
        guard UHDModuleManager.shared.isActive(for: server) else { return }
        UHDModuleManager.shared.activePersonSheet = UHDPersonSheetTarget(server: server, person: person)
    }

    public func wrapRootSheets(_ content: AnyView) -> AnyView {
        AnyView(content.donbyUHDModuleSheets())
    }

    public func makeSettingsCard() -> AnyView {
        AnyView(UHDSettingsModuleCard())
    }

    public func makeEmbyToolbarButtons(server: EmbyServerConfig) -> AnyView {
        AnyView(UHDEmbyToolbarButtons(server: server))
    }

    public func makeServerContextMenuExtraItems(server: EmbyServerConfig) -> AnyView {
        AnyView(UHDServerContextMenuExtraItems(server: server))
    }

    public func makeServerLogoutMenuItem(server: EmbyServerConfig) -> AnyView {
        AnyView(UHDServerLogoutMenuItem(server: server))
    }

    public func makeCustomLineSwitchView(serverId: UUID, onDismiss: @escaping () -> Void) -> AnyView? {
        AnyView(UHDLineAndAccountSheetView(serverId: serverId, onDismiss: onDismiss))
    }

    public func makeDetailWatchPartyCreateSheet(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String?
    ) -> AnyView {
        AnyView(
            UHDWatchPartyCreateSheet(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId
            )
        )
    }

    public func makePlayerCompanion(
        server: EmbyServerConfig,
        appState: AppState,
        notifyHost: @escaping () -> Void
    ) -> (any DonbyPlayerCompanion)? {
        UHDPlayerCompanionController(server: server, appState: appState, notifyHost: notifyHost)
    }
}
#endif

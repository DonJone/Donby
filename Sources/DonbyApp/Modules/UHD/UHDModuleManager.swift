#if canImport(DonbyUHDModule)
import Foundation
import Combine
import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyUHDModule

public struct UHDPersonSheetTarget: Identifiable {
    public var id: String { "\(server.id.uuidString)|\(person.id)" }
    public let server: EmbyServerConfig
    public let person: EmbyPerson

    public init(server: EmbyServerConfig, person: EmbyPerson) {
        self.server = server
        self.person = person
    }
}

/// Self-contained state & action coordinator for the optional UHDNow service module.
/// Owns all UHD-specific state so Donby's core AppState stays clean and decoupled.
@MainActor
public final class UHDModuleManager: ObservableObject {
    public static let shared = UHDModuleManager()

    private static let enabledKey = "donby.module.uhd.enabled"

    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                DonbyUHDModule.install()
            } else {
                DonbyUHDModule.uninstall()
                clearRuntimeState()
            }
        }
    }

    // UHD-scoped reactive UI & session state
    @Published public var accountSnapshots: [UUID: UHDAccountSnapshot] = [:]
    @Published public var hotItems: [EmbyItem] = []
    @Published public var animeHotItems: [EmbyItem] = []
    @Published public var libraryModeByServer: [UUID: UHDLibraryMode] = [:]
    @Published public var librarySettingsByServer: [UUID: UHDLibrarySettings] = [:]

    // UHD-scoped sheets & active Watch Party session
    @Published public var accountSheetServer: EmbyServerConfig? = nil
    @Published public var showLibraryHubSheet: Bool = false
    @Published public var showAnimeCalendarSheet: Bool = false
    @Published public var showFavoritesSheet: Bool = false
    @Published public var showWatchPartyJoinSheet: Bool = false
    @Published public var activePersonSheet: UHDPersonSheetTarget? = nil
    @Published public var activeWatchPartySession: UHDWatchPartySession? = nil

    private var changeForwarder: AnyCancellable?

    private init() {
        let initialEnabled: Bool
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            initialEnabled = true
        } else {
            initialEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        self.isEnabled = initialEnabled
        if initialEnabled {
            DonbyUHDModule.install()
        } else {
            DonbyUHDModule.uninstall()
        }
        self.changeForwarder = objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                DonbyAppExtensionCenter.shared.objectWillChange.send()
            }
        }
    }

    public func isActive(for server: EmbyServerConfig?) -> Bool {
        guard isEnabled, let server else { return false }
        return server.type == .uhdNative
    }

    public func currentLibraryMode(for serverId: UUID?) -> UHDLibraryMode {
        guard let serverId else { return .normal }
        return libraryModeByServer[serverId] ?? .normal
    }

    public func refreshLibrarySettings(server: EmbyServerConfig) async throws -> UHDLibrarySettings {
        let settings = try await UHDStreamClient.shared.fetchLibrarySettings(server: server)
        librarySettingsByServer[server.id] = settings
        if libraryModeByServer[server.id] == nil {
            libraryModeByServer[server.id] = settings.preferences.mode
        }
        return settings
    }

    public func switchLibraryMode(
        _ mode: UHDLibraryMode,
        persistDefault: Bool,
        server: EmbyServerConfig,
        appState: AppState
    ) async throws {
        var resolvedMode = mode
        if persistDefault {
            let saved = try await UHDStreamClient.shared.saveLibrarySettings(server: server, mode: mode, collectionIds: nil)
            resolvedMode = saved.mode
            if let existing = librarySettingsByServer[server.id] {
                librarySettingsByServer[server.id] = UHDLibrarySettings(preferences: saved, collections: existing.collections)
            }
        }
        libraryModeByServer[server.id] = resolvedMode
        await appState.loadActiveServerHome(syncDomains: false)
    }

    public func saveLibraryCollections(
        mode: UHDLibraryMode,
        collectionIds: [String],
        server: EmbyServerConfig,
        appState: AppState
    ) async throws -> UHDLibraryPreferences {
        let saved = try await UHDStreamClient.shared.saveLibrarySettings(
            server: server,
            mode: mode,
            collectionIds: collectionIds
        )
        libraryModeByServer[server.id] = saved.mode
        if let existing = librarySettingsByServer[server.id] {
            librarySettingsByServer[server.id] = UHDLibrarySettings(preferences: saved, collections: existing.collections)
        }
        await appState.loadActiveServerHome(syncDomains: false)
        return saved
    }

    public func resetHomeShelves() {
        hotItems = []
        animeHotItems = []
    }

    private func clearRuntimeState() {
        accountSnapshots.removeAll()
        hotItems.removeAll()
        animeHotItems.removeAll()
        libraryModeByServer.removeAll()
        librarySettingsByServer.removeAll()
        accountSheetServer = nil
        showLibraryHubSheet = false
        showAnimeCalendarSheet = false
        showFavoritesSheet = false
        showWatchPartyJoinSheet = false
        activePersonSheet = nil
        leaveOrEndActiveWatchParty(endRoom: false, notifyServer: true)
    }

    // MARK: - Zero-URL Login with Automatic Smart -> V1 Fallback & China-Optimized Line Selection

    public func authenticateAndConfigureServer(
        draft: EmbyServerConfig,
        uhdLoginCode: String? = nil,
        customEndpointOverride: String? = nil,
        autoSyncDomains: Bool,
        appState: AppState
    ) async throws -> (server: EmbyServerConfig, usedChinaOptimizedLine: Bool) {
        var server = draft
        server.type = .uhdNative
        server.iconURL = "uhd"
        server.isDemoServer = false
        if server.note == "待配置服务器地址与账号" {
            server.note = ""
        }

        let explicitCustom = customEndpointOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customBase: String? = {
            if !explicitCustom.isEmpty {
                return explicitCustom
            }
            // If user edited an existing non-default custom host (not smart/v1), keep it unless cleared
            let existingHost = server.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !existingHost.isEmpty
                && existingHost != UHDModuleEndpoints.primaryChinaOptimizedHost
                && existingHost != UHDModuleEndpoints.fallbackStandardHost {
                return server.mainLineURL
            }
            return nil
        }()

        let trimmedLoginCode = uhdLoginCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasToken = !server.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !server.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var resolvedBaseURL = UHDModuleEndpoints.primaryChinaOptimizedBaseURL

        if !trimmedLoginCode.isEmpty {
            let outcome = try await UHDStreamClient.shared.loginWithCodeAutoFallback(
                customBaseURL: customBase,
                rawCode: trimmedLoginCode
            )
            server.host = outcome.host
            server.isHttps = outcome.isHttps
            server.port = outcome.port
            server.accessToken = outcome.auth.token
            server.tokenExpiresAt = outcome.auth.expiresAt
            server.lastLoginDate = Date()
            resolvedBaseURL = outcome.baseURL
            if server.serverId.isEmpty { server.serverId = outcome.host }
            if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { server.name = "UHDNow" }
            server.serverName = "UHDNow"
        } else if hasUsername && hasPassword {
            let outcome = try await UHDStreamClient.shared.loginWithAutoFallback(
                customBaseURL: customBase,
                username: server.username,
                password: server.password
            )
            server.host = outcome.host
            server.isHttps = outcome.isHttps
            server.port = outcome.port
            server.accessToken = outcome.auth.token
            server.tokenExpiresAt = outcome.auth.expiresAt
            server.lastLoginDate = Date()
            resolvedBaseURL = outcome.baseURL
            if server.userId.isEmpty { server.userId = server.username }
            if server.serverId.isEmpty { server.serverId = outcome.host }
            if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { server.name = "UHDNow" }
            server.serverName = "UHDNow"
        } else if hasToken {
            let outcome = try await UHDStreamClient.shared.validateTokenAutoFallback(
                customBaseURL: customBase,
                token: server.accessToken
            )
            server.host = outcome.host
            server.isHttps = outcome.isHttps
            server.port = outcome.port
            if !outcome.subscription.userId.isEmpty { server.userId = outcome.subscription.userId }
            server.lastLoginDate = Date()
            resolvedBaseURL = outcome.baseURL
            if server.serverId.isEmpty { server.serverId = outcome.host }
            if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { server.name = "UHDNow" }
            server.serverName = "UHDNow"
        } else {
            throw EmbyClientError.httpStatus(400, "请输入账号密码、登录码或 API Key")
        }

        var usedChinaOptimizedLine = UHDModuleEndpoints.isChinaOptimizedHost(resolvedBaseURL)

        if !server.accessToken.isEmpty {
            let snap = await UHDStreamClient.shared.fetchAccountSnapshot(server: server)
            accountSnapshots[server.id] = snap
            if let sub = snap.subscription {
                if !sub.userId.isEmpty { server.userId = sub.userId }
                appState.serverCapabilities[server.id] = ServerDeliveryCapabilities(
                    allowDownload: sub.allowDownload,
                    activeVideoDeliveryLimit: max(0, sub.activeVideoDeliveryLimit),
                    planName: sub.plan?.name,
                    displayUnlimitedTraffic: sub.displayUnlimitedTraffic,
                    trafficLimitBytes: sub.trafficLimitBytes
                )
            }
            if autoSyncDomains,
               let uhdLines = try? await UHDStreamClient.shared.fetchPlaybackDomains(server: server) {
                let manual = server.backupLines.filter { !$0.isAutoSynced }
                server.backupLines = manual + uhdLines
                server.lastExtDomainSyncDate = Date()

                if let preferred = UHDModuleEndpoints.pickPreferredDefaultLine(
                    from: uhdLines,
                    loggedInBaseURL: resolvedBaseURL
                ) {
                    server.selectedLineId = preferred.id
                    usedChinaOptimizedLine = UHDModuleEndpoints.isChinaOptimizedLine(preferred)
                }
            }
        }

        return (server, usedChinaOptimizedLine)
    }

    // MARK: - Playback Domains & Capabilities

    public func syncPlaybackDomains(
        for serverId: UUID,
        appState: AppState,
        showFeedback: Bool = false
    ) async {
        guard isEnabled else { return }
        guard let idx = appState.servers.firstIndex(where: { $0.id == serverId }) else { return }
        var server = appState.servers[idx]
        guard server.type == .uhdNative else { return }

        if server.accessToken.isEmpty && !server.username.isEmpty && !server.password.isEmpty {
            if let outcome = try? await UHDStreamClient.shared.loginWithAutoFallback(
                username: server.username,
                password: server.password
            ) {
                server.host = outcome.host
                server.isHttps = outcome.isHttps
                server.port = outcome.port
                server.accessToken = outcome.auth.token
                if let currentIdx = appState.servers.firstIndex(where: { $0.id == serverId }) {
                    appState.servers[currentIdx].host = outcome.host
                    appState.servers[currentIdx].isHttps = outcome.isHttps
                    appState.servers[currentIdx].port = outcome.port
                    appState.servers[currentIdx].accessToken = outcome.auth.token
                }
            }
        }
        guard !server.accessToken.isEmpty else {
            if showFeedback {
                appState.showToast("请先登录 UHDNow 账号", icon: "exclamationmark.triangle.fill", isError: true)
            }
            return
        }

        if let uhdLines = try? await UHDStreamClient.shared.fetchPlaybackDomains(server: server) {
            if let currentIdx = appState.servers.firstIndex(where: { $0.id == serverId }) {
                let manual = appState.servers[currentIdx].backupLines.filter { !$0.isAutoSynced }
                appState.servers[currentIdx].backupLines = manual + uhdLines
                appState.servers[currentIdx].lastExtDomainSyncDate = Date()
                let currentSel = appState.servers[currentIdx].selectedLineId
                if currentSel == nil || !appState.servers[currentIdx].backupLines.contains(where: { $0.id == currentSel }) {
                    let preferred = UHDModuleEndpoints.pickPreferredDefaultLine(
                        from: uhdLines,
                        loggedInBaseURL: appState.servers[currentIdx].mainLineURL
                    )
                    appState.servers[currentIdx].selectedLineId = preferred?.id
                }
            }
            if showFeedback {
                appState.showToast("已同步 \(uhdLines.count) 条线路", icon: "icloud.and.arrow.down.fill")
            }
            await appState.pingAllLines(for: serverId)
        } else if showFeedback {
            appState.showToast("获取线路列表失败", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func refreshAccountSnapshot(for server: EmbyServerConfig, appState: AppState) async {
        guard isEnabled, server.type == .uhdNative, !server.accessToken.isEmpty else { return }
        let snap = await UHDStreamClient.shared.fetchAccountSnapshot(server: server)
        accountSnapshots[server.id] = snap
        if let sub = snap.subscription {
            appState.serverCapabilities[server.id] = ServerDeliveryCapabilities(
                allowDownload: sub.allowDownload,
                activeVideoDeliveryLimit: max(0, sub.activeVideoDeliveryLimit),
                planName: sub.plan?.name,
                displayUnlimitedTraffic: sub.displayUnlimitedTraffic,
                trafficLimitBytes: sub.trafficLimitBytes
            )
            if !sub.userId.isEmpty,
               let idx = appState.servers.firstIndex(where: { $0.id == server.id }),
               appState.servers[idx].userId != sub.userId {
                appState.servers[idx].userId = sub.userId
            }
        }
    }

    public func logoutServer(_ server: EmbyServerConfig, appState: AppState) async {
        let ok = await UHDStreamClient.shared.logout(server: server)
        if ok, let idx = appState.servers.firstIndex(where: { $0.id == server.id }) {
            appState.servers[idx].accessToken = ""
            appState.servers[idx].password = ""
            appState.servers[idx].tokenExpiresAt = nil
            accountSnapshots.removeValue(forKey: server.id)
            appState.serverCapabilities.removeValue(forKey: server.id)
            if appState.openedServerId == server.id {
                appState.openedServerId = nil
                appState.selectedTab = .servers
            }
            appState.showToast("已退出 \(server.name)", icon: "checkmark.circle.fill")
        } else {
            appState.showToast("退出登录失败，请稍后重试", icon: "exclamationmark.triangle.fill", isError: true)
        }
    }

    public func updateLineSpeedResult(
        serverId: UUID,
        domainId: String,
        result: UHDSpeedTestResult,
        latencyMs: Int? = nil,
        appState: AppState
    ) {
        guard let sIdx = appState.servers.firstIndex(where: { $0.id == serverId }) else { return }
        if let lIdx = appState.servers[sIdx].backupLines.firstIndex(where: { $0.domainId == domainId }) {
            appState.servers[sIdx].backupLines[lIdx].lastSpeedMbps = result.averageMbps
            appState.servers[sIdx].backupLines[lIdx].lastPeakMbps = result.peakMbps
            appState.servers[sIdx].backupLines[lIdx].lastExitLocation = nil
            appState.servers[sIdx].backupLines[lIdx].lastExitISP = nil
            appState.servers[sIdx].backupLines[lIdx].latencyMs = nil
            appState.servers[sIdx].backupLines[lIdx].lastCheckedAt = Date()
        }
    }

    public func updateLineExitInfo(
        serverId: UUID,
        domainId: String,
        info: UHDSpeedTestNetworkInfo,
        latencyMs: Int,
        appState: AppState
    ) {
        guard let sIdx = appState.servers.firstIndex(where: { $0.id == serverId }) else { return }
        if let lIdx = appState.servers[sIdx].backupLines.firstIndex(where: { $0.domainId == domainId }) {
            appState.servers[sIdx].backupLines[lIdx].lastExitLocation = info.displayLocation
            appState.servers[sIdx].backupLines[lIdx].lastExitISP = info.isp
            appState.servers[sIdx].backupLines[lIdx].latencyMs = latencyMs
            appState.servers[sIdx].backupLines[lIdx].lastCheckedAt = Date()
        }
    }

    // MARK: - Home Content Loading

    public func loadHomeContent(
        for server: EmbyServerConfig,
        appState: AppState,
        isCurrentGeneration: @escaping @MainActor () -> Bool
    ) async {
        guard isEnabled else {
            appState.homeErrorMessage = "UHDNow 扩展模块已关闭，请在设置中重新启用"
            appState.isLoadingHome = false
            return
        }

        var workingServer = server

        do {
            if libraryModeByServer[workingServer.id] == nil,
               let settings = try? await UHDStreamClient.shared.fetchLibrarySettings(server: workingServer) {
                librarySettingsByServer[workingServer.id] = settings
                libraryModeByServer[workingServer.id] = settings.preferences.mode
            }
            let activeMode = currentLibraryMode(for: workingServer.id)

            let views: [EmbyItem]
            do {
                views = try await UHDStreamClient.shared.fetchCollections(server: workingServer, mode: activeMode)
            } catch {
                // If user temporarily disabled the extension (which re-authed as standard Emby) and later re-enabled it,
                // transparently re-acquire a UHD Stream session using saved credentials.
                if !workingServer.username.isEmpty, !workingServer.password.isEmpty {
                    let outcome = try await UHDStreamClient.shared.loginWithAutoFallback(
                        customBaseURL: nil,
                        username: workingServer.username,
                        password: workingServer.password
                    )
                    workingServer.host = outcome.host
                    workingServer.port = outcome.port
                    workingServer.isHttps = outcome.isHttps
                    workingServer.accessToken = outcome.auth.token
                    workingServer.tokenExpiresAt = outcome.auth.expiresAt
                    if let idx = appState.servers.firstIndex(where: { $0.id == workingServer.id }) {
                        appState.servers[idx].host = workingServer.host
                        appState.servers[idx].port = workingServer.port
                        appState.servers[idx].isHttps = workingServer.isHttps
                        appState.servers[idx].accessToken = workingServer.accessToken
                        appState.servers[idx].tokenExpiresAt = workingServer.tokenExpiresAt
                    }
                    views = try await UHDStreamClient.shared.fetchCollections(server: workingServer, mode: activeMode)
                } else {
                    throw error
                }
            }

            let resolvedServer = workingServer
            async let statesTask = UHDStreamClient.shared.fetchPlaybackStates(server: resolvedServer, limit: 16)
            async let favTask = UHDStreamClient.shared.fetchFavorites(server: resolvedServer, limit: 24)
            async let hotTask = UHDStreamClient.shared.fetchHot(server: resolvedServer, limit: 20, mode: activeMode)
            async let animeHotTask: [EmbyItem]? = activeMode == .normal
                ? (try? await UHDStreamClient.shared.fetchAnimeHot(server: resolvedServer, limit: 20))
                : []

            guard isCurrentGeneration() else { return }
            if appState.libraryViews != views { appState.libraryViews = views }

            let states = (try? await statesTask) ?? (resume: [], nextUp: [])
            let favs = (try? await favTask)?.items ?? []
            let hot = (try? await hotTask) ?? []
            let animeHot = (await animeHotTask) ?? []

            guard isCurrentGeneration() else { return }
            if appState.resumeItems != states.resume { appState.resumeItems = states.resume }
            if appState.nextUpItems != states.nextUp { appState.nextUpItems = states.nextUp }
            if appState.favoriteItems != favs { appState.favoriteItems = favs }
            if self.hotItems != hot { self.hotItems = hot }
            if self.animeHotItems != animeHot { self.animeHotItems = animeHot }

            let homePrewarmTargets = Array((states.resume + states.nextUp).filter { !$0.isSeries }.prefix(3))
            if !homePrewarmTargets.isEmpty {
                let targetSrv = workingServer
                Task.detached(priority: .utility) {
                    for target in homePrewarmTargets {
                        _ = try? await UHDStreamClient.shared.fetchAssetMediaSources(server: targetSrv, item: target)
                    }
                }
            }

            var latestMap: [String: [EmbyItem]] = [:]
            var topRatedCandidates: [EmbyItem] = []
            let hadCachedLatest = !appState.latestByLibrary.isEmpty
            let hideWatched = appState.hideWatchedInLatest

            await withTaskGroup(of: (String, [EmbyItem], [EmbyItem]).self) { group in
                let targetSrv = workingServer
                for (idx, view) in views.enumerated() {
                    let fetchTopRated = idx < 4
                    group.addTask {
                        async let latestFetch = UHDStreamClient.shared.fetchCollectionItems(
                            server: targetSrv,
                            collectionId: view.id,
                            mediaType: nil,
                            sortBy: "asset_updated_at",
                            sortOrder: "desc",
                            limit: 16
                        )
                        async let topFetch: [EmbyItem] = fetchTopRated
                            ? ((try? await UHDStreamClient.shared.fetchCollectionItems(
                                server: targetSrv,
                                collectionId: view.id,
                                mediaType: nil,
                                sortBy: "rating",
                                sortOrder: "desc",
                                limit: 12
                            ).items) ?? [])
                            : []

                        let fetched = (try? await latestFetch.items) ?? []
                        let filtered = hideWatched ? fetched.filter { $0.userData?.played != true } : fetched
                        let topItems = await topFetch
                        return (view.id, filtered, topItems)
                    }
                }
                for await (viewId, items, topItems) in group {
                    guard isCurrentGeneration() else { return }
                    latestMap[viewId] = items
                    if !hadCachedLatest && appState.latestByLibrary[viewId] != items {
                        appState.latestByLibrary[viewId] = items
                    }
                    topRatedCandidates.append(contentsOf: topItems)
                }
            }

            guard isCurrentGeneration() else { return }
            appState.finalizeHomeContent(
                for: server.id,
                libraryViews: views,
                resumeItems: states.resume,
                nextUpItems: states.nextUp,
                favoriteItems: favs,
                latestByLibrary: latestMap,
                extraHeroCandidates: topRatedCandidates
            )
        } catch {
            guard isCurrentGeneration() else { return }
            let isAuthExpired: Bool = {
                if let clientErr = error as? EmbyClientError {
                    if case .unauthorized = clientErr { return true }
                    if case .httpStatus(401, _) = clientErr { return true }
                }
                return false
            }()
            if isAuthExpired,
               server.keepSignedIn,
               !server.username.isEmpty,
               !server.password.isEmpty,
               let outcome = try? await UHDStreamClient.shared.loginWithAutoFallback(
                    username: server.username,
                    password: server.password
               ) {
                if let idx = appState.servers.firstIndex(where: { $0.id == server.id }) {
                    appState.servers[idx].host = outcome.host
                    appState.servers[idx].isHttps = outcome.isHttps
                    appState.servers[idx].port = outcome.port
                    appState.servers[idx].accessToken = outcome.auth.token
                    appState.servers[idx].tokenExpiresAt = outcome.auth.expiresAt
                    appState.servers[idx].lastLoginDate = Date()
                }
                await appState.loadActiveServerHome(syncDomains: false)
                return
            }
            if isAuthExpired, let idx = appState.servers.firstIndex(where: { $0.id == server.id }) {
                appState.servers[idx].accessToken = ""
                appState.homeErrorMessage = "登录凭证已失效，请重新登录"
            } else {
                appState.homeErrorMessage = error.localizedDescription
            }
            appState.isLoadingHome = false
        }
    }

    // MARK: - Series Resume Resolution (TV Playback State)

    public func resolveSeriesStartEpisode(
        server: EmbyServerConfig,
        seriesItem: EmbyItem
    ) async throws -> (episodes: [EmbyItem], preferredTarget: EmbyItem?) {
        async let seasonsTask = UHDStreamClient.shared.fetchSeasons(server: server, tvId: seriesItem.id)
        async let tvStateTask = try? UHDStreamClient.shared.fetchTVPlaybackState(server: server, tvId: seriesItem.id)
        let seasons = try await seasonsTask
        let tvState = await tvStateTask
        if let preferredEp = tvState?.preferredEpisode,
           let matchedSeason = seasons.first(where: { $0.id == preferredEp.seasonId || $0.indexNumber == preferredEp.seasonNumber }) {
            let eps = try await UHDStreamClient.shared.fetchSeasonEpisodes(
                server: server,
                tvId: seriesItem.id,
                seasonId: matchedSeason.id,
                seasonNumber: matchedSeason.indexNumber,
                seriesName: seriesItem.name,
                posterFallback: matchedSeason.uhdPosterURL ?? seriesItem.uhdPosterURL,
                fanartFallback: seriesItem.uhdBackdropURL,
                logoFallback: seriesItem.uhdLogoURL
            ).items
            return (eps, eps.first(where: { $0.id == preferredEp.episodeId }))
        }
        if let season = seasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? seasons.first {
            let eps = try await UHDStreamClient.shared.fetchSeasonEpisodes(
                server: server,
                tvId: seriesItem.id,
                seasonId: season.id,
                seasonNumber: season.indexNumber,
                seriesName: seriesItem.name,
                posterFallback: season.uhdPosterURL ?? seriesItem.uhdPosterURL,
                fanartFallback: seriesItem.uhdBackdropURL,
                logoFallback: seriesItem.uhdLogoURL
            ).items
            return (eps, nil)
        }
        return ([], nil)
    }

    // MARK: - Watch Party

    public func createAndStartWatchParty(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String? = nil,
        maxMembers: Int = 4,
        appState: AppState
    ) async throws {
        guard isEnabled, server.type == .uhdNative, !server.accessToken.isEmpty else {
            throw EmbyClientError.unauthorized
        }
        await refreshAccountSnapshot(for: server, appState: appState)
        let freshServer = appState.servers.first(where: { $0.id == server.id }) ?? server

        var targetItem = item
        if item.isSeries {
            let seasons = try await UHDStreamClient.shared.fetchSeasons(server: freshServer, tvId: item.id)
            if let firstSeason = seasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? seasons.first {
                let eps = try await UHDStreamClient.shared.fetchSeasonEpisodes(
                    server: freshServer,
                    tvId: item.id,
                    seasonId: firstSeason.id,
                    seasonNumber: firstSeason.indexNumber,
                    seriesName: item.name,
                    posterFallback: firstSeason.uhdPosterURL ?? item.uhdPosterURL,
                    fanartFallback: item.uhdBackdropURL,
                    logoFallback: item.uhdLogoURL
                ).items
                if let firstEp = eps.first {
                    targetItem = firstEp
                }
            }
        }

        let resource = try await UHDStreamClient.shared.resolvePlaybackResource(
            server: freshServer,
            item: targetItem,
            preferredSourceId: preferredSourceId,
            preferredPreset: appState.preferredVersionPreset,
            enable302Cache: appState.enable302Cache && freshServer.cache302Request
        )
        let assetId = resource.mediaSource.id
        let created = try await UHDWatchPartyClient.shared.createRoom(
            server: freshServer,
            assetId: assetId,
            maxMembers: maxMembers
        )

        leaveOrEndActiveWatchParty(endRoom: false, notifyServer: false)
        let uid = freshServer.userId.isEmpty ? (accountSnapshots[freshServer.id]?.subscription?.userId ?? "") : freshServer.userId
        let wpSession = UHDWatchPartySession(
            server: freshServer,
            roomId: created.id,
            inviteCode: created.invite,
            currentUserId: uid
        )
        wpSession.connect()
        self.activeWatchPartySession = wpSession

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(created.invite, forType: .string)
        appState.showToast("已创建同看 · 邀请码 \(UHDLoginCodeNormalizer.formattedDisplay(created.invite)) 已复制", icon: "person.2.wave.2.fill")

        appState.activePlayback = ActivePlaybackSession(
            server: freshServer,
            item: targetItem,
            episodesQueue: [targetItem],
            resource: resource,
            startPositionSeconds: targetItem.resumePositionSeconds,
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil
        )
    }

    public func joinAndStartWatchParty(
        server: EmbyServerConfig,
        rawInvite: String,
        appState: AppState
    ) async throws {
        guard isEnabled, server.type == .uhdNative, !server.accessToken.isEmpty else {
            throw EmbyClientError.unauthorized
        }
        await refreshAccountSnapshot(for: server, appState: appState)
        let freshServer = appState.servers.first(where: { $0.id == server.id }) ?? server
        let roomId = try await UHDWatchPartyClient.shared.joinRoom(server: freshServer, inviteCode: rawInvite)

        leaveOrEndActiveWatchParty(endRoom: false, notifyServer: false)
        let uid = freshServer.userId.isEmpty ? (accountSnapshots[freshServer.id]?.subscription?.userId ?? "") : freshServer.userId
        let normalizedInvite = UHDWatchPartyInviteParser.extractInviteCode(from: rawInvite)
        let wpSession = UHDWatchPartySession(
            server: freshServer,
            roomId: roomId,
            inviteCode: normalizedInvite,
            currentUserId: uid
        )
        wpSession.connect()

        guard let firstSnap = await wpSession.waitForFirstSnapshot(timeoutSeconds: 8.0) else {
            wpSession.disconnect(permanently: true)
            throw EmbyClientError.httpStatus(504, "连接同看房间超时")
        }

        let isEpisode = firstSnap.media.itemType.lowercased() == "episode"
        let stubItem = EmbyItem(
            id: firstSnap.media.itemId,
            name: "同看影片",
            serverId: freshServer.serverId,
            type: isEpisode ? "Episode" : "Movie",
            uhdMediaType: isEpisode ? "episode" : "movie"
        )
        let detailedItem = (try? await UHDStreamClient.shared.fetchItemDetail(server: freshServer, item: stubItem)) ?? stubItem
        let resource = try await UHDStreamClient.shared.resolvePlaybackResource(
            server: freshServer,
            item: detailedItem,
            preferredSourceId: firstSnap.media.assetId,
            preferredPreset: appState.preferredVersionPreset,
            enable302Cache: appState.enable302Cache && freshServer.cache302Request
        )
        self.activeWatchPartySession = wpSession
        let targetSec = firstSnap.extrapolatedPositionSeconds(estimatedServerNowMs: wpSession.estimatedServerNowMs)
        appState.showToast("已加入同看 · \(detailedItem.name)", icon: "person.2.wave.2.fill")

        appState.activePlayback = ActivePlaybackSession(
            server: freshServer,
            item: detailedItem,
            episodesQueue: [detailedItem],
            resource: resource,
            startPositionSeconds: targetSec,
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil
        )
    }

    public func leaveOrEndActiveWatchParty(endRoom: Bool, notifyServer: Bool = true) {
        guard let wp = activeWatchPartySession else { return }
        activeWatchPartySession = nil
        let srv = wp.server
        let rid = wp.roomId
        wp.disconnect(permanently: true)
        if notifyServer {
            Task {
                if endRoom {
                    try? await UHDWatchPartyClient.shared.endRoom(server: srv, roomId: rid)
                } else {
                    try? await UHDWatchPartyClient.shared.leaveRoom(server: srv, roomId: rid)
                }
            }
        }
    }
}
#endif

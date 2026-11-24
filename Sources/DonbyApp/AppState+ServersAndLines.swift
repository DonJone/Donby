import Foundation
import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

extension AppState {
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
        presentServerEditor(for: draft)
        showToast("已识别服务器「\(draft.name)」", icon: "wand.and.stars")
    }

    public func setDefaultHomeServer(_ server: EmbyServerConfig) {
        let wasDefault = server.isDefaultHome
        for i in servers.indices {
            servers[i].isDefaultHome = wasDefault ? false : (servers[i].id == server.id)
        }
        showToast(wasDefault ? "已取消默认首页" : "已设为默认首页", icon: "house.fill")
    }

    public func connectAndSaveServer(
        _ draft: EmbyServerConfig,
        uhdLoginCode: String? = nil,
        customEndpointOverride: String? = nil
    ) async throws {
        var server = draft
        server.isDemoServer = false
        if server.note == "待配置服务器地址与账号" {
            server.note = ""
        }

        let hasToken = !server.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !server.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var usedChinaOptimizedLine = false

        if isUsingUHDExtension(for: server), let ext = DonbyAppExtensionCenter.shared.plugin {
            let result = try await ext.authenticateAndConfigureServer(
                draft: server,
                loginCode: uhdLoginCode,
                customEndpointOverride: customEndpointOverride,
                autoSyncDomains: autoSyncDomains,
                appState: self
            )
            server = result.server
            usedChinaOptimizedLine = result.usedChinaOptimizedLine
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
        if server.lastLoginDate == nil {
            server.lastLoginDate = Date()
        }
        if !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            servers.removeAll { $0.id != server.id && $0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let selId = server.selectedLineId, !server.backupLines.contains(where: { $0.id == selId }) {
            server.selectedLineId = server.backupLines.first?.id
        }
        updateServerInList(server)
        activeServerId = server.id
        openedServerId = server.id
        selectedLibrary = nil
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()

        let syncedCount = server.autoSyncedLineCount
        if isUsingUHDExtension(for: server) && usedChinaOptimizedLine {
            showToast("已登录 \(server.name) · 中国大陆 CDN", icon: "checkmark.circle.fill")
        } else if syncedCount > 0 {
            showToast("已登录 \(server.name) · \(syncedCount) 条线路", icon: "checkmark.circle.fill")
        } else {
            showToast("已登录 \(server.name)", icon: "checkmark.circle.fill")
        }

        await loadActiveServerHome(syncDomains: false)
    }

    public func isUsingUHDExtension(for server: EmbyServerConfig) -> Bool {
        DonbyAppExtensionCenter.shared.isActive(for: server)
    }

    /// Seamlessly transitions active server views between UHD extension mode and standard Emby mode
    /// whenever the user toggles the optional UHDNow module in Settings.
    public func reloadAfterModuleToggle() {
        homeErrorMessage = nil
        selectedLibrary = nil
        detailStack.removeAll()
        if let srv = activeServer {
            ServerHomeCacheStore.shared.clear(for: srv.id)
            libraryViews = []
            resumeItems = []
            nextUpItems = []
            favoriteItems = []
            latestByLibrary = [:]
            carouselItems = []
            Task {
                await loadActiveServerHome(syncDomains: true)
            }
        }
    }

    public func syncExtDomains(for serverId: UUID, showFeedback: Bool = false) async {
        guard let idx = servers.firstIndex(where: { $0.id == serverId }) else { return }
        var server = servers[idx]
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if showFeedback { showToast("请先配置服务器", icon: "exclamationmark.triangle.fill", isError: true) }
            return
        }
        activeSyncDomainsCount += 1
        isSyncingDomains = true
        defer {
            activeSyncDomainsCount = max(0, activeSyncDomainsCount - 1)
            isSyncingDomains = activeSyncDomainsCount > 0
        }

        if isUsingUHDExtension(for: server), let ext = DonbyAppExtensionCenter.shared.plugin {
            await ext.syncPlaybackDomains(for: serverId, appState: self, showFeedback: showFeedback)
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

    public func switchLineImmediate(to lineId: UUID?, for serverId: UUID, triggerReload: Bool = true) {
        guard let idx = servers.firstIndex(where: { $0.id == serverId }) else { return }
        let sType = servers[idx].type
        servers[idx].selectedLineId = lineId
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: sType) {
            Task { await ext.invalidateCaches(serverId: serverId) }
        }
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
        let extProvider = DonbyMediaServiceRegistry.shared.provider(for: server.type)

        async let mainPing: Int? = { [extProvider] in
            if let extProvider {
                return await extProvider.pingLine(server: server, line: nil)
            } else {
                return await EmbyClient.shared.pingLine(baseURL: mainURL, token: token, timeout: pingTimeout)
            }
        }()

        var linePings: [UUID: Int?] = [:]
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for line in backupSnapshot {
                group.addTask {
                    let ms: Int? = if let extProvider {
                        await extProvider.pingLine(server: server, line: line)
                    } else {
                        await EmbyClient.shared.pingLine(baseURL: line.url, token: token, timeout: pingTimeout)
                    }
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

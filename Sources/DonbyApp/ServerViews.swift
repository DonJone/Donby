import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
#if canImport(DonbyUHDModule)
import DonbyUHDModule
#endif

public struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    #if canImport(DonbyUHDModule)
    @ObservedObject private var uhdModule = UHDModuleManager.shared
    #endif
    @State private var searchText: String = ""
    @State private var showDisplayOptionsPopover: Bool = false
    @State private var isRefreshingAllServers: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 256), spacing: 18)
    ]

    public init() {}

    private var filteredServers: [EmbyServerConfig] {
        var list = appState.servers
        if appState.hideEncryptedServers { list = list.filter { !$0.isEncrypted } }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || $0.note.lowercased().contains(q)
                    || $0.host.lowercased().contains(q)
                    || $0.username.lowercased().contains(q)
            }
        }
        return list
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if appState.isSidebarCollapsed {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            appState.isSidebarCollapsed = false
                        }
                    } label: {
                        DonbyToolbarCircleView(systemName: "sidebar.left")
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padding(.leading, appState.collapsedSidebarLeadingPadding)
                }

                Text("服务器")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                ToolbarVectorButton(
                    tooltip: "刷新服务器",
                    action: {
                        guard !isRefreshingAllServers else { return }
                        Task {
                            isRefreshingAllServers = true
                            defer { isRefreshingAllServers = false }
                            let snapshot = appState.servers
                            await withTaskGroup(of: Void.self) { group in
                                for srv in snapshot {
                                    group.addTask { @MainActor in
                                        await appState.syncExtDomains(for: srv.id, showFeedback: false)
                                        await appState.refreshServerCapabilities(for: srv)
                                    }
                                }
                            }
                            appState.showToast("已刷新服务器状态", icon: "checkmark.circle.fill")
                        }
                    }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    RefreshVectorIcon(
                        size: 14.5,
                        color: iconColor,
                        isSpinning: isRefreshingAllServers || appState.isSyncingDomains
                    )
                }

                ToolbarVectorButton(
                    tooltip: "添加服务",
                    action: {
                        appState.presentServerEditor()
                    }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    PlusVectorIcon(size: 14, color: iconColor)
                }

                ToolbarVectorButton(
                    tooltip: appState.hideEncryptedServers ? "显示加密服务器" : "隐藏加密服务器",
                    isActive: appState.hideEncryptedServers,
                    action: {
                        appState.hideEncryptedServers.toggle()
                        appState.showToast(
                            appState.hideEncryptedServers ? "已隐藏加密的文件或服务器" : "已显示加密的文件或服务器",
                            icon: appState.hideEncryptedServers ? "lock.slash.fill" : "lock.open.fill"
                        )
                    }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    Image(systemName: appState.hideEncryptedServers ? "lock.fill" : "lock.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconColor)
                }

                ToolbarVectorButton(
                    tooltip: "卡片显示选项",
                    isActive: showDisplayOptionsPopover,
                    action: { showDisplayOptionsPopover.toggle() }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    MoreDotsVectorIcon(size: 15, color: iconColor)
                }
                .popover(isPresented: $showDisplayOptionsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("卡片显示项")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Toggle("显示连接状态", isOn: $appState.displayConnectionStatus)
                        Toggle("显示媒体统计", isOn: $appState.displayMediaStatistics)
                        Toggle("显示服务器图标", isOn: $appState.displayServerIcon)
                        Toggle("显示观看时间", isOn: $appState.displayWatchTime)
                        Toggle("显示搜索框", isOn: $appState.displaySearchBox)
                        Toggle("卡片光晕质感", isOn: $appState.displayAeroGlass)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .padding(14)
                    .frame(width: 195)
                }

                if appState.displaySearchBox {
                    DonbySearchPillField(placeholder: "搜索服务器", text: $searchText, width: 210)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 54)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(filteredServers) { server in
                        ServerCardView(server: server)
                    }

                    AddServerDashedCard {
                        appState.presentServerEditor()
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .task(id: appState.servers.count) {
            #if canImport(DonbyUHDModule)
            guard uhdModule.isEnabled else { return }
            for srv in appState.servers where srv.type == .uhdNative && !srv.host.isEmpty && !srv.accessToken.isEmpty {
                if uhdModule.accountSnapshots[srv.id] == nil {
                    await uhdModule.refreshAccountSnapshot(for: srv, appState: appState)
                }
            }
            #endif
        }
    }
}

private struct AddServerDashedCard: View {
    @EnvironmentObject private var appState: AppState
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                Text("添加服务")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered ? (appState.isLightMode ? Color.black.opacity(0.025) : Color.white.opacity(0.045)) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isHovered ? DonbyGlassPalette.separator(isLight: appState.isLightMode).opacity(1.6) : DonbyGlassPalette.separator(isLight: appState.isLightMode),
                        style: StrokeStyle(lineWidth: 1.0, dash: [5, 5])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

public struct ServerCardView: View {
    @EnvironmentObject private var appState: AppState
    #if canImport(DonbyUHDModule)
    @ObservedObject private var uhdModule = UHDModuleManager.shared
    #endif
    public let server: EmbyServerConfig
    @State private var isHovered: Bool = false

    private var isUnconfigured: Bool {
        server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasValidSession: Bool {
        !isUnconfigured && (!server.accessToken.isEmpty || !server.password.isEmpty)
    }

    private var uhdTrafficSummaryText: String? {
        #if canImport(DonbyUHDModule)
        guard uhdModule.isActive(for: server),
              let traffic = uhdModule.accountSnapshots[server.id]?.traffic else { return nil }
        return traffic.shortToolbarBadgeText
        #else
        return nil
        #endif
    }

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        Button {
            if isUnconfigured || !hasValidSession {
                #if canImport(DonbyUHDModule)
                let preferred: ServerType? = (uhdModule.isEnabled && server.usesUHDLogo) ? .uhdNative : nil
                #else
                let preferred: ServerType? = nil
                #endif
                appState.presentServerEditor(for: server, preferredType: preferred)
            } else {
                appState.openServer(server)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))

                if appState.displayAeroGlass && !appState.isLightMode {
                    RadialGradient(
                        colors: [
                            Color(red: 0.12, green: 0.32, blue: 0.64).opacity(0.36),
                            Color(red: 0.10, green: 0.22, blue: 0.44).opacity(0.12),
                            Color.clear
                        ],
                        center: .topTrailing,
                        startRadius: 4,
                        endRadius: 128
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(server.name.isEmpty ? server.host : server.name)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .lineLimit(1)

                            if isUnconfigured {
                                Text("待配置")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14))
                                    .clipShape(Capsule())
                            } else if appState.displayConnectionStatus {
                                Circle()
                                    .fill(hasValidSession ? Color(red: 0.22, green: 0.84, blue: 0.36) : Color.orange)
                                    .frame(width: 5.5, height: 5.5)
                            }
                        }

                        Spacer()

                        if appState.displayServerIcon {
                            ServerIconView(server: server, size: 30)
                                .offset(y: 1)
                        }
                    }

                    Spacer()

                    if !isUnconfigured {
                        if let trafficText = uhdTrafficSummaryText {
                            HStack(spacing: 6) {
                                if !server.username.isEmpty {
                                    Text(server.username)
                                        .lineLimit(1)
                                    Text("·")
                                }
                                Text(trafficText)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .padding(.bottom, 7)
                        } else if appState.displayMediaStatistics && (server.movieCount > 0 || server.episodeCount > 0) {
                            HStack(spacing: 10) {
                                HStack(spacing: 4) {
                                    Image(systemName: "movieclapper")
                                        .font(.system(size: 10.5))
                                    Text(String(server.movieCount))
                                        .font(.system(size: 12, weight: .regular))
                                }

                                HStack(spacing: 4) {
                                    Image(systemName: "play.tv")
                                        .font(.system(size: 10.5))
                                    Text(String(server.episodeCount))
                                        .font(.system(size: 12, weight: .regular))
                                }
                            }
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .padding(.bottom, 7)
                        }
                    }

                    HStack {
                        if isUnconfigured {
                            HStack(spacing: 5) {
                                Image(systemName: "person.badge.key")
                                    .font(.system(size: 11, weight: .medium))
                                Text("点击登录")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(appState.accentColor)
                            .lineLimit(1)
                            Spacer()
                        } else {
                            Text(server.note.isEmpty ? server.activeLineName : server.note)
                                .font(.system(size: 12))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .lineLimit(1)
                            Spacer()
                            if appState.displayWatchTime && !server.relativeWatchTimeText.isEmpty {
                                Text(server.relativeWatchTimeText)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isHovered ? appState.accentColor.opacity(0.45) : DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { ServerContextMenuItems(server: server) }
    }
}

public struct ServerContextMenuItems: View {
    @EnvironmentObject private var appState: AppState
    #if canImport(DonbyUHDModule)
    @ObservedObject private var uhdModule = UHDModuleManager.shared
    #endif
    public let server: EmbyServerConfig

    public var body: some View {
        Button { appState.openServer(server) } label: { Label("打开媒体库", systemImage: "play.tv") }
        Button { appState.linePickerServer = server } label: {
            Label(server.type == .uhdNative ? "线路与测速" : "切换线路", systemImage: server.type == .uhdNative ? "speedometer" : "bolt.horizontal.icloud")
        }
        #if canImport(DonbyUHDModule)
        if uhdModule.isActive(for: server) {
            Button { uhdModule.accountSheetServer = server } label: { Label("账户与流量", systemImage: "gauge.with.dots.needle.67percent") }
            Button {
                appState.activeServerId = server.id
                uhdModule.showWatchPartyJoinSheet = true
            } label: { Label("加入同看", systemImage: "person.2.wave.2") }
        }
        #endif
        Button { Task { await appState.syncExtDomains(for: server.id, showFeedback: true) } } label: { Label("同步云端线路", systemImage: "arrow.clockwise.icloud") }
        Button { appState.setDefaultHomeServer(server) } label: { Label(server.isDefaultHome ? "取消默认首页" : "设为默认首页", systemImage: "house") }
        Divider()
        Button {
            appState.presentServerEditor(for: server)
        } label: { Label("修改配置", systemImage: "square.and.pencil") }
        Button {
            var updated = server
            updated.iconURL = (server.iconURL == "uhd") ? "emby" : "uhd"
            appState.updateServerInList(updated)
            appState.showToast("已切换图标", icon: "photo")
        } label: { Label("切换图标", systemImage: "photo") }
        #if canImport(DonbyUHDModule)
        if uhdModule.isActive(for: server) && !server.accessToken.isEmpty {
            Button {
                Task { await uhdModule.logoutServer(server, appState: appState) }
            } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
        }
        #endif
        Button(role: .destructive) { appState.deleteServer(server) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - Line Picker Sheet (Core Donby + Optional UHD Speed Test Extension)

public struct ServerLinePickSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let serverId: UUID

    private enum SheetTab: String, CaseIterable, Identifiable {
        case lines = "线路"
        case account = "账户"
        var id: String { rawValue }
    }

    @State private var activeTab: SheetTab = .lines
    #if canImport(DonbyUHDModule)
    @ObservedObject private var uhdModule = UHDModuleManager.shared
    @StateObject private var speedModel = UHDSpeedTestSessionModel()
    #endif

    private var server: EmbyServerConfig? { appState.servers.first(where: { $0.id == serverId }) }

    private var isUHDExtensionActive: Bool {
        #if canImport(DonbyUHDModule)
        return uhdModule.isActive(for: server)
        #else
        return false
        #endif
    }

    public init(serverId: UUID) { self.serverId = serverId }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(isUHDExtensionActive ? "线路与测速 · \(server.name)" : "切换线路 · \(server.name)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            if server.autoSyncedLineCount > 0 {
                                Text("\(server.autoSyncedLineCount) 条")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08)))
                            }
                        }
                        Text("当前线路：\(server.activeLineName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }

                    Spacer()

                    if isUHDExtensionActive {
                        Picker("", selection: $activeTab) {
                            ForEach(SheetTab.allCases) { t in Text(t.rawValue).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 136)
                    }

                    ToolbarVectorButton(tooltip: "关闭", action: {
                        #if canImport(DonbyUHDModule)
                        speedModel.cancel()
                        #endif
                        dismiss()
                    }) { hovered in
                        let iconCol = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconCol)
                    }
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                #if canImport(DonbyUHDModule)
                if isUHDExtensionActive && activeTab == .account {
                    UHDAccountDashboardContent(server: server, onDismiss: { dismiss() })
                } else {
                    linesBody(server: server)
                }
                #else
                linesBody(server: server)
                #endif
            }
        }
        .padding(22)
        .frame(width: isUHDExtensionActive ? 610 : 540)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .onDisappear {
            #if canImport(DonbyUHDModule)
            speedModel.cancel()
            #endif
        }
    }

    @ViewBuilder
    private func linesBody(server: EmbyServerConfig) -> some View {
        #if canImport(DonbyUHDModule)
        if isUHDExtensionActive {
            UHDCapabilitySummaryStrip(server: server)
        }
        #endif

        let fastestLineId: UUID? = server.backupLines
            .filter { ($0.lastSpeedMbps ?? 0) > 0 }
            .max { ($0.lastSpeedMbps ?? 0) < ($1.lastSpeedMbps ?? 0) }?.id

        let rowCount = (server.type == .uhdNative && !server.backupLines.isEmpty) ? server.backupLines.count : (1 + server.backupLines.count)
        let listHeight = min(max(CGFloat(rowCount) * 64, 128), 280)

        ScrollView {
            VStack(spacing: 8) {
                if server.type != .uhdNative || server.backupLines.isEmpty {
                    ServerLineOptionRow(
                        title: "默认主线路",
                        url: server.mainLineURL,
                        latencyMs: server.mainLineLatencyMs,
                        lastSpeedMbps: nil,
                        exitBadge: nil,
                        isAutoSynced: false,
                        isSelected: server.selectedLineId == nil,
                        isFastest: false,
                        isTesting: false,
                        isProbing: false,
                        onProbeExit: nil,
                        onRunSpeedTest: nil
                    ) {
                        appState.switchLineImmediate(to: nil, for: server.id)
                        dismiss()
                    }
                }

                ForEach(server.backupLines) { line in
                    let exitStr: String? = {
                        var parts: [String] = []
                        if let loc = line.lastExitLocation, !loc.isEmpty { parts.append(loc) }
                        if let isp = line.lastExitISP, !isp.isEmpty { parts.append(isp) }
                        return parts.isEmpty ? nil : parts.joined(separator: " · ")
                    }()

                    #if canImport(DonbyUHDModule)
                    let canProbe = isUHDExtensionActive && (line.domainId?.isEmpty == false)
                    let isTestingLine = speedModel.isSpeedTesting && speedModel.testingDomainId == line.domainId
                    let isProbingLine = speedModel.probingDomainId == line.domainId
                    let probeAction: (() -> Void)? = canProbe ? {
                        if let did = line.domainId {
                            Task { await speedModel.probeLineExit(server: server, domainId: did, appState: appState) }
                        }
                    } : nil
                    let speedAction: (() -> Void)? = canProbe ? {
                        if let did = line.domainId, !speedModel.isSpeedTesting {
                            speedModel.launchSingle(server: server, domainId: did, appState: appState)
                        }
                    } : nil
                    #else
                    let isTestingLine = false
                    let isProbingLine = false
                    let probeAction: (() -> Void)? = nil
                    let speedAction: (() -> Void)? = nil
                    #endif

                    ServerLineOptionRow(
                        title: line.name,
                        url: line.url,
                        latencyMs: line.latencyMs,
                        lastSpeedMbps: line.lastSpeedMbps,
                        exitBadge: exitStr,
                        isAutoSynced: line.isAutoSynced,
                        isSelected: server.selectedLineId == line.id,
                        isFastest: fastestLineId == line.id && server.backupLines.count > 1,
                        isTesting: isTestingLine,
                        isProbing: isProbingLine,
                        onProbeExit: probeAction,
                        onRunSpeedTest: speedAction
                    ) {
                        appState.switchLineImmediate(to: line.id, for: server.id)
                        dismiss()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: listHeight)

        #if canImport(DonbyUHDModule)
        if isUHDExtensionActive {
            UHDSpeedTestConsoleView(model: speedModel, server: server)
        }
        #endif

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

            #if canImport(DonbyUHDModule)
            if isUHDExtensionActive {
                UHDProxyRulesPopoverButton()
            }
            #endif

            Spacer()

            if let fastestLineId, server.selectedLineId != fastestLineId {
                Button {
                    appState.switchLineImmediate(to: fastestLineId, for: server.id)
                    dismiss()
                } label: {
                    Text("切换最快")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7.5)
                        .background(Color.green.opacity(0.11))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                #if canImport(DonbyUHDModule)
                speedModel.cancel()
                #endif
                dismiss()
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
            if isUHDExtensionActive {
                await appState.refreshServerCapabilities(for: server)
            }
        }
    }
}

private struct ServerLineOptionRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let url: String
    let latencyMs: Int?
    let lastSpeedMbps: Double?
    let exitBadge: String?
    let isAutoSynced: Bool
    let isSelected: Bool
    let isFastest: Bool
    let isTesting: Bool
    let isProbing: Bool
    let onProbeExit: (() -> Void)?
    let onRunSpeedTest: (() -> Void)?
    let action: () -> Void

    @State private var isHovered: Bool = false

    private var rowBackground: Color {
        if isSelected {
            return appState.accentColor.opacity(appState.isLightMode ? 0.08 : 0.14)
        } else if isHovered {
            return appState.isLightMode ? Color.black.opacity(0.035) : Color.white.opacity(0.07)
        } else {
            return DonbyGlassPalette.cardBackground(isLight: appState.isLightMode)
        }
    }

    private var rowBorderColor: Color {
        if isSelected {
            return appState.accentColor.opacity(0.40)
        } else if isHovered {
            return DonbyGlassPalette.separator(isLight: appState.isLightMode).opacity(1.3)
        } else {
            return DonbyGlassPalette.separator(isLight: appState.isLightMode)
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            Circle()
                .fill(appState.accentColor)
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(appState.accentTextColor)
                )
        } else {
            Circle()
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 1.2)
                .frame(width: 16, height: 16)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 12) {
                    selectionIndicator

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .lineLimit(1)
                            if isFastest {
                                Text("最快")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.green.opacity(0.13))
                                    .clipShape(Capsule())
                            } else if isAutoSynced {
                                Text("云端")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                        }

                        HStack(spacing: 6) {
                            Text(url)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .lineLimit(1)
                            if let exitBadge {
                                Text("· \(exitBadge)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    VStack(alignment: .trailing, spacing: 2) {
                        if let spd = lastSpeedMbps, spd > 0 {
                            Text(String(format: "%.1f Mbps", spd))
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(spd >= 100 ? .green : (spd >= 40 ? appState.accentColor : .orange))
                        }
                        if let latencyMs {
                            Text("\(latencyMs) ms")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(latencyMs < 150 ? .green : (latencyMs < 350 ? .orange : .red))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onProbeExit {
                Button(action: onProbeExit) {
                    Group {
                        if isProbing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .frame(width: 26, height: 26)
                    .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.07))
                    .clipShape(Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("探测出口")
            }

            if let onRunSpeedTest {
                Button(action: onRunSpeedTest) {
                    Group {
                        if isTesting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "speedometer")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(appState.accentColor)
                    .frame(width: 26, height: 26)
                    .background(appState.accentColor.opacity(0.12))
                    .clipShape(Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("线路测速")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: isSelected ? 1.0 : 0.6)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Donby Native Liquid Glass Server Configuration Sheet

public struct ServerConfigSheet: View {
    @EnvironmentObject private var appState: AppState
    #if canImport(DonbyUHDModule)
    @ObservedObject private var uhdModule = UHDModuleManager.shared
    #endif
    @Environment(\.dismiss) private var dismiss

    private enum UHDAuthMode: String, CaseIterable, Identifiable {
        case password = "账号密码"
        case loginCode = "登录码"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    @State private var draft: EmbyServerConfig
    @State private var isEditingExisting: Bool
    @State private var uhdAuthMode: UHDAuthMode = .password
    @State private var uhdLoginCode: String = ""
    @State private var uhdCustomEndpoint: String = ""
    @State private var portText: String = "443"
    @State private var showPassword: Bool = false
    @State private var showAdvanced: Bool = false
    @State private var newLineName: String = ""
    @State private var newLineURL: String = ""
    @State private var isConnecting: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var connectionTestMessage: String? = nil
    @State private var connectionTestSucceeded: Bool = false
    @State private var errorMessage: String? = nil

    private var isUHDEnabled: Bool {
        #if canImport(DonbyUHDModule)
        return uhdModule.isEnabled
        #else
        return false
        #endif
    }

    private var primaryTypes: [ServerType] {
        isUHDEnabled ? [.uhdNative, .emby, .jellyfin] : [.emby, .jellyfin]
    }

    private let extraTypes: [ServerType] = [.feiniu, .plex, .webdav, .smb]

    public init(existingServer: EmbyServerConfig?, preferredType: ServerType? = nil) {
        let uhdRegistered = DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)
        var initial: EmbyServerConfig
        let editing: Bool
        if let existingServer {
            initial = existingServer
            editing = !existingServer.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let preferredType {
                initial.type = preferredType
            } else if !editing && uhdRegistered && existingServer.usesUHDLogo {
                initial.type = .uhdNative
            } else if !editing && !uhdRegistered && initial.type == .uhdNative {
                initial.type = .emby
            }
            if initial.note == "待配置服务器地址与账号" {
                initial.note = ""
            }
        } else {
            let defaultType = preferredType ?? (uhdRegistered ? .uhdNative : .emby)
            initial = EmbyServerConfig(
                name: "",
                type: defaultType,
                host: "",
                port: 443,
                isHttps: true,
                username: "",
                password: "",
                iconURL: defaultType == .uhdNative ? "uhd" : defaultType.rawValue,
                keepSignedIn: true
            )
            editing = false
        }

        self._draft = State(initialValue: initial)
        self._isEditingExisting = State(initialValue: editing)
        self._portText = State(initialValue: initial.port > 0 ? "\(initial.port)" : (initial.isHttps ? "443" : "80"))

        #if canImport(DonbyUHDModule)
        if initial.type == .uhdNative {
            let hostLower = initial.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !hostLower.isEmpty
                && hostLower != UHDModuleEndpoints.primaryChinaOptimizedHost
                && hostLower != UHDModuleEndpoints.fallbackStandardHost {
                self._uhdCustomEndpoint = State(initialValue: initial.mainLineURL)
            }
        }
        #endif

        if initial.type == .uhdNative && initial.password.isEmpty && !initial.accessToken.isEmpty && initial.username.isEmpty {
            self._uhdAuthMode = State(initialValue: .apiKey)
        }
    }

    private func shortTabTitle(for type: ServerType) -> String {
        switch type {
        case .uhdNative: return "UHDNow"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .feiniu: return "飞牛"
        case .plex: return "Plex"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Donby Header
            HStack(spacing: 12) {
                ServerIconView(server: draft, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditingExisting ? "编辑服务" : "添加服务")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(draft.type == .uhdNative ? "自动接入优选节点" : "配置服务器地址与账号")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                if draft.type != .uhdNative {
                    Button { pasteFromClipboard() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 11, weight: .medium))
                            Text("剪贴板识别")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            // Donby Service Type Segmented Bar
            HStack(spacing: 4) {
                ForEach(primaryTypes) { sType in
                    let isSelected = (draft.type == sType)
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            selectServerType(sType)
                        }
                    } label: {
                        Text(shortTabTitle(for: sType))
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(
                                isSelected
                                    ? appState.accentTextColor
                                    : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? appState.accentColor : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    ForEach(extraTypes) { sType in
                        Button {
                            selectServerType(sType)
                        } label: {
                            if draft.type == sType {
                                Label(sType.displayName, systemImage: "checkmark")
                            } else {
                                Text(sType.displayName)
                            }
                        }
                    }
                } label: {
                    let isExtra = extraTypes.contains(draft.type)
                    HStack(spacing: 3) {
                        Text(isExtra ? shortTabTitle(for: draft.type) : "更多")
                            .font(.system(size: 12.5, weight: isExtra ? .semibold : .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(isExtra ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isExtra ? appState.accentColor : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Main Donby Settings-Style Form Card
            VStack(alignment: .leading, spacing: 12) {
                if draft.type == .uhdNative {
                    uhdFormContent
                } else {
                    standardServerFormContent
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            // Keep Signed In & Advanced Options
            HStack(spacing: 12) {
                Toggle("保持登录", isOn: $draft.keepSignedIn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("高级选项")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("显示名称", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                        TextField("备注", text: $draft.note)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }

                    if draft.type == .uhdNative {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("自定义接入地址（留空自动优选节点）", text: $uhdCustomEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Text("默认优先连接中国优化节点，无优化套餐自动回退标准节点")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                    } else {
                        TextField("API Key / 访问令牌（可选）", text: $draft.accessToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("备用线路")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            ForEach(draft.backupLines.filter { !$0.isAutoSynced }) { line in
                                HStack(spacing: 8) {
                                    Text(line.name).font(.system(size: 11.5, weight: .semibold))
                                    Text(line.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button {
                                        draft.backupLines.removeAll { $0.id == line.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 6) {
                                TextField("线路名称", text: $newLineName).textFieldStyle(.roundedBorder).frame(width: 110)
                                TextField("https://...", text: $newLineURL).textFieldStyle(.roundedBorder)
                                Button("新增") {
                                    let clean = newLineURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !clean.isEmpty else { return }
                                    let name = newLineName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.backupLines.append(ServerLineInfo(name: name.isEmpty ? "备用线路 \(draft.backupLines.count + 1)" : name, url: clean, isAutoSynced: false))
                                    newLineName = ""; newLineURL = ""
                                }
                                .disabled(newLineURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                )
            }

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            // Bottom Actions
            HStack(spacing: 10) {
                if isEditingExisting {
                    Button("仅保存") {
                        #if canImport(DonbyUHDModule)
                        if draft.type == .uhdNative {
                            let custom = uhdCustomEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !custom.isEmpty {
                                let parsed = UHDModuleEndpoints.parseEndpointComponents(from: custom)
                                draft.host = parsed.host
                                draft.isHttps = parsed.isHttps
                                draft.port = parsed.port
                            }
                        } else {
                            syncPortFromText()
                        }
                        #else
                        syncPortFromText()
                        #endif
                        if draft.name.isEmpty { draft.name = draft.type == .uhdNative ? "UHDNow" : draft.host }
                        appState.updateServerInList(draft)
                        appState.showToast("已保存 \(draft.name)", icon: "checkmark.circle.fill")
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .disabled(draft.type != .uhdNative && draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7.5)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await saveAndConnect() }
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isEditingExisting ? "保存并登录" : "登录")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(canSubmit ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 7.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(canSubmit ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10)))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isConnecting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 490)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .preferredColorScheme(appState.colorScheme)
    }

    @ViewBuilder
    private var uhdFormContent: some View {
        HStack {
            Text("登录方式")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Spacer()
            Picker("", selection: $uhdAuthMode) {
                ForEach(UHDAuthMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 215)
        }

        Divider().opacity(appState.isLightMode ? 0.25 : 0.10)

        switch uhdAuthMode {
        case .password:
            credentialsFields
        case .loginCode:
            VStack(alignment: .leading, spacing: 6) {
                TextField("8 位数字登录码", text: $uhdLoginCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(fieldBorder)
                    .onChange(of: uhdLoginCode) { _, next in
                        #if canImport(DonbyUHDModule)
                        let formatted = UHDLoginCodeNormalizer.formattedDisplay(next)
                        if formatted != next { uhdLoginCode = formatted }
                        #endif
                    }
                Text("在网页后台「概览 → 设备 → 登录码」生成，3 分钟有效")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        case .apiKey:
            VStack(alignment: .leading, spacing: 6) {
                TextField("粘贴 API Key 或 Stream Token", text: $draft.accessToken)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(fieldBorder)
                Text("支持免密连接，团队主账号可管理成员额度")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        }
    }

    @ViewBuilder
    private var standardServerFormContent: some View {
        HStack(spacing: 8) {
            Picker("", selection: $draft.isHttps) {
                Text("HTTPS").tag(true)
                Text("HTTP").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)
            .onChange(of: draft.isHttps) { _, isHttps in
                if isHttps && (portText == "80" || portText.isEmpty) {
                    portText = "443"; draft.port = 443
                } else if !isHttps && (portText == "443" || portText.isEmpty) {
                    portText = "80"; draft.port = 80
                }
            }

            TextField("服务器地址", text: $draft.host)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(fieldBorder)
                .onChange(of: draft.host) { _, newVal in
                    if newVal.contains("://") {
                        var parsed = ParsedServerImportResult()
                        parsed.isHttps = draft.isHttps
                        ServerTextParser.applyAddress(newVal, to: &parsed)
                        if !parsed.host.isEmpty && parsed.host != newVal {
                            draft.host = parsed.host
                            draft.isHttps = parsed.isHttps
                            draft.port = parsed.port
                            portText = "\(parsed.port)"
                            if !parsed.path.isEmpty { draft.path = parsed.path }
                        }
                    }
                }

            TextField("端口", text: $portText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 64)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(fieldBorder)
                .onChange(of: portText) { _, newVal in
                    let digits = newVal.filter(\.isNumber)
                    if digits != newVal { portText = digits }
                    if let p = Int(digits), p > 0 && p <= 65535 {
                        draft.port = p
                    }
                }
        }

        HStack(spacing: 10) {
            Button {
                Task { await testConnection() }
            } label: {
                HStack(spacing: 5) {
                    if isTestingConnection { ProgressView().controlSize(.mini) }
                    Text("测试连接")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(
                    draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6)
                        : DonbyGlassPalette.primaryText(isLight: appState.isLightMode)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .donbyLiquidGlassCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)

            if let msg = connectionTestMessage {
                HStack(spacing: 4) {
                    Image(systemName: connectionTestSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(connectionTestSucceeded ? .green : .red)
                    Text(msg)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(connectionTestSucceeded ? .green : .red)
                        .lineLimit(1)
                }
            }
            Spacer()
        }

        Divider().opacity(appState.isLightMode ? 0.25 : 0.10)

        credentialsFields
    }

    @ViewBuilder
    private var credentialsFields: some View {
        VStack(spacing: 10) {
            TextField("用户名", text: $draft.username)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .padding(.vertical, 8.5)
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(fieldBorder)

            HStack(spacing: 8) {
                Group {
                    if showPassword {
                        TextField("密码", text: $draft.password)
                    } else {
                        SecureField("密码", text: $draft.password)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8.5)
            .background(fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(fieldBorder)
        }
    }

    private var canSubmit: Bool {
        if draft.type == .uhdNative {
            switch uhdAuthMode {
            case .password:
                return !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !draft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .loginCode:
                #if canImport(DonbyUHDModule)
                return UHDLoginCodeNormalizer.normalize(uhdLoginCode) != nil
                #else
                return false
                #endif
            case .apiKey:
                return !draft.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fieldBackground: Color {
        appState.isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.06)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.65)
    }

    private func selectServerType(_ sType: ServerType) {
        draft.type = sType
        draft.iconURL = (sType == .uhdNative) ? "uhd" : sType.rawValue
        connectionTestMessage = nil
        errorMessage = nil
    }

    private func syncPortFromText() {
        if let p = Int(portText), p > 0 && p <= 65535 {
            draft.port = p
        } else {
            draft.port = draft.isHttps ? 443 : 80
        }
    }

    private func pasteFromClipboard() {
        guard let str = NSPasteboard.general.string(forType: .string),
              let parsed = ServerTextParser.parseClipboardText(str) else {
            errorMessage = "剪贴板中未找到可识别的地址"
            return
        }
        errorMessage = nil
        draft.apply(parsed: parsed, overwriteName: true)
        portText = "\(draft.port)"
    }

    private func normalizeDraftHostAndPort() {
        let trimmedHost = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.contains("://") || trimmedHost.contains(":") {
            var temp = ParsedServerImportResult()
            temp.isHttps = draft.isHttps
            ServerTextParser.applyAddress(trimmedHost, to: &temp)
            if !temp.host.isEmpty {
                draft.host = temp.host
                draft.isHttps = temp.isHttps
                draft.port = temp.port
                portText = "\(temp.port)"
                if draft.path.isEmpty { draft.path = temp.path }
                return
            }
        }
        syncPortFromText()
    }

    private func testConnection() async {
        normalizeDraftHostAndPort()
        errorMessage = nil
        connectionTestMessage = nil
        isTestingConnection = true
        defer { isTestingConnection = false }

        let base = draft.mainLineURL
        let ms = await EmbyClient.shared.pingLine(baseURL: base, token: draft.accessToken, timeout: 6)
        if let ms {
            connectionTestSucceeded = true
            connectionTestMessage = "可达 (\(ms) ms)"
        } else {
            connectionTestSucceeded = false
            connectionTestMessage = "连接超时"
        }
    }

    private func saveAndConnect() async {
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }

        if draft.type != .uhdNative {
            normalizeDraftHostAndPort()
        }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = (draft.type == .uhdNative) ? "UHDNow" : draft.host
        }
        if draft.note == "待配置服务器地址与账号" { draft.note = "" }
        draft.isDemoServer = false

        var submitting = draft
        var codeArg: String? = nil
        var customEndpointArg: String? = nil

        if submitting.type == .uhdNative {
            let trimmedCustom = uhdCustomEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCustom.isEmpty {
                customEndpointArg = trimmedCustom
            } else {
                // Reset host when user uses automatic smart.uhdnow.com -> v1.uhdnow.com routing
                submitting.host = ""
                submitting.isHttps = true
                submitting.port = 443
            }
            switch uhdAuthMode {
            case .password:
                submitting.accessToken = ""
            case .loginCode:
                submitting.password = ""
                submitting.accessToken = ""
                codeArg = uhdLoginCode
            case .apiKey:
                submitting.password = ""
            }
        }

        do {
            try await appState.connectAndSaveServer(
                submitting,
                uhdLoginCode: codeArg,
                customEndpointOverride: customEndpointArg
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

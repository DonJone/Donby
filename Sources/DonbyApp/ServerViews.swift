import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

public struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddServerPopover: Bool = false
    @State private var showDisplayOptionsPopover: Bool = false
    @State private var isRefreshingAllServers: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 236, maximum: 265), spacing: 18)
    ]

    public init() {}

    private var filteredServers: [EmbyServerConfig] {
        var list = appState.servers
        if appState.hideEncryptedServers { list = list.filter { !$0.isEncrypted } }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q) || $0.host.lowercased().contains(q) || $0.username.lowercased().contains(q) }
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
                    .padding(.leading, appState.collapsedSidebarLeadingPadding)
                }

                Text("服务器")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                ToolbarVectorButton(
                    tooltip: "刷新服务器状态与额度",
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
                    isActive: showAddServerPopover,
                    action: {
                        appState.editingServer = nil
                        appState.showAddServerSheet = true
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
                        appState.editingServer = nil
                        appState.showAddServerSheet = true
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
            for srv in appState.servers where srv.type == .uhdNative && !srv.host.isEmpty && !srv.accessToken.isEmpty {
                if appState.uhdAccountSnapshots[srv.id] == nil {
                    await appState.refreshServerCapabilities(for: srv)
                }
            }
        }
    }
}

private struct AddServerDashedCard: View {
    @EnvironmentObject private var appState: AppState
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isHovered ? appState.accentColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                Text("添加服务")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 138)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered ? (appState.isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.05)) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isHovered ? appState.accentColor.opacity(0.55) : DonbyGlassPalette.separator(isLight: appState.isLightMode).opacity(1.2),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
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
    public let server: EmbyServerConfig
    @State private var isHovered: Bool = false

    private var isUnconfigured: Bool {
        server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasValidSession: Bool {
        !isUnconfigured && (!server.accessToken.isEmpty || !server.password.isEmpty)
    }

    private var uhdSnapshot: UHDAccountSnapshot? {
        server.type == .uhdNative ? appState.uhdAccountSnapshots[server.id] : nil
    }

    private static let loginDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name.isEmpty ? server.host : server.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .lineLimit(1)

                        if !server.username.isEmpty {
                            Text(server.username)
                                .font(.system(size: 11.5))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .lineLimit(1)
                        } else if server.type == .uhdNative && !isUnconfigured {
                            Text("UHD 原生接口")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if appState.displayServerIcon {
                        ServerIconView(server: server, size: 30)
                            .offset(y: 1)
                    }
                }

                Spacer(minLength: 8)

                if isUnconfigured {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("待配置")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.bottom, 6)
                } else if appState.displayConnectionStatus {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hasValidSession ? Color(red: 0.22, green: 0.80, blue: 0.36) : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(hasValidSession ? "登录有效" : "需要重新登录")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(hasValidSession ? DonbyGlassPalette.secondaryText(isLight: appState.isLightMode) : .orange)

                        Spacer(minLength: 4)

                        if let snap = uhdSnapshot, let traffic = snap.traffic {
                            Text(traffic.shortToolbarBadgeText)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(appState.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(appState.accentColor.opacity(appState.isLightMode ? 0.10 : 0.18))
                                .clipShape(Capsule())
                                .lineLimit(1)
                        } else if appState.displayMediaStatistics && (server.movieCount > 0 || server.episodeCount > 0) {
                            HStack(spacing: 6) {
                                Text("\(server.movieCount)片")
                                Text("\(server.episodeCount)集")
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                    }
                    .padding(.bottom, 6)
                }

                HStack {
                    if isUnconfigured {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 11, weight: .medium))
                            Text("点击填写服务器与账号")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(appState.accentColor)
                        .lineLimit(1)
                        Spacer()
                    } else {
                        let leftLabel: String = {
                            if let plan = uhdSnapshot?.subscription?.plan?.name, !plan.isEmpty {
                                return plan
                            }
                            return server.note.isEmpty ? server.activeLineName : server.note
                        }()
                        Text(leftLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                        Spacer()
                        if appState.displayWatchTime {
                            let timeStr: String = {
                                if !server.relativeWatchTimeText.isEmpty {
                                    return server.relativeWatchTimeText
                                }
                                if let loginDate = server.lastLoginDate {
                                    return "登录 \(Self.loginDateFormatter.string(from: loginDate))"
                                }
                                return ""
                            }()
                            Text(timeStr)
                                .font(.system(size: 11))
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
        .frame(height: 138)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovered ? appState.accentColor.opacity(0.50) : DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isUnconfigured || !hasValidSession {
                appState.editingServer = server
                appState.showAddServerSheet = true
            } else {
                appState.openServer(server)
            }
        }
        .contextMenu { ServerContextMenuItems(server: server) }
    }
}

public struct ServerContextMenuItems: View {
    @EnvironmentObject private var appState: AppState
    public let server: EmbyServerConfig

    public var body: some View {
        Button { appState.openServer(server) } label: { Label("打开媒体库", systemImage: "play.tv") }
        Button { appState.linePickerServer = server } label: { Label(server.type == .uhdNative ? "线路与测速中心" : "切换线路", systemImage: server.type == .uhdNative ? "speedometer" : "bolt.horizontal.icloud") }
        if server.type == .uhdNative {
            Button { appState.uhdAccountSheetServer = server } label: { Label("账户与流量余额", systemImage: "gauge.with.dots.needle.67percent") }
            Button {
                appState.activeServerId = server.id
                appState.showUHDWatchPartyJoinSheet = true
            } label: { Label("加入同看房间", systemImage: "person.2.wave.2") }
        }
        Button { Task { await appState.syncExtDomains(for: server.id, showFeedback: true) } } label: { Label("同步云端线路", systemImage: "arrow.clockwise.icloud") }
        Button { appState.setDefaultHomeServer(server) } label: { Label(server.isDefaultHome ? "取消默认首页" : "设为默认首页", systemImage: "house") }
        Divider()
        Button {
            appState.editingServer = server
            appState.showAddServerSheet = true
        } label: { Label("修改配置", systemImage: "square.and.pencil") }
        Button {
            var updated = server
            updated.iconURL = (server.iconURL == "uhd") ? "emby" : "uhd"
            appState.updateServerInList(updated)
            appState.showToast("已切换图标", icon: "photo")
        } label: { Label("切换图标", systemImage: "photo") }
        if server.type == .uhdNative && !server.accessToken.isEmpty {
            Button {
                Task { await appState.logoutUHDServer(server) }
            } label: { Label("退出当前登录", systemImage: "rectangle.portrait.and.arrow.right") }
        }
        Button(role: .destructive) { appState.deleteServer(server) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - Line Picker & Pro-Grade UHD Speed Test Center

public struct ServerLinePickSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let serverId: UUID

    private enum SheetTab: String, CaseIterable, Identifiable {
        case lines = "线路与测速"
        case account = "套餐与余额"
        var id: String { rawValue }
    }

    @State private var activeTab: SheetTab = .lines
    @State private var selectedSizeMiB: Int = 32
    @State private var isSpeedTesting: Bool = false
    @State private var isBatchTesting: Bool = false
    @State private var testingDomainId: String? = nil
    @State private var probingDomainId: String? = nil
    @State private var liveProgress: UHDSpeedTestProgress? = nil
    @State private var liveNetworkInfo: UHDSpeedTestNetworkInfo? = nil
    @State private var liveResolvedHost: String = ""
    @State private var lastResult: UHDSpeedTestResult? = nil
    @State private var speedTestError: String? = nil
    @State private var speedTestTask: Task<Void, Never>? = nil
    @State private var showProxyRulesPopover: Bool = false

    private var server: EmbyServerConfig? { appState.servers.first(where: { $0.id == serverId }) }

    public init(serverId: UUID) { self.serverId = serverId }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(server.type == .uhdNative ? "线路与测速 · \(server.name)" : "切换线路 · \(server.name)")
                                .font(.system(size: 16.5, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            if server.autoSyncedLineCount > 0 {
                                HStack(spacing: 4) {
                                    RouteSwitchVectorIcon(size: 9.5, color: appState.accentColor)
                                    Text("云端 \(server.autoSyncedLineCount) 条")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(appState.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(appState.accentColor.opacity(appState.isLightMode ? 0.10 : 0.15)))
                            }
                        }
                        Text("当前使用：\(server.activeLineName) · 点击即可切换")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }

                    Spacer()

                    if server.type == .uhdNative {
                        Picker("", selection: $activeTab) {
                            ForEach(SheetTab.allCases) { t in Text(t.rawValue).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 175)
                    }

                    ToolbarVectorButton(tooltip: "关闭", action: {
                        speedTestTask?.cancel()
                        dismiss()
                    }) { hovered in
                        let iconCol = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconCol)
                    }
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                if server.type == .uhdNative && activeTab == .account {
                    UHDAccountDashboardContent(server: server, onDismiss: { dismiss() })
                } else {
                    linesAndSpeedTestBody(server: server)
                }
            }
        }
        .padding(22)
        .frame(width: 630)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .onDisappear {
            speedTestTask?.cancel()
        }
    }

    @ViewBuilder
    private func linesAndSpeedTestBody(server: EmbyServerConfig) -> some View {
        if server.type == .uhdNative {
            uhdCapabilityBanner(server: server)
        }

        let fastestLineId: UUID? = server.backupLines
            .filter { ($0.lastSpeedMbps ?? 0) > 0 }
            .max { ($0.lastSpeedMbps ?? 0) < ($1.lastSpeedMbps ?? 0) }?.id

        let rowCount = (server.type == .uhdNative && !server.backupLines.isEmpty) ? server.backupLines.count : (1 + server.backupLines.count)
        let listHeight = min(max(CGFloat(rowCount) * 66, 130), 285)

        ScrollView {
            VStack(spacing: 8) {
                if server.type != .uhdNative || server.backupLines.isEmpty {
                    ServerLineOptionRow(
                        title: "默认主线路",
                        url: server.mainLineURL,
                        latencyMs: server.mainLineLatencyMs,
                        lastSpeedMbps: nil,
                        lastPeakMbps: nil,
                        exitBadge: nil,
                        isAutoSynced: false,
                        isSelected: server.selectedLineId == nil,
                        isFastest: false,
                        isTesting: false,
                        isProbing: false,
                        accentColor: appState.accentColor,
                        onProbeExit: nil,
                        onRunSpeedTest: nil
                    ) {
                        appState.switchLineImmediate(to: nil, for: server.id)
                        dismiss()
                    }
                }

                ForEach(server.backupLines) { line in
                    let isUHDLine = (server.type == .uhdNative && line.domainId?.isEmpty == false)
                    let exitStr: String? = {
                        var parts: [String] = []
                        if let loc = line.lastExitLocation, !loc.isEmpty { parts.append(loc) }
                        if let isp = line.lastExitISP, !isp.isEmpty { parts.append(isp) }
                        return parts.isEmpty ? nil : parts.joined(separator: " · ")
                    }()
                    ServerLineOptionRow(
                        title: line.name,
                        url: line.url,
                        latencyMs: line.latencyMs,
                        lastSpeedMbps: line.lastSpeedMbps,
                        lastPeakMbps: line.lastPeakMbps,
                        exitBadge: exitStr,
                        isAutoSynced: line.isAutoSynced,
                        isSelected: server.selectedLineId == line.id,
                        isFastest: fastestLineId == line.id && server.backupLines.count > 1,
                        isTesting: isSpeedTesting && testingDomainId == line.domainId,
                        isProbing: probingDomainId == line.domainId,
                        accentColor: appState.accentColor,
                        onProbeExit: isUHDLine ? {
                            if let did = line.domainId {
                                Task { await probeLineExit(server: server, domainId: did) }
                            }
                        } : nil,
                        onRunSpeedTest: isUHDLine ? {
                            if let did = line.domainId, !isSpeedTesting {
                                launchSingleSpeedTest(server: server, domainId: did)
                            }
                        } : nil
                    ) {
                        appState.switchLineImmediate(to: line.id, for: server.id)
                        dismiss()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: listHeight)

        if server.type == .uhdNative {
            uhdSpeedTestConsole(server: server, fastestLineId: fastestLineId)
        }

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

            if server.type == .uhdNative {
                Button {
                    showProxyRulesPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network.badge.shield.half.filled")
                        Text("分流规则")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7.5)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showProxyRulesPopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("UHD 官方代理与直连分流参考")
                                .font(.system(size: 12.5, weight: .bold))
                            Spacer()
                            Button("复制规则") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(UHDProxyRoutingRules.standardRulesText, forType: .string)
                                appState.showToast("已复制分流规则", icon: "doc.on.doc.fill")
                            }
                            .controlSize(.small)
                        }
                        Text(UHDProxyRoutingRules.standardRulesText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("注：将 PROXY 替换为你的代理策略组；探测出口与测速须命中相同策略。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(width: 390)
                }
            }

            Spacer()

            if let fastestLineId, server.selectedLineId != fastestLineId {
                Button {
                    appState.switchLineImmediate(to: fastestLineId, for: server.id)
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                        Text("切换最快线路")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7.5)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                speedTestTask?.cancel()
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("完成")
                }
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
            if server.type == .uhdNative {
                await appState.refreshServerCapabilities(for: server)
            }
        }
    }

    @ViewBuilder
    private func uhdCapabilityBanner(server: EmbyServerConfig) -> some View {
        let snap = appState.uhdAccountSnapshots[server.id]
        let cap = appState.serverCapabilities[server.id]
        HStack(spacing: 10) {
            if let plan = snap?.subscription?.plan?.name ?? cap?.planName {
                Text(plan)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(appState.accentColor)
            }
            if let cap {
                Text("并发 \(cap.activeVideoDeliveryLimit) 路 · \(cap.allowDownload ? "可下载" : "仅在线")")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            if let days = snap?.subscription?.remainingDays {
                Text(days >= 0 ? "剩 \(days) 天" : "已到期")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(days <= 7 ? .orange : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            Spacer()
            if let t = snap?.traffic {
                if t.displayUnlimitedTraffic {
                    Text("已用 \(UHDTrafficSummary.formatBytes(t.usedBytes)) / 不限")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                } else {
                    Text("剩 \(UHDTrafficSummary.formatBytes(t.remainingBytes)) / \(UHDTrafficSummary.formatBytes(t.limitBytes))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func uhdSpeedTestConsole(server: EmbyServerConfig, fastestLineId: UUID?) -> some View {
        let uhdLines = server.backupLines.filter { $0.domainId?.isEmpty == false }
        let activeDomainId = (server.backupLines.first(where: { $0.id == server.selectedLineId }) ?? uhdLines.first)?.domainId

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentColor)
                Text("UHD 线路测速")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Picker("", selection: $selectedSizeMiB) {
                    Text("32 MiB").tag(32)
                    Text("64 MiB").tag(64)
                    Text("100 MiB").tag(100)
                }
                .pickerStyle(.segmented)
                .frame(width: 195)
                .disabled(isSpeedTesting)

                Spacer()

                if isSpeedTesting {
                    Button {
                        speedTestTask?.cancel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9.5))
                            Text("取消测速")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    if let activeDomainId {
                        Button {
                            launchSingleSpeedTest(server: server, domainId: activeDomainId)
                        } label: {
                            Text("测当前线路")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if uhdLines.count > 1 {
                        Button {
                            launchBatchSpeedTest(server: server, lines: uhdLines)
                        } label: {
                            Text("测速全部 (\(uhdLines.count))")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(appState.accentTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(appState.accentColor)
                                .clipShape(Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isSpeedTesting, let prog = liveProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if prog.recentSamplesMbps.count >= 2 {
                        UHDSpeedSparklineChart(
                            samplesMbps: prog.recentSamplesMbps,
                            accentColor: appState.accentColor,
                            isLightMode: appState.isLightMode
                        )
                    }
                    ProgressView(value: prog.fraction)
                        .tint(appState.accentColor)
                    HStack(spacing: 10) {
                        Text(String(format: "实时 %.1f Mbps · 稳态均值 %.1f Mbps · 峰值 %.1f Mbps", prog.currentMbps, prog.averageMbps, prog.peakMbps))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Spacer()
                        Text("\(UHDTrafficSummary.formatBytes(prog.downloadedBytes)) / \(selectedSizeMiB) MiB")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    if let net = liveNetworkInfo {
                        Text("测速节点：\(liveResolvedHost) · 出口：\(net.compactSummary)\(net.ip.isEmpty ? "" : " (\(net.ip))")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }
                }
            } else if isSpeedTesting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解析测速节点并探测出口网络...")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            } else if let res = lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    if res.samplesMbps.count >= 2 {
                        UHDSpeedSparklineChart(
                            samplesMbps: Array(res.samplesMbps.suffix(48)),
                            accentColor: .green,
                            isLightMode: appState.isLightMode
                        )
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(String(format: "均值 %.1f Mbps · 峰值 %.1f Mbps · 耗时 %.1fs (%d MiB)", res.averageMbps, res.peakMbps, Double(res.elapsedMs) / 1000.0, res.sizeMiB))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Spacer()
                        if !res.reportSubmitted {
                            Text("本地保留")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("出口：\(res.networkInfo.compactSummary)\(res.networkInfo.ip.isEmpty ? "" : " · \(res.networkInfo.ip)")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                        Spacer()
                        if !res.networkInfo.country.isEmpty {
                            Text(res.networkInfo.isChinaMainlandExit ? "CN 出口" : "\(res.networkInfo.country) 出口")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(res.networkInfo.isChinaMainlandExit ? .green : .blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((res.networkInfo.isChinaMainlandExit ? Color.green : Color.blue).opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            } else if let speedTestError {
                Text(speedTestError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            } else {
                Text("测速按实际下载字节计入当期流量配额；取消测速不会上报成绩。可先点各线路右侧「探测出口」免费验证分流出口。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        }
        .padding(12)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }

    private func probeLineExit(server: EmbyServerConfig, domainId: String) async {
        guard probingDomainId == nil else { return }
        probingDomainId = domainId
        speedTestError = nil
        defer { probingDomainId = nil }
        do {
            let (resolvedURL, info, ms) = try await UHDStreamClient.shared.probeLineExitNetworkInfo(server: server, domainId: domainId)
            appState.updateUHDLineExitInfo(serverId: server.id, domainId: domainId, info: info, latencyMs: ms)
            liveNetworkInfo = info
            liveResolvedHost = resolvedURL.host ?? resolvedURL.absoluteString
            appState.showToast("出口探测：\(info.compactSummary) (\(ms) ms)", icon: "antenna.radiowaves.left.and.right")
        } catch {
            speedTestError = "出口探测失败: \(error.localizedDescription)"
        }
    }

    private func launchSingleSpeedTest(server: EmbyServerConfig, domainId: String) {
        speedTestTask?.cancel()
        let sizeMiB = selectedSizeMiB
        speedTestTask = Task {
            await executeSingleSpeedTest(server: server, domainId: domainId, sizeMiB: sizeMiB)
            await appState.refreshServerCapabilities(for: server)
        }
    }

    private func launchBatchSpeedTest(server: EmbyServerConfig, lines: [ServerLineInfo]) {
        speedTestTask?.cancel()
        let sizeMiB = selectedSizeMiB
        speedTestTask = Task {
            isBatchTesting = true
            defer { isBatchTesting = false }
            for line in lines {
                if Task.isCancelled { break }
                guard let did = line.domainId, !did.isEmpty else { continue }
                await executeSingleSpeedTest(server: server, domainId: did, sizeMiB: sizeMiB)
            }
            if !Task.isCancelled {
                await appState.refreshServerCapabilities(for: server)
            }
        }
    }

    private func executeSingleSpeedTest(server: EmbyServerConfig, domainId: String, sizeMiB: Int) async {
        speedTestError = nil
        liveProgress = nil
        liveNetworkInfo = nil
        liveResolvedHost = ""
        testingDomainId = domainId
        isSpeedTesting = true
        defer {
            isSpeedTesting = false
            testingDomainId = nil
        }
        do {
            let res = try await UHDStreamClient.shared.runSpeedTest(
                server: server,
                domainId: domainId,
                sizeMiB: sizeMiB,
                onNetworkInfo: { resolvedURL, info in
                    Task { @MainActor in
                        self.liveResolvedHost = resolvedURL.host ?? resolvedURL.absoluteString
                        self.liveNetworkInfo = info
                    }
                },
                onProgress: { prog in
                    Task { @MainActor in
                        self.liveProgress = prog
                    }
                }
            )
            self.lastResult = res
            appState.updateUHDLineSpeedResult(serverId: server.id, domainId: domainId, result: res)
        } catch is CancellationError {
            self.speedTestError = "已取消测速（未上报成绩）"
        } catch {
            self.speedTestError = "测速失败: \(error.localizedDescription)"
        }
    }
}

private struct ServerLineOptionRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let url: String
    let latencyMs: Int?
    let lastSpeedMbps: Double?
    let lastPeakMbps: Double?
    let exitBadge: String?
    let isAutoSynced: Bool
    let isSelected: Bool
    let isFastest: Bool
    let isTesting: Bool
    let isProbing: Bool
    let accentColor: Color
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
                                Text("推荐最快")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.green.opacity(0.14))
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

                        HStack(spacing: 8) {
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
                .help("探测出口地区与运营商（不扣流量）")
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
                .help("对此线路运行下载测速")
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

// MARK: - Modern Minimalist "添加服务" Login Sheet (UHD / Emby / Jellyfin)

public struct ServerConfigSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum UHDAuthMode: String, CaseIterable, Identifiable {
        case password = "账号密码"
        case loginCode = "8位登录码"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    @State private var draft: EmbyServerConfig
    @State private var isEditingExisting: Bool
    @State private var uhdAuthMode: UHDAuthMode = .password
    @State private var uhdLoginCode: String = ""
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

    private let primaryTypes: [ServerType] = [.uhdNative, .emby, .jellyfin]
    private let extraTypes: [ServerType] = [.feiniu, .plex, .webdav, .smb]

    public init(existingServer: EmbyServerConfig?) {
        let initial: EmbyServerConfig
        let editing: Bool
        if let existingServer {
            initial = existingServer
            editing = !existingServer.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            initial = EmbyServerConfig(
                name: "",
                type: .uhdNative,
                host: "",
                port: 443,
                isHttps: true,
                username: "",
                password: "",
                iconURL: "uhd",
                keepSignedIn: true
            )
            editing = false
        }
        self._draft = State(initialValue: initial)
        self._isEditingExisting = State(initialValue: editing)
        self._portText = State(initialValue: initial.port > 0 ? "\(initial.port)" : (initial.isHttps ? "443" : "80"))
        if initial.type == .uhdNative && initial.password.isEmpty && !initial.accessToken.isEmpty && initial.username.isEmpty {
            self._uhdAuthMode = State(initialValue: .apiKey)
        }
    }

    private func shortTabTitle(for type: ServerType) -> String {
        switch type {
        case .uhdNative: return "UHD"
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
            // Top Header
            HStack(alignment: .center) {
                Text(isEditingExisting ? "编辑服务" : "添加服务")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                Button { pasteFromClipboard() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("剪贴板识别")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Centered Protocol Type Segmented Capsule (UHD | Emby | Jellyfin)
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    ForEach(primaryTypes) { sType in
                        let isSelected = (draft.type == sType)
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) {
                                selectServerType(sType)
                            }
                        } label: {
                            Text(shortTabTitle(for: sType))
                                .font(.system(size: 13.5, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(
                                    isSelected
                                        ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode)
                                        : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)
                                )
                                .padding(.horizontal, 18)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(isSelected ? (appState.isLightMode ? Color.white : Color.white.opacity(0.16)) : Color.clear)
                                        .shadow(color: isSelected ? Color.black.opacity(appState.isLightMode ? 0.08 : 0.25) : .clear, radius: 3, y: 1)
                                )
                                .contentShape(Capsule())
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
                                .font(.system(size: 12.5, weight: isExtra ? .bold : .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(isExtra ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isExtra ? (appState.isLightMode ? Color.white : Color.white.opacity(0.16)) : Color.clear)
                        )
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
                .padding(4)
                .background(
                    Capsule(style: .continuous)
                        .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                )
                Spacer()
            }

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
                .background(Color.red.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            // Address Row: [ http | https ]  [ 服务器地址 ]  [ 端口 ]
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    protocolSegmentButton(title: "http", isSelected: !draft.isHttps) {
                        draft.isHttps = false
                        if portText == "443" || portText.isEmpty { portText = "80"; draft.port = 80 }
                    }
                    protocolSegmentButton(title: "https", isSelected: draft.isHttps) {
                        draft.isHttps = true
                        if portText == "80" || portText.isEmpty { portText = "443"; draft.port = 443 }
                    }
                }
                .padding(3)
                .background(
                    Capsule(style: .continuous)
                        .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                )

                TextField(
                    draft.type == .uhdNative ? "服务器地址（用户后台 API 域名）" : "服务器地址",
                    text: $draft.host
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
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
                    .font(.system(size: 13, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 68)
                    .padding(.horizontal, 8)
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

            // Test Connection Row
            HStack(spacing: 10) {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if isTestingConnection {
                            ProgressView().controlSize(.mini)
                        }
                        Text("测试连接")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(
                        draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6)
                            : DonbyGlassPalette.primaryText(isLight: appState.isLightMode)
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(appState.isLightMode ? Color.black.opacity(0.045) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)

                if let msg = connectionTestMessage {
                    HStack(spacing: 5) {
                        Image(systemName: connectionTestSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(connectionTestSucceeded ? .green : .red)
                        Text(msg)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(connectionTestSucceeded ? .green : .red)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if draft.type == .uhdNative {
                    Picker("", selection: $uhdAuthMode) {
                        ForEach(UHDAuthMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 215)
                }
            }

            // Auth Input Fields
            if draft.type == .uhdNative && uhdAuthMode == .loginCode {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("输入 8 位数字登录码（如 0428 1753）", text: $uhdLoginCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(fieldBorder)
                        .onChange(of: uhdLoginCode) { _, next in
                            let formatted = UHDLoginCodeNormalizer.formattedDisplay(next)
                            if formatted != next { uhdLoginCode = formatted }
                        }

                    Text("在 UHD 网页后台「概览 -> 设备 -> 登录码」点击生成，有效期 3 分钟，单次兑换并自动保留前导 0。")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            } else if draft.type == .uhdNative && uhdAuthMode == .apiKey {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("粘贴平台 API Key 或 Stream Token", text: $draft.accessToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(fieldBorder)

                    Text("支持免密直连；若为团队主账号平台 API Key，将自动解锁「团队管理 API v2」面板。")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            } else {
                VStack(spacing: 10) {
                    TextField("用户名", text: $draft.username)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(fieldBorder)
                }
            }

            // Keep Signed In Toggle + Advanced Disclosure
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("保持登录")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Toggle("", isOn: $draft.keepSignedIn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                }

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
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("显示名称（留空自动命名）", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                        TextField("备注（可选）", text: $draft.note)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }

                    if draft.type != .uhdNative {
                        TextField("API Key / 访问令牌（可选，免密直连）", text: $draft.accessToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    if !draft.backupLines.isEmpty || draft.type != .uhdNative {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("自定义备用线路")
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
                                TextField("线路名称", text: $newLineName).textFieldStyle(.roundedBorder).frame(width: 115)
                                TextField("完整地址 https://...", text: $newLineURL).textFieldStyle(.roundedBorder)
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
                .padding(12)
                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                )
            }

            // Bottom Action Buttons: [ 取消 ]  [ 添加 / 保存 ]
            HStack(spacing: 10) {
                if isEditingExisting {
                    Button("仅保存配置") {
                        syncPortFromText()
                        if draft.name.isEmpty { draft.name = draft.host }
                        appState.updateServerInList(draft)
                        appState.showToast("已保存服务器 \(draft.name)", icon: "checkmark.circle.fill")
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 7.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(appState.isLightMode ? Color.white : Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await saveAndConnect() }
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isEditingExisting ? "保存并登录" : "添加")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(canSubmit ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 24)
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
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 520)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .preferredColorScheme(appState.colorScheme)
    }

    private var canSubmit: Bool {
        let hasHost = !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasHost else { return false }
        if draft.type == .uhdNative && uhdAuthMode == .loginCode {
            return UHDLoginCodeNormalizer.normalize(uhdLoginCode) != nil
        }
        return true
    }

    private var fieldBackground: Color {
        appState.isLightMode ? Color.white : Color.white.opacity(0.06)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
    }

    private func protocolSegmentButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                .foregroundStyle(
                    isSelected
                        ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode)
                        : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? (appState.isLightMode ? Color.white : Color.white.opacity(0.16)) : Color.clear)
                        .shadow(color: isSelected ? Color.black.opacity(appState.isLightMode ? 0.06 : 0.20) : .clear, radius: 2, y: 0.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            errorMessage = "剪贴板中未找到可识别的服务器地址"
            return
        }
        errorMessage = nil
        draft.apply(parsed: parsed, overwriteName: true)
        portText = "\(draft.port)"
        if draft.type == .uhdNative && !draft.accessToken.isEmpty && draft.password.isEmpty {
            uhdAuthMode = .apiKey
        }
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
        if draft.type == .uhdNative {
            do {
                let tokenToTest = (uhdAuthMode == .apiKey) ? draft.accessToken : ""
                let res = try await UHDStreamClient.shared.testConnection(baseURL: base, token: tokenToTest)
                connectionTestSucceeded = true
                connectionTestMessage = res.message
            } catch {
                connectionTestSucceeded = false
                connectionTestMessage = error.localizedDescription
            }
        } else {
            let ms = await EmbyClient.shared.pingLine(baseURL: base, token: draft.accessToken, timeout: 6)
            if let ms {
                connectionTestSucceeded = true
                connectionTestMessage = "服务器可达 (\(ms) ms)"
            } else {
                connectionTestSucceeded = false
                connectionTestMessage = "连接超时或服务器不可达"
            }
        }
    }

    private func saveAndConnect() async {
        normalizeDraftHostAndPort()
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }

        if draft.name.isEmpty {
            draft.name = (draft.type == .uhdNative) ? "UHDNow" : draft.host
        }
        if draft.note == "待配置服务器地址与账号" { draft.note = "" }
        draft.isDemoServer = false

        let codeParam: String? = (draft.type == .uhdNative && uhdAuthMode == .loginCode) ? uhdLoginCode : nil

        do {
            try await appState.connectAndSaveServer(draft, uhdLoginCode: codeParam)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

public struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared
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
                    .toggleStyle(
                        DonbyCheckboxToggleStyle(
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor
                        )
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
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
            await extCenter.plugin?.refreshMissingAccountSnapshots(servers: appState.servers, appState: appState)
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
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared
    public let server: EmbyServerConfig
    @State private var isHovered: Bool = false

    private var isUnconfigured: Bool {
        server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasValidSession: Bool {
        !isUnconfigured && (!server.accessToken.isEmpty || !server.password.isEmpty)
    }

    private var uhdTrafficSummaryText: String? {
        extCenter.plugin?.serverCardBadgeText(for: server)
    }

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        Button {
            if isUnconfigured || !hasValidSession {
                let preferred = extCenter.plugin?.preferredEditorType(forUnconfigured: server)
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
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
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
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared
    public let server: EmbyServerConfig

    public var body: some View {
        Button { appState.openServer(server) } label: { Label("打开媒体库", systemImage: "play.tv") }
        Button { appState.linePickerServer = server } label: {
            let extActive = appState.isUsingUHDExtension(for: server)
            Label(extActive ? "线路与测速" : "切换线路", systemImage: extActive ? "speedometer" : "bolt.horizontal.icloud")
        }
        if let plugin = extCenter.plugin {
            plugin.makeServerContextMenuExtraItems(server: server)
        }
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
        if let plugin = extCenter.plugin {
            plugin.makeServerLogoutMenuItem(server: server)
        }
        Button(role: .destructive) { appState.deleteServer(server) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - Line Picker Sheet (Core Donby + Optional Extension Slot)

public struct ServerLinePickSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared
    @Environment(\.dismiss) private var dismiss
    public let serverId: UUID

    private var server: EmbyServerConfig? { appState.servers.first(where: { $0.id == serverId }) }

    public init(serverId: UUID) { self.serverId = serverId }

    public var body: some View {
        if let server,
           let ext = extCenter.plugin,
           ext.isActive(for: server),
           let customView = ext.makeCustomLineSwitchView(serverId: serverId, onDismiss: { dismiss() }) {
            customView
        } else {
            standardLineSwitchBody
        }
    }

    private var standardLineSwitchBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("切换线路")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("\(server.name) · 当前：\(server.activeLineName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }

                    Spacer()

                    ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
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
        .frame(width: 540)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func linesBody(server: EmbyServerConfig) -> some View {
        let rowCount = 1 + server.backupLines.count
        let listHeight = min(max(CGFloat(rowCount) * 60, 124), 260)

        ScrollView {
            VStack(spacing: 8) {
                ServerLineOptionRow(
                    title: "默认主线路",
                    url: ServerLineInfo(name: "默认主线路", url: server.mainLineURL).cleanDisplayHost,
                    lastSpeedMbps: nil,
                    isSelected: server.selectedLineId == nil,
                    isTesting: false,
                    onRunSpeedTest: nil
                ) {
                    appState.switchLineImmediate(to: nil, for: server.id)
                    dismiss()
                }

                ForEach(server.backupLines) { line in
                    ServerLineOptionRow(
                        title: line.cleanDisplayName,
                        url: line.cleanDisplayHost,
                        lastSpeedMbps: line.lastSpeedMbps,
                        isSelected: server.selectedLineId == line.id,
                        isTesting: false,
                        onRunSpeedTest: nil
                    ) {
                        appState.switchLineImmediate(to: line.id, for: server.id)
                        dismiss()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: listHeight)

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

            Spacer()

            Button {
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
    }
}

struct ServerLineOptionRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let url: String
    let lastSpeedMbps: Double?
    let isSelected: Bool
    let isTesting: Bool
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
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .lineLimit(1)

                        Text(url)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if let spd = lastSpeedMbps, spd > 0 {
                        Text(String(format: "%.1f Mbps", spd))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onRunSpeedTest {
                Button(action: onRunSpeedTest) {
                    Group {
                        if isTesting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "speedometer")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    }
                    .foregroundStyle(isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .frame(width: 26, height: 26)
                    .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("测速")
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

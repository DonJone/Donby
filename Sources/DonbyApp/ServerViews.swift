import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyStorage

public struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddServerPopover: Bool = false
    @State private var showDisplayOptionsPopover: Bool = false
    @State private var isRefreshingAllServers: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 224, maximum: 245), spacing: 18)
    ]

    public init() {}

    private var filteredServers: [EmbyServerConfig] {
        var list = appState.servers
        if appState.hideEncryptedServers { list = list.filter { !$0.isEncrypted } }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q) || $0.host.lowercased().contains(q) }
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
                    .padding(.leading, 54)
                }

                Text("服务器")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                ToolbarVectorButton(
                    tooltip: "刷新全部服务器与同步线路",
                    action: {
                        guard !isRefreshingAllServers else { return }
                        Task {
                            isRefreshingAllServers = true
                            defer { isRefreshingAllServers = false }
                            for s in appState.servers {
                                await appState.syncExtDomains(for: s.id, showFeedback: false)
                            }
                            appState.showToast("已刷新所有服务器状态与云端线路", icon: "checkmark.circle.fill")
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
                    tooltip: "新增服务器",
                    isActive: showAddServerPopover,
                    action: { showAddServerPopover.toggle() }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    PlusVectorIcon(size: 14, color: iconColor)
                }
                .popover(isPresented: $showAddServerPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择服务器类型")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)

                        ForEach(ServerType.allCases) { sType in
                            Button {
                                showAddServerPopover = false
                                appState.editingServer = EmbyServerConfig(
                                    name: "",
                                    type: sType,
                                    host: "",
                                    port: 443,
                                    isHttps: true,
                                    username: "",
                                    iconURL: sType == .emby ? "uhd" : sType.rawValue
                                )
                                appState.showAddServerSheet = true
                            } label: {
                                HStack(spacing: 10) {
                                    ServerIconView(
                                        server: EmbyServerConfig(
                                            name: "",
                                            type: sType,
                                            host: "",
                                            username: "",
                                            iconURL: sType == .emby ? "uhd" : sType.rawValue
                                        ),
                                        size: 20
                                    )
                                    Text(sType.displayName)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Divider().padding(.vertical, 4)

                        Button {
                            showAddServerPopover = false
                            importFromClipboard()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 13))
                                    .foregroundStyle(appState.accentColor)
                                    .frame(width: 20)
                                Text("从剪贴板智能拉取")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(appState.accentColor)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .frame(width: 215)
                    .preferredColorScheme(appState.colorScheme)
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
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
    }

    private func importFromClipboard() {
        appState.importServerFromClipboard()
    }
}

public struct ServerCardView: View {
    @EnvironmentObject private var appState: AppState
    public let server: EmbyServerConfig
    @State private var isHovered: Bool = false

    private var isUnconfigured: Bool {
        server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                    HStack(alignment: .center, spacing: 6) {
                        Text(server.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .lineLimit(1)

                        if isUnconfigured {
                            Text("待配置")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.16))
                                .clipShape(Capsule())
                        } else if appState.displayConnectionStatus {
                            Circle()
                                .fill(Color(red: 0.22, green: 0.84, blue: 0.36))
                                .frame(width: 5.5, height: 5.5)
                        }
                    }

                    Spacer()

                    if appState.displayServerIcon {
                        ServerIconView(server: server, size: 30)
                            .offset(y: 2)
                    }
                }

                Spacer()

                if appState.displayMediaStatistics && (server.movieCount > 0 || server.episodeCount > 0) {
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
                        Text(server.note.isEmpty ? server.activeLineName : server.note)
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                        Spacer()
                        if appState.displayWatchTime {
                            Text(server.relativeWatchTimeText)
                                .font(.system(size: 12))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
        }
        .frame(width: 225, height: 124)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovered ? appState.accentColor.opacity(0.50) : DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isUnconfigured {
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
        Button { appState.linePickerServer = server } label: { Label("切换线路", systemImage: "bolt.horizontal.icloud") }
        Button { Task { await appState.syncExtDomains(for: server.id, showFeedback: true) } } label: { Label("同步云端线路", systemImage: "arrow.clockwise.icloud") }
        Button { appState.setDefaultHomeServer(server) } label: { Label(server.isDefaultHome ? "取消默认首页" : "设为默认首页", systemImage: "house") }
        Divider()
        Button {
            appState.editingServer = server
            appState.showAddServerSheet = true
        } label: { Label("修改", systemImage: "square.and.pencil") }
        Button {
            var updated = server
            updated.iconURL = (server.iconURL == "uhd") ? "emby" : "uhd"
            appState.updateServerInList(updated)
            appState.showToast("已切换图标", icon: "photo")
        } label: { Label("切换图标", systemImage: "photo") }
        Button(role: .destructive) { appState.deleteServer(server) } label: { Label("删除", systemImage: "trash") }
    }
}

public struct ServerLinePickSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let serverId: UUID

    private var server: EmbyServerConfig? { appState.servers.first(where: { $0.id == serverId }) }

    public init(serverId: UUID) { self.serverId = serverId }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("切换线路 · \(server.name)")
                                .font(.system(size: 16.5, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            if server.autoSyncedLineCount > 0 {
                                HStack(spacing: 4) {
                                    RouteSwitchVectorIcon(size: 9.5, color: appState.accentColor)
                                    Text("云端 \(server.autoSyncedLineCount) 条线路")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(appState.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule()
                                        .fill(appState.accentColor.opacity(appState.isLightMode ? 0.10 : 0.15))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(appState.accentColor.opacity(0.20), lineWidth: 0.5)
                                )
                            }
                        }
                        Text("当前使用：\(server.activeLineName) · 点击即时切换")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }

                    Spacer()

                    ToolbarVectorButton(
                        tooltip: "关闭",
                        action: { dismiss() }
                    ) { hovered in
                        let iconCol = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconCol)
                    }
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                let rowCount = 1 + server.backupLines.count
                let listHeight = min(max(CGFloat(rowCount) * 62, 128), 312)

                ScrollView {
                    VStack(spacing: 8) {
                        ServerLineOptionRow(
                            title: "默认主线路",
                            url: server.mainLineURL,
                            isAutoSynced: false,
                            isSelected: server.selectedLineId == nil,
                            accentColor: appState.accentColor
                        ) {
                            appState.switchLineImmediate(to: nil, for: server.id)
                            dismiss()
                        }
                        ForEach(server.backupLines) { line in
                            ServerLineOptionRow(
                                title: line.name,
                                url: line.url,
                                isAutoSynced: line.isAutoSynced,
                                isSelected: server.selectedLineId == line.id,
                                accentColor: appState.accentColor
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
                        HStack(spacing: 7) {
                            RefreshVectorIcon(
                                size: 13.5,
                                color: appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(white: 0.90),
                                isSpinning: appState.isSyncingDomains
                            )
                            Text("同步云端线路")
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .donbyLiquidGlassCapsule()
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                            Text("完成")
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7.5)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(22)
        .frame(width: 530)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }
}

private struct ServerLineOptionRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let url: String
    let isAutoSynced: Bool
    let isSelected: Bool
    let accentColor: Color
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
        Button(action: action) {
            HStack(spacing: 12) {
                selectionIndicator

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                        if isAutoSynced {
                            Text("云端同步")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(rowBorderColor, lineWidth: isSelected ? 1.0 : 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

public struct ServerConfigSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: EmbyServerConfig
    @State private var newLineName: String = ""
    @State private var newLineURL: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String? = nil

    public init(existingServer: EmbyServerConfig?) {
        let initial = existingServer ?? EmbyServerConfig(name: "", host: "", port: 443, isHttps: true, username: "", password: "", iconURL: "uhd")
        self._draft = State(initialValue: initial)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.host.isEmpty ? "新增服务器" : "服务配置 · \(draft.name)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("支持 Emby / UHDNow / Jellyfin，自动同步 ServerDomains").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { pasteFromClipboard() } label: {
                    HStack(spacing: 5) { Image(systemName: "doc.on.clipboard"); Text("从剪贴板识别填充") }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(appState.accentColor)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(appState.accentColor.opacity(0.14)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(errorMessage).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(appState.accentColor)
                            Text("服务器连接")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        }

                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                Picker("类型", selection: $draft.type) {
                                    ForEach(ServerType.allCases) { t in Text(t.displayName).tag(t) }
                                }
                                .frame(width: 210)
                                TextField("名称", text: $draft.name).textFieldStyle(.roundedBorder)
                            }
                            HStack(spacing: 12) {
                                Toggle("HTTPS", isOn: $draft.isHttps)
                                TextField("主机地址", text: $draft.host).textFieldStyle(.roundedBorder)
                                TextField("端口", value: $draft.port, format: .number).textFieldStyle(.roundedBorder).frame(width: 85)
                            }
                        }
                    }
                    .padding(14)
                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.key.fill")
                                .foregroundStyle(appState.accentColor)
                            Text("身份认证")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            Spacer()
                            Text("支持账号密码或 API Key 令牌")
                                .font(.system(size: 11))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }

                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("用户名").font(.system(size: 11.5, weight: .medium)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    TextField("如 admin 或 UHDNow 账户", text: $draft.username).textFieldStyle(.roundedBorder)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("密码").font(.system(size: 11.5, weight: .medium)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    SecureField("账号密码 (若有)", text: $draft.password).textFieldStyle(.roundedBorder)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("API Key / 令牌 (可选，UHDNow 免密直连)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    Spacer()
                                    if !draft.accessToken.isEmpty {
                                        Text("已就绪").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
                                    }
                                }
                                TextField("如 a080a78a5355e0093ad18804a6953a6a", text: $draft.accessToken).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(14)
                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.horizontal.icloud.fill")
                                .foregroundStyle(appState.accentColor)
                            Text("多线路与 ServerDomains")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            Spacer()
                            if draft.autoSyncedLineCount > 0 {
                                Text("已同步 \(draft.autoSyncedLineCount) 条云端线路")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(appState.accentColor)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(draft.backupLines) { line in
                                HStack(spacing: 10) {
                                    Image(systemName: line.isAutoSynced ? "cloud.fill" : "network").foregroundStyle(line.isAutoSynced ? appState.accentColor : .secondary)
                                    Text(line.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                    Text(line.url).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)).lineLimit(1)
                                    Spacer()
                                    Button { draft.backupLines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8)) }.buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 8) {
                                TextField("线路名称", text: $newLineName).textFieldStyle(.roundedBorder).frame(width: 145)
                                TextField("线路完整地址", text: $newLineURL).textFieldStyle(.roundedBorder)
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
                    .padding(14)
                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
                    )
                }
            }
            .frame(maxHeight: 380)

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8))
                    .keyboardShortcut(.cancelAction)

                Spacer()
                Button("保存") {
                    if draft.name.isEmpty { draft.name = draft.host }
                    appState.updateServerInList(draft)
                    appState.showToast("已保存服务器 \(draft.name)", icon: "checkmark.circle.fill")
                    dismiss()
                }
                .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await saveAndConnect() }
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text("连接并拉取云端账户").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 8).background(appState.accentColor).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 570)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .preferredColorScheme(appState.colorScheme)
    }

    private func pasteFromClipboard() {
        guard let str = NSPasteboard.general.string(forType: .string),
              let parsed = ServerTextParser.parseClipboardText(str) else {
            errorMessage = "剪贴板中未找到可识别的服务器地址"
            return
        }
        errorMessage = nil
        draft.isDemoServer = false
        draft.name = parsed.name
        draft.note = parsed.note
        draft.type = parsed.type
        draft.host = parsed.host
        draft.port = parsed.port
        draft.isHttps = parsed.isHttps
        draft.path = parsed.path
        if !parsed.username.isEmpty { draft.username = parsed.username }
        if !parsed.password.isEmpty { draft.password = parsed.password }
        if !parsed.accessToken.isEmpty { draft.accessToken = parsed.accessToken }
        if !parsed.userId.isEmpty { draft.userId = parsed.userId }
        if !parsed.backupLines.isEmpty {
            let existingManual = draft.backupLines.filter { !$0.isAutoSynced }
            draft.backupLines = existingManual + parsed.backupLines
        }
    }

    private func saveAndConnect() async {
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }
        if draft.host.contains("://") {
            var temp = ParsedServerImportResult()
            ServerTextParser.applyAddress(draft.host, to: &temp)
            draft.host = temp.host
            draft.port = temp.port
            draft.isHttps = temp.isHttps
            if draft.path.isEmpty { draft.path = temp.path }
        }
        if draft.name.isEmpty { draft.name = draft.host }
        if draft.note == "待配置服务器地址与账号" { draft.note = "" }
        draft.isDemoServer = false

        do {
            try await appState.connectAndSaveServer(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

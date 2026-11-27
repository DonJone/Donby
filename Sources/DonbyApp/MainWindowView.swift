import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork

public struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = AppUpdateManager.shared
    @State private var showDelayedResolvePill: Bool = false
    @State private var escapeKeyMonitor: Any? = nil

    public init() {}

    public var body: some View {
        let isPlaying = (appState.activePlayback != nil)
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if !appState.isSidebarCollapsed {
                    appSidebarView
                        .frame(width: appState.isWindowFullScreen ? 228 : 206)
                        .layoutPriority(1)
                        .background(
                            ZStack {
                                DonbyVisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                                DonbyGlassPalette.sidebar(isLight: appState.isLightMode).opacity(appState.isLightMode ? 0.35 : 0.85)
                            }
                        )

                    Rectangle()
                        .fill(DonbyGlassPalette.separator(isLight: appState.isLightMode))
                        .frame(width: 1)
                }

                let hasDetail = (appState.currentDetailItem != nil)
                ZStack(alignment: .topLeading) {
                    Group {
                        if appState.openedServerId != nil {
                            EmbyMainView()
                        } else {
                            switch appState.selectedTab {
                            case .files:
                                FilesModuleView()
                            case .servers:
                                ServerListView()
                            case .iptv:
                                IPTVModuleView()
                            case .records:
                                RecordsView()
                            case .downloads:
                                DownloadsView()
                            case .search:
                                GlobalSearchView()
                            case .settings:
                                SettingsView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
                    .opacity(hasDetail ? 0 : 1)
                    .allowsHitTesting(!hasDetail)
                    .accessibilityHidden(hasDetail)

                    if let detailItem = appState.currentDetailItem {
                        DetailView(
                            item: detailItem,
                            preferOfflineFocus: appState.detailOfflineFocusIds.contains(detailItem.id)
                        )
                        .id(detailItem.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .ignoresSafeArea(.container, edges: .top)
            .opacity(isPlaying ? 0 : 1)
            .allowsHitTesting(!isPlaying)
            .accessibilityHidden(isPlaying)

            if let playback = appState.activePlayback {
                PlayerView(session: playback)
                    .transition(.opacity)
                    .environment(\.colorScheme, .dark)
                    .preferredColorScheme(.dark)
                    .zIndex(50)
            }

            if appState.activePlayback == nil && showDelayedResolvePill {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在连接媒体...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Button {
                            appState.cancelPendingPlaybackStart()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text("取消")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
                    .padding(.trailing, 24)
                    .padding(.bottom, 22)
                }
                .transition(.opacity)
                .zIndex(95)
            }

            DonbyToastOverlayView(
                store: appState.toastStore,
                isLightMode: appState.activePlayback == nil && appState.isLightMode
            )
            .zIndex(100)
        }
        .task(id: appState.isStartingPlayback) {
            if appState.isStartingPlayback {
                showDelayedResolvePill = false
                try? await Task.sleep(nanoseconds: 120_000_000)
                if !Task.isCancelled && appState.isStartingPlayback && appState.activePlayback == nil {
                    withAnimation(.easeOut(duration: 0.14)) {
                        showDelayedResolvePill = true
                    }
                }
            } else {
                showDelayedResolvePill = false
            }
        }
        .onExitCommand {
            _ = handleBrowseEscape()
        }
        .onAppear {
            if let win = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first {
                appState.isWindowFullScreen = win.styleMask.contains(.fullScreen)
            }
            if let km = escapeKeyMonitor { NSEvent.removeMonitor(km); escapeKeyMonitor = nil }
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                guard RunLoop.current.currentMode != .eventTracking else { return event }
                guard appState.activePlayback == nil else { return event }
                guard event.window?.sheetParent == nil, event.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                guard !(event.window?.firstResponder is NSTextView), !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty else { return event }
                return handleBrowseEscape() ? nil : event
            }
        }
        .onDisappear {
            if let km = escapeKeyMonitor { NSEvent.removeMonitor(km); escapeKeyMonitor = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            appState.isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            appState.isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            appState.isWindowFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            appState.isWindowFullScreen = false
        }
        .sheet(item: $appState.serverEditorRequest) { req in
            ServerConfigSheet(existingServer: req.existingServer, preferredType: req.preferredType)
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
                .tint(appState.accentColor)
        }
        .sheet(item: $appState.linePickerServer) { server in
            ServerLinePickSheet(serverId: server.id)
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
                .tint(appState.accentColor)
        }
        .donbyExtensionSheets()
        .sheet(isPresented: $appState.showLogViewer) {
            LogViewerSheet()
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
                .tint(appState.accentColor)
        }
        .sheet(isPresented: $updater.showUpdatePromptSheet) {
            AppUpdatePromptSheet(
                updater: updater,
                isLightMode: appState.isLightMode,
                accentColor: appState.accentColor,
                accentTextColor: appState.accentTextColor,
                onOpenAboutTab: {
                    updater.showUpdatePromptSheet = false
                    appState.preferredSettingsTabRaw = "关于"
                    appState.selectSidebarModule(.settings)
                }
            )
            .preferredColorScheme(appState.colorScheme)
            .tint(appState.accentColor)
        }
    }

    private func handleBrowseEscape() -> Bool {
        guard appState.activePlayback == nil else { return false }
        if appState.isStartingPlayback {
            appState.cancelPendingPlaybackStart()
            return true
        } else if !appState.detailStack.isEmpty {
            appState.popDetail()
            return true
        } else if appState.selectedLibrary != nil {
            appState.selectedLibrary = nil
            return true
        } else if appState.browsingFolder != nil {
            appState.browsingFolder = nil
            return true
        }
        return false
    }

    private var appSidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if appState.isWindowFullScreen {
                    Text("Donby")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode).opacity(0.88))
                        .padding(.leading, 16)
                        .padding(.top, 4)
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        appState.isSidebarCollapsed = true
                    }
                } label: {
                    DonbyToolbarCircleView(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.trailing, 12)
                .padding(.top, appState.isWindowFullScreen ? 4 : 8)
            }
            .frame(height: appState.isWindowFullScreen ? 46 : 52)

            let visibleServers = appState.servers.filter { !appState.hideEncryptedServers || !$0.isEncrypted }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !visibleServers.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(visibleServers) { server in
                                SidebarServerItemButton(server: server)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)

                        Rectangle()
                            .fill(DonbyGlassPalette.separator(isLight: appState.isLightMode))
                            .frame(height: 1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(MainNavigationTab.allCases) { tab in
                            let isSelected = (appState.openedServerId == nil && appState.currentDetailItem == nil && appState.selectedTab == tab)
                            SidebarTabItemButton(tab: tab, isSelected: isSelected)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, visibleServers.isEmpty ? 4 : 0)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

// MARK: - Sidebar Item Helpers
private struct SidebarTabItemButton: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = AppUpdateManager.shared
    let tab: MainNavigationTab
    let isSelected: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            appState.selectSidebarModule(tab)
        } label: {
            HStack(spacing: 11) {
                let iconFg = isSelected
                    ? (appState.isMonochromeTheme ? Color.white : appState.accentTextColor)
                    : (isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                Image(systemName: tab.icon)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(iconFg)
                    .frame(width: 20, alignment: .center)

                Text(tab.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? (appState.isMonochromeTheme ? .white : appState.accentTextColor) : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()

                if tab == .settings && updater.availableRelease != nil {
                    Circle()
                        .fill(isSelected ? (appState.isMonochromeTheme ? .white : appState.accentTextColor) : appState.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 35)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isMonochromeTheme
                                  ? (appState.isLightMode ? Color(white: 0.12) : Color.white.opacity(0.20))
                                  : appState.accentColor)
                            .shadow(color: appState.isMonochromeTheme ? Color.black.opacity(0.12) : appState.accentColor.opacity(0.35), radius: 4, y: 1.5)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.07))
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct AppUpdatePromptSheet: View {
    @ObservedObject var updater: AppUpdateManager
    let isLightMode: Bool
    let accentColor: Color
    let accentTextColor: Color
    let onOpenAboutTab: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let release = updater.availableRelease {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("发现 Donby 新版本 v\(release.version)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                            if release.isPrerelease {
                                Text("Pre-release")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(accentColor.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                        }
                        Text("当前版本 v\(AppUpdateManager.currentVersion) -> 最新版本 v\(release.version)")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    }
                    Spacer()
                }

                if !release.body.isEmpty {
                    ScrollView {
                        Text(release.body)
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(12)
                    .background(DonbyGlassPalette.cardBackground(isLight: isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                switch updater.state {
                case .downloading(_, let progress, let dlBytes, let totalBytes):
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                            .tint(accentColor)
                        HStack {
                            Text("正在下载 (\(Int(progress * 100))%)")
                            Spacer()
                            Text("\(ByteCountFormatter.string(fromByteCount: dlBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    }
                case .verifying:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在验证更新...")
                            .font(.system(size: 12))
                    }
                case .installing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在安装更新并重启...")
                            .font(.system(size: 12))
                    }
                case .error(let msg):
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }

                HStack(spacing: 10) {
                    Button("跳过此版本") {
                        updater.skipVersion(release)
                    }
                    .buttonStyle(.bordered)

                    Button("查看详情") {
                        onOpenAboutTab()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if case .downloading = updater.state {
                        Button("取消下载") {
                            updater.cancelDownload()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("稍后提醒") {
                            updater.showUpdatePromptSheet = false
                        }
                        .buttonStyle(.bordered)

                        Button {
                            updater.startDownloadAndInstall(release)
                        } label: {
                            Text("立即更新")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(accentTextColor)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(updater.isBusy)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("关闭") { updater.showUpdatePromptSheet = false }
                    Spacer()
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(DonbyGlassPalette.canvas(isLight: isLightMode))
    }
}

private struct SidebarServerItemButton: View {
    @EnvironmentObject private var appState: AppState
    let server: EmbyServerConfig
    @State private var isHovered: Bool = false

    private var isServerOpen: Bool {
        appState.openedServerId == server.id
    }

    var body: some View {
        Button {
            appState.openServer(server)
        } label: {
            HStack(spacing: 10) {
                ServerIconView(server: server, size: 18)
                    .frame(width: 20, alignment: .center)

                Text(server.name)
                    .font(.system(size: 13, weight: isServerOpen ? .semibold : .regular))
                    .foregroundStyle(isServerOpen ? (appState.isMonochromeTheme ? .white : appState.accentTextColor) : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 33)
            .background(
                Group {
                    if isServerOpen {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isMonochromeTheme
                                  ? (appState.isLightMode ? Color(white: 0.12) : Color.white.opacity(0.20))
                                  : appState.accentColor)
                            .shadow(color: appState.isMonochromeTheme ? Color.black.opacity(0.12) : appState.accentColor.opacity(0.35), radius: 4, y: 1.5)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.07))
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            ServerContextMenuItems(server: server)
        }
    }
}

private struct DonbyToastOverlayView: View {
    @ObservedObject var store: DonbyToastStore
    let isLightMode: Bool

    var body: some View {
        if let toast = store.message {
            ToastBannerView(toast: toast, isLightMode: isLightMode)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

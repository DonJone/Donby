import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork
import DonbyStorage

public struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            if let playback = appState.activePlayback {
                PlayerView(session: playback)
                    .transition(.opacity)
                    .environment(\.colorScheme, .dark)
                    .preferredColorScheme(.dark)
            } else {
                HStack(spacing: 0) {
                    if !appState.isSidebarCollapsed {
                        appSidebarView
                            .frame(width: 206)
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

                    ZStack(alignment: .topLeading) {
                        Group {
                            if let detailItem = appState.currentDetailItem {
                                DetailView(
                                    item: detailItem,
                                    preferOfflineFocus: appState.detailOfflineFocusIds.contains(detailItem.id)
                                )
                                .id(detailItem.id)
                            } else if appState.openedServerId != nil {
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
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }

            if let toast = appState.toastMessage {
                ToastBannerView(toast: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .sheet(isPresented: $appState.showAddServerSheet) {
            ServerConfigSheet(existingServer: appState.editingServer)
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
        .sheet(item: $appState.linePickerServer) { server in
            ServerLinePickSheet(serverId: server.id)
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
        .sheet(isPresented: $appState.showLogViewer) {
            LogViewerSheet()
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
    }

    private var appSidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        appState.isSidebarCollapsed = true
                    }
                } label: {
                    DonbyToolbarCircleView(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .padding(.top, 8)
            }
            .frame(height: 52)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(MainNavigationTab.allCases) { tab in
                    let isSelected = (appState.openedServerId == nil && appState.currentDetailItem == nil && appState.selectedTab == tab)
                    SidebarTabItemButton(tab: tab, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Text("服务器")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.servers.filter { !appState.hideEncryptedServers || !$0.isEncrypted }) { server in
                        SidebarServerItemButton(server: server)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()
        }
    }
}

// MARK: - Sidebar Item Helpers
private struct SidebarTabItemButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: MainNavigationTab
    let isSelected: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            appState.selectSidebarModule(tab)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? (appState.isMonochromeTheme ? .white : appState.accentTextColor) : (isHovered ? DonbyGlassPalette.primaryText(isLight: appState.isLightMode) : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)))
                    .frame(width: 20, alignment: .center)

                Text(tab.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? (appState.isMonochromeTheme ? .white : appState.accentTextColor) : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            ServerContextMenuItems(server: server)
        }
    }
}

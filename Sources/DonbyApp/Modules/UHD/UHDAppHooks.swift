#if canImport(DonbyUHDModule)
import SwiftUI
import DonbyCore
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
            }
            .sheet(isPresented: $uhd.showAnimeCalendarSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDAnimeCalendarSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                }
            }
            .sheet(isPresented: $uhd.showFavoritesSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDFavoritesSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                }
            }
            .sheet(isPresented: $uhd.showWatchPartyJoinSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDWatchPartyJoinSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                }
            }
            .sheet(item: $uhd.activePersonSheet) { target in
                UHDPersonDetailSheet(target: target)
                    .environmentObject(appState)
                    .preferredColorScheme(appState.colorScheme)
            }
    }
}

public extension View {
    func donbyUHDModuleSheets() -> some View {
        modifier(DonbyUHDModuleSheetsModifier())
    }
}

/// Compact single Donby Liquid Glass toolbar popover unifying UHD account, calendar, favorites, and watch party
/// without crowding EmbyMainView's top bar or overflowing the window width.
public struct UHDEmbyToolbarMenuButton: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    public let server: EmbyServerConfig
    @State private var showPopover: Bool = false

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        if uhd.isActive(for: server), !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ToolbarVectorButton(
                tooltip: "服务功能与账户",
                isActive: showPopover,
                action: { showPopover.toggle() }
            ) { hovered in
                let iconColor = appState.isLightMode
                    ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28))
                    : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                let snap = uhd.accountSnapshots[server.id]
                let planTitle = UHDDisplayNormalizer.formatPlanName(
                    snap?.subscription?.plan?.name ?? appState.serverCapabilities[server.id]?.planName
                ) ?? "账户与流量"
                let trafficSub = snap?.traffic?.shortToolbarBadgeText ?? "查看套餐与额度"

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        showPopover = false
                        uhd.accountSheetServer = server
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(planTitle)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                Text(trafficSub)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(appState.isLightMode ? Color.black.opacity(0.035) : Color.white.opacity(0.06))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.vertical, 2)

                    popoverRow(icon: "calendar", title: "追番日历") {
                        showPopover = false
                        uhd.showAnimeCalendarSheet = true
                    }
                    popoverRow(icon: "heart", title: "我的收藏") {
                        showPopover = false
                        uhd.showFavoritesSheet = true
                    }
                    popoverRow(icon: "person.2.wave.2", title: "加入同看") {
                        showPopover = false
                        uhd.showWatchPartyJoinSheet = true
                    }
                    popoverRow(icon: "speedometer", title: "线路与测速") {
                        showPopover = false
                        appState.linePickerServer = server
                    }
                }
                .padding(12)
                .frame(width: 210)
            }
        }
    }

    private func popoverRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .toggleStyle(.switch)
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
#endif

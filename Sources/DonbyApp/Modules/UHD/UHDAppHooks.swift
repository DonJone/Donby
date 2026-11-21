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

/// Restrained Donby-styled UHD account pill shown beside the active line capsule in EmbyMainView.
public struct UHDEmbyAccountBadgePill: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    public let server: EmbyServerConfig

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        if uhd.isActive(for: server) {
            let snap = uhd.accountSnapshots[server.id]
            let badgeText: String = {
                if let t = snap?.traffic {
                    return t.shortToolbarBadgeText
                }
                if let plan = appState.serverCapabilities[server.id]?.planName, !plan.isEmpty {
                    return plan
                }
                return "账户"
            }()

            Button {
                uhd.accountSheetServer = server
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Text(badgeText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(appState.isLightMode ? Color.white : Color(white: 0.16))
                        .shadow(color: Color.black.opacity(appState.isLightMode ? 0.04 : 0.18), radius: 2, y: 1)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .help("账户与流量")
        }
    }
}

/// Compact Donby toolbar buttons for UHD discovery & watch party in EmbyMainView.
public struct UHDEmbyToolbarButtons: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    public let server: EmbyServerConfig

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        if uhd.isActive(for: server), !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ToolbarVectorButton(
                tooltip: "追番日历",
                action: { uhd.showAnimeCalendarSheet = true }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28)) : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            ToolbarVectorButton(
                tooltip: "我的收藏",
                action: { uhd.showFavoritesSheet = true }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28)) : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "heart")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            ToolbarVectorButton(
                tooltip: "加入同看",
                action: { uhd.showWatchPartyJoinSheet = true }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28)) : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
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

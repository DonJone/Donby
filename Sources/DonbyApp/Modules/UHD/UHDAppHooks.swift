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
                    .tint(appState.accentColor)
            }
            .sheet(isPresented: $uhd.showAnimeCalendarSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDAnimeCalendarSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                        .tint(appState.accentColor)
                }
            }
            .sheet(isPresented: $uhd.showWatchPartyJoinSheet) {
                if let server = appState.activeServer, uhd.isActive(for: server) {
                    UHDWatchPartyJoinSheet(server: server)
                        .environmentObject(appState)
                        .preferredColorScheme(appState.colorScheme)
                        .tint(appState.accentColor)
                }
            }
            .sheet(item: $uhd.activePersonSheet) { target in
                UHDPersonDetailSheet(target: target)
                    .environmentObject(appState)
                    .preferredColorScheme(appState.colorScheme)
                    .tint(appState.accentColor)
            }
    }
}

public extension View {
    func donbyUHDModuleSheets() -> some View {
        modifier(DonbyUHDModuleSheetsModifier())
    }
}

/// Direct Donby Liquid Glass toolbar actions for optional UHD capabilities (Anime Calendar & Watch Party).
/// Favorites remain natively integrated into Donby's home shelf and library filter rather than cluttering the toolbar.
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
                let iconColor = appState.isLightMode
                    ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28))
                    : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "calendar")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            ToolbarVectorButton(
                tooltip: "加入同看",
                action: { uhd.showWatchPartyJoinSheet = true }
            ) { hovered in
                let iconColor = appState.isLightMode
                    ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28))
                    : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13.5, weight: .medium))
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
                    .toggleStyle(
                        DonbySwitchToggleStyle(
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor
                        )
                    )
                    .onChange(of: uhd.isEnabled) { _, _ in
                        appState.reloadAfterModuleToggle()
                    }
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

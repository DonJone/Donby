#if canImport(DonbyUHDModule)
import SwiftUI
import AppKit
import DonbyCore
import DonbyUHDModule

// MARK: - Account & Traffic Balance Sheet (Donby Liquid Glass Aesthetic)

public struct UHDAccountSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let serverId: UUID

    private var server: EmbyServerConfig? {
        appState.servers.first(where: { $0.id == serverId })
    }

    public init(serverId: UUID) {
        self.serverId = serverId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("账户与流量")
                            .font(.system(size: 16.5, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text(server.username.isEmpty ? server.name : "\(server.name) · \(server.username)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                        let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(col)
                    }
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                UHDAccountDashboardContent(server: server, onDismiss: { dismiss() })
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }
}

public struct UHDAccountDashboardContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    public let server: EmbyServerConfig
    public var showRouteSwitchAction: Bool = true
    public var onDismiss: (() -> Void)? = nil

    @State private var isRefreshing: Bool = false
    @State private var showTeamPanel: Bool = false
    @State private var teamOverview: UHDTeamOverview? = nil
    @State private var teamMembers: [UHDTeamMember] = []
    @State private var teamNextCursor: String? = nil
    @State private var teamSearchQuery: String = ""
    @State private var isLoadingTeam: Bool = false
    @State private var teamError: String? = nil
    @State private var isLoggingOut: Bool = false

    private var snapshot: UHDAccountSnapshot? {
        uhd.accountSnapshots[server.id]
    }

    public init(server: EmbyServerConfig, showRouteSwitchAction: Bool = true, onDismiss: (() -> Void)? = nil) {
        self.server = server
        self.showRouteSwitchAction = showRouteSwitchAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                trafficBalanceCard
                subscriptionPlanCard
                teamManagementSection
                sessionActionBar
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 460)
        .task(id: server.id) {
            await refreshAccount()
        }
    }

    private var trafficBalanceCard: some View {
        let traffic = snapshot?.traffic
        let sub = snapshot?.subscription
        let isUnlimited = traffic?.displayUnlimitedTraffic ?? sub?.displayUnlimitedTraffic ?? false
        let fraction = traffic?.usageFraction ?? 0
        let barColor = appState.accentColor

        return dashboardCard {
            HStack(alignment: .center) {
                Text("当期流量")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
                Button {
                    Task { await refreshAccount() }
                } label: {
                    HStack(spacing: 4) {
                        RefreshVectorIcon(
                            size: 11,
                            color: DonbyGlassPalette.secondaryText(isLight: appState.isLightMode),
                            isSpinning: isRefreshing
                        )
                        Text("刷新")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let traffic {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if isUnlimited {
                        Text("不限流量")
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("已用 \(UHDTrafficSummary.formatBytes(traffic.usedBytes))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    } else {
                        Text(UHDTrafficSummary.formatBytes(traffic.remainingBytes))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("剩余 / \(UHDTrafficSummary.formatBytes(traffic.limitBytes))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    if !isUnlimited && traffic.limitBytes > 0 {
                        Text(String(format: "%.1f%%", fraction * 100))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }

                if !isUnlimited && traffic.limitBytes > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10))
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(6, geo.size.width * CGFloat(fraction)))
                        }
                    }
                    .frame(height: 6)
                }

                HStack(spacing: 12) {
                    if let renewDay = sub?.renewDay, renewDay > 0 {
                        let countdown = sub?.nextResetDaysRemaining.map { " · 还有 \($0) 天" } ?? ""
                        Text("每月 \(renewDay) 日重置\(countdown)")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    if !isUnlimited {
                        Text("已用 \(UHDTrafficSummary.formatBytes(traffic.usedBytes))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
            } else if isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在同步账户数据...")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .padding(.vertical, 4)
            } else {
                Text("暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        }
    }

    private var subscriptionPlanCard: some View {
        let sub = snapshot?.subscription
        let planLabel: String = {
            let base = UHDDisplayNormalizer.formatPlanName(sub?.plan?.name) ?? "订阅信息"
            return sub?.isTrial == true ? "\(base) · 试用" : base
        }()
        return dashboardCard {
            HStack(spacing: 8) {
                Text(planLabel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Spacer()
                if let expStr = sub?.formattedExpiresDate {
                    let daysText = sub?.remainingDays.map { d -> String in
                        if d < 0 { return "已过期" }
                        if d == 0 { return "今日到期" }
                        return "剩 \(d) 天"
                    } ?? ""
                    Text("\(expStr) · \(daysText)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            }

            if let sub {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    metricTile("并发连接", "\(sub.activeVideoDeliveryLimit) 路")
                    metricTile("离线下载", sub.allowDownload ? "允许" : "不支持")
                    metricTile("登录设备", sub.plan?.loginDeviceLimit.map { "\($0) 台" } ?? "默认")
                    if let quota = sub.plan?.memberQuota, quota > 0 {
                        metricTile("团队席位", "\(sub.memberUsage ?? 0) / \(quota)")
                    }
                    if let teamGB = sub.plan?.teamTrafficLimitGB, teamGB > 0 {
                        metricTile("团队流量池", "\(teamGB) GiB")
                    }
                }
            }
        }
    }

    private var teamManagementSection: some View {
        dashboardCard {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showTeamPanel.toggle()
                }
                if showTeamPanel && teamOverview == nil && !isLoadingTeam {
                    Task { await loadTeamData(reset: true) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("团队管理")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Spacer()
                    Image(systemName: showTeamPanel ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTeamPanel {
                Divider().opacity(appState.isLightMode ? 0.25 : 0.10)
                if isLoadingTeam && teamOverview == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载...")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                } else if let teamError {
                    Text(teamError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                } else if let team = teamOverview {
                    HStack(spacing: 10) {
                        metricTile("成员", "\(team.memberCount) / \(team.memberLimit == 0 ? "不限" : "\(team.memberLimit)")")
                        metricTile("团队流量", "\(UHDTrafficSummary.formatBytes(team.trafficUsedBytes)) / \(UHDTrafficSummary.formatBytes(team.trafficLimitBytes))")
                        metricTile("并发策略", team.settings.activeVideoDeliveryLimit == 0 ? "不限" : "\(team.settings.activeVideoDeliveryLimit) 路")
                    }

                    HStack(spacing: 8) {
                        TextField("搜索成员", text: $teamSearchQuery)
                            .font(.system(size: 12))
                            .donbyFlatTextField(isLight: appState.isLightMode, cornerRadius: 8, horizontalPadding: 10, verticalPadding: 6)
                            .onSubmit { Task { await loadTeamData(reset: true) } }
                        Button {
                            Task { await loadTeamData(reset: true) }
                        } label: {
                            Text("筛选")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if !teamMembers.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(teamMembers) { member in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(member.username)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                            Text("会话 \(member.sessionCount)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                        }
                                        Text("\(UHDTrafficSummary.formatBytes(member.trafficUsedBytes)) / \(UHDTrafficSummary.formatBytes(member.trafficLimitBytes))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    }
                                    Spacer()
                                    Button {
                                        Task {
                                            try? await UHDStreamClient.shared.setTeamMemberTrafficUsage(server: server, memberId: member.id, usedBytes: 0)
                                            await loadTeamData(reset: true)
                                            appState.showToast("已重置 \(member.username) 流量", icon: "checkmark.circle.fill")
                                        }
                                    } label: {
                                        Text("清零")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .donbyLiquidGlassCapsule()
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(appState.isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }

                    if let cursor = teamNextCursor, !cursor.isEmpty {
                        Button {
                            Task { await loadTeamData(reset: false) }
                        } label: {
                            Text("加载更多")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var sessionActionBar: some View {
        HStack(spacing: 10) {
            if showRouteSwitchAction {
                Button {
                    onDismiss?()
                    appState.linePickerServer = server
                } label: {
                    HStack(spacing: 6) {
                        RouteSwitchVectorIcon(size: 12, color: DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("线路与测速")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                guard !isLoggingOut else { return }
                Task {
                    isLoggingOut = true
                    await uhd.logoutServer(server, appState: appState)
                    isLoggingOut = false
                    onDismiss?()
                }
            } label: {
                HStack(spacing: 5) {
                    if isLoggingOut { ProgressView().controlSize(.mini) }
                    Text("退出登录")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .donbyLiquidGlassCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isLoggingOut)
        }
        .padding(.top, 2)
    }

    private func dashboardCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
        )
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appState.isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func refreshAccount() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await uhd.refreshAccountSnapshot(for: server, appState: appState)
    }

    private func loadTeamData(reset: Bool) async {
        isLoadingTeam = true
        teamError = nil
        defer { isLoadingTeam = false }
        do {
            if reset || teamOverview == nil {
                teamOverview = try await UHDStreamClient.shared.fetchTeamOverview(server: server)
            }
            let page = try await UHDStreamClient.shared.fetchTeamMembers(
                server: server,
                query: teamSearchQuery,
                limit: 30,
                cursor: reset ? nil : teamNextCursor
            )
            if reset {
                teamMembers = page.items
            } else {
                teamMembers.append(contentsOf: page.items)
            }
            teamNextCursor = page.nextCursor
        } catch {
            teamError = "需要团队主账号 API Key 权限"
        }
    }
}
#endif

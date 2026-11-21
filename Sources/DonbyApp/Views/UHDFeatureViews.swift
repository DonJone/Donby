import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

public struct UHDPersonSheetTarget: Identifiable {
    public var id: String { "\(server.id.uuidString)|\(person.id)" }
    public let server: EmbyServerConfig
    public let person: EmbyPerson

    public init(server: EmbyServerConfig, person: EmbyPerson) {
        self.server = server
        self.person = person
    }
}

// MARK: - Speed Test Live Sparkline Chart

public struct UHDSpeedSparklineChart: View {
    public let samplesMbps: [Double]
    public let accentColor: Color
    public let isLightMode: Bool

    public init(samplesMbps: [Double], accentColor: Color, isLightMode: Bool) {
        self.samplesMbps = samplesMbps
        self.accentColor = accentColor
        self.isLightMode = isLightMode
    }

    public var body: some View {
        Canvas { ctx, size in
            guard samplesMbps.count >= 2 else { return }
            let maxVal = max(10.0, (samplesMbps.max() ?? 10.0) * 1.12)
            let stepX = size.width / CGFloat(max(1, samplesMbps.count - 1))
            var linePath = Path()
            var areaPath = Path()

            for (idx, val) in samplesMbps.enumerated() {
                let x = CGFloat(idx) * stepX
                let yRatio = CGFloat(max(0.0, min(1.0, val / maxVal)))
                let y = size.height - (yRatio * (size.height - 6)) - 3
                let pt = CGPoint(x: x, y: y)
                if idx == 0 {
                    linePath.move(to: pt)
                    areaPath.move(to: CGPoint(x: x, y: size.height))
                    areaPath.addLine(to: pt)
                } else {
                    linePath.addLine(to: pt)
                    areaPath.addLine(to: pt)
                }
            }
            areaPath.addLine(to: CGPoint(x: size.width, y: size.height))
            areaPath.closeSubpath()

            ctx.fill(
                areaPath,
                with: .linearGradient(
                    Gradient(colors: [accentColor.opacity(isLightMode ? 0.24 : 0.34), accentColor.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            ctx.stroke(linePath, with: .color(accentColor), style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.5)
        )
    }
}

// MARK: - UHD Account, Traffic Balance & Team v2 Dashboard

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
                    ServerIconView(server: server, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UHD 账户与流量余额")
                            .font(.system(size: 16.5, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("\(server.name) · \(server.username.isEmpty ? "令牌会话" : server.username)")
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
        .frame(width: 580)
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
    public let server: EmbyServerConfig
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
        appState.uhdAccountSnapshots[server.id]
    }

    public init(server: EmbyServerConfig, onDismiss: (() -> Void)? = nil) {
        self.server = server
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
        .frame(maxHeight: 470)
        .task(id: server.id) {
            await refreshAccount()
        }
    }

    private var trafficBalanceCard: some View {
        let traffic = snapshot?.traffic
        let sub = snapshot?.subscription
        let isUnlimited = traffic?.displayUnlimitedTraffic ?? sub?.displayUnlimitedTraffic ?? false
        let fraction = traffic?.usageFraction ?? 0
        let barColor: Color = {
            if fraction >= 0.95 { return .red }
            if fraction >= 0.80 { return .orange }
            return appState.accentColor
        }()

        return dashboardCard {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(appState.accentColor)
                    Text("当期流量余额")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
                Spacer()
                Button {
                    Task { await refreshAccount() }
                } label: {
                    HStack(spacing: 4) {
                        RefreshVectorIcon(
                            size: 11.5,
                            color: DonbyGlassPalette.secondaryText(isLight: appState.isLightMode),
                            isSpinning: isRefreshing
                        )
                        Text("刷新")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let traffic {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if isUnlimited {
                        Text("不限流量")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("已使用 \(UHDTrafficSummary.formatBytes(traffic.usedBytes))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    } else {
                        Text(UHDTrafficSummary.formatBytes(traffic.remainingBytes))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("剩余 / 配额 \(UHDTrafficSummary.formatBytes(traffic.limitBytes))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    Spacer()
                    if !isUnlimited && traffic.limitBytes > 0 {
                        Text(String(format: "已用 %.1f%%", fraction * 100))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(barColor)
                    }
                }

                if !isUnlimited && traffic.limitBytes > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(appState.isLightMode ? Color.black.opacity(0.07) : Color.white.opacity(0.10))
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(6, geo.size.width * CGFloat(fraction)))
                        }
                    }
                    .frame(height: 7)
                }

                HStack(spacing: 12) {
                    if let renewDay = sub?.renewDay, renewDay > 0 {
                        let countdown = sub?.nextResetDaysRemaining.map { "（还有 \($0) 天）" } ?? ""
                        Label("每月 \(renewDay) 日重置\(countdown)", systemImage: "calendar.badge.clock")
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
                    Text("正在拉取账户流量与订阅状态...")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .padding(.vertical, 6)
            } else {
                Text("暂无流量数据，请确认登录凭证有效后点击刷新")
                    .font(.system(size: 12))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
        }
    }

    private var subscriptionPlanCard: some View {
        let sub = snapshot?.subscription
        return dashboardCard {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentColor)
                Text(sub?.plan?.name ?? "当前订阅套餐")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                if sub?.isTrial == true {
                    pillBadge("试用", tint: .orange)
                }
                if sub?.autoRenew == true {
                    pillBadge("自动续订", tint: .green)
                }
                if let pType = sub?.plan?.planType, !pType.isEmpty {
                    pillBadge(pType.uppercased(), tint: appState.accentColor)
                }
                Spacer()
                if let expStr = sub?.formattedExpiresDate {
                    let daysText = sub?.remainingDays.map { d -> String in
                        if d < 0 { return "已过期" }
                        if d == 0 { return "今日到期" }
                        return "剩 \(d) 天"
                    } ?? ""
                    Text("\(expStr) \(daysText)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle((sub?.isExpired == true || sub?.isExpiringSoon == true) ? .orange : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            }

            if let desc = sub?.plan?.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .lineLimit(2)
            }

            if let sub {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    metricTile("并发传输上限", "\(sub.activeVideoDeliveryLimit) 路")
                    metricTile("下载权限", sub.allowDownload ? "允许离线下载" : "仅在线播放")
                    metricTile(
                        "登录设备上限",
                        sub.plan?.loginDeviceLimit.map { "\($0) 台" } ?? "按套餐策略"
                    )
                    if let quota = sub.plan?.memberQuota, quota > 0 {
                        metricTile("团队名额", "\(sub.memberUsage ?? 0) / \(quota) 人")
                    }
                    if let mp = sub.plan?.monthlyPriceUSD, mp > 0 {
                        let ypText = (sub.plan?.yearlyPriceUSD ?? 0) > 0 ? String(format: " / $%.0f年", sub.plan!.yearlyPriceUSD!) : ""
                        metricTile("套餐参考价", String(format: "$%.2f/月%@", mp, ypText))
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
                withAnimation(.easeInOut(duration: 0.18)) {
                    showTeamPanel.toggle()
                }
                if showTeamPanel && teamOverview == nil && !isLoadingTeam {
                    Task { await loadTeamData(reset: true) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(appState.accentColor)
                    Text("团队管理 (Team API v2)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("仅平台 API Key 主账号可用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
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
                        Text("正在读取团队概览...")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                } else if let teamError {
                    Text(teamError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                } else if let team = teamOverview {
                    HStack(spacing: 12) {
                        metricTile("团队成员", "\(team.memberCount) / \(team.memberLimit == 0 ? "不限" : "\(team.memberLimit)")")
                        metricTile("团队流量", "\(UHDTrafficSummary.formatBytes(team.trafficUsedBytes)) / \(UHDTrafficSummary.formatBytes(team.trafficLimitBytes))")
                        metricTile("团队策略", "并发 \(team.settings.activeVideoDeliveryLimit == 0 ? "不限" : "\(team.settings.activeVideoDeliveryLimit)") · \(team.settings.allowDownload ? "可下载" : "禁下载")")
                    }

                    HStack(spacing: 8) {
                        TextField("按用户名筛选成员...", text: $teamSearchQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit { Task { await loadTeamData(reset: true) } }
                        Button("筛选") {
                            Task { await loadTeamData(reset: true) }
                        }
                        .controlSize(.small)
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
                                        Text("\(UHDTrafficSummary.formatBytes(member.trafficUsedBytes)) / \(UHDTrafficSummary.formatBytes(member.trafficLimitBytes)) · 重置日 \(member.renewDay) 号")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    }
                                    Spacer()
                                    Button("流量清零") {
                                        Task {
                                            try? await UHDStreamClient.shared.setTeamMemberTrafficUsage(server: server, memberId: member.id, usedBytes: 0)
                                            await loadTeamData(reset: true)
                                            appState.showToast("已清零 \(member.username) 的当期流量计数", icon: "checkmark.circle.fill")
                                        }
                                    }
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(appState.isLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }

                    if let cursor = teamNextCursor, !cursor.isEmpty {
                        Button("加载更多成员") {
                            Task { await loadTeamData(reset: false) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var sessionActionBar: some View {
        HStack(spacing: 10) {
            Button {
                onDismiss?()
                appState.linePickerServer = server
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                    Text("线路与测速中心")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .donbyLiquidGlassCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                guard !isLoggingOut else { return }
                Task {
                    isLoggingOut = true
                    await appState.logoutUHDServer(server)
                    isLoggingOut = false
                    onDismiss?()
                }
            } label: {
                HStack(spacing: 5) {
                    if isLoggingOut { ProgressView().controlSize(.mini) }
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("退出当前登录")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.red.opacity(0.24), lineWidth: 0.6))
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.7)
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

    private func pillBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }

    private func refreshAccount() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await appState.refreshServerCapabilities(for: server)
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
            teamError = "当前凭证不是团队主账号的平台 API Key，或暂无团队管理权限（\(error.localizedDescription)）"
        }
    }
}

// MARK: - UHD Anime Calendar Sheet (动漫追番日历)

public struct UHDAnimeCalendarSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    @State private var days: [UHDAnimeCalendarDay] = (1...7).map { UHDAnimeCalendarDay(weekday: $0, total: 0) }
    @State private var selectedWeekday: Int = UHDAnimeCalendarDay.todayShanghaiWeekday()
    @State private var entries: [UHDAnimeCalendarEntry] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        let todayWD = UHDAnimeCalendarDay.todayShanghaiWeekday()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("动漫追番日历")
                        .font(.system(size: 17.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("按北京时间 (Asia/Shanghai) 展示近期排期，点击作品直接查看详情")
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

            HStack(spacing: 6) {
                ForEach(days) { day in
                    let isSelected = (day.weekday == selectedWeekday)
                    let isToday = (day.weekday == todayWD)
                    Button {
                        selectedWeekday = day.weekday
                    } label: {
                        VStack(spacing: 2) {
                            Text(isToday ? "\(day.shortTitle)·今" : day.shortTitle)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            Text("\(day.total)")
                                .font(.system(size: 10, design: .monospaced))
                                .opacity(0.75)
                        }
                        .foregroundStyle(isSelected ? appState.accentTextColor : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? appState.accentColor : DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isSelected ? appState.accentColor : DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.7)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.vertical, 8)
            } else if isLoading && entries.isEmpty {
                VStack {
                    Spacer()
                    ProgressView().controlSize(.regular)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            } else if entries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "calendar")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Text("当天暂无动漫播出排期")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 165), spacing: 14)], alignment: .leading, spacing: 16) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                ZStack(alignment: .topTrailing) {
                                    PosterCardView(
                                        item: entry.item,
                                        width: 148,
                                        appearance: appearance,
                                        onSelect: {
                                            dismiss()
                                            appState.openDetail(for: entry.item)
                                        },
                                        onPlay: {
                                            dismiss()
                                            Task { await appState.startPlayback(item: entry.item) }
                                        }
                                    )
                                    .equatable()

                                    Text(entry.schedule.badgeText)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2.5)
                                        .background(entry.schedule.estimated ? Color.black.opacity(0.66) : appState.accentColor.opacity(0.90))
                                        .clipShape(Capsule())
                                        .padding(6)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 360, maxHeight: 480)
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .task {
            if let fetchedDays = try? await UHDStreamClient.shared.fetchAnimeCalendarDays(server: server), !fetchedDays.isEmpty {
                days = fetchedDays
            }
        }
        .task(id: selectedWeekday) {
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }
            do {
                entries = try await UHDStreamClient.shared.fetchAnimeCalendarItems(server: server, weekday: selectedWeekday)
            } catch {
                errorMessage = "加载动漫日历失败: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - UHD Favorites Browser (电影 / 剧集 / 人物)

public struct UHDFavoritesSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    private enum FavTab: String, CaseIterable, Identifiable {
        case movie = "电影"
        case tv = "剧集"
        case person = "人物"
        var id: String { rawValue }
        var apiType: String {
            switch self {
            case .movie: return "movie"
            case .tv: return "tv"
            case .person: return "person"
            }
        }
    }

    @State private var tab: FavTab = .movie
    @State private var mediaItems: [EmbyItem] = []
    @State private var persons: [UHDPersonDetail] = []
    @State private var totalCount: Int = 0
    @State private var nextCursor: String? = nil
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Text("我的收藏")
                        .font(.system(size: 17.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    if totalCount > 0 {
                        Text("\(totalCount)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(FavTab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            if isLoading && mediaItems.isEmpty && persons.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else if tab == .person {
                if persons.isEmpty {
                    emptyPlaceholder("尚未收藏任何人物")
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 125), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(persons) { p in
                                let embyPerson = EmbyPerson(id: p.id, name: p.name, role: nil, type: "Actor", primaryImageTag: nil, uhdImageURL: p.imageURL)
                                Button {
                                    dismiss()
                                    appState.activeUHDPersonSheet = UHDPersonSheetTarget(server: server, person: embyPerson)
                                } label: {
                                    VStack(spacing: 7) {
                                        PersonAvatarView(server: server, person: embyPerson, width: 88, height: 112, accentColor: appState.accentColor)
                                        Text(p.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 100)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        loadMoreFooter
                    }
                    .frame(minHeight: 360, maxHeight: 470)
                }
            } else {
                if mediaItems.isEmpty {
                    emptyPlaceholder("尚未收藏任何\(tab.rawValue)")
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 165), spacing: 14)], alignment: .leading, spacing: 16) {
                            ForEach(mediaItems) { item in
                                PosterCardView(
                                    item: item,
                                    width: 148,
                                    appearance: appearance,
                                    onSelect: {
                                        dismiss()
                                        appState.openDetail(for: item)
                                    },
                                    onPlay: {
                                        dismiss()
                                        Task { await appState.startPlayback(item: item) }
                                    }
                                )
                                .equatable()
                            }
                        }
                        .padding(.vertical, 4)
                        loadMoreFooter
                    }
                    .frame(minHeight: 360, maxHeight: 470)
                }
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .task(id: tab) {
            await loadPage(reset: true)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if let nextCursor, !nextCursor.isEmpty {
            HStack {
                Spacer()
                Button {
                    Task { await loadPage(reset: false) }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingMore { ProgressView().controlSize(.small) }
                        Text("加载更多")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingMore)
                Spacer()
            }
            .padding(.top, 10)
        }
    }

    private func emptyPlaceholder(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "heart")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 340)
    }

    private func loadPage(reset: Bool) async {
        if reset {
            isLoading = true
            nextCursor = nil
        } else {
            guard !isLoadingMore, nextCursor != nil else { return }
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        if tab == .person {
            if let res = try? await UHDStreamClient.shared.fetchFavoritePersons(server: server, limit: 40, cursor: reset ? nil : nextCursor) {
                if reset { persons = res.items } else { persons.append(contentsOf: res.items) }
                totalCount = res.total
                nextCursor = res.nextCursor
            }
        } else {
            if let res = try? await UHDStreamClient.shared.fetchFavorites(server: server, type: tab.apiType, limit: 36, cursor: reset ? nil : nextCursor) {
                if reset { mediaItems = res.items } else { mediaItems.append(contentsOf: res.items) }
                totalCount = res.total
                nextCursor = res.nextCursor
            }
        }
    }
}

// MARK: - UHD Person Detail & Works Sheet (人物详情与库内作品)

public struct UHDPersonDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let target: UHDPersonSheetTarget

    @State private var detail: UHDPersonDetail? = nil
    @State private var works: [EmbyItem] = []
    @State private var nextCursor: String? = nil
    @State private var mediaTypeFilter: String = "" // "", "movie", "tv"
    @State private var sortBy: String = "release_date"
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var isTogglingFav: Bool = false

    public init(target: UHDPersonSheetTarget) {
        self.target = target
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        let isFav = detail?.favorite ?? false
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                PersonAvatarView(
                    server: target.server,
                    person: target.person,
                    width: 62,
                    height: 80,
                    accentColor: appState.accentColor
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(detail?.name ?? target.person.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    HStack(spacing: 8) {
                        if let tmdb = detail?.tmdbId, !tmdb.isEmpty {
                            Text("TMDB \(tmdb)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                .clipShape(Capsule())
                        }
                        if let imdb = detail?.imdbId, !imdb.isEmpty {
                            Text("IMDb \(imdb)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                .clipShape(Capsule())
                        }
                        Text("库内作品 \(works.count)\(nextCursor != nil ? "+" : "")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }

                Spacer()

                Button {
                    guard !isTogglingFav else { return }
                    Task {
                        isTogglingFav = true
                        defer { isTogglingFav = false }
                        let nextFav = !isFav
                        if (try? await UHDStreamClient.shared.setPersonFavorite(server: target.server, personId: target.person.id, isFavorite: nextFav)) != nil {
                            if var d = detail {
                                d.favorite = nextFav
                                detail = d
                            } else {
                                detail = UHDPersonDetail(id: target.person.id, name: target.person.name, imageURL: target.person.uhdImageURL, favorite: nextFav)
                            }
                            appState.showToast(nextFav ? "已收藏人物 \(target.person.name)" : "已取消人物收藏", icon: nextFav ? "heart.fill" : "heart.slash")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .foregroundStyle(isFav ? AppState.appleMusicRed : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text(isFav ? "已收藏" : "收藏人物")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            HStack(spacing: 10) {
                Picker("类型", selection: $mediaTypeFilter) {
                    Text("全部").tag("")
                    Text("电影").tag("movie")
                    Text("剧集").tag("tv")
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                Spacer()

                Picker("排序", selection: $sortBy) {
                    Text("发行日期").tag("release_date")
                    Text("热门度").tag("hot")
                    Text("评分").tag("rating")
                    Text("最新入库").tag("asset_updated_at")
                    Text("名称").tag("title")
                }
                .frame(width: 150)
            }

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 330)
            } else if works.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("当前片库暂无该人物的可见作品")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 330)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 165), spacing: 14)], alignment: .leading, spacing: 16) {
                        ForEach(works) { item in
                            PosterCardView(
                                item: item,
                                width: 148,
                                appearance: appearance,
                                onSelect: {
                                    dismiss()
                                    appState.openDetail(for: item)
                                },
                                onPlay: {
                                    dismiss()
                                    Task { await appState.startPlayback(item: item) }
                                }
                            )
                            .equatable()
                        }
                    }
                    .padding(.vertical, 4)

                    if let cursor = nextCursor, !cursor.isEmpty {
                        HStack {
                            Spacer()
                            Button {
                                Task { await loadWorks(reset: false) }
                            } label: {
                                HStack(spacing: 6) {
                                    if isLoadingMore { ProgressView().controlSize(.small) }
                                    Text("加载更多作品")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMore)
                            Spacer()
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(minHeight: 340, maxHeight: 450)
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .task {
            if let fetched = try? await UHDStreamClient.shared.fetchPersonDetail(server: target.server, personId: target.person.id) {
                detail = fetched
            }
        }
        .task(id: "\(mediaTypeFilter)|\(sortBy)") {
            await loadWorks(reset: true)
        }
    }

    private func loadWorks(reset: Bool) async {
        if reset {
            isLoading = true
            nextCursor = nil
        } else {
            guard !isLoadingMore, nextCursor != nil else { return }
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        let order = (sortBy == "title") ? "asc" : "desc"
        if let res = try? await UHDStreamClient.shared.fetchPersonWorks(
            server: target.server,
            personId: target.person.id,
            mediaType: mediaTypeFilter.isEmpty ? nil : mediaTypeFilter,
            sortBy: sortBy,
            sortOrder: order,
            limit: 36,
            cursor: reset ? nil : nextCursor
        ) {
            if reset {
                works = res.items
            } else {
                works.append(contentsOf: res.items)
            }
            nextCursor = res.nextCursor
        }
    }
}

// MARK: - UHD Watch Party Join & Create Sheets (同看房间)

public struct UHDWatchPartyJoinSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    @State private var rawInvite: String = ""
    @State private var isJoining: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("加入 UHD 同看房间")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("输入 8 位数字邀请码或粘贴同看分享链接，各成员使用各自线路同步观影")
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("输入 8 位邀请码（如 0428 1736）或邀请链接", text: $rawInvite)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .onSubmit { Task { await joinNow() } }

                Button("粘贴") {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        rawInvite = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .controlSize(.regular)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await joinNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isJoining { ProgressView().controlSize(.small) }
                        Text("加入同看")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(UHDWatchPartyInviteParser.extractInviteCode(from: rawInvite) == nil || isJoining)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func joinNow() async {
        guard !isJoining else { return }
        errorMessage = nil
        isJoining = true
        defer { isJoining = false }
        do {
            try await appState.joinAndStartWatchParty(server: server, rawInvite: rawInvite)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct UHDWatchPartyCreateSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig
    public let item: EmbyItem
    public let preferredSourceId: String?

    @State private var maxMembers: Int = 4
    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig, item: EmbyItem, preferredSourceId: String?) {
        self.server = server
        self.item = item
        self.preferredSourceId = preferredSourceId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("创建 UHD 同看房间")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("影片：\(item.name) · 房主控制进度与片源，成员各自选用本地线路与字幕")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(2)
                }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("房间人数上限（含房主）")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
                Stepper("\(maxMembers) 人", value: $maxMembers, in: 2...10)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .padding(12)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await createNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text("创建并开始同看")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func createNow() async {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await appState.createAndStartWatchParty(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId,
                maxMembers: maxMembers
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Lightweight UHD Danmu Canvas Renderer

public struct UHDDanmuCanvasOverlay: View {
    public let comments: [UHDDanmuComment]
    public let currentTime: Double
    public let isEnabled: Bool
    public let opacity: Double

    public init(comments: [UHDDanmuComment], currentTime: Double, isEnabled: Bool, opacity: Double = 0.86) {
        self.comments = comments
        self.currentTime = currentTime
        self.isEnabled = isEnabled
        self.opacity = opacity
    }

    public var body: some View {
        if isEnabled && !comments.isEmpty {
            Canvas { ctx, size in
                let scrollDuration = 9.0
                let staticDuration = 4.2
                let windowStart = currentTime - scrollDuration
                let windowEnd = currentTime + 0.1

                // Binary search first visible comment
                var lo = 0
                var hi = comments.count
                while lo < hi {
                    let mid = (lo + hi) >> 1
                    if comments[mid].timeSeconds < windowStart {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }

                let laneHeight: CGFloat = 28
                let maxLanes = max(4, min(10, Int((size.height * 0.48) / laneHeight)))
                let topPadding: CGFloat = 44
                var drawn = 0

                for i in lo..<comments.count {
                    let c = comments[i]
                    if c.timeSeconds > windowEnd { break }
                    let age = currentTime - c.timeSeconds
                    guard age >= 0 else { continue }

                    let isTopOrBottom = (c.mode == 4 || c.mode == 5)
                    let life = isTopOrBottom ? staticDuration : scrollDuration
                    guard age <= life else { continue }
                    if drawn >= 45 { break }
                    drawn += 1

                    let r = Double((c.colorRGB >> 16) & 0xFF) / 255.0
                    let g = Double((c.colorRGB >> 8) & 0xFF) / 255.0
                    let b = Double(c.colorRGB & 0xFF) / 255.0
                    let textColor = Color(red: r, green: g, blue: b).opacity(opacity)

                    let resolved = ctx.resolve(
                        Text(c.text)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(textColor)
                    )
                    let shadowResolved = ctx.resolve(
                        Text(c.text)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(Color.black.opacity(opacity * 0.72))
                    )
                    let textSize = resolved.measure(in: size)
                    let lane = abs(c.id.hashValue) % maxLanes

                    let x: CGFloat
                    let y: CGFloat
                    if isTopOrBottom {
                        x = (size.width - textSize.width) * 0.5
                        y = c.mode == 4
                            ? max(topPadding, size.height - 110 - CGFloat(lane % 4) * laneHeight)
                            : topPadding + CGFloat(lane % 4) * laneHeight
                    } else {
                        let progress = CGFloat(age / scrollDuration)
                        x = size.width - progress * (size.width + textSize.width + 24)
                        y = topPadding + CGFloat(lane) * laneHeight
                    }

                    ctx.draw(shadowResolved, at: CGPoint(x: x + 1.2, y: y + 1.2), anchor: .topLeading)
                    ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}


/// Isolated 30fps TimelineView wrapper so Danmu scrolls smoothly even while PlayerView's HUD is hidden
/// without triggering any re-evaluation of PlayerView's main body.
public struct UHDDanmuLiveOverlay: View {
    public let comments: [UHDDanmuComment]
    public let isEnabled: Bool
    public let isPlaying: Bool
    public let playbackRate: Double
    public let timeProvider: () -> (baseTime: Double, baseUptime: TimeInterval)

    public init(
        comments: [UHDDanmuComment],
        isEnabled: Bool,
        isPlaying: Bool,
        playbackRate: Double,
        timeProvider: @escaping () -> (baseTime: Double, baseUptime: TimeInterval)
    ) {
        self.comments = comments
        self.isEnabled = isEnabled
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.timeProvider = timeProvider
    }

    public var body: some View {
        if isEnabled && !comments.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
                let sample = timeProvider()
                let dt = isPlaying ? max(0, min(1.5, ProcessInfo.processInfo.systemUptime - sample.baseUptime)) : 0
                let smoothTime = sample.baseTime + dt * max(0.25, playbackRate)
                UHDDanmuCanvasOverlay(comments: comments, currentTime: smoothTime, isEnabled: true)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}

public struct UHDDanmuPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig
    public let initialKeyword: String
    public let onSelectEpisode: (String, Int, [UHDDanmuComment]) -> Void

    @State private var keyword: String
    @State private var animes: [UHDDanmuAnimeMatch] = []
    @State private var selectedAnime: UHDDanmuAnimeMatch? = nil
    @State private var episodes: [UHDDanmuEpisodeOption] = []
    @State private var isSearching: Bool = false
    @State private var isLoadingComments: Bool = false
    @State private var errorMessage: String? = nil

    public init(
        server: EmbyServerConfig,
        initialKeyword: String,
        onSelectEpisode: @escaping (String, Int, [UHDDanmuComment]) -> Void
    ) {
        self.server = server
        self.initialKeyword = initialKeyword
        self.onSelectEpisode = onSelectEpisode
        self._keyword = State(initialValue: initialKeyword)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("手动匹配 UHD 弹幕")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                TextField("输入番剧或影视名称...", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await runSearch() } }
                Button("搜索") { Task { await runSearch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("剧目候选 (\(animes.count))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(animes) { anime in
                                let isSel = selectedAnime?.animeId == anime.animeId
                                Button {
                                    selectedAnime = anime
                                    Task { await loadEpisodes(animeId: anime.animeId) }
                                } label: {
                                    HStack {
                                        Text(anime.animeTitle)
                                            .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(isSel ? Color.white.opacity(0.18) : Color.white.opacity(0.05)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 250)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("选择分集 (\(episodes.count))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(episodes) { ep in
                                Button {
                                    Task { await pickEpisode(ep) }
                                } label: {
                                    HStack {
                                        Text(ep.episodeTitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Spacer()
                                        if isLoadingComments {
                                            ProgressView().controlSize(.mini)
                                        }
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoadingComments)
                            }
                        }
                    }
                    .frame(height: 250)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(red: 0.09, green: 0.095, blue: 0.115))
        .preferredColorScheme(.dark)
        .task {
            if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await runSearch()
            }
        }
    }

    private func runSearch() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await UHDDanmuClient.shared.searchAnime(server: server, keyword: keyword)
            animes = found
            if let first = found.first {
                selectedAnime = first
                await loadEpisodes(animeId: first.animeId)
            } else {
                episodes = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEpisodes(animeId: Int) async {
        errorMessage = nil
        do {
            episodes = try await UHDDanmuClient.shared.fetchBangumiEpisodes(server: server, animeId: animeId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickEpisode(_ ep: UHDDanmuEpisodeOption) async {
        isLoadingComments = true
        errorMessage = nil
        defer { isLoadingComments = false }
        do {
            let list = try await UHDDanmuClient.shared.fetchComments(server: server, commentId: ep.episodeId)
            let label = [selectedAnime?.animeTitle, ep.episodeTitle].compactMap { $0 }.joined(separator: " · ")
            onSelectEpisode(label, ep.episodeId, list)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Reactive Watch Party HUD Subviews (Observe UHDWatchPartySession directly without churning PlayerView body)

public struct WatchPartyTopStatusPill: View {
    @ObservedObject public var session: UHDWatchPartySession
    public let onTap: () -> Void

    public init(session: UHDWatchPartySession, onTap: @escaping () -> Void) {
        self.session = session
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.connectionState == .connected ? Color.green : Color.orange)
                    .frame(width: 6.5, height: 6.5)
                Text("同看 \(session.snapshot?.members.count ?? 1)/\(session.snapshot?.maxMembers ?? 4)")
                    .font(.system(size: 11.5, weight: .semibold))
                if let inv = session.inviteCode, !inv.isEmpty {
                    Text(UHDLoginCodeNormalizer.formattedDisplay(inv))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("打开同看房间面板")
    }
}

public struct WatchPartyActiveRoomDrawerView: View {
    @ObservedObject public var session: UHDWatchPartySession
    public let accentColor: Color
    public let onCopyToast: (String, String) -> Void
    public let onLeave: () -> Void
    public let onEnd: () -> Void

    public init(
        session: UHDWatchPartySession,
        accentColor: Color,
        onCopyToast: @escaping (String, String) -> Void,
        onLeave: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.session = session
        self.accentColor = accentColor
        self.onCopyToast = onCopyToast
        self.onLeave = onLeave
        self.onEnd = onEnd
    }

    public var body: some View {
        let snap = session.snapshot
        VStack(alignment: .leading, spacing: 10) {
            card {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.connectionState == .connected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(snap?.localizedPhase ?? "连接中...")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text(session.isHost ? "房主" : "成员")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(session.isHost ? accentColor.opacity(0.65) : Color.white.opacity(0.14)))
                }

                if let invite = session.inviteCode, !invite.isEmpty {
                    HStack(spacing: 8) {
                        Text(UHDLoginCodeNormalizer.formattedDisplay(invite))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(invite, forType: .string)
                            onCopyToast("已复制邀请码 \(invite)", "doc.on.doc.fill")
                        } label: {
                            Text("复制码")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            let link = "\(session.server.mainLineURL)/stream/play?invite=\(invite)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            onCopyToast("已复制同看邀请链接", "link")
                        } label: {
                            Text("复制链接")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if session.isHost, let snap {
                    Divider().opacity(0.20)
                    HStack {
                        Text(snap.locked ? "房间已锁定（禁止新成员加入）" : "房间开放中")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer()
                        Button {
                            let targetLock = !snap.locked
                            Task {
                                try? await UHDWatchPartyClient.shared.setLocked(server: session.server, roomId: session.roomId, locked: targetLock)
                            }
                        } label: {
                            Text(snap.locked ? "解锁房间" : "锁定房间")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(snap.locked ? Color.orange.opacity(0.45) : Color.white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let members = snap?.members {
                card {
                    Text("房间成员 (\(members.count)/\(snap?.maxMembers ?? 10))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))

                    ForEach(members) { m in
                        let memberIsHost = (m.userId == snap?.hostId)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(m.online ? Color.green : Color.gray)
                                .frame(width: 6.5, height: 6.5)
                            Text(m.name)
                                .font(.system(size: 12, weight: memberIsHost ? .bold : .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if memberIsHost {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.yellow)
                            }
                            Spacer()
                            Text(m.localizedStatus)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.62))

                            if session.isHost && !memberIsHost {
                                Menu {
                                    Button("移交房主") {
                                        Task { try? await UHDWatchPartyClient.shared.transferHost(server: session.server, roomId: session.roomId, userId: m.userId) }
                                    }
                                    Button("移出房间", role: .destructive) {
                                        Task { try? await UHDWatchPartyClient.shared.kickMember(server: session.server, roomId: session.roomId, userId: m.userId) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Circle())
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .menuIndicator(.hidden)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: onLeave) {
                    Text("退出房间")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                if session.isHost {
                    Button(action: onEnd) {
                        Text("结束房间")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.16)))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.65))
    }
}

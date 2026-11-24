#if canImport(DonbyUHDModule)
import SwiftUI
import Combine
import DonbyCore
import DonbyNetwork
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

// MARK: - Server Context Menu & Enhanced Route/Speed-Test Sheet Slots

private struct UHDServerContextMenuExtraItems: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    let server: EmbyServerConfig

    var body: some View {
        if uhd.isActive(for: server) {
            Button { uhd.accountSheetServer = server } label: {
                Label("账户与流量", systemImage: "gauge.with.dots.needle.67percent")
            }
            Button {
                appState.activeServerId = server.id
                uhd.showWatchPartyJoinSheet = true
            } label: {
                Label("加入同看", systemImage: "person.2.wave.2")
            }
        }
    }
}

private struct UHDServerLogoutMenuItem: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    let server: EmbyServerConfig

    var body: some View {
        if uhd.isActive(for: server) && !server.accessToken.isEmpty {
            Button {
                Task { await uhd.logoutServer(server, appState: appState) }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

private struct UHDLineAndAccountSheetView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    @StateObject private var speedModel = UHDSpeedTestSessionModel()

    let serverId: UUID
    let onDismiss: () -> Void

    private enum SheetTab: String, CaseIterable, Identifiable {
        case lines = "线路"
        case account = "账户"
        var id: String { rawValue }
    }

    @State private var activeTab: SheetTab = .lines

    private var server: EmbyServerConfig? {
        appState.servers.first(where: { $0.id == serverId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 12) {
                    ServerIconView(server: server, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("线路与测速")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("\(server.name) · 当前：\(server.activeLineName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }

                    Spacer()

                    DonbySegmentedControl(
                        options: SheetTab.allCases,
                        selection: $activeTab,
                        isLightMode: appState.isLightMode,
                        accentColor: appState.accentColor,
                        accentTextColor: appState.accentTextColor,
                        fontSize: 12,
                        horizontalPadding: 14,
                        verticalPadding: 5,
                        title: { $0.rawValue }
                    )

                    ToolbarVectorButton(tooltip: "关闭", action: {
                        speedModel.cancel()
                        onDismiss()
                    }) { hovered in
                        let iconCol = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconCol)
                    }
                }

                Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

                if activeTab == .account {
                    UHDAccountDashboardContent(server: server, showRouteSwitchAction: false, onDismiss: onDismiss)
                } else {
                    linesBody(server: server)
                }
            }
        }
        .padding(22)
        .frame(width: 610)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .onDisappear {
            speedModel.cancel()
        }
    }

    @ViewBuilder
    private func linesBody(server: EmbyServerConfig) -> some View {
        UHDCapabilitySummaryStrip(server: server)

        let rowCount = !server.backupLines.isEmpty ? server.backupLines.count : 1
        let listHeight = min(max(CGFloat(rowCount) * 60, 124), 260)

        ScrollView {
            VStack(spacing: 8) {
                if server.backupLines.isEmpty {
                    ServerLineOptionRow(
                        title: "默认主线路",
                        url: ServerLineInfo(name: "默认主线路", url: server.mainLineURL).cleanDisplayHost,
                        lastSpeedMbps: nil,
                        isSelected: server.selectedLineId == nil,
                        isTesting: false,
                        onRunSpeedTest: nil
                    ) {
                        appState.switchLineImmediate(to: nil, for: server.id)
                        onDismiss()
                    }
                }

                ForEach(server.backupLines) { line in
                    let canSpeedTest = (line.domainId?.isEmpty == false)
                    let isTestingLine = speedModel.isSpeedTesting && speedModel.testingDomainId == line.domainId
                    let speedAction: (() -> Void)? = canSpeedTest ? {
                        if let did = line.domainId, !speedModel.isSpeedTesting {
                            speedModel.launchSingle(server: server, domainId: did, appState: appState)
                        }
                    } : nil

                    ServerLineOptionRow(
                        title: line.cleanDisplayName,
                        url: line.cleanDisplayHost,
                        lastSpeedMbps: line.lastSpeedMbps,
                        isSelected: server.selectedLineId == line.id,
                        isTesting: isTestingLine,
                        onRunSpeedTest: speedAction
                    ) {
                        appState.switchLineImmediate(to: line.id, for: server.id)
                        onDismiss()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: listHeight)

        UHDSpeedTestConsoleView(model: speedModel, server: server)

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

            UHDProxyRulesPopoverButton()

            Spacer()

            Button {
                speedModel.cancel()
                onDismiss()
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
        .task(id: server.id) {
            await appState.refreshServerCapabilities(for: server)
        }
    }
}

// MARK: - Player Companion Implementation (Danmu + Watch Party Sync)

@MainActor
final class UHDPlayerCompanionController: ObservableObject, DonbyPlayerCompanion {
    let server: EmbyServerConfig
    weak var appState: AppState?
    private let notifyHost: () -> Void

    @Published var uhdDanmuTrack: UHDDanmuTrack? = nil { didSet { notifyHost() } }
    @Published var uhdDanmuMatchedTitle: String = "" { didSet { notifyHost() } }
    @Published var isLoadingUHDDanmu: Bool = false { didSet { notifyHost() } }
    @Published var showUHDDanmuPickerSheet: Bool = false { didSet { notifyHost() } }
    @Published var showWatchPartyCreateSheetInPlayer: Bool = false { didSet { notifyHost() } }

    private var isApplyingWatchPartyRemoteState: Bool = false
    private var lastWatchPartyEpoch: Int = -1
    private var lastWatchPartyHostReportUptime: TimeInterval = 0
    private var lastWatchPartyMemberStatus: String = ""
    private var boundRoomId: String? = nil
    private var uhdSub: AnyCancellable?

    private var pauseAndGetPosition: (() -> Double)?
    private var playDriver: (() -> Void)?
    private var pauseDriver: (() -> Void)?
    private var seekAccurateDriver: ((Double) -> Void)?
    private var setRateDriver: ((Float) -> Void)?
    private var switchMediaDriver: ((EmbyItem, ResolvedPlaybackResource, Double) -> Void)?
    private var snapshotProvider: (() -> DonbyPlayerStateSnapshot)?

    init(server: EmbyServerConfig, appState: AppState, notifyHost: @escaping () -> Void) {
        self.server = server
        self.appState = appState
        self.notifyHost = notifyHost
        self.uhdSub = UHDModuleManager.shared.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyHost()
                Task { @MainActor [weak self] in
                    self?.bindActiveWatchPartyCallbacksIfNeeded()
                }
            }
        }
    }

    var showsCompanionDrawerTab: Bool {
        UHDModuleManager.shared.isActive(for: server) || UHDModuleManager.shared.activeWatchPartySession != nil
    }

    func bindDriver(
        pauseAndGetPosition: @escaping () -> Double,
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        seekAccurate: @escaping (Double) -> Void,
        setRate: @escaping (Float) -> Void,
        switchMedia: @escaping (EmbyItem, ResolvedPlaybackResource, Double) -> Void,
        snapshot: @escaping () -> DonbyPlayerStateSnapshot
    ) {
        self.pauseAndGetPosition = pauseAndGetPosition
        self.playDriver = play
        self.pauseDriver = pause
        self.seekAccurateDriver = seekAccurate
        self.setRateDriver = setRate
        self.switchMediaDriver = switchMedia
        self.snapshotProvider = snapshot
        bindActiveWatchPartyCallbacksIfNeeded()
    }

    func onAppear() {
        bindActiveWatchPartyCallbacksIfNeeded()
    }

    func onMediaOrFirstFrameChanged(
        item: EmbyItem,
        mediaSource: MediaSourceInfo,
        enableDanmaku: Bool,
        hasRenderedFirstFrame: Bool
    ) async {
        guard UHDModuleManager.shared.isActive(for: server), enableDanmaku else { return }
        guard hasRenderedFirstFrame else { return }
        guard !server.accessToken.isEmpty else { return }
        // Yield slightly after first video frame renders so 2 MB danmu fetch never competes with initial stream buffering
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        isLoadingUHDDanmu = true
        defer { isLoadingUHDDanmu = false }
        if let loaded = try? await UHDDanmuClient.shared.autoLoadComments(
            server: server,
            item: item,
            mediaSource: mediaSource
        ) {
            guard !Task.isCancelled else { return }
            uhdDanmuMatchedTitle = loaded.matchedTitle
            uhdDanmuTrack = UHDDanmuTrack(title: loaded.matchedTitle, comments: loaded.comments)
        }
    }

    func onProgressTick(
        nowUptime: TimeInterval,
        livePos: Double,
        isPlaying: Bool,
        hasRenderedFirstFrame: Bool,
        isOpeningMedia: Bool,
        isWaitingForSeekOrBuffer: Bool,
        didHandlePlaybackEnded: Bool,
        playbackSpeed: Float
    ) {
        guard let wp = UHDModuleManager.shared.activeWatchPartySession, hasRenderedFirstFrame && !isOpeningMedia else { return }
        if wp.isHost {
            if isPlaying && !didHandlePlaybackEnded && (nowUptime - lastWatchPartyHostReportUptime) >= 1.0 {
                lastWatchPartyHostReportUptime = nowUptime
                wp.sendPlayback(state: "playing", positionSeconds: livePos, rate: Double(playbackSpeed))
            }
        } else {
            let desiredStatus = isWaitingForSeekOrBuffer ? "buffering" : "ready"
            if desiredStatus != lastWatchPartyMemberStatus {
                lastWatchPartyMemberStatus = desiredStatus
                wp.sendMemberStatus(desiredStatus)
            }
        }
    }

    func onPlaybackEnded(livePos: Double, playbackSpeed: Float) {
        if let wp = UHDModuleManager.shared.activeWatchPartySession, wp.isHost {
            wp.sendPlayback(state: "ended", positionSeconds: livePos, rate: Double(playbackSpeed))
        }
    }

    func onLocalPlayPauseChanged(isPlaying: Bool, livePos: Double, playbackSpeed: Float) {
        guard !isApplyingWatchPartyRemoteState,
              let wp = UHDModuleManager.shared.activeWatchPartySession,
              wp.isHost else { return }
        wp.sendPlayback(state: isPlaying ? "playing" : "paused", positionSeconds: livePos, rate: Double(playbackSpeed))
    }

    func onLocalSeek(seconds: Double, isPlaying: Bool, playbackSpeed: Float) {
        guard !isApplyingWatchPartyRemoteState,
              let wp = UHDModuleManager.shared.activeWatchPartySession,
              wp.isHost else { return }
        wp.sendPlayback(state: isPlaying ? "playing" : "paused", positionSeconds: seconds, rate: Double(playbackSpeed))
    }

    func onLocalRateChanged(rate: Double, isPlaying: Bool, livePos: Double) {
        guard !isApplyingWatchPartyRemoteState,
              let wp = UHDModuleManager.shared.activeWatchPartySession,
              wp.isHost else { return }
        wp.sendPlayback(state: isPlaying ? "playing" : "paused", positionSeconds: livePos, rate: rate)
    }

    func onLocalEpisodeSwitched(assetId: String, positionSeconds: Double, playbackSpeed: Float) {
        guard !isApplyingWatchPartyRemoteState,
              let wp = UHDModuleManager.shared.activeWatchPartySession,
              wp.isHost else { return }
        wp.sendSwitch(assetId: assetId, positionSeconds: positionSeconds, rate: Double(playbackSpeed), playing: true)
    }

    func onPlayerClose() {
        if UHDModuleManager.shared.activeWatchPartySession != nil {
            UHDModuleManager.shared.leaveOrEndActiveWatchParty(endRoom: false)
        }
    }

    private func bindActiveWatchPartyCallbacksIfNeeded() {
        guard let wp = UHDModuleManager.shared.activeWatchPartySession else {
            boundRoomId = nil
            return
        }
        guard boundRoomId != wp.roomId || wp.onRoomSnapshot == nil else { return }
        boundRoomId = wp.roomId

        wp.onRoomSnapshot = { [weak self] room in
            self?.handleWatchPartySnapshot(room, session: wp)
        }
        wp.onStaleRevision = { [weak self] latest in
            guard let self, wp.isHost, latest != nil, let snap = self.snapshotProvider?() else { return }
            wp.sendPlayback(
                state: snap.isPlaying ? "playing" : "paused",
                positionSeconds: snap.liveCurrentTime,
                rate: Double(snap.playbackSpeed)
            )
        }
        wp.onTerminated = { [weak self] reason in
            self?.appState?.showToast(reason, icon: "person.2.slash")
            if UHDModuleManager.shared.activeWatchPartySession?.roomId == wp.roomId {
                UHDModuleManager.shared.activeWatchPartySession = nil
            }
        }
        if let existing = wp.snapshot {
            handleWatchPartySnapshot(existing, session: wp)
        }
    }

    private func handleWatchPartySnapshot(_ room: UHDWatchPartyRoomSnapshot, session wp: UHDWatchPartySession) {
        guard let snap = snapshotProvider?() else { return }
        if wp.isHost {
            if room.phase == "aligning", let pauseAndPos = pauseAndGetPosition {
                isApplyingWatchPartyRemoteState = true
                let exactPos = pauseAndPos()
                isApplyingWatchPartyRemoteState = false
                wp.sendPlayback(state: "paused", positionSeconds: exactPos, rate: Double(snap.playbackSpeed))
                appState?.showToast("新成员加入，已暂停等待对齐", icon: "person.2.wave.2")
            } else if room.phase == "preparing" && snap.hasRenderedFirstFrame && !snap.isOpeningMedia {
                wp.sendPlayback(
                    state: snap.isPlaying ? "playing" : "paused",
                    positionSeconds: snap.liveCurrentTime,
                    rate: Double(snap.playbackSpeed)
                )
            }
            return
        }

        if room.media.assetId != snap.currentMediaSourceId && room.epoch != lastWatchPartyEpoch {
            lastWatchPartyEpoch = room.epoch
            let srv = wp.server
            let targetPos = room.extrapolatedPositionSeconds(estimatedServerNowMs: wp.estimatedServerNowMs)
            let preset = appState?.preferredVersionPreset ?? .higherBitrate
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isEp = room.media.itemType.lowercased() == "episode"
                let stub = EmbyItem(
                    id: room.media.itemId,
                    name: "同看影片",
                    serverId: srv.serverId,
                    type: isEp ? "Episode" : "Movie",
                    uhdMediaType: isEp ? "episode" : "movie"
                )
                let detailed = (try? await UHDStreamClient.shared.fetchItemDetail(server: srv, item: stub)) ?? stub
                if let res = try? await UHDStreamClient.shared.resolvePlaybackResource(
                    server: srv,
                    item: detailed,
                    preferredSourceId: room.media.assetId,
                    preferredPreset: preset
                ) {
                    self.isApplyingWatchPartyRemoteState = true
                    self.switchMediaDriver?(detailed, res, targetPos)
                    self.isApplyingWatchPartyRemoteState = false
                }
            }
            return
        }

        guard snap.hasRenderedFirstFrame && !snap.isOpeningMedia else { return }
        isApplyingWatchPartyRemoteState = true
        defer { isApplyingWatchPartyRemoteState = false }

        let targetRate = Float(max(0.25, min(3.0, room.rate)))
        if abs(snap.playbackSpeed - targetRate) > 0.04 {
            setRateDriver?(targetRate)
        }

        let targetPos = room.extrapolatedPositionSeconds(estimatedServerNowMs: wp.estimatedServerNowMs)
        if abs(targetPos - snap.liveCurrentTime) > 1.25 {
            seekAccurateDriver?(targetPos)
        }

        let shouldPlay = (room.phase == "playing")
        if shouldPlay && !snap.isPlaying {
            playDriver?()
        } else if !shouldPlay && snap.isPlaying {
            pauseDriver?()
        }
    }

    func makeVideoOverlay(
        isEnabled: Bool,
        isPlaying: Bool,
        playbackRate: Double,
        timeProvider: @escaping () -> (Double, TimeInterval)
    ) -> AnyView {
        if UHDModuleManager.shared.isActive(for: server) {
            return AnyView(
                UHDDanmuLiveOverlay(
                    track: uhdDanmuTrack,
                    isEnabled: isEnabled,
                    isPlaying: isPlaying,
                    playbackRate: playbackRate,
                    timeProvider: timeProvider
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
            )
        }
        return AnyView(EmptyView())
    }

    func makeTopBarControls(activeDrawer: Binding<PlayerDrawerTab?>) -> AnyView {
        AnyView(UHDPlayerTopBarControlsView(controller: self, activeDrawer: activeDrawer))
    }

    func makeContextMenuItems(activeDrawer: Binding<PlayerDrawerTab?>) -> AnyView {
        AnyView(UHDPlayerContextMenuItemsView(controller: self, activeDrawer: activeDrawer))
    }

    func makeDrawerContent(accentTint: Color) -> AnyView {
        AnyView(UHDPlayerDrawerContentView(controller: self, accentTint: accentTint))
    }

    func wrapPlayerSheets(_ content: AnyView, currentItem: EmbyItem, currentMediaSource: MediaSourceInfo) -> AnyView {
        AnyView(
            content.modifier(
                UHDPlayerSheetsModifier(
                    controller: self,
                    currentItem: currentItem,
                    currentMediaSource: currentMediaSource
                )
            )
        )
    }
}

private struct UHDPlayerTopBarControlsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: UHDPlayerCompanionController
    @ObservedObject private var uhd = UHDModuleManager.shared
    @Binding var activeDrawer: PlayerDrawerTab?

    var body: some View {
        if let wp = uhd.activeWatchPartySession {
            WatchPartyTopStatusPill(session: wp) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    activeDrawer = (activeDrawer == .watchParty) ? nil : .watchParty
                }
            }
        }

        if uhd.isActive(for: controller.server) {
            Button {
                appState.enableDanmaku.toggle()
                appState.showToast(
                    appState.enableDanmaku ? "已开启弹幕" : "已关闭弹幕",
                    icon: appState.enableDanmaku ? "text.bubble.fill" : "text.bubble"
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: appState.enableDanmaku ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(
                        appState.enableDanmaku && !(controller.uhdDanmuTrack?.comments.isEmpty ?? true)
                            ? "弹幕 \(controller.uhdDanmuTrack?.comments.count ?? 0)"
                            : "弹幕"
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(appState.enableDanmaku ? .white : .white.opacity(0.72))
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(
                    Capsule()
                        .fill(
                            appState.enableDanmaku
                                ? (appState.isMonochromeTheme
                                    ? Color(red: 0.08, green: 0.085, blue: 0.105).opacity(0.84)
                                    : appState.accentColor.opacity(0.82))
                                : Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.72)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    Color.white.opacity(appState.enableDanmaku ? 0.38 : 0.18),
                                    lineWidth: 0.7
                                )
                        )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("切换弹幕")
        }
    }
}

private struct UHDPlayerContextMenuItemsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: UHDPlayerCompanionController
    @ObservedObject private var uhd = UHDModuleManager.shared
    @Binding var activeDrawer: PlayerDrawerTab?

    var body: some View {
        if uhd.isActive(for: controller.server) {
            Button(uhd.activeWatchPartySession != nil ? "打开同看面板" : "同看房间...") {
                withAnimation(.easeInOut(duration: 0.18)) { activeDrawer = .watchParty }
            }
            Button(appState.enableDanmaku ? "关闭弹幕" : "开启弹幕") {
                appState.enableDanmaku.toggle()
            }
            Button("匹配弹幕...") {
                controller.showUHDDanmuPickerSheet = true
            }
        }
    }
}

private struct UHDPlayerDrawerContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: UHDPlayerCompanionController
    @ObservedObject private var uhd = UHDModuleManager.shared
    let accentTint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let wp = uhd.activeWatchPartySession {
                WatchPartyActiveRoomDrawerView(
                    session: wp,
                    accentColor: accentTint,
                    onCopyToast: { msg, icon in appState.showToast(msg, icon: icon) },
                    onLeave: {
                        uhd.leaveOrEndActiveWatchParty(endRoom: false)
                        appState.showToast("已退出同看房间", icon: "rectangle.portrait.and.arrow.right")
                    },
                    onEnd: {
                        uhd.leaveOrEndActiveWatchParty(endRoom: true)
                        appState.showToast("已结束同看房间", icon: "xmark.circle.fill")
                    }
                )
            } else {
                PlayerDrawerGlassCard {
                    Text("同看房间")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("邀请好友同步进度观影")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.68))

                    Button {
                        controller.showWatchPartyCreateSheetInPlayer = true
                    } label: {
                        HStack {
                            Image(systemName: "person.2.wave.2.fill")
                            Text("创建同看房间")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appState.isMonochromeTheme ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(accentTint))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }

            if uhd.isActive(for: controller.server) {
                PlayerDrawerGlassCard {
                    HStack {
                        Text("弹幕")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: $appState.enableDanmaku)
                            .labelsHidden()
                            .toggleStyle(
                                DonbySwitchToggleStyle(
                                    isLightMode: false,
                                    accentColor: accentTint,
                                    accentTextColor: appState.isMonochromeTheme ? .black : .white,
                                    compact: true
                                )
                            )
                    }
                    if !controller.uhdDanmuMatchedTitle.isEmpty {
                        Text("\(controller.uhdDanmuMatchedTitle)（\(controller.uhdDanmuTrack?.comments.count ?? 0) 条）")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    } else if controller.isLoadingUHDDanmu {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在匹配弹幕...")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                    }

                    Button {
                        controller.showUHDDanmuPickerSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("手动匹配弹幕")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            PlayerDrawerRowBackground(
                                isSelected: false,
                                isMonochromeTheme: appState.isMonochromeTheme,
                                accentColor: appState.accentColor
                            )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct UHDPlayerSheetsModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: UHDPlayerCompanionController
    let currentItem: EmbyItem
    let currentMediaSource: MediaSourceInfo

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $controller.showUHDDanmuPickerSheet) {
                UHDDanmuPickerSheet(
                    server: controller.server,
                    initialKeyword: currentItem.isEpisode ? (currentItem.seriesName ?? currentItem.name) : currentItem.name,
                    onSelectEpisode: { label, _, comments in
                        controller.uhdDanmuMatchedTitle = label
                        controller.uhdDanmuTrack = UHDDanmuTrack(title: label, comments: comments)
                        appState.enableDanmaku = true
                        appState.showToast("已加载 \(comments.count) 条弹幕 · \(label)", icon: "text.bubble.fill")
                    }
                )
            }
            .sheet(isPresented: $controller.showWatchPartyCreateSheetInPlayer) {
                UHDWatchPartyCreateSheet(
                    server: controller.server,
                    item: currentItem,
                    preferredSourceId: currentMediaSource.id
                )
                .environmentObject(appState)
                .preferredColorScheme(.dark)
            }
    }
}

// MARK: - Registered UI Extension Plugin Bridge

@MainActor
public final class UHDAppExtensionPlugin: DonbyAppUIExtensionPlugin {
    public static let shared = UHDAppExtensionPlugin()

    private init() {}

    public static func registerIfNeeded() {
        _ = UHDModuleManager.shared
        DonbyAppExtensionCenter.shared.register(shared)
    }

    public var isEnabled: Bool {
        UHDModuleManager.shared.isEnabled
    }

    public func isActive(for server: EmbyServerConfig?) -> Bool {
        UHDModuleManager.shared.isActive(for: server)
    }

    public func extraHomeItemLists() -> [[EmbyItem]] {
        guard UHDModuleManager.shared.isEnabled else { return [] }
        return [UHDModuleManager.shared.hotItems, UHDModuleManager.shared.animeHotItems]
    }

    public func resetHomeShelves() {
        UHDModuleManager.shared.resetHomeShelves()
    }

    public func authenticateAndConfigureServer(
        draft: EmbyServerConfig,
        loginCode: String?,
        customEndpointOverride: String?,
        autoSyncDomains: Bool,
        appState: AppState
    ) async throws -> (server: EmbyServerConfig, usedChinaOptimizedLine: Bool) {
        try await UHDModuleManager.shared.authenticateAndConfigureServer(
            draft: draft,
            uhdLoginCode: loginCode,
            customEndpointOverride: customEndpointOverride,
            autoSyncDomains: autoSyncDomains,
            appState: appState
        )
    }

    public func syncPlaybackDomains(for serverId: UUID, appState: AppState, showFeedback: Bool) async {
        await UHDModuleManager.shared.syncPlaybackDomains(for: serverId, appState: appState, showFeedback: showFeedback)
    }

    public func loadHomeContent(
        for server: EmbyServerConfig,
        appState: AppState,
        isCurrentGeneration: @escaping () -> Bool
    ) async {
        await UHDModuleManager.shared.loadHomeContent(
            for: server,
            appState: appState,
            isCurrentGeneration: isCurrentGeneration
        )
    }

    public func resolveSeriesStartEpisode(
        server: EmbyServerConfig,
        seriesItem: EmbyItem
    ) async throws -> (episodes: [EmbyItem], preferredTarget: EmbyItem?) {
        try await UHDModuleManager.shared.resolveSeriesStartEpisode(server: server, seriesItem: seriesItem)
    }

    public func refreshAccountSnapshot(for server: EmbyServerConfig, appState: AppState) async {
        await UHDModuleManager.shared.refreshAccountSnapshot(for: server, appState: appState)
    }

    public func refreshMissingAccountSnapshots(servers: [EmbyServerConfig], appState: AppState) async {
        let uhd = UHDModuleManager.shared
        guard uhd.isEnabled else { return }
        for srv in servers where srv.type == .uhdNative && !srv.host.isEmpty && !srv.accessToken.isEmpty {
            if uhd.accountSnapshots[srv.id] == nil {
                await uhd.refreshAccountSnapshot(for: srv, appState: appState)
            }
        }
    }

    public func serverCardBadgeText(for server: EmbyServerConfig) -> String? {
        let uhd = UHDModuleManager.shared
        guard uhd.isActive(for: server),
              let traffic = uhd.accountSnapshots[server.id]?.traffic else { return nil }
        return traffic.shortToolbarBadgeText
    }

    public func preferredEditorType(forUnconfigured server: EmbyServerConfig) -> ServerType? {
        (UHDModuleManager.shared.isEnabled && server.usesUHDLogo) ? .uhdNative : nil
    }

    public func initialCustomEndpoint(for server: EmbyServerConfig) -> String {
        guard server.type == .uhdNative else { return "" }
        let hostLower = server.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !hostLower.isEmpty
            && hostLower != UHDModuleEndpoints.primaryChinaOptimizedHost
            && hostLower != UHDModuleEndpoints.fallbackStandardHost {
            return server.mainLineURL
        }
        return ""
    }

    public func applyCustomEndpointOnSaveOnly(_ customEndpoint: String, to draft: inout EmbyServerConfig) {
        let trimmed = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = UHDModuleEndpoints.parseEndpointComponents(from: trimmed)
        draft.host = parsed.host
        draft.isHttps = parsed.isHttps
        draft.port = parsed.port
    }

    public func formatLoginCodeDisplay(_ raw: String) -> String {
        UHDLoginCodeNormalizer.formattedDisplay(raw)
    }

    public func isValidLoginCode(_ raw: String) -> Bool {
        UHDLoginCodeNormalizer.normalize(raw) != nil
    }

    public func homeShelves(for server: EmbyServerConfig?) -> [HomeShelfSection] {
        let uhd = UHDModuleManager.shared
        guard uhd.isActive(for: server) else { return [] }
        var result: [HomeShelfSection] = []
        if !uhd.hotItems.isEmpty {
            result.append(HomeShelfSection(id: "uhd_hot", title: "热门影视", kind: .poster, items: uhd.hotItems))
        }
        if !uhd.animeHotItems.isEmpty {
            result.append(HomeShelfSection(id: "uhd_anime_hot", title: "热门动漫", kind: .poster, items: uhd.animeHotItems))
        }
        return result
    }

    public func fetchAvailableGenres(for server: EmbyServerConfig) async -> [String]? {
        guard UHDModuleManager.shared.isActive(for: server),
              let genres = try? await UHDStreamClient.shared.fetchGenres(server: server) else { return nil }
        return genres.map(\.name)
    }

    public func fetchLibraryPage(
        server: EmbyServerConfig,
        library: EmbyItem,
        query: String,
        sortField: EmbySortField,
        ascending: Bool,
        filterUnwatchedOnly: Bool,
        filterFavoritesOnly: Bool,
        selectedGenreFilter: String,
        cursor: String?
    ) async throws -> DonbyExtensionLibraryPage {
        if !query.isEmpty {
            let found = try await UHDStreamClient.shared.search(server: server, query: query, limit: 50)
            return DonbyExtensionLibraryPage(items: found, nextCursor: nil, hasMore: false, totalOverride: found.count)
        }
        if filterFavoritesOnly {
            let libType: String? = {
                let lower = library.name.lowercased()
                if lower.contains("电影") || lower.contains("movie") { return "movie" }
                if lower.contains("剧") || lower.contains("动漫") || lower.contains("综艺") || lower.contains("tv") || lower.contains("series") { return "tv" }
                return nil
            }()
            let favPage = try await UHDStreamClient.shared.fetchFavorites(
                server: server,
                type: libType,
                limit: 50,
                cursor: cursor
            )
            var fetched = favPage.items
            if filterUnwatchedOnly { fetched = fetched.filter { $0.userData?.played != true } }
            if !selectedGenreFilter.isEmpty {
                fetched = fetched.filter { $0.genres?.contains(selectedGenreFilter) == true }
            }
            return DonbyExtensionLibraryPage(
                items: fetched,
                nextCursor: favPage.nextCursor,
                hasMore: favPage.nextCursor != nil,
                totalOverride: favPage.total
            )
        }
        let uhdSortBy: String = switch sortField {
        case .premiereDate: "release_date"
        case .communityRating: "rating"
        case .hot: "hot"
        case .sortName: "title"
        default: "asset_updated_at"
        }
        let pageRes = try await UHDStreamClient.shared.fetchCollectionItems(
            server: server,
            collectionId: library.id,
            sortBy: uhdSortBy,
            sortOrder: ascending ? "asc" : "desc",
            limit: 50,
            cursor: cursor
        )
        var fetched = pageRes.items
        if filterUnwatchedOnly { fetched = fetched.filter { $0.userData?.played != true } }
        if filterFavoritesOnly { fetched = fetched.filter { $0.userData?.isFavorite == true } }
        if !selectedGenreFilter.isEmpty {
            fetched = fetched.filter { $0.genres?.contains(selectedGenreFilter) == true }
        }
        return DonbyExtensionLibraryPage(
            items: fetched,
            nextCursor: pageRes.nextCursor,
            hasMore: pageRes.nextCursor != nil,
            totalOverride: library.childCount
        )
    }

    public func loadDetailPayload(
        server: EmbyServerConfig,
        initialItem: EmbyItem,
        targetSeriesId: String?
    ) async -> DonbyExtensionDetailPayload {
        async let detailTask = try? UHDStreamClient.shared.fetchItemDetail(server: server, item: initialItem)
        let creditMediaId = initialItem.isEpisode ? (initialItem.seriesId ?? initialItem.id) : initialItem.id
        async let creditsTask = try? UHDStreamClient.shared.fetchCredits(server: server, mediaId: creditMediaId)
        async let assetsTask: [MediaSourceInfo]? = {
            guard !initialItem.isSeries else { return nil }
            return try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: initialItem)
        }()
        async let seasonsTask: [EmbyItem]? = {
            guard let sid = targetSeriesId, !sid.isEmpty else { return nil }
            return try? await UHDStreamClient.shared.fetchSeasons(server: server, tvId: sid)
        }()
        async let tvPlaybackStateTask: UHDTVPlaybackState? = {
            guard let sid = targetSeriesId, !sid.isEmpty else { return nil }
            return try? await UHDStreamClient.shared.fetchTVPlaybackState(server: server, tvId: sid)
        }()

        var enriched: EmbyItem? = nil
        if let detailed = await detailTask {
            let loadedSources = await assetsTask
            let loadedPeople = await creditsTask
            enriched = detailed.withDetailEnrichment(mediaSources: loadedSources, people: loadedPeople)
        }
        let seasons = await seasonsTask
        let prefEp = await tvPlaybackStateTask?.preferredEpisode
        let preferredTuple = prefEp.map { ($0.seasonId, $0.seasonNumber, $0.episodeId) }
        return DonbyExtensionDetailPayload(enrichedItem: enriched, seasons: seasons, preferredEpisode: preferredTuple)
    }

    public func openPersonSheet(server: EmbyServerConfig, person: EmbyPerson) {
        guard UHDModuleManager.shared.isActive(for: server) else { return }
        UHDModuleManager.shared.activePersonSheet = UHDPersonSheetTarget(server: server, person: person)
    }

    public func wrapRootSheets(_ content: AnyView) -> AnyView {
        AnyView(content.donbyUHDModuleSheets())
    }

    public func makeSettingsCard() -> AnyView {
        AnyView(UHDSettingsModuleCard())
    }

    public func makeEmbyToolbarButtons(server: EmbyServerConfig) -> AnyView {
        AnyView(UHDEmbyToolbarButtons(server: server))
    }

    public func makeServerContextMenuExtraItems(server: EmbyServerConfig) -> AnyView {
        AnyView(UHDServerContextMenuExtraItems(server: server))
    }

    public func makeServerLogoutMenuItem(server: EmbyServerConfig) -> AnyView {
        AnyView(UHDServerLogoutMenuItem(server: server))
    }

    public func makeCustomLineSwitchView(serverId: UUID, onDismiss: @escaping () -> Void) -> AnyView? {
        AnyView(UHDLineAndAccountSheetView(serverId: serverId, onDismiss: onDismiss))
    }

    public func makeDetailWatchPartyCreateSheet(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String?
    ) -> AnyView {
        AnyView(
            UHDWatchPartyCreateSheet(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId
            )
        )
    }

    public func makePlayerCompanion(
        server: EmbyServerConfig,
        appState: AppState,
        notifyHost: @escaping () -> Void
    ) -> (any DonbyPlayerCompanion)? {
        UHDPlayerCompanionController(server: server, appState: appState, notifyHost: notifyHost)
    }
}
#endif

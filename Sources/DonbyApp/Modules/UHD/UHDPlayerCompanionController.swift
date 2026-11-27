#if canImport(DonbyUHDModule)
import SwiftUI
import Combine
import DonbyCore
import DonbyNetwork
import DonbyUHDModule

// MARK: - Player Companion Implementation (Danmu + Watch Party Sync)

@MainActor
final class UHDPlayerCompanionController: ObservableObject, DonbyPlayerCompanion {
    let server: EmbyServerConfig
    weak var appState: AppState?
    private let notifyHost: () -> Void

    @Published var uhdDanmuTrack: UHDDanmuTrack? = nil {
        didSet { if oldValue?.revision != uhdDanmuTrack?.revision { notifyHost() } }
    }
    @Published var uhdDanmuMatchedTitle: String = "" {
        didSet { if oldValue != uhdDanmuMatchedTitle { notifyHost() } }
    }
    @Published var isLoadingUHDDanmu: Bool = false {
        didSet { if oldValue != isLoadingUHDDanmu { notifyHost() } }
    }
    @Published var showUHDDanmuPickerSheet: Bool = false {
        didSet { if oldValue != showUHDDanmuPickerSheet { notifyHost() } }
    }
    @Published var showWatchPartyCreateSheetInPlayer: Bool = false {
        didSet { if oldValue != showWatchPartyCreateSheetInPlayer { notifyHost() } }
    }

    private var isApplyingWatchPartyRemoteState: Bool = false
    private var lastWatchPartyEpoch: Int = -1
    private var lastWatchPartyHostReportUptime: TimeInterval = 0
    private var lastWatchPartyMemberStatus: String = ""
    private var lastFollowSeekUptime: TimeInterval = 0
    private var lastHostAlignToastRevision: Int = -1
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
        self.uhdSub = Publishers.CombineLatest(
            UHDModuleManager.shared.$isEnabled.removeDuplicates(),
            UHDModuleManager.shared.$activeWatchPartySession.map { $0?.roomId }.removeDuplicates()
        )
        .dropFirst()
        .sink { [weak self] _, _ in
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
                if lastHostAlignToastRevision != room.revision {
                    lastHostAlignToastRevision = room.revision
                    appState?.showToast("新成员加入，已暂停等待对齐", icon: "person.2.wave.2")
                }
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
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if abs(targetPos - snap.liveCurrentTime) > 1.25 && (nowUptime - lastFollowSeekUptime) >= 2.0 {
            lastFollowSeekUptime = nowUptime
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
#endif

#if canImport(DonbyUHDModule)
import SwiftUI
import AppKit
import DonbyCore
import DonbyUHDModule

// MARK: - Watch Party Join & Create Sheets

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
                VStack(alignment: .leading, spacing: 2) {
                    Text("加入同看")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("输入 8 位邀请码或粘贴分享链接")
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
                    .background(Color.red.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("8 位邀请码或链接", text: $rawInvite)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
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
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await joinNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isJoining { ProgressView().controlSize(.small) }
                        Text("加入")
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
        .frame(width: 440)
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
            try await UHDModuleManager.shared.joinAndStartWatchParty(server: server, rawInvite: rawInvite, appState: appState)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("创建同看")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(item.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
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
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("人数上限")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Spacer()
                Stepper("\(maxMembers) 人", value: $maxMembers, in: 2...10)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await createNow() }
                } label: {
                    HStack(spacing: 6) {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text("创建房间")
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
        .frame(width: 420)
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
            try await UHDModuleManager.shared.createAndStartWatchParty(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId,
                maxMembers: maxMembers,
                appState: appState
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Danmu Overlay & Picker

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
                Text("匹配弹幕")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                TextField("搜索名称", text: $keyword)
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
                    Text("剧目 (\(animes.count))")
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
                    Text("分集 (\(episodes.count))")
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

// MARK: - Reactive Watch Party HUD Subviews

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
        .help("同看房间")
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
                            onCopyToast("已复制邀请链接", "link")
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
                        Text(snap.locked ? "已锁定" : "开放加入")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer()
                        Button {
                            let targetLock = !snap.locked
                            Task {
                                try? await UHDWatchPartyClient.shared.setLocked(server: session.server, roomId: session.roomId, locked: targetLock)
                            }
                        } label: {
                            Text(snap.locked ? "解锁" : "锁定")
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
                    Text("成员 (\(members.count)/\(snap?.maxMembers ?? 10))")
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
#endif

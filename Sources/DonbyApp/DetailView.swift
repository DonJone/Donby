import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public struct DetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadManager = DonbyDownloadManager.shared
    public let initialItem: EmbyItem
    public let preferOfflineFocus: Bool

    @State private var item: EmbyItem
    @State private var selectedSourceId: String = ""
    @State private var selectedAudioIndex: Int? = nil
    @State private var selectedSubtitleIndex: Int? = nil
    @State private var seasons: [EmbyItem] = []
    @State private var selectedSeasonIndex: Int = 1
    @State private var episodes: [EmbyItem] = []
    @State private var similarItems: [EmbyItem] = []
    @State private var isLoadingDetails: Bool = false
    @State private var focusedEpisodeId: String? = nil
    @State private var selectedEpisodeForInfo: EmbyItem? = nil
    @State private var didUserDisableSubtitle: Bool = false
    @State private var userDidPickEpisodeLocally: Bool = false
    @State private var cachedOfflineGroup: OfflineLibraryGroup? = nil
    @State private var cachedUnpinnedAssets: [CachedMediaSummary] = []

    private var detailSeriesKey: String {
        AppState.detailSeriesKey(for: item)
    }

    public init(item: EmbyItem, preferOfflineFocus: Bool = false) {
        self.initialItem = item
        self.preferOfflineFocus = preferOfflineFocus
        self._item = State(initialValue: item)
    }

    private var effectiveDetailServer: EmbyServerConfig? {
        if let local = cachedOfflineGroup,
           let sid = local.serverId,
           let matched = appState.servers.first(where: { $0.id == sid }) {
            return matched
        }
        if let sIdStr = item.serverId,
           let srv = appState.servers.first(where: { $0.id.uuidString == sIdStr }) {
            return srv
        }
        return appState.activeServer
    }

    private func cachedProgressSnapshot(
        forItemId itemId: String,
        serverId: UUID? = nil,
        mediaSourceId: String? = nil
    ) -> CachedMediaSummary? {
        guard !cachedUnpinnedAssets.isEmpty else { return nil }
        if let serverId, let mediaSourceId, !mediaSourceId.isEmpty {
            let exactKey = DonbyTurboCacheEngine.makeAssetKey(serverId: serverId, itemId: itemId, mediaSourceId: mediaSourceId)
            if let hit = cachedUnpinnedAssets.first(where: { $0.assetKey == exactKey }) {
                return hit
            }
        }
        return cachedUnpinnedAssets.first { summary in
            summary.itemId == itemId &&
            (serverId == nil || summary.serverId == serverId) &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || summary.mediaSourceId == mediaSourceId)
        }
    }

    private var selectedMediaSource: MediaSourceInfo? {
        guard let sources = item.mediaSources, !sources.isEmpty else { return nil }
        return sources.first(where: { $0.id == selectedSourceId }) ?? sources.first
    }

    private var audioStreams: [MediaStream] {
        (selectedMediaSource?.mediaStreams ?? item.allStreams).filter { $0.type?.lowercased() == "audio" }
    }

    private var subtitleStreams: [MediaStream] {
        (selectedMediaSource?.mediaStreams ?? item.allStreams).filter { $0.type?.lowercased() == "subtitle" }
    }

    public var body: some View {
        let canvasCol = DonbyGlassPalette.canvas(isLight: appState.isLightMode)
        return GeometryReader { viewportGeo in
            let heroHeight = min(
                max(440, min(viewportGeo.size.width * 0.42, viewportGeo.size.height * 0.64)),
                680
            )
            ZStack(alignment: .top) {
                canvasCol
                    .ignoresSafeArea(.container, edges: .top)

                // Static 1:1 color-matched weighted top-edge strip (#03):
                // hidden behind the crisp hero at rest; smoothly revealed on pull-down overscroll with zero zoom or jitter.
                HeroTopEdgeBackdropView(
                    server: effectiveDetailServer,
                    item: item,
                    viewportAspect: viewportGeo.size.width / max(1, heroHeight)
                )
                .frame(width: viewportGeo.size.width, height: 240)
                .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroHeaderSection(heroHeight: heroHeight)

                        VStack(alignment: .leading, spacing: 24) {
                            if item.isSeries || !episodes.isEmpty {
                                episodesSection
                            }

                            if let people = item.people, !people.isEmpty {
                                castSection(people: people)
                            }

                            mediaSpecsCard
                                .padding(.horizontal, 28)

                            if !similarItems.isEmpty {
                                similarSection
                            }
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(canvasCol)
                    }
                    .background(DetailScrollViewTopInsetFix())
                }
                .scrollContentBackground(.hidden)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $selectedEpisodeForInfo) { ep in
            EpisodeInfoSheet(episode: ep, isLightMode: appState.isLightMode)
        }
        .onChange(of: selectedSourceId) { _, _ in
            syncStreamsForSelectedSource()
        }
        .task(id: initialItem.id) {
            await loadFullDetailData()
        }
        .task(id: downloadManager.statusIndex) {
            await refreshOfflineAndCacheSnapshots()
        }
        .onDisappear {
            DonbyTurboCacheEngine.shared.cancelDetailPreload()
        }
        .task(id: "\(item.id)|\(heroTargetEpisode?.id ?? "")|\(selectedSourceId)|\(Int(effectivePlayButtonStartSeconds))|\(isLoadingDetails)|\(appState.detailPreloadEnabled)|\(appState.detailPreloadSeconds)") {
            await runDetailPrewarmAndPreload()
        }
    }

    private var effectivePlayButtonStartSeconds: Double {
        let target = heroResolvedPlayTarget
        if target.resumePositionSeconds > 0.5 {
            return target.resumePositionSeconds
        }
        if target.isEpisode, let serverId = effectiveDetailServer?.id ?? appState.activeServer?.id {
            let pref = appState.effectiveSkipPreference(serverId: serverId, item: target)
            if pref.introEnabled && pref.mode == .automatic && pref.introSeconds > 0 {
                return Double(pref.introSeconds)
            }
        }
        return 0.0
    }

    private func runDetailPrewarmAndPreload() async {
        guard !isLoadingDetails else { return }
        guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if item.isSeries && heroTargetEpisode == nil { return }
        let target = heroResolvedPlayTarget
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let sourceHint = (target.id == item.id && !selectedSourceId.isEmpty) ? selectedSourceId : nil
        if server.type == .uhdNative {
            await UHDStreamClient.shared.prewarmPlaybackDomain(server: server)
            if target.isEpisode {
                _ = try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: target)
            }
        } else {
            await EmbyClient.shared.prewarmPlaybackInfo(server: server, itemId: target.id, mediaSourceId: sourceHint)
        }

        guard appState.detailPreloadEnabled,
              appState.turboEnabled,
              appState.activePlayback == nil,
              DonbyDownloadManager.shared.completedEntry(for: target.id, serverId: server.id) == nil else {
            return
        }
        // Gentle debounce so quick detail browsing never wastes traffic
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, appState.activePlayback == nil else { return }

        let preset = appState.preferredVersionPreset
        let enable302 = appState.enable302Cache && server.cache302Request
        let resolved: ResolvedPlaybackResource?
        if server.type == .uhdNative {
            resolved = try? await UHDStreamClient.shared.resolvePlaybackResource(
                server: server,
                item: target,
                preferredSourceId: sourceHint,
                preferredPreset: preset
            )
        } else {
            resolved = try? await EmbyClient.shared.resolvePlaybackResource(
                server: server,
                item: target,
                preferredSourceId: sourceHint,
                preferredPreset: preset,
                enable302Cache: enable302,
                defer302ProbeWhenTurbo: true
            )
        }
        guard !Task.isCancelled, appState.activePlayback == nil, let res = resolved else { return }
        let urlStr = res.streamURL.absoluteString.lowercased()
        guard (urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://")),
              !urlStr.contains(".m3u8"), !urlStr.contains(".mpd") else {
            return
        }

        let assetKey = DonbyTurboCacheEngine.makeAssetKey(
            serverId: server.id,
            itemId: target.id,
            mediaSourceId: res.mediaSource.id
        )
        let redirectKey = EmbyClient.redirectCacheKey(
            serverId: server.id,
            itemId: target.id,
            mediaSourceId: res.mediaSource.id,
            baseURL: server.activeBaseURL
        )
        let originURL = res.originStreamURL ?? res.streamURL
        let cachedRedirectURL: URL? = (res.originStreamURL != nil && res.originStreamURL != res.streamURL) ? res.streamURL : nil
        let durationSec = Double(target.runTimeTicks ?? res.mediaSource.runTimeTicks ?? 0) / 10_000_000.0
        let playStartSec = effectivePlayButtonStartSeconds
        let redirectHandler: (@Sendable (URL) -> Void)? = enable302
            ? Self.makeRedirectStoreHandler(key: redirectKey)
            : nil

        DonbyTurboCacheEngine.shared.startDetailPreload(
            assetKey: assetKey,
            streamURL: originURL,
            cachedRedirectURL: cachedRedirectURL,
            headers: res.headers,
            knownTotalSize: res.mediaSource.size,
            durationSeconds: durationSec,
            resumePositionSeconds: playStartSec,
            preloadSeconds: appState.detailPreloadSeconds,
            maxMemoryBytes: max(64, appState.turboMemoryCacheMB) * 1024 * 1024,
            onResolvedRedirectURL: redirectHandler
        )
    }

    private nonisolated static func makeRedirectStoreHandler(key: String) -> @Sendable (URL) -> Void {
        { finalURL in
            Task {
                await RedirectCacheStore.shared.storeRedirect(finalURL, for: key)
            }
        }
    }

    private func heroHeaderSection(heroHeight: CGFloat) -> some View {
        let canvasCol = appState.isLightMode ? DonbyGlassPalette.canvasLight : DonbyGlassPalette.canvasBlack
        return ZStack(alignment: .bottomLeading) {
            // 1. Crisp top-aligned Backdrop Fanart (fixed heroHeight, zero dynamic zoom/rescaling on scroll)
            MediaArtworkView(
                server: effectiveDetailServer,
                item: item,
                kind: .backdrop,
                maxWidth: 3840,
                alignment: .top
            )
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .saturation(1.10)
            .contrast(1.04)
            .clipped()

            // 2. Silky Ambient Gradient Dissolve into Canvas (upper 46% completely clear & vivid)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.46),
                    .init(color: canvasCol.opacity(0.26), location: 0.62),
                    .init(color: canvasCol.opacity(0.76), location: 0.76),
                    .init(color: canvasCol.opacity(0.96), location: 0.90),
                    .init(color: canvasCol, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: heroHeight)
            .allowsHitTesting(false)

            // 3. Floating Navigation Capsules & Hero Metadata Content
            VStack(alignment: .leading, spacing: 0) {
                // Top Floating Navigation Bar
                HStack {
                    // Floating Left Capsule: [ < | 🏠 ] — full-area clickable halves with zero dead rim
                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { appState.popDetail() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                .frame(width: 40, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(appState.isLightMode ? Color.black.opacity(0.10) : Color.white.opacity(0.14))
                            .frame(width: 0.75, height: 14)

                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                appState.popToRootDetail()
                            }
                        } label: {
                            Image(systemName: "house")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                .frame(width: 40, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .clipShape(Capsule(style: .continuous))
                    .donbyLiquidGlassCapsule()
                    .padding(.leading, appState.isSidebarCollapsed ? (appState.isWindowFullScreen ? 0 : 68) : 0)

                    Spacer()

                    // Floating Right Capsule: [ 🔍 | ⋯ ∨ ] — full-area clickable halves with zero dead rim
                    HStack(spacing: 0) {
                        Button {
                            appState.selectSidebarModule(.search)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                .frame(width: 40, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(appState.isLightMode ? Color.black.opacity(0.10) : Color.white.opacity(0.14))
                            .frame(width: 0.75, height: 14)

                        Menu {
                            Button {
                                Task { await loadFullDetailData() }
                            } label: {
                                Label("刷新详情信息", systemImage: "arrow.clockwise")
                            }

                            if let server = effectiveDetailServer {
                                Button {
                                    appState.linePickerServer = server
                                } label: {
                                    Label("切换线路 (\(server.activeLineName))", systemImage: "arrow.triangle.swap")
                                }
                            }

                            Button {
                                playHighestSpecification()
                            } label: {
                                Label("播放最高画质版本", systemImage: "sparkles")
                            }

                            Button {
                                Task {
                                    await appState.copyStreamDirectURL(item: item, preferredSourceId: selectedSourceId)
                                }
                            } label: {
                                Label("复制播放链接", systemImage: "link")
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                    }
                    .clipShape(Capsule(style: .continuous))
                    .donbyLiquidGlassCapsule()
                    .fixedSize()
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)

                Spacer()

                // Hero Title + Actions + Metadata Row
                VStack(alignment: .leading, spacing: 14) {
                    ClearLogoHeaderView(
                        server: effectiveDetailServer,
                        item: item,
                        isLightMode: appState.isLightMode,
                        showTitle: item.isEpisode ? (item.seriesName ?? item.name) : item.name,
                        subtitle: heroSubtitle
                    )

                    HStack(alignment: .top, spacing: 28) {
                        // Left Column: Action Buttons (Stacked: 6 Circle Buttons above Wide Play Capsule)
                        VStack(alignment: .leading, spacing: 12) {
                            // Circular action buttons row
                            HStack(alignment: .center, spacing: 11) {
                                LiquidGlassCircleButton(
                                    systemImage: "arrow.counterclockwise",
                                    size: 38,
                                    tooltip: "从头开始播放"
                                ) {
                                    startPlaybackFromBeginning()
                                }

                                LiquidGlassCircleButton(
                                    systemImage: (item.userData?.played == true) ? "checkmark.circle.fill" : "checkmark",
                                    iconColor: (item.userData?.played == true) ? appState.accentColor : nil,
                                    size: 38,
                                    tooltip: "标记已看 / 未看"
                                ) {
                                    Task { item = await appState.togglePlayed(for: item) }
                                }

                                LiquidGlassCircleButton(
                                    systemImage: (item.userData?.isFavorite == true) ? "heart.fill" : "heart",
                                    iconColor: (item.userData?.isFavorite == true) ? AppState.appleMusicRed : nil,
                                    size: 38,
                                    tooltip: "加入 / 取消收藏"
                                ) {
                                    Task { item = await appState.toggleFavorite(for: item) }
                                }

                                LiquidGlassCircleMenu(
                                    systemImage: "film.stack",
                                    size: 38,
                                    tooltip: "选择资源版本"
                                ) {
                                    if let sources = item.mediaSources, !sources.isEmpty {
                                        ForEach(sources) { src in
                                            Button {
                                                selectedSourceId = src.id
                                            } label: {
                                                if src.id == selectedMediaSource?.id {
                                                    Label(src.displayVersionName, systemImage: "checkmark")
                                                } else {
                                                    Text(src.displayVersionName)
                                                }
                                            }
                                        }
                                    } else {
                                        Button("原画版本 (默认)") {}
                                    }
                                }

                                LiquidGlassCircleMenu(
                                    systemImage: "headphones",
                                    size: 38,
                                    tooltip: "选择音频轨道"
                                ) {
                                    if !audioStreams.isEmpty {
                                        ForEach(audioStreams) { stream in
                                            Button {
                                                selectedAudioIndex = stream.index
                                            } label: {
                                                if stream.index == selectedAudioIndex {
                                                    Label(stream.readableLabel, systemImage: "checkmark")
                                                } else {
                                                    Text(stream.readableLabel)
                                                }
                                            }
                                        }
                                    } else {
                                        Button("默认音轨") {}
                                    }
                                }

                                LiquidGlassCircleMenu(
                                    systemImage: "bubble.left.and.bubble.right",
                                    size: 38,
                                    tooltip: "选择字幕语言"
                                ) {
                                    Button {
                                        didUserDisableSubtitle = true
                                        selectedSubtitleIndex = nil
                                        if let srvId = effectiveDetailServer?.id ?? appState.activeServer?.id {
                                            appState.recordPrimarySubtitleChoice(
                                                serverId: srvId,
                                                item: item,
                                                preference: .disabled,
                                                updateGlobal: false
                                            )
                                        }
                                    } label: {
                                        if selectedSubtitleIndex == nil {
                                            Label("关闭字幕", systemImage: "checkmark")
                                        } else {
                                            Text("关闭字幕")
                                        }
                                    }
                                    if !subtitleStreams.isEmpty {
                                        Divider()
                                        ForEach(subtitleStreams) { stream in
                                            Button {
                                                didUserDisableSubtitle = false
                                                selectedSubtitleIndex = stream.index
                                                if let srvId = effectiveDetailServer?.id ?? appState.activeServer?.id {
                                                    appState.recordPrimarySubtitleChoice(
                                                        serverId: srvId,
                                                        item: item,
                                                        preference: SubtitleTrackPreference(
                                                            isDisabled: false,
                                                            language: stream.language,
                                                            titleHint: stream.readableLabel,
                                                            codec: stream.codec,
                                                            isExternal: stream.isExternal == true,
                                                            embyStreamIndex: stream.index
                                                        )
                                                    )
                                                }
                                            } label: {
                                                if stream.index == selectedSubtitleIndex {
                                                    Label(stream.readableLabel, systemImage: "checkmark")
                                                } else {
                                                    Text(stream.readableLabel)
                                                }
                                            }
                                        }
                                    }
                                }

                                detailDownloadButton
                            }

                            // Main Wide Frosted Capsule Play Button (as in better1.png)
                            LiquidGlassCapsuleButton(
                                title: mainPlayButtonTitle,
                                systemImage: "play.fill",
                                tint: nil,
                                progressFraction: (item.isSeries ? (heroTargetEpisode?.progressFraction ?? item.progressFraction) : item.progressFraction),
                                horizontalPadding: 24,
                                verticalPadding: 11,
                                fontSize: 13.5
                            ) {
                                let playTarget = heroResolvedPlayTarget
                                if playTarget.isEpisode {
                                    appState.rememberDetailFocusedEpisode(
                                        seriesKey: detailSeriesKey,
                                        seasonNumber: playTarget.parentIndexNumber ?? selectedSeasonIndex,
                                        episodeId: playTarget.id
                                    )
                                }
                                Task {
                                    await appState.startPlayback(
                                        item: playTarget,
                                        episodesQueue: episodes,
                                        preferredSourceId: playTarget.id == item.id ? selectedSourceId : nil,
                                        audioStreamIndex: selectedAudioIndex,
                                        subtitleStreamIndex: selectedSubtitleIndex,
                                        subtitleExplicitlyOff: didUserDisableSubtitle
                                    )
                                }
                            }
                        }

                        // Right Column: Rating, Specs & Synopsis
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(AppState.appleMusicRed)
                                    Text(String(format: "%.1f", item.communityRating ?? 10.0))
                                        .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                }

                                if let genres = item.genres, !genres.isEmpty {
                                    Text(genres.joined(separator: " · "))
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                }

                                if let dlSummary = heroDownloadedBadgeText {
                                    DonbyDownloadedBadgePill(
                                        text: dlSummary,
                                        isCompleted: downloadManager.completedEntry(for: item.id) != nil || item.isSeries,
                                        accentColor: appState.accentColor,
                                        fontSize: 10.5
                                    )
                                }
                            }

                            // Specs Line (e.g. 45 分钟 · 2026年11月2日 · 4K · 25FPS · 1.11 GB)
                            Text(specsSummaryLine)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .lineLimit(1)

                            // Synopsis Overview
                            if let overview = item.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                    .lineLimit(3)
                                    .frame(maxWidth: 580, alignment: .leading)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
            }
        }
    }

    private var heroDownloadedBadgeText: String? {
        if item.isSeries {
            let cnt = downloadManager.statusIndex.downloadedCount(forSeries: item)
            return cnt > 0 ? "已下载 \(cnt) 集" : nil
        }
        if downloadManager.completedEntry(for: item.id) != nil {
            return "已下载"
        }
        if let active = downloadManager.activeOrCompletedEntry(for: item.id),
           active.status == .downloading || active.status == .queued {
            return String(format: "下载中 %.0f%%", active.progressFraction * 100)
        }
        return nil
    }

    private var heroTargetEpisode: EmbyItem? {
        guard item.isSeries else { return nil }
        return episodes.first(where: { $0.id == focusedEpisodeId }) ?? episodes.first
    }

    private var heroResolvedPlayTarget: EmbyItem {
        if item.isSeries, let ep = heroTargetEpisode {
            return (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
        }
        return item
    }

    @ViewBuilder
    private var detailDownloadButton: some View {
        let matchingEntry = downloadManager.entries.first {
            $0.itemId == item.id && (selectedSourceId.isEmpty || $0.mediaSourceId == selectedSourceId)
        }
        let cachedSummary = (matchingEntry == nil) ? cachedProgressSnapshot(
            forItemId: item.id,
            serverId: effectiveDetailServer?.id,
            mediaSourceId: selectedSourceId.isEmpty ? nil : selectedSourceId
        ) : nil
        let serverAllows = effectiveDetailServer.map { appState.canDownload(from: $0) } ?? true
        let defaultInk = Color(red: 0.12, green: 0.12, blue: 0.14)
        let vectorState: DownloadVectorIcon.State = {
            if !serverAllows { return .locked }
            switch matchingEntry?.status {
            case .completed:
                return .completed
            case .downloading, .queued:
                return .active(progress: matchingEntry?.progressFraction ?? 0.08)
            case .paused:
                return .paused
            default:
                return .idle
            }
        }()
        let tintCol: Color = {
            if !serverAllows { return Color(white: 0.50) }
            switch matchingEntry?.status {
            case .completed: return defaultInk
            case .downloading, .queued: return appState.accentColor
            case .paused: return appState.accentColor
            default: return (cachedSummary != nil) ? appState.accentColor : defaultInk
            }
        }()
        let tip: String = {
            if !serverAllows { return "当前账户套餐不允许下载" }
            switch matchingEntry?.status {
            case .completed: return "已下载（点击打开下载页面）"
            case .downloading:
                return String(format: "下载中 %.0f%%", (matchingEntry?.progressFraction ?? 0) * 100)
            case .queued: return "已在下载队列等待"
            default:
                if let cached = cachedSummary {
                    return String(format: "已播放缓存 %.0f%%（点击从断点继续下载至 ~/Movies/Donby）", cached.progressFraction * 100)
                }
                return item.isSeries ? "下载首集或未看剧集至 ~/Movies/Donby" : "下载至 ~/Movies/Donby"
            }
        }()

        LiquidGlassVectorCircleButton(
            size: 38,
            tooltip: tip,
            action: {
                if matchingEntry?.status == .completed {
                    appState.selectSidebarModule(.downloads)
                    return
                }
                guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    appState.showToast("当前为离线模式", icon: "internaldrive.fill")
                    return
                }
                Task {
                    await appState.enqueueDownload(
                        server: server,
                        item: item,
                        seriesItemHint: item.isSeries ? item : nil,
                        preferredSourceId: selectedSourceId.isEmpty ? nil : selectedSourceId
                    )
                }
            }
        ) {
            DownloadVectorIcon(state: vectorState, size: 15.5, color: tintCol)
        }
    }

    private var mainPlayButtonTitle: String {
        if item.isSeries, let ep = heroTargetEpisode {
            let code = ep.episodeCodeString ?? ep.name
            if ep.resumePositionSeconds > 0 {
                return "续播 \(code) \(ep.resumePositionString)"
            }
            return "播放 \(code)"
        }
        if item.resumePositionSeconds > 0 {
            return "播放 \(item.resumePositionString)"
        } else if item.isSeries {
            return "播放第 1 集"
        } else {
            return "播放"
        }
    }

    private var heroSubtitle: String {
        if item.isEpisode {
            let code = item.episodeCodeString
            let epName = item.name
            if let code, !epName.contains(code) {
                return "\(code) · \(epName)"
            }
            return epName
        } else {
            return item.taglines?.first ?? item.originalTitle ?? item.displaySubtitle
        }
    }

    private var specsSummaryLine: String {
        var parts: [String] = []
        if let runtime = item.runtimeMinutesString { parts.append(runtime) }
        if let date = item.premiereDateString ?? (item.productionYear.map { "\($0)年" }) { parts.append(date) }
        if let res = item.resolutionBadge { parts.append(res) }
        if let dyn = item.dynamicRangeTag { parts.append(dyn) }
        if let fps = selectedMediaSource?.mediaStreams?.first(where: { $0.type?.lowercased() == "video" })?.averageFrameRate {
            let cleanFps = Int(fps)
            parts.append("\(cleanFps)FPS")
        }
        if let size = selectedMediaSource?.formattedFileSize { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    private func startPlaybackFromBeginning() {
        let playTarget = heroResolvedPlayTarget
        if playTarget.isEpisode {
            appState.rememberDetailFocusedEpisode(
                seriesKey: detailSeriesKey,
                seasonNumber: playTarget.parentIndexNumber ?? selectedSeasonIndex,
                episodeId: playTarget.id
            )
        }
        Task {
            await appState.startPlayback(
                item: playTarget,
                episodesQueue: episodes,
                preferredSourceId: playTarget.id == item.id ? selectedSourceId : nil,
                audioStreamIndex: selectedAudioIndex,
                subtitleStreamIndex: selectedSubtitleIndex,
                subtitleExplicitlyOff: didUserDisableSubtitle,
                fromBeginning: true
            )
        }
    }

    private var streamAndLineSelectorSection: some View {
        let sources = item.mediaSources ?? []
        let currentVersionText = selectedMediaSource?.displayVersionName
            ?? (item.container.map { "\($0.uppercased()) · 原画直连" } ?? "自动选择版本")
        let currentAudioText = audioStreams.first(where: { $0.index == selectedAudioIndex })?.readableLabel
            ?? audioStreams.first?.readableLabel
            ?? "默认主音轨"
        let currentSubText: String = {
            guard let idx = selectedSubtitleIndex else { return "关闭字幕" }
            return subtitleStreams.first(where: { $0.index == idx })?.readableLabel ?? "字幕轨道 #\(idx)"
        }()

        return DonbyGlassContainer(spacing: 14) {
        HStack(spacing: 14) {
            LiquidGlassSelectorCard(
                title: "资源版本",
                icon: "film.stack.fill",
                valueText: currentVersionText,
                badgeText: appState.preferredVersionPreset.shortTitle,
                accentColor: appState.accentColor,
                badgeForegroundColor: appState.accentTextColor
            ) {
                if sources.isEmpty {
                    Button("默认原画版本") {}
                } else {
                    ForEach(sources) { src in
                        Button {
                            selectedSourceId = src.id
                        } label: {
                            if src.id == selectedMediaSource?.id {
                                Label(src.displayVersionName, systemImage: "checkmark")
                            } else {
                                Text(src.displayVersionName)
                            }
                        }
                    }
                }
                Divider()
                ForEach(PreferredVersionPreset.allCases) { preset in
                    Button {
                        appState.preferredVersionPreset = preset
                        if let matched = sources.preferredSource(for: preset) {
                            selectedSourceId = matched.id
                        }
                        appState.showToast("已切换默认预设：\(preset.title)", icon: "slider.horizontal.3")
                    } label: {
                        if appState.preferredVersionPreset == preset {
                            Label("默认预设：\(preset.title)", systemImage: "checkmark")
                        } else {
                            Text("默认预设：\(preset.title)")
                        }
                    }
                }
            }

            LiquidGlassSelectorCard(
                title: "音轨选择",
                icon: "speaker.wave.2.fill",
                valueText: currentAudioText,
                accentColor: appState.accentColor
            ) {
                if audioStreams.isEmpty {
                    Button("自动默认音轨") {}
                } else {
                    ForEach(audioStreams) { stream in
                        Button {
                            selectedAudioIndex = stream.index
                        } label: {
                            if stream.index == selectedAudioIndex {
                                Label(stream.readableLabel, systemImage: "checkmark")
                            } else {
                                Text(stream.readableLabel)
                            }
                        }
                    }
                }
            }

            LiquidGlassSelectorCard(
                title: "主字幕",
                icon: "captions.bubble.fill",
                valueText: currentSubText,
                accentColor: appState.accentColor
            ) {
                Button {
                    didUserDisableSubtitle = true
                    selectedSubtitleIndex = nil
                    if let srvId = effectiveDetailServer?.id ?? appState.activeServer?.id {
                        appState.recordPrimarySubtitleChoice(
                            serverId: srvId,
                            item: item,
                            preference: .disabled,
                            updateGlobal: false
                        )
                    }
                } label: {
                    if selectedSubtitleIndex == nil {
                        Label("关闭字幕", systemImage: "checkmark")
                    } else {
                        Text("关闭字幕")
                    }
                }
                if !subtitleStreams.isEmpty {
                    Divider()
                    ForEach(subtitleStreams) { stream in
                        Button {
                            didUserDisableSubtitle = false
                            selectedSubtitleIndex = stream.index
                            if let srvId = effectiveDetailServer?.id ?? appState.activeServer?.id {
                                appState.recordPrimarySubtitleChoice(
                                    serverId: srvId,
                                    item: item,
                                    preference: SubtitleTrackPreference(
                                        isDisabled: false,
                                        language: stream.language,
                                        titleHint: stream.readableLabel,
                                        codec: stream.codec,
                                        isExternal: stream.isExternal == true,
                                        embyStreamIndex: stream.index
                                    )
                                )
                            }
                        } label: {
                            if stream.index == selectedSubtitleIndex {
                                Label(stream.readableLabel, systemImage: "checkmark")
                            } else {
                                Text(stream.readableLabel)
                            }
                        }
                    }
                }
            }
        }
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Episodes Section Header: [ 第 1 季 ∨ ]  ...  [ ← → 更多 ]
            HStack {
                Menu {
                    if seasons.count > 1 {
                        ForEach(Array(seasons.enumerated()), id: \.element.id) { idx, season in
                            let sNum = season.indexNumber ?? (idx + 1)
                            Button {
                                selectedSeasonIndex = sNum
                                Task { await loadEpisodesForSeason(season, seasonNumber: sNum) }
                            } label: {
                                if selectedSeasonIndex == sNum {
                                    Label(season.name, systemImage: "checkmark")
                                } else {
                                    Text(season.name)
                                }
                            }
                        }
                    } else {
                        Button("第 1 季 (当前)") {}
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.isSeries ? "第 \(selectedSeasonIndex) 季" : "选集列表")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        scrollEpisodes(direction: -1)
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        scrollEpisodes(direction: 1)
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text("更多")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            }
            .padding(.horizontal, 28)

            if episodes.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载分季剧集...").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .leading) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(episodes) { ep in
                                let isSelected = (ep.id == (focusedEpisodeId ?? episodes.first?.id))
                                episodeCardItem(ep, isSelected: isSelected)
                                    .id(ep.id)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                    }

                    // Floating < and > glass buttons on the carousel
                    HStack {
                        if (currentFocusedIndex ?? 0) > 0 {
                            Button {
                                scrollEpisodes(direction: -1)
                            } label: {
                                ZStack {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                }
                                .frame(width: 32, height: 32)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 14)
                        }

                        Spacer()

                        if (currentFocusedIndex ?? 0) < episodes.count - 1 {
                            Button {
                                scrollEpisodes(direction: 1)
                            } label: {
                                ZStack {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                }
                                .frame(width: 32, height: 32)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 14)
                        }
                    }
                    }
                    .onAppear {
                        if let target = focusedEpisodeId ?? episodes.first?.id {
                            DispatchQueue.main.async {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: focusedEpisodeId) { _, newId in
                        if let newId {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: episodes.map(\.id)) { _, _ in
                        if let target = focusedEpisodeId ?? episodes.first?.id {
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var currentFocusedIndex: Int? {
        let targetId = focusedEpisodeId ?? episodes.first?.id
        return episodes.firstIndex(where: { $0.id == targetId })
    }

    private func scrollEpisodes(direction: Int) {
        guard !episodes.isEmpty else { return }
        let cur = currentFocusedIndex ?? 0
        let nextIdx = max(0, min(episodes.count - 1, cur + direction))
        let nextEp = episodes[nextIdx]
        userDidPickEpisodeLocally = true
        focusedEpisodeId = nextEp.id
        appState.rememberDetailFocusedEpisode(
            seriesKey: detailSeriesKey,
            seasonNumber: nextEp.parentIndexNumber ?? selectedSeasonIndex,
            episodeId: nextEp.id
        )
    }

    private func episodeCardItem(_ ep: EmbyItem, isSelected: Bool) -> some View {
        let epDownloadEntry = downloadManager.activeOrCompletedEntry(for: ep.id)
        let isEpDownloaded = (epDownloadEntry?.status == .completed)
        let isEpDownloading = (epDownloadEntry?.status == .downloading || epDownloadEntry?.status == .queued)
        let isEpWatched = appState.isItemWatchedOfflineOrLocal(ep, localVideoPath: epDownloadEntry?.localVideoFilePath)
        let epCachedSummary = (!isEpDownloaded && !isEpDownloading) ? cachedProgressSnapshot(
            forItemId: ep.id,
            serverId: effectiveDetailServer?.id
        ) : nil

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(server: effectiveDetailServer, item: ep, kind: .primary, maxWidth: 560)
                    .frame(width: 256, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.40)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Badges overlay
                VStack {
                    HStack(spacing: 6) {
                        if let code = ep.episodeCodeString {
                            Text(code)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.70))
                                .clipShape(Capsule())
                        }
                        if isEpDownloaded {
                            DonbyDownloadedBadgePill(
                                text: "已下载",
                                isCompleted: true,
                                accentColor: appState.accentColor,
                                fontSize: 9.5
                            )
                        } else if isEpDownloading, let entry = epDownloadEntry {
                            DonbyDownloadedBadgePill(
                                text: String(format: "%.0f%%", entry.progressFraction * 100),
                                isCompleted: false,
                                accentColor: appState.accentColor,
                                fontSize: 9.5
                            )
                        }
                        Spacer()
                        if isEpWatched {
                            DonbyWatchedBadgeView(size: 19)
                        }
                        if let duration = ep.runtimeMinutesString {
                            Text(duration)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.70))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(8)

                    Spacer()

                    // Red progress line at bottom
                    if ep.progressFraction > 0 {
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.35))
                                Capsule()
                                    .fill(Color(red: 0.98, green: 0.18, blue: 0.28))
                                    .frame(width: barGeo.size.width * ep.progressFraction)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(width: 256, height: 144)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? (appState.isLightMode ? appState.accentColor : Color.white)
                            : (appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 2.2 : 0.65
                    )
            )
            .shadow(
                color: Color.black.opacity(isSelected ? 0.28 : (appState.isLightMode ? 0.10 : 0.30)),
                radius: isSelected ? 10 : 6,
                y: isSelected ? 4 : 3
            )
            .contentShape(Rectangle())
            .onTapGesture {
                userDidPickEpisodeLocally = true
                focusedEpisodeId = ep.id
                appState.rememberDetailFocusedEpisode(
                    seriesKey: detailSeriesKey,
                    seasonNumber: ep.parentIndexNumber ?? selectedSeasonIndex,
                    episodeId: ep.id
                )
                let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                Task {
                    await appState.startPlayback(
                        item: targetEp,
                        episodesQueue: episodes,
                        audioStreamIndex: selectedAudioIndex,
                        subtitleStreamIndex: selectedSubtitleIndex,
                        subtitleExplicitlyOff: didUserDisableSubtitle
                    )
                }
            }
            .contextMenu {
                Button {
                    userDidPickEpisodeLocally = true
                    focusedEpisodeId = ep.id
                    appState.rememberDetailFocusedEpisode(
                        seriesKey: detailSeriesKey,
                        seasonNumber: ep.parentIndexNumber ?? selectedSeasonIndex,
                        episodeId: ep.id
                    )
                    let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                    Task {
                        await appState.startPlayback(
                            item: targetEp,
                            episodesQueue: episodes,
                            audioStreamIndex: selectedAudioIndex,
                            subtitleStreamIndex: selectedSubtitleIndex,
                            subtitleExplicitlyOff: didUserDisableSubtitle
                        )
                    }
                } label: {
                    Label(isEpDownloaded ? "离线播放本集" : "立即播放", systemImage: "play.fill")
                }

                if isEpDownloaded, let doneEntry = epDownloadEntry {
                    if let videoPath = doneEntry.localVideoFilePath,
                       FileManager.default.fileExists(atPath: videoPath) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: videoPath)])
                        } label: {
                            Label("在访达中显示视频文件", systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        DonbyDownloadManager.shared.removeDownload(assetKey: doneEntry.assetKey)
                    } label: {
                        Label("删除本地离线文件", systemImage: "trash")
                    }
                } else if !isEpDownloading, let srv = effectiveDetailServer, !srv.host.isEmpty {
                    let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                    Button {
                        Task {
                            await appState.enqueueDownload(
                                server: srv,
                                item: targetEp,
                                seriesItemHint: item
                            )
                        }
                    } label: {
                        if let cached = epCachedSummary {
                            Label(String(format: "下载此集 (已缓存 %.0f%%)", cached.progressFraction * 100), systemImage: "arrow.down.circle")
                        } else {
                            Label("下载此集", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }

            // Bottom title row: Primary title, subtitle, and (i) info button
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.seriesName ?? item.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)

                    Text(ep.name)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    selectedEpisodeForInfo = ep
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 256)
        }
        .frame(width: 256)
    }

    private static func localizedPersonSubtitle(for person: EmbyPerson) -> String? {
        if let role = person.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            return role
        }
        switch person.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "director": return "导演"
        case "writer", "screenplay": return "编剧"
        case "producer", "executive producer": return "制片"
        case "composer": return "配乐"
        case "gueststar", "guest star": return "客串"
        default: return nil
        }
    }

    private func castSection(people: [EmbyPerson]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: "演职人员")
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(people.prefix(20)) { person in
                        let subtitle = Self.localizedPersonSubtitle(for: person)
                        VStack(spacing: 8) {
                            PersonAvatarView(
                                server: effectiveDetailServer,
                                person: person,
                                width: 78,
                                height: 100,
                                accentColor: appState.accentColor
                            )

                            VStack(spacing: 2) {
                                Text(person.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                    .lineLimit(1)
                                Text(subtitle ?? " ")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    .opacity(subtitle == nil ? 0 : 1)
                                    .lineLimit(1)
                            }
                            .frame(width: 82)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 6)
            }
        }
    }

    private var mediaSpecsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "媒体信息")
            let v = selectedMediaSource?.mediaStreams?.first(where: { $0.type?.lowercased() == "video" }) ?? item.primaryVideoStream
            let a = audioStreams.first

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                specCell("封装格式", (selectedMediaSource?.container ?? item.container ?? "MKV").uppercased())
                specCell("文件大小", selectedMediaSource?.formattedFileSize ?? "未知")
                specCell("总码率", selectedMediaSource?.formattedBitrate ?? "自适应")
                specCell("视频编码", v?.codec?.uppercased() ?? "HEVC")
                specCell("分辨率", (v?.width != nil && v?.height != nil) ? "\(v!.width!) × \(v!.height!)" : "3840 × 2160")
                specCell("动态范围", item.dynamicRangeTag ?? v?.videoRange ?? "SDR")
                specCell("主音轨", a?.readableLabel ?? "立体声")
            }
        }
    }

    private func specCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode)).lineLimit(1)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6))
    }

    private var similarSection: some View {
        let appearance = appState.cardAppearance
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: "类似作品")
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 15) {
                    ForEach(similarItems) { sim in
                        PosterCardView(
                            item: sim,
                            width: 148,
                            appearance: appearance,
                            onSelect: { appState.openDetail(for: sim) },
                            onPlay: { Task { await appState.startPlayback(item: sim) } }
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
        }
    }

    private func playHighestSpecification() {
        let sources = item.mediaSources ?? []
        let bestSource = sources.max { a, b in
            let aBitrate = a.bitrate ?? 0
            let bBitrate = b.bitrate ?? 0
            let aWidth = a.mediaStreams?.first(where: { $0.type?.lowercased() == "video" })?.width ?? 0
            let bWidth = b.mediaStreams?.first(where: { $0.type?.lowercased() == "video" })?.width ?? 0
            return (aBitrate + aWidth * 10_000) < (bBitrate + bWidth * 10_000)
        }

        if let best = bestSource {
            selectedSourceId = best.id
            Task {
                await appState.startPlayback(
                    item: item,
                    episodesQueue: episodes,
                    preferredSourceId: best.id,
                    audioStreamIndex: selectedAudioIndex,
                    subtitleStreamIndex: selectedSubtitleIndex,
                    subtitleExplicitlyOff: didUserDisableSubtitle
                )
                if appState.activePlayback != nil {
                    appState.showToast("正在播放最高画质：\(best.displayVersionName)", icon: "sparkles")
                }
            }
        } else {
            Task {
                await appState.startPlayback(
                    item: item,
                    episodesQueue: episodes,
                    audioStreamIndex: selectedAudioIndex,
                    subtitleStreamIndex: selectedSubtitleIndex,
                    subtitleExplicitlyOff: didUserDisableSubtitle
                )
                if appState.activePlayback != nil {
                    appState.showToast("正在播放最高画质版本", icon: "sparkles")
                }
            }
        }
    }

    private nonisolated static func matchOfflineGroup(for target: EmbyItem, in groups: [OfflineLibraryGroup]) -> OfflineLibraryGroup? {
        let targetSeriesId = target.isSeries ? target.id : (target.seriesId ?? target.id)
        return groups.first { g in
            g.displayItem.id == target.id ||
            g.displayItem.id == targetSeriesId ||
            g.displayItem.name == (target.seriesName ?? target.name) ||
            g.episodesBySeason.values.contains(where: { eps in eps.contains(where: { $0.id == target.id }) })
        }
    }

    private func downloadedEpisodesIn(_ group: OfflineLibraryGroup?) -> [EmbyItem] {
        var result: [EmbyItem] = []
        var seenIds = Set<String>()
        if let group {
            for sNum in group.episodesBySeason.keys.sorted() {
                for ep in group.episodesBySeason[sNum] ?? [] {
                    if seenIds.insert(ep.id).inserted {
                        result.append(ep)
                    }
                }
            }
        }
        let targetSeriesId = initialItem.isSeries ? initialItem.id : (initialItem.seriesId ?? initialItem.id)
        for entry in downloadManager.entries where entry.status == .completed {
            let snap = entry.hydratedItemSnapshot
            let matchesSeries = (snap.seriesId == targetSeriesId) || (snap.seriesName == item.name)
            if matchesSeries && seenIds.insert(snap.id).inserted {
                result.append(snap)
            }
        }
        return result.sorted {
            let sA = $0.parentIndexNumber ?? 1
            let sB = $1.parentIndexNumber ?? 1
            if sA != sB { return sA < sB }
            return ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0)
        }
    }

    private func isEpisodeWatched(_ ep: EmbyItem) -> Bool {
        let localPath = downloadManager.activeOrCompletedEntry(for: ep.id)?.localVideoFilePath
        return appState.isItemWatchedOfflineOrLocal(ep, localVideoPath: localPath)
    }

    private func preferredFocusEpisodeId(in eps: [EmbyItem]) -> String? {
        if initialItem.isEpisode, let exact = eps.first(where: { $0.id == initialItem.id }) {
            return exact.id
        }
        if preferOfflineFocus {
            let downloadedInSeason = eps.filter { downloadManager.completedEntry(for: $0.id) != nil }
            if let unwatchedDownloaded = downloadedInSeason.first(where: { !isEpisodeWatched($0) }) {
                return unwatchedDownloaded.id
            }
            if let firstDownloaded = downloadedInSeason.first {
                return firstDownloaded.id
            }
        }
        return eps.first(where: { !isEpisodeWatched($0) })?.id ?? eps.first?.id
    }

    private func mergeEpisodes(remote: [EmbyItem], local: [EmbyItem]) -> [EmbyItem] {
        guard !local.isEmpty else { return remote }
        var merged = remote
        let existingIds = Set(remote.map(\.id))
        for localEp in local where !existingIds.contains(localEp.id) {
            merged.append(localEp)
        }
        return merged.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
    }

    private func refreshOfflineAndCacheSnapshots() async {
        let entries = downloadManager.entries
        let target = initialItem
        let (group, assets) = await Task.detached(priority: .userInitiated) {
            let groups = DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: entries)
            let matched = Self.matchOfflineGroup(for: target, in: groups)
            let unpinned = DonbyTurboCacheEngine.shared.listUnpinnedCachedAssets()
            return (matched, unpinned)
        }.value
        guard !Task.isCancelled else { return }
        self.cachedOfflineGroup = group
        self.cachedUnpinnedAssets = assets
    }

    private func loadFullDetailData() async {
        await refreshOfflineAndCacheSnapshots()
        guard !Task.isCancelled else { return }
        let localGroup = cachedOfflineGroup
        // Hydrate from local offline library first so offline items / slow networks show immediately
        if let localGroup {
            self.item = localGroup.displayItem
            let remembered = appState.detailFocusedEpisode(forSeriesKey: AppState.detailSeriesKey(for: localGroup.displayItem))
            if localGroup.isSeries && !localGroup.seasonItems.isEmpty {
                self.seasons = localGroup.seasonItems
                if let remembered,
                   let rSeason = remembered.seasonNumber,
                   let localEps = localGroup.episodesBySeason[rSeason],
                   !localEps.isEmpty {
                    self.selectedSeasonIndex = rSeason
                    self.episodes = localEps
                    if localEps.contains(where: { $0.id == remembered.episodeId }) {
                        self.focusedEpisodeId = remembered.episodeId
                    } else if !userDidPickEpisodeLocally {
                        self.focusedEpisodeId = preferredFocusEpisodeId(in: localEps)
                    }
                } else if preferOfflineFocus {
                    let allDownloaded = downloadedEpisodesIn(localGroup)
                    let targetEp = allDownloaded.first(where: { !isEpisodeWatched($0) }) ?? allDownloaded.first
                    let preferredSeasonNum = targetEp?.parentIndexNumber ?? localGroup.seasonItems.first?.indexNumber ?? 1
                    let localEps = localGroup.episodesBySeason[preferredSeasonNum] ?? []
                    self.selectedSeasonIndex = preferredSeasonNum
                    self.episodes = localEps
                    if !userDidPickEpisodeLocally {
                        self.focusedEpisodeId = targetEp?.id ?? preferredFocusEpisodeId(in: localEps)
                    }
                } else {
                    let preferredSeasonNum = initialItem.isEpisode
                        ? (initialItem.parentIndexNumber ?? localGroup.seasonItems.first?.indexNumber ?? 1)
                        : (localGroup.seasonItems.first?.indexNumber ?? 1)
                    let localEps = localGroup.episodesBySeason[preferredSeasonNum] ?? []
                    self.selectedSeasonIndex = preferredSeasonNum
                    self.episodes = localEps
                    if let remembered, localEps.contains(where: { $0.id == remembered.episodeId }) {
                        self.focusedEpisodeId = remembered.episodeId
                    } else if !userDidPickEpisodeLocally {
                        self.focusedEpisodeId = preferredFocusEpisodeId(in: localEps)
                    }
                }
            }
            syncDefaultTracks()
        }

        guard let server = effectiveDetailServer else { return }
        guard !server.host.isEmpty else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        let targetSeriesId: String? = initialItem.isSeries ? initialItem.id : (initialItem.isEpisode ? initialItem.seriesId : nil)

        if server.type == .uhdNative {
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

            if let detailed = await detailTask {
                guard !Task.isCancelled else { return }
                let loadedSources = await assetsTask
                let loadedPeople = await creditsTask
                self.item = detailed.withDetailEnrichment(mediaSources: loadedSources, people: loadedPeople)
            }
            guard !Task.isCancelled else { return }
            syncDefaultTracks()

            if let preloadedSeasons = await seasonsTask, !preloadedSeasons.isEmpty {
                self.seasons = preloadedSeasons
                await applyInitialSeasonAndFocus(seasons: preloadedSeasons, localGroup: localGroup)
            }
            self.similarItems = []
            return
        }

        async let detailTask = try? EmbyClient.shared.fetchItemDetail(server: server, itemId: initialItem.id)
        async let similarTask = try? EmbyClient.shared.fetchSimilarItems(server: server, itemId: initialItem.id)
        async let seasonsTask: [EmbyItem]? = {
            guard let sid = targetSeriesId, !sid.isEmpty else { return nil }
            return try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: sid)
        }()

        if let detailed = await detailTask {
            guard !Task.isCancelled else { return }
            self.item = detailed
        }
        guard !Task.isCancelled else { return }
        syncDefaultTracks()

        let preloadedSeasons = await seasonsTask
        guard !Task.isCancelled else { return }

        if item.isSeries {
            if let loadedSeasons = preloadedSeasons, !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                await applyInitialSeasonAndFocus(seasons: loadedSeasons, localGroup: localGroup)
            } else if let allEps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id) {
                guard !Task.isCancelled else { return }
                let sNums = Set(allEps.compactMap { $0.parentIndexNumber }).sorted()
                if !sNums.isEmpty {
                    let builtSeasons = sNums.map { s in
                        EmbyItem(id: "\(item.id)_s\(s)", name: "第 \(s) 季", type: "Season", seriesId: item.id, indexNumber: s)
                    }
                    self.seasons = builtSeasons
                    await applyInitialSeasonAndFocus(seasons: builtSeasons, localGroup: localGroup, preloadedAllEpisodes: allEps)
                } else {
                    self.episodes = allEps
                    let remembered = appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey)
                    if let remembered, allEps.contains(where: { $0.id == remembered.episodeId }) {
                        self.focusedEpisodeId = remembered.episodeId
                    } else if !userDidPickEpisodeLocally || !allEps.contains(where: { $0.id == focusedEpisodeId }) {
                        self.focusedEpisodeId = preferredFocusEpisodeId(in: allEps)
                    }
                }
            }
        } else if item.isEpisode, let sId = item.seriesId {
            let loadedSeasons: [EmbyItem]?
            if let preloadedSeasons, !preloadedSeasons.isEmpty {
                loadedSeasons = preloadedSeasons
            } else {
                loadedSeasons = try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: sId)
            }
            guard !Task.isCancelled else { return }
            if let loadedSeasons, !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                let remembered = appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey)
                let sNum = remembered?.seasonNumber ?? item.parentIndexNumber ?? 1
                selectedSeasonIndex = sNum
                if let currentSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == sNum }) ?? loadedSeasons.first {
                    await loadEpisodesForSeason(currentSeason, seasonNumber: sNum, preferredOverrideEpisodeId: remembered?.episodeId)
                }
            }
        }

        guard !Task.isCancelled else { return }
        if let sims = await similarTask {
            self.similarItems = sims
        }
    }

    private func applyInitialSeasonAndFocus(
        seasons loadedSeasons: [EmbyItem],
        localGroup: OfflineLibraryGroup?,
        preloadedAllEpisodes: [EmbyItem]? = nil
    ) async {
        let remembered = appState.detailFocusedEpisode(forSeriesKey: detailSeriesKey)
        if let remembered {
            let targetSeasonNum = remembered.seasonNumber ?? (item.isEpisode ? (item.parentIndexNumber ?? 1) : (loadedSeasons.first(where: { ($0.indexNumber ?? 1) > 0 })?.indexNumber ?? 1))
            if let matchedSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == targetSeasonNum }) ?? loadedSeasons.first {
                await loadEpisodesForSeason(
                    matchedSeason,
                    seasonNumber: targetSeasonNum,
                    preloadedAllEpisodes: preloadedAllEpisodes,
                    preferredOverrideEpisodeId: remembered.episodeId
                )
                return
            }
        }

        if item.isEpisode, let epSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == (item.parentIndexNumber ?? 1) }) ?? loadedSeasons.first {
            let sNum = item.parentIndexNumber ?? epSeason.indexNumber ?? 1
            await loadEpisodesForSeason(epSeason, seasonNumber: sNum, preloadedAllEpisodes: preloadedAllEpisodes)
            return
        }

        if preferOfflineFocus {
            let allDownloaded = downloadedEpisodesIn(localGroup)
            let downloadedIds = Set(allDownloaded.map(\.id))
            let downloadedSeasonNums = Array(Set(allDownloaded.map { $0.parentIndexNumber ?? 1 })).sorted()

            if !downloadedSeasonNums.isEmpty {
                var fallbackSeasonNum: Int? = nil
                var fallbackEps: [EmbyItem] = []
                var fallbackFocusId: String? = nil

                for sNum in downloadedSeasonNums {
                    guard let seasonObj = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == sNum }) else { continue }
                    let seasonEps = await fetchMergedEpisodesForSeason(seasonObj, seasonNumber: sNum, localGroup: localGroup, preloadedAllEpisodes: preloadedAllEpisodes)
                    guard !Task.isCancelled else { return }

                    let downloadedInSeason = seasonEps.filter { downloadedIds.contains($0.id) }
                    if fallbackSeasonNum == nil && !downloadedInSeason.isEmpty {
                        fallbackSeasonNum = sNum
                        fallbackEps = seasonEps
                        fallbackFocusId = downloadedInSeason.first?.id
                    }
                    if let firstUnwatched = downloadedInSeason.first(where: { !isEpisodeWatched($0) }) {
                        self.selectedSeasonIndex = sNum
                        self.episodes = seasonEps
                        self.focusedEpisodeId = firstUnwatched.id
                        return
                    }
                }

                if let fallbackSeasonNum {
                    self.selectedSeasonIndex = fallbackSeasonNum
                    self.episodes = fallbackEps
                    self.focusedEpisodeId = fallbackFocusId ?? preferredFocusEpisodeId(in: fallbackEps)
                    return
                }
            }
        }

        if let defaultSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) > 0 }) ?? loadedSeasons.first {
            let sNum = defaultSeason.indexNumber ?? 1
            await loadEpisodesForSeason(defaultSeason, seasonNumber: sNum, preloadedAllEpisodes: preloadedAllEpisodes)
        }
    }

    private func fetchMergedEpisodesForSeason(
        _ season: EmbyItem,
        seasonNumber: Int,
        localGroup: OfflineLibraryGroup?,
        preloadedAllEpisodes: [EmbyItem]? = nil
    ) async -> [EmbyItem] {
        let localEps = localGroup?.episodesBySeason[seasonNumber] ?? []
        if let preloadedAllEpisodes {
            let filtered = preloadedAllEpisodes.filter { ($0.parentIndexNumber ?? 1) == seasonNumber }
            let remote = filtered.isEmpty ? preloadedAllEpisodes : filtered
            return mergeEpisodes(remote: remote, local: localEps)
        }
        guard let server = effectiveDetailServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return localEps
        }
        if server.type == .uhdNative {
            let tvId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
            let sName = item.isEpisode ? item.seriesName : item.name
            if let page = try? await UHDStreamClient.shared.fetchSeasonEpisodes(
                server: server,
                tvId: tvId,
                seasonId: season.id,
                seasonNumber: seasonNumber,
                seriesName: sName
            ) {
                return mergeEpisodes(remote: page.items, local: localEps)
            }
            return localEps
        }
        let seriesId = item.isEpisode ? (item.seriesId ?? item.id) : item.id
        if let eps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: seriesId, seasonId: season.id), !eps.isEmpty {
            return mergeEpisodes(remote: eps, local: localEps)
        }
        if let allEps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: seriesId) {
            let filtered = allEps.filter { ($0.parentIndexNumber ?? 1) == seasonNumber }
            return mergeEpisodes(remote: filtered.isEmpty ? allEps : filtered, local: localEps)
        }
        return localEps
    }

    private func loadEpisodesForSeason(
        _ season: EmbyItem,
        seasonNumber: Int? = nil,
        preloadedAllEpisodes: [EmbyItem]? = nil,
        preferredOverrideEpisodeId: String? = nil
    ) async {
        let sNum = seasonNumber ?? season.indexNumber ?? 1
        selectedSeasonIndex = sNum
        let localGroup = cachedOfflineGroup
        let merged = await fetchMergedEpisodesForSeason(season, seasonNumber: sNum, localGroup: localGroup, preloadedAllEpisodes: preloadedAllEpisodes)
        guard !Task.isCancelled else { return }
        self.episodes = merged
        if let ovId = preferredOverrideEpisodeId, merged.contains(where: { $0.id == ovId }) {
            self.focusedEpisodeId = ovId
        } else if userDidPickEpisodeLocally, let curId = focusedEpisodeId, merged.contains(where: { $0.id == curId }) {
            self.focusedEpisodeId = curId
        } else {
            self.focusedEpisodeId = preferredFocusEpisodeId(in: merged)
        }
    }

    private func syncDefaultTracks() {
        if let preferredSource = item.mediaSources?.preferredSource(for: appState.preferredVersionPreset) ?? item.mediaSources?.first {
            selectedSourceId = preferredSource.id
        }
        syncStreamsForSelectedSource()
    }

    private func syncStreamsForSelectedSource() {
        if let selAudio = selectedAudioIndex, audioStreams.contains(where: { $0.index == selAudio }) {
            // keep valid audio selection
        } else {
            selectedAudioIndex = (audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first)?.index
        }

        if let selSub = selectedSubtitleIndex, subtitleStreams.contains(where: { $0.index == selSub }) {
            // keep valid subtitle selection
        } else if !didUserDisableSubtitle {
            let candidates = subtitleStreams.map { stream in
                SubtitleTrackCandidate(
                    id: "emb-\(stream.index ?? -1)",
                    language: stream.language,
                    title: stream.readableLabel,
                    codec: stream.codec,
                    isExternal: stream.isExternal == true,
                    embyIndex: stream.index,
                    avStreamIndex: stream.index,
                    isDefault: stream.isDefault == true
                )
            }
            if let srvId = effectiveDetailServer?.id ?? appState.activeServer?.id,
               let remembered = appState.resolvedPrimarySubtitleMemory(serverId: srvId, item: item) {
                if remembered.isDisabled {
                    didUserDisableSubtitle = true
                    selectedSubtitleIndex = nil
                    return
                }
                if let matchedIdx = SubtitleTrackMatcher.bestMatchIndex(in: candidates, for: remembered) {
                    selectedSubtitleIndex = subtitleStreams[matchedIdx].index
                    return
                }
            }
            if let smartDefaultIdx = SubtitleTrackMatcher.defaultPreferredIndex(in: candidates) {
                selectedSubtitleIndex = subtitleStreams[smartDefaultIdx].index
            } else {
                selectedSubtitleIndex = (subtitleStreams.first(where: { $0.isDefault == true }) ?? subtitleStreams.first)?.index
            }
        }
    }
}

// MARK: - Episode Info Sheet
public struct EpisodeInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let episode: EmbyItem
    public let isLightMode: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let series = episode.seriesName {
                        Text(series)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppState.appleMusicRed)
                    }
                    Text(episode.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                if let code = episode.episodeCodeString {
                    Text(code)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(DonbyGlassPalette.cardBackground(isLight: isLightMode))
                        .clipShape(Capsule())
                }
                if let runtime = episode.runtimeMinutesString {
                    Text(runtime)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
                if let date = episode.premiereDateString {
                    Text(date)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
            }

            if let overview = episode.overview, !overview.isEmpty {
                ScrollView {
                    Text(overview)
                        .font(.system(size: 13, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else {
                Text("暂无分集简介")
                    .font(.system(size: 13))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(DonbyGlassPalette.canvas(isLight: isLightMode))
    }
}

/// Disables AppKit's automatic 28pt titlebar contentInset on DetailView's edge-to-edge ScrollView
/// so releasing a two-finger pull-down always bounces cleanly back to y=0 instead of hanging at +28pt.
private struct DetailScrollViewTopInsetFix: NSViewRepresentable {
    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyZeroTopInset()
            DispatchQueue.main.async { [weak self] in
                self?.applyZeroTopInset()
            }
        }

        func applyZeroTopInset() {
            guard let sv = enclosingScrollView else { return }
            if sv.hasVerticalScroller {
                sv.hasVerticalScroller = false
            }
            if sv.hasHorizontalScroller {
                sv.hasHorizontalScroller = false
            }
            if sv.automaticallyAdjustsContentInsets {
                sv.automaticallyAdjustsContentInsets = false
            }
            if sv.contentInsets.top != 0 {
                var insets = sv.contentInsets
                insets.top = 0
                sv.contentInsets = insets
            }
            if sv.contentView.bounds.origin.y < 0 {
                sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.origin.x, y: 0))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView(frame: .zero)
        v.isHidden = true
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.applyZeroTopInset()
    }
}

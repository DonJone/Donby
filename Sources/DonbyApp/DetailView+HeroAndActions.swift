import SwiftUI
import DonbyCore
import DonbyNetwork

extension DetailView {
    func heroHeaderSection(heroHeight: CGFloat) -> some View {
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
            .clipped()

            // 2. Silky Ambient Gradient Dissolve into Canvas (upper 46-50% completely clear & vivid)
            LinearGradient(
                stops: appState.isLightMode ? [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.50),
                    .init(color: canvasCol.opacity(0.30), location: 0.66),
                    .init(color: canvasCol.opacity(0.82), location: 0.80),
                    .init(color: canvasCol.opacity(0.97), location: 0.92),
                    .init(color: canvasCol, location: 1.0)
                ] : [
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

            // 3. Hero Metadata Content
            VStack(alignment: .leading, spacing: 0) {
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
                    .shadow(color: Color.black.opacity(appState.isLightMode ? 0.26 : 0.0), radius: 7, y: 2)
                    .frame(minHeight: 58, alignment: .bottomLeading)

                    HStack(alignment: .top, spacing: 28) {
                        // Left Column: Action Buttons (Stacked: Circle Buttons above Wide Play Capsule)
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
                                    iconColor: (item.userData?.played == true) ? appState.lightSurfaceAccentColor : nil,
                                    size: 38,
                                    tooltip: "标记已看 / 未看"
                                ) {
                                    Task { item = await appState.togglePlayed(for: item) }
                                }

                                LiquidGlassCircleButton(
                                    systemImage: (item.userData?.isFavorite == true) ? "heart.fill" : "heart",
                                    iconColor: (item.userData?.isFavorite == true) ? appState.lightSurfaceAccentColor : nil,
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

                                if DonbyAppExtensionCenter.shared.isActive(for: effectiveDetailServer) {
                                    LiquidGlassCircleButton(
                                        systemImage: "person.2.wave.2",
                                        size: 38,
                                        tooltip: "发起同看"
                                    ) {
                                        showWatchPartyCreateSheet = true
                                    }
                                }
                            }

                            // Main Wide Frosted Capsule Play Button
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

                        // Right Column: Multi-Platform Ratings, Genres, Specs & Synopsis
                        VStack(alignment: .leading, spacing: 7) {
                            HeroRatingBadgesRow(
                                item: item,
                                ratings: effectiveDetailRatings,
                                isLightSurface: appState.isLightMode,
                                fontSize: 13.5,
                                iconHeight: 17
                            )
                            .frame(minHeight: 24, alignment: .leading)

                            if (item.genres?.isEmpty == false) || heroDownloadedBadgeText != nil {
                                HStack(spacing: 8) {
                                    if let genres = item.genres, !genres.isEmpty {
                                        Text(genres.joined(separator: " · "))
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                    }

                                    if let dlSummary = heroDownloadedBadgeText {
                                        DonbyDownloadedBadgePill(
                                            text: dlSummary,
                                            isCompleted: observedDownloadIndex.completedItemIds.contains(item.id) || item.isSeries,
                                            accentColor: appState.overlayAccentColor,
                                            fontSize: 10.5
                                        )
                                    }
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
            let cnt = observedDownloadIndex.downloadedCount(forSeries: item)
            return cnt > 0 ? "已下载 \(cnt) 集" : nil
        }
        if observedDownloadIndex.completedItemIds.contains(item.id) {
            return "已下载"
        }
        if let prog = observedDownloadIndex.inProgressByItemId[item.id] {
            return String(format: "下载中 %.0f%%", max(0, min(1, prog)) * 100)
        }
        return nil
    }

    var heroTargetEpisode: EmbyItem? {
        guard item.isSeries else { return nil }
        return episodes.first(where: { $0.id == focusedEpisodeId }) ?? episodes.first
    }

    var heroResolvedPlayTarget: EmbyItem {
        if item.isSeries, let ep = heroTargetEpisode {
            return (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
        }
        return item
    }

    @ViewBuilder
    private var detailDownloadButton: some View {
        let matchingEntry = DonbyDownloadManager.shared.entries.first {
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
            case .downloading, .queued: return appState.lightSurfaceAccentColor
            case .paused: return appState.lightSurfaceAccentColor
            default: return (cachedSummary != nil) ? appState.lightSurfaceAccentColor : defaultInk
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

    func playHighestSpecification() {
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
}

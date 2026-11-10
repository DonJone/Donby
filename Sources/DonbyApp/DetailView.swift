import SwiftUI
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public struct DetailView: View {
    @EnvironmentObject private var appState: AppState
    public let initialItem: EmbyItem

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

    public init(item: EmbyItem) {
        self.initialItem = item
        self._item = State(initialValue: item)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroHeaderSection

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
            .padding(.bottom, 48)
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .sheet(item: $selectedEpisodeForInfo) { ep in
            EpisodeInfoSheet(episode: ep, isLightMode: appState.isLightMode)
        }
        .onChange(of: selectedSourceId) { _, _ in
            syncStreamsForSelectedSource()
        }
        .task(id: initialItem.id) {
            await loadFullDetailData()
        }
    }

    private var heroHeaderSection: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Clear High-Resolution Backdrop Fanart (Cinematic bleed)
            GeometryReader { bgGeo in
                MediaArtworkView(server: appState.activeServer, item: item, kind: .backdrop, maxWidth: 3840)
                    .frame(width: bgGeo.size.width, height: bgGeo.size.height)
                    .clipped()
            }
            .frame(height: 440)
            .clipped()

            // 2. Ambient Gradient Dissolve into Canvas
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: (appState.isLightMode ? DonbyGlassPalette.canvasLight : DonbyGlassPalette.canvasBlack).opacity(0.18), location: 0.44),
                    .init(color: (appState.isLightMode ? DonbyGlassPalette.canvasLight : DonbyGlassPalette.canvasBlack).opacity(0.74), location: 0.74),
                    .init(color: (appState.isLightMode ? DonbyGlassPalette.canvasLight : DonbyGlassPalette.canvasBlack), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 440)

            // 3. Floating Navigation Capsules & Hero Metadata Content
            VStack(alignment: .leading, spacing: 0) {
                // Top Floating Navigation Bar
                HStack {
                    // Floating Left Capsule: [ < | 🏠 ]
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { appState.popDetail() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(appState.isLightMode ? Color.black.opacity(0.10) : Color.white.opacity(0.14))
                            .frame(width: 0.75, height: 14)

                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                appState.detailStack.removeAll()
                            }
                        } label: {
                            Image(systemName: "house")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .donbyLiquidGlassCapsule()
                    .padding(.leading, appState.isSidebarCollapsed ? 68 : 0)

                    Spacer()

                    // Floating Right Capsule: [ 🔍 | ⋯ ∨ ]
                    HStack(spacing: 8) {
                        Button {
                            appState.selectSidebarModule(.search)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                .frame(width: 26, height: 26)
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

                            if let server = appState.activeServer {
                                Button {
                                    appState.linePickerServer = server
                                } label: {
                                    Label("切换线路 (\(server.activeLineName))", systemImage: "arrow.triangle.swap")
                                }
                            }

                            Button {
                                playHighestSpecification()
                            } label: {
                                Label("以最高规格直解播放", systemImage: "sparkles")
                            }

                            Button {
                                Task {
                                    await appState.copyStreamDirectURL(item: item, preferredSourceId: selectedSourceId)
                                }
                            } label: {
                                Label("复制原画直链", systemImage: "link")
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                            .frame(height: 26)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                            .fixedSize()
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .donbyLiquidGlassCapsule()
                    .fixedSize()
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)

                Spacer()

                // Hero Title + Actions + Metadata Row
                VStack(alignment: .leading, spacing: 14) {
                    ClearLogoHeaderView(
                        server: appState.activeServer,
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
                                    iconColor: (item.userData?.played == true) ? Color(red: 0.22, green: 0.86, blue: 0.38) : nil,
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
                                        selectedSubtitleIndex = nil
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
                                                selectedSubtitleIndex = stream.index
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

                            // Main Wide Frosted Capsule Play Button (as in better1.png)
                            LiquidGlassCapsuleButton(
                                title: mainPlayButtonTitle,
                                systemImage: "play.fill",
                                tint: nil,
                                progressFraction: item.progressFraction,
                                horizontalPadding: 24,
                                verticalPadding: 11,
                                fontSize: 13.5
                            ) {
                                Task {
                                    await appState.startPlayback(
                                        item: item,
                                        episodesQueue: episodes,
                                        preferredSourceId: selectedSourceId,
                                        audioStreamIndex: selectedAudioIndex,
                                        subtitleStreamIndex: selectedSubtitleIndex
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

    private var mainPlayButtonTitle: String {
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
        Task {
            await appState.startPlayback(
                item: item,
                episodesQueue: episodes,
                preferredSourceId: selectedSourceId,
                audioStreamIndex: selectedAudioIndex,
                subtitleStreamIndex: selectedSubtitleIndex,
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
                accentColor: appState.accentColor
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
                    selectedSubtitleIndex = nil
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
                            selectedSubtitleIndex = stream.index
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
                }
                .menuStyle(.borderlessButton)

                Spacer()

                HStack(spacing: 14) {
                    Button {
                        scrollEpisodes(direction: -1)
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .buttonStyle(.plain)

                    Button {
                        scrollEpisodes(direction: 1)
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
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
                        HStack(spacing: 16) {
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
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 14)
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
        focusedEpisodeId = episodes[nextIdx].id
    }

    private func episodeCardItem(_ ep: EmbyItem, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(server: appState.activeServer, item: ep, kind: .primary, maxWidth: 560)
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
                    HStack {
                        if let code = ep.episodeCodeString {
                            Text(code)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.70))
                                .clipShape(Capsule())
                        }
                        Spacer()
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
                        isSelected ? Color.white : (appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 2.0 : 0.65
                    )
            )
            .shadow(
                color: Color.black.opacity(isSelected ? 0.28 : (appState.isLightMode ? 0.10 : 0.30)),
                radius: isSelected ? 10 : 6,
                y: isSelected ? 4 : 3
            )
            .contentShape(Rectangle())
            .onTapGesture {
                focusedEpisodeId = ep.id
                let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                Task {
                    await appState.startPlayback(
                        item: targetEp,
                        episodesQueue: episodes,
                        audioStreamIndex: selectedAudioIndex,
                        subtitleStreamIndex: selectedSubtitleIndex
                    )
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

    private func castSection(people: [EmbyPerson]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: "演职人员")
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(people.prefix(20)) { person in
                        VStack(spacing: 8) {
                            PersonAvatarView(
                                server: appState.activeServer,
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
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.system(size: 11)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)).lineLimit(1)
                                }
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
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: "类似作品")
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach(similarItems) { sim in
                        PosterCardView(
                            item: sim,
                            width: 148,
                            onSelect: { appState.openDetail(for: sim) },
                            onPlay: { Task { await appState.startPlayback(item: sim) } }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
        }
    }

    private func specPill(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .donbyLiquidGlassRect(cornerRadius: 6, tint: highlight ? appState.accentColor : nil, interactive: false, isHovered: false)
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
                    subtitleStreamIndex: selectedSubtitleIndex
                )
                appState.showToast("已启动原画最高规格直解: \(best.displayVersionName)", icon: "sparkles")
            }
        } else {
            Task {
                await appState.startPlayback(
                    item: item,
                    episodesQueue: episodes,
                    audioStreamIndex: selectedAudioIndex,
                    subtitleStreamIndex: selectedSubtitleIndex
                )
                appState.showToast("已启动原画规格直解播放", icon: "sparkles")
            }
        }
    }

    private func loadFullDetailData() async {
        guard let server = appState.activeServer else { return }
        guard !server.host.isEmpty else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        if let detailed = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: initialItem.id) {
            self.item = detailed
        }
        syncDefaultTracks()

        if item.isSeries {
            if let loadedSeasons = try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: item.id), !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                if let firstSeason = loadedSeasons.first {
                    let sNum = firstSeason.indexNumber ?? 1
                    selectedSeasonIndex = sNum
                    await loadEpisodesForSeason(firstSeason, seasonNumber: sNum)
                }
            } else if let allEps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.id) {
                self.episodes = allEps
                let sNums = Set(allEps.compactMap { $0.parentIndexNumber }).sorted()
                if !sNums.isEmpty {
                    self.seasons = sNums.map { s in
                        EmbyItem(id: "\(item.id)_s\(s)", name: "第 \(s) 季", type: "Season", seriesId: item.id, indexNumber: s)
                    }
                    selectedSeasonIndex = sNums.first ?? 1
                    self.episodes = allEps.filter { ($0.parentIndexNumber ?? 1) == selectedSeasonIndex }
                }
            }
        } else if item.isEpisode, let sId = item.seriesId {
            if let loadedSeasons = try? await EmbyClient.shared.fetchSeasons(server: server, seriesId: sId), !loadedSeasons.isEmpty {
                self.seasons = loadedSeasons
                let sNum = item.parentIndexNumber ?? 1
                selectedSeasonIndex = sNum
                if let currentSeason = loadedSeasons.first(where: { ($0.indexNumber ?? 1) == sNum }) ?? loadedSeasons.first {
                    await loadEpisodesForSeason(currentSeason, seasonNumber: sNum)
                }
            }
        }

        if let sims = try? await EmbyClient.shared.fetchSimilarItems(server: server, itemId: item.id) {
            self.similarItems = sims
        }
    }

    private func loadEpisodesForSeason(_ season: EmbyItem, seasonNumber: Int? = nil) async {
        let sNum = seasonNumber ?? season.indexNumber ?? 1
        selectedSeasonIndex = sNum
        guard let server = appState.activeServer else { return }
        do {
            let eps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.isEpisode ? (item.seriesId ?? item.id) : item.id, seasonId: season.id)
            if !eps.isEmpty {
                self.episodes = eps
            } else {
                let allEps = try await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.isEpisode ? (item.seriesId ?? item.id) : item.id)
                let filtered = allEps.filter { ($0.parentIndexNumber ?? 1) == sNum }
                self.episodes = filtered.isEmpty ? allEps : filtered
            }
        } catch {
            if let allEps = try? await EmbyClient.shared.fetchEpisodes(server: server, seriesId: item.isEpisode ? (item.seriesId ?? item.id) : item.id) {
                let filtered = allEps.filter { ($0.parentIndexNumber ?? 1) == sNum }
                self.episodes = filtered.isEmpty ? allEps : filtered
            }
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
        } else {
            selectedSubtitleIndex = (subtitleStreams.first(where: { $0.isDefault == true }) ?? subtitleStreams.first)?.index
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

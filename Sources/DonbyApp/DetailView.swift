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
            VStack(alignment: .leading, spacing: 26) {
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
        .background(DonbyGlassPalette.canvasBlack)
        .onChange(of: selectedSourceId) { _, _ in
            syncStreamsForSelectedSource()
        }
        .task(id: initialItem.id) {
            await loadFullDetailData()
        }
    }

    private var heroHeaderSection: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { bgGeo in
                MediaArtworkView(server: appState.activeServer, item: item, kind: .backdrop, maxWidth: 1600)
                    .frame(width: bgGeo.size.width, height: bgGeo.size.height)
                    .saturation(1.22)
                    .blur(radius: 22)
                    .clipped()
            }
            .clipped()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.56),
                    DonbyGlassPalette.canvasBlack.opacity(0.86),
                    DonbyGlassPalette.canvasBlack
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 20) {
                DonbyGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    LiquidGlassCapsuleButton(
                        title: "返回",
                        systemImage: "chevron.left",
                        tint: nil,
                        horizontalPadding: 15,
                        verticalPadding: 7.5,
                        fontSize: 13
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) { appState.popDetail() }
                    }
                    .padding(.leading, appState.isSidebarCollapsed ? 68 : 0)

                    Spacer()

                    ToolbarVectorButton(
                        tooltip: "刷新详情信息",
                        action: { Task { await loadFullDetailData() } }
                    ) { hovered in
                        RefreshVectorIcon(size: 14.5, color: hovered ? .white : Color(white: 0.90), isSpinning: isLoadingDetails)
                    }

                    if let server = appState.activeServer {
                        Button { appState.linePickerServer = server } label: {
                            HStack(spacing: 6.5) {
                                RouteSwitchVectorIcon(size: 13, color: appState.accentColor)
                                Text(server.activeLineName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                LatencyBadgeView(latencyMs: server.activeLineLatencyMs, isPinging: appState.isPingingLines)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5.5)
                            .donbyLiquidGlassCapsule(tint: nil, interactive: true, isHovered: false)
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                }

                HStack(alignment: .bottom, spacing: 26) {
                    MediaArtworkView(server: appState.activeServer, item: item, kind: .primary, maxWidth: 500)
                        .frame(width: 185, height: 278)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            if let res = item.resolutionBadge { specPill(res, highlight: true) }
                            if let vCodec = item.videoCodecTag { specPill(vCodec) }
                            if let dyn = item.dynamicRangeTag { specPill(dyn) }
                            if let audioTag = item.audioSummaryTag { specPill(audioTag) }
                            if let official = item.officialRating, !official.isEmpty { specPill(official) }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            if let orig = item.originalTitle, !orig.isEmpty, orig != item.name {
                                Text(orig).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.68))
                            }
                        }

                        HStack(spacing: 14) {
                            if let rating = item.communityRating, rating > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    Text(String(format: "IMDb %.1f", rating)).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                }
                            }
                            if let year = item.productionYear { Text(String(year)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
                            if let runtime = item.runtimeMinutesString { Text(runtime).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
                            if let genres = item.genres, !genres.isEmpty { Text(genres.joined(separator: " / ")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.78)) }
                        }

                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(3)
                                .frame(maxWidth: 720, alignment: .leading)
                        }

                        DonbyGlassContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            LiquidGlassCapsuleButton(
                                title: item.resumePositionSeconds > 0 ? "继续播放" : (item.isSeries ? "播放第 1 集" : "立即播放"),
                                systemImage: "play.fill",
                                tint: appState.accentColor,
                                horizontalPadding: 22,
                                verticalPadding: 10.5,
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

                            LiquidGlassCircleButton(
                                systemImage: "sparkles",
                                size: 39,
                                tooltip: "原画规格直解 (选择最高码率/分辨率版本播放)"
                            ) {
                                playHighestSpecification()
                            }

                            LiquidGlassCircleButton(
                                systemImage: "link",
                                size: 39,
                                tooltip: "复制原画直链"
                            ) {
                                Task {
                                    await appState.copyStreamDirectURL(item: item, preferredSourceId: selectedSourceId)
                                }
                            }

                            LiquidGlassCircleButton(
                                systemImage: (item.userData?.isFavorite == true) ? "heart.fill" : "heart",
                                iconColor: (item.userData?.isFavorite == true) ? AppState.appleMusicRed : .white,
                                size: 39,
                                tooltip: "加入 / 取消收藏"
                            ) {
                                Task { item = await appState.toggleFavorite(for: item) }
                            }

                            LiquidGlassCircleButton(
                                systemImage: (item.userData?.played == true) ? "checkmark.circle.fill" : "checkmark.circle",
                                iconColor: (item.userData?.played == true) ? Color(red: 0.22, green: 0.86, blue: 0.38) : .white,
                                size: 39,
                                tooltip: "标记已观看 / 未观看"
                            ) {
                                Task { item = await appState.togglePlayed(for: item) }
                            }
                        }
                        }
                    }
                }

                streamAndLineSelectorSection
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 12)
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
            HStack {
                SectionHeaderView(
                    title: "选集列表",
                    subtitle: "第 \(selectedSeasonIndex) 季 · 共 \(episodes.count) 集"
                )
                Spacer()
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        DonbyGlassContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Array(seasons.enumerated()), id: \.element.id) { idx, season in
                                let sNum = season.indexNumber ?? (idx + 1)
                                Button {
                                    selectedSeasonIndex = sNum
                                    Task { await loadEpisodesForSeason(season, seasonNumber: sNum) }
                                } label: {
                                    Text(season.name)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(selectedSeasonIndex == sNum ? .white : .secondary)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .donbyLiquidGlassCapsule(
                                            tint: selectedSeasonIndex == sNum ? appState.accentColor : nil,
                                            interactive: true,
                                            isHovered: false
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        }
                    }
                    .frame(maxWidth: 360)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(episodes) { ep in
                            LandscapeCardView(
                                item: ep,
                                width: 248,
                                onPlay: {
                                    Task {
                                        await appState.startPlayback(
                                            item: ep,
                                            episodesQueue: episodes,
                                            audioStreamIndex: selectedAudioIndex,
                                            subtitleStreamIndex: selectedSubtitleIndex
                                        )
                                    }
                                },
                                onDetail: { appState.openDetail(for: ep) }
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func castSection(people: [EmbyPerson]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: "演职人员")
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(people.prefix(20)) { person in
                        VStack(spacing: 9) {
                            PersonAvatarView(
                                server: appState.activeServer,
                                person: person,
                                size: 72,
                                accentColor: appState.accentColor
                            )

                            VStack(spacing: 2) {
                                Text(person.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.94))
                                    .lineLimit(1)
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 94)
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
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
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

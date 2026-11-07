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

                streamAndLineSelectorSection
                    .padding(.horizontal, 28)

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
        .background(Color(red: 0.098, green: 0.098, blue: 0.106))
        .task(id: initialItem.id) {
            await loadFullDetailData()
        }
    }

    private var heroHeaderSection: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { bgGeo in
                MediaArtworkView(server: appState.activeServer, item: item, kind: .backdrop, maxWidth: 1600)
                    .frame(width: bgGeo.size.width, height: 420)
                    .blur(radius: 16)
                    .clipped()
            }
            .frame(height: 420)
            .clipped()

            LinearGradient(
                colors: [Color.black.opacity(0.40), Color.black.opacity(0.75), Color(red: 0.098, green: 0.098, blue: 0.106)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { appState.popDetail() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                            Text("返回").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.ultraThinMaterial).clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
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
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
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

                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    await appState.startPlayback(
                                        item: item,
                                        episodesQueue: episodes,
                                        preferredSourceId: selectedSourceId,
                                        audioStreamIndex: selectedAudioIndex,
                                        subtitleStreamIndex: selectedSubtitleIndex
                                    )
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                                    Text(item.resumePositionSeconds > 0 ? "继续播放" : (item.isSeries ? "播放第 1 集" : "立即播放"))
                                        .font(.system(size: 13.5, weight: .bold))
                                }
                                .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 10)
                                .background(appState.accentColor).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                playHighestSpecification()
                            } label: {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38).background(.ultraThinMaterial).clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("原画规格直解 (选择最高码率/分辨率版本播放)")

                            Button {
                                Task {
                                    await appState.copyStreamDirectURL(item: item, preferredSourceId: selectedSourceId)
                                }
                            } label: {
                                Image(systemName: "link")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38).background(.ultraThinMaterial).clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("复制原画直链")

                            Button {
                                Task { item = await appState.toggleFavorite(for: item) }
                            } label: {
                                Image(systemName: (item.userData?.isFavorite == true) ? "heart.fill" : "heart")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle((item.userData?.isFavorite == true) ? .pink : .white)
                                    .frame(width: 38, height: 38).background(.ultraThinMaterial).clipShape(Circle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { item = await appState.togglePlayed(for: item) }
                            } label: {
                                Image(systemName: (item.userData?.played == true) ? "checkmark.circle.fill" : "checkmark.circle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle((item.userData?.played == true) ? .green : .white)
                                    .frame(width: 38, height: 38).background(.ultraThinMaterial).clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
    }

    private var streamAndLineSelectorSection: some View {
        HStack(spacing: 14) {
            if let sources = item.mediaSources, !sources.isEmpty {
                selectorCard(title: "资源版本", icon: "film.stack") {
                    Picker("资源版本", selection: $selectedSourceId) {
                        ForEach(sources) { src in Text(src.displayVersionName).tag(src.id) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }

            if !audioStreams.isEmpty {
                selectorCard(title: "音轨选择", icon: "speaker.wave.2.fill") {
                    Picker("音轨", selection: $selectedAudioIndex) {
                        ForEach(audioStreams) { stream in Text(stream.readableLabel).tag(stream.index as Int?) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }

            selectorCard(title: "主字幕", icon: "captions.bubble.fill") {
                Picker("字幕", selection: $selectedSubtitleIndex) {
                    Text("关闭字幕").tag(nil as Int?)
                    ForEach(subtitleStreams) { stream in Text(stream.readableLabel).tag(stream.index as Int?) }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        }
    }

    private func selectorCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(appState.accentColor)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
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
                                        .background(selectedSeasonIndex == sNum ? appState.accentColor : Color.white.opacity(0.06))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
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
                    ForEach(people.prefix(15)) { person in
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [appState.accentColor.opacity(0.35), Color.purple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 68, height: 68)
                                Text(String(person.name.prefix(1)))
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))

                            VStack(spacing: 2) {
                                Text(person.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 90)
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
            .background(highlight ? appState.accentColor : Color.white.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        if let firstSource = item.mediaSources?.first { selectedSourceId = firstSource.id }
        if let defAudio = audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first { selectedAudioIndex = defAudio.index }
        if let defSub = subtitleStreams.first(where: { $0.isDefault == true }) ?? subtitleStreams.first { selectedSubtitleIndex = defSub.index }
    }
}

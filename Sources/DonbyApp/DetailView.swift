import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloadManager = DonbyDownloadManager.shared
    public let initialItem: EmbyItem
    public let preferOfflineFocus: Bool

    @State var item: EmbyItem
    @State var selectedSourceId: String = ""
    @State var selectedAudioIndex: Int? = nil
    @State var selectedSubtitleIndex: Int? = nil
    @State var seasons: [EmbyItem] = []
    @State var selectedSeasonIndex: Int = 1
    @State var episodes: [EmbyItem] = []
    @State var similarItems: [EmbyItem] = []
    @State var isLoadingDetails: Bool = false
    @State var focusedEpisodeId: String? = nil
    @State var selectedEpisodeForInfo: EmbyItem? = nil
    @State var didUserDisableSubtitle: Bool = false
    @State var userDidPickEpisodeLocally: Bool = false
    @State var cachedOfflineGroup: OfflineLibraryGroup? = nil
    @State var cachedUnpinnedAssets: [CachedMediaSummary] = []
    @State var showWatchPartyCreateSheet: Bool = false

    var detailSeriesKey: String {
        AppState.detailSeriesKey(for: item)
    }

    public init(item: EmbyItem, preferOfflineFocus: Bool = false) {
        self.initialItem = item
        self.preferOfflineFocus = preferOfflineFocus
        self._item = State(initialValue: item)
    }

    var effectiveDetailServer: EmbyServerConfig? {
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

    func cachedProgressSnapshot(
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

    var selectedMediaSource: MediaSourceInfo? {
        guard let sources = item.mediaSources, !sources.isEmpty else { return nil }
        return sources.first(where: { $0.id == selectedSourceId }) ?? sources.first
    }

    var audioStreams: [MediaStream] {
        (selectedMediaSource?.mediaStreams ?? item.allStreams).filter { $0.type?.lowercased() == "audio" }
    }

    var subtitleStreams: [MediaStream] {
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

                // Pinned top floating navigation capsules (fixed to viewport, never scrolls with hero)
                floatingTopNavBar
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $selectedEpisodeForInfo) { ep in
            EpisodeInfoSheet(
                episode: ep,
                isLightMode: appState.isLightMode,
                accentColor: appState.accentColor
            )
            .tint(appState.accentColor)
        }
        .sheet(isPresented: $showWatchPartyCreateSheet) {
            if let srv = effectiveDetailServer,
               let ext = DonbyAppExtensionCenter.shared.plugin,
               ext.isActive(for: srv) {
                let target = heroResolvedPlayTarget
                ext.makeDetailWatchPartyCreateSheet(
                    server: srv,
                    item: target,
                    preferredSourceId: target.id == item.id && !selectedSourceId.isEmpty ? selectedSourceId : nil
                )
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
            }
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

    private var floatingTopNavBar: some View {
        HStack {
            // Floating Left Capsule: [ Back | Home ] — full-area clickable halves with zero dead rim
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

            // Floating Right Capsule: [ Search | More ] — full-area clickable halves with zero dead rim
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
                        if DonbyAppExtensionCenter.shared.isActive(for: server) {
                            Button {
                                showWatchPartyCreateSheet = true
                            } label: {
                                Label("发起同看", systemImage: "person.2.wave.2")
                            }
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
}

// MARK: - Episode Info Sheet
public struct EpisodeInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let episode: EmbyItem
    public let isLightMode: Bool
    public let accentColor: Color

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let series = episode.seriesName {
                        Text(series)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accentColor)
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

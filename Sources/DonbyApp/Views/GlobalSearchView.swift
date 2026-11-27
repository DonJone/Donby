import SwiftUI
import DonbyCore
import DonbyNetwork

private struct GlobalSearchSnapshot: Equatable, Sendable {
    let query: String
    let filterChip: String
    let mediaItems: [EmbyItem]
    let mediaFiles: [LocalOrURLMediaItem]
    let iptvChannels: [IPTVChannelItem]

    var totalCount: Int {
        mediaItems.count + mediaFiles.count + iptvChannels.count
    }

    static let empty = GlobalSearchSnapshot(
        query: "",
        filterChip: "全部",
        mediaItems: [],
        mediaFiles: [],
        iptvChannels: []
    )
}

private struct RemoteSearchResultBucket: Equatable, Sendable {
    let serverId: UUID?
    let normalizedQuery: String
    let items: [EmbyItem]

    static let empty = RemoteSearchResultBucket(serverId: nil, normalizedQuery: "", items: [])

    func matches(serverId: UUID?, normalizedQuery: String) -> Bool {
        self.serverId == serverId && self.normalizedQuery == normalizedQuery && !normalizedQuery.isEmpty
    }
}

// MARK: - Global Search View
public struct GlobalSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var localQuery: String = ""
    @State private var localFilterChip: String = "全部"
    @State private var snapshot: GlobalSearchSnapshot = .empty
    @State private var remoteBucket: RemoteSearchResultBucket = .empty
    @State private var isSearchingRemote: Bool = false
    @State private var filterTask: Task<Void, Never>? = nil
    @State private var showAllMediaFiles: Bool = false
    @State private var showAllIPTVChannels: Bool = false

    private let filterChips = ["全部", "电影", "电视剧", "本地/网络"]
    private let initialListDisplayCap = 30

    public init() {}

    private var trimmedLocalQuery: String {
        localQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedLocalQuery: String {
        trimmedLocalQuery.lowercased()
    }

    private var remoteTaskKey: String {
        "\(appState.activeServer?.id.uuidString ?? "none")|\(normalizedLocalQuery)"
    }

    private func scheduleFilterSnapshot(debounceNanoseconds: UInt64) {
        filterTask?.cancel()
        let q = normalizedLocalQuery
        let chip = localFilterChip
        guard !q.isEmpty else {
            snapshot = .empty
            return
        }
        filterTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            let currentQ = localQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let currentChip = localFilterChip
            guard currentQ == q, currentChip == chip, !currentQ.isEmpty else { return }

            let serverId = appState.activeServer?.id
            let remoteItems: [EmbyItem] = remoteBucket.matches(serverId: serverId, normalizedQuery: currentQ)
                ? remoteBucket.items
                : []
            let loadedItems: [EmbyItem] = (currentChip == "本地/网络") ? [] : appState.allLoadedMediaItems
            let files: [LocalOrURLMediaItem] = (currentChip == "全部" || currentChip == "本地/网络") ? appState.urlMediaItems : []
            let channels: [IPTVChannelItem] = (currentChip == "全部" || currentChip == "本地/网络") ? appState.iptvChannels : []

            let computed = await Task.detached(priority: .userInitiated) {
                Self.buildSnapshot(
                    normalizedQuery: currentQ,
                    filterChip: currentChip,
                    remoteItems: remoteItems,
                    loadedItems: loadedItems,
                    mediaFiles: files,
                    iptvChannels: channels
                )
            }.value

            guard !Task.isCancelled else { return }
            let latestQ = localQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard latestQ == currentQ, localFilterChip == currentChip else { return }
            self.snapshot = computed
        }
    }

    private nonisolated static func buildSnapshot(
        normalizedQuery q: String,
        filterChip: String,
        remoteItems: [EmbyItem],
        loadedItems: [EmbyItem],
        mediaFiles: [LocalOrURLMediaItem],
        iptvChannels: [IPTVChannelItem]
    ) -> GlobalSearchSnapshot {
        guard !q.isEmpty else { return .empty }

        let mediaResults: [EmbyItem]
        if filterChip == "本地/网络" {
            mediaResults = []
        } else {
            let localMatches = loadedItems.filter { item in
                item.name.lowercased().contains(q) ||
                (item.originalTitle?.lowercased().contains(q) ?? false) ||
                (item.overview?.lowercased().contains(q) ?? false) ||
                (item.genres?.contains(where: { $0.lowercased().contains(q) }) ?? false)
            }
            var seen = Set<String>()
            var list: [EmbyItem] = []
            list.reserveCapacity(remoteItems.count + localMatches.count)
            for item in remoteItems where seen.insert(item.id).inserted {
                list.append(item)
            }
            for item in localMatches where seen.insert(item.id).inserted {
                list.append(item)
            }
            if filterChip == "电影" {
                mediaResults = list.filter { $0.type?.lowercased() == "movie" }
            } else if filterChip == "电视剧" {
                mediaResults = list.filter { $0.type?.lowercased() == "series" || $0.type?.lowercased() == "episode" }
            } else {
                mediaResults = list
            }
        }

        let matchedFiles: [LocalOrURLMediaItem]
        let matchedChannels: [IPTVChannelItem]
        if filterChip == "全部" || filterChip == "本地/网络" {
            matchedFiles = mediaFiles.filter {
                $0.name.lowercased().contains(q) || $0.urlString.lowercased().contains(q)
            }
            matchedChannels = iptvChannels.filter {
                $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q)
            }
        } else {
            matchedFiles = []
            matchedChannels = []
        }

        return GlobalSearchSnapshot(
            query: q,
            filterChip: filterChip,
            mediaItems: mediaResults,
            mediaFiles: matchedFiles,
            iptvChannels: matchedChannels
        )
    }

    public var body: some View {
        let searchResults = snapshot.mediaItems
        let matchingMediaFiles = snapshot.mediaFiles
        let matchingChannels = snapshot.iptvChannels
        let totalResultCount = snapshot.totalCount
        let isSnapshotCurrent = (snapshot.query == normalizedLocalQuery && snapshot.filterChip == localFilterChip)

        VStack(alignment: .leading, spacing: 0) {
            // Search Top Bar
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if appState.isSidebarCollapsed {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { appState.isSidebarCollapsed = false }
                        } label: {
                            DonbyToolbarCircleView(systemName: "sidebar.left")
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .padding(.leading, appState.collapsedSidebarLeadingPadding)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                        TextField("搜索电影、电视剧、演员、本地视频或 IPTV 频道...", text: $localQuery)
                            .textFieldStyle(.plain)
                            .donbyFocusEffectDisabled()
                            .font(.system(size: 15))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .onSubmit {
                                appState.globalSearchQuery = localQuery
                                appState.recordSearchHistory(localQuery)
                            }

                        if isSearchingRemote {
                            ProgressView().controlSize(.small)
                        }

                        if !localQuery.isEmpty {
                            Button {
                                filterTask?.cancel()
                                localQuery = ""
                                snapshot = .empty
                                remoteBucket = .empty
                                isSearchingRemote = false
                                appState.globalSearchQuery = ""
                                if !appState.globalSearchRemoteResults.isEmpty {
                                    appState.globalSearchRemoteResults = []
                                }
                                appState.globalSearchLastFetchedQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
                    )
                }

                // Filter Chips
                HStack(spacing: 8) {
                    ForEach(filterChips, id: \.self) { chip in
                        let isSel = (localFilterChip == chip)
                        Button {
                            localFilterChip = chip
                        } label: {
                            Text(chip)
                                .font(.system(size: 12, weight: isSel ? .bold : .medium))
                                .foregroundStyle(isSel ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(isSel ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if !trimmedLocalQuery.isEmpty && isSnapshotCurrent {
                        Text("共找到 \(totalResultCount) 条结果")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider().opacity(appState.isLightMode ? 0.35 : 0.12)

            ScrollView {
                if trimmedLocalQuery.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        if !appState.searchHistory.isEmpty {
                            searchHistorySection
                        }
                        recommendedDiscoverSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                } else if totalResultCount == 0 && !isSearchingRemote && isSnapshotCurrent {
                    emptySearchPlaceholder
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if !searchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("影视作品 (\(searchResults.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                DonbyDownloadStatusObserver(store: appState.downloadStatusStore) { statusIndex in
                                    let appearance = appState.cardAppearance(downloadStatusIndex: statusIndex)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                                        ForEach(searchResults) { item in
                                            PosterCardView(
                                                item: item,
                                                width: 150,
                                                appearance: appearance,
                                                onSelect: {
                                                    appState.globalSearchQuery = localQuery
                                                    appState.recordSearchHistory(localQuery)
                                                    appState.openDetail(for: item)
                                                },
                                                onPlay: {
                                                    appState.globalSearchQuery = localQuery
                                                    appState.recordSearchHistory(localQuery)
                                                    Task { await appState.startPlayback(item: item) }
                                                }
                                            )
                                            .equatable()
                                        }
                                    }
                                }
                            }
                        }

                        if !matchingMediaFiles.isEmpty {
                            let displayedFiles = showAllMediaFiles || matchingMediaFiles.count <= initialListDisplayCap
                                ? matchingMediaFiles
                                : Array(matchingMediaFiles.prefix(initialListDisplayCap))
                            VStack(alignment: .leading, spacing: 12) {
                                Text("本地与网络流 (\(matchingMediaFiles.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(displayedFiles) { file in
                                        HStack {
                                            Image(systemName: file.isLocalFile ? "film" : "link")
                                                .foregroundStyle(appState.accentColor)
                                            Text(file.name)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                            Spacer()
                                            Button {
                                                appState.globalSearchQuery = localQuery
                                                appState.recordSearchHistory(localQuery)
                                                if let url = URL(string: file.urlString) {
                                                    appState.playDirectURL(url: url, title: file.name)
                                                }
                                            } label: {
                                                Text("播放")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .foregroundStyle(appState.accentTextColor)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 5)
                                                    .background(appState.accentColor)
                                                    .clipShape(Capsule())
                                                    .contentShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(12)
                                        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                                        )
                                    }
                                }

                                if !showAllMediaFiles && matchingMediaFiles.count > initialListDisplayCap {
                                    Button {
                                        showAllMediaFiles = true
                                    } label: {
                                        Text("显示全部 \(matchingMediaFiles.count) 项")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !matchingChannels.isEmpty {
                            let displayedChannels = showAllIPTVChannels || matchingChannels.count <= initialListDisplayCap
                                ? matchingChannels
                                : Array(matchingChannels.prefix(initialListDisplayCap))
                            VStack(alignment: .leading, spacing: 12) {
                                Text("IPTV 频道 (\(matchingChannels.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(displayedChannels) { ch in
                                        HStack {
                                            Image(systemName: "tv")
                                                .foregroundStyle(Color.purple)
                                            Text(ch.name)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                            Text(ch.group)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button {
                                                appState.globalSearchQuery = localQuery
                                                appState.recordSearchHistory(localQuery)
                                                if let url = URL(string: ch.urlString) {
                                                    appState.playDirectURL(url: url, title: ch.name)
                                                }
                                            } label: {
                                                Text("播放")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .foregroundStyle(appState.accentTextColor)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 5)
                                                    .background(appState.accentColor)
                                                    .clipShape(Capsule())
                                                    .contentShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(12)
                                        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                                        )
                                    }
                                }

                                if !showAllIPTVChannels && matchingChannels.count > initialListDisplayCap {
                                    Button {
                                        showAllIPTVChannels = true
                                    } label: {
                                        Text("显示全部 \(matchingChannels.count) 个频道")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .onAppear {
            if localQuery != appState.globalSearchQuery {
                localQuery = appState.globalSearchQuery
            }
            if localFilterChip != appState.globalSearchFilterChip {
                localFilterChip = appState.globalSearchFilterChip
            }
            let normalized = normalizedLocalQuery
            if let serverId = appState.activeServer?.id,
               !normalized.isEmpty,
               appState.globalSearchLastServerId == serverId,
               appState.globalSearchLastFetchedQuery.lowercased() == normalized,
               !appState.globalSearchRemoteResults.isEmpty {
                remoteBucket = RemoteSearchResultBucket(
                    serverId: serverId,
                    normalizedQuery: normalized,
                    items: appState.globalSearchRemoteResults
                )
            } else if !remoteBucket.matches(serverId: appState.activeServer?.id, normalizedQuery: normalized) {
                remoteBucket = .empty
            }
            if !normalized.isEmpty {
                scheduleFilterSnapshot(debounceNanoseconds: 0)
            }
        }
        .onDisappear {
            filterTask?.cancel()
            filterTask = nil
            if appState.globalSearchQuery != localQuery {
                appState.globalSearchQuery = localQuery
            }
            if appState.globalSearchFilterChip != localFilterChip {
                appState.globalSearchFilterChip = localFilterChip
            }
        }
        .onReceive(appState.searchStore.$globalSearchQuery) { newValue in
            if newValue != localQuery { localQuery = newValue }
        }
        .onReceive(appState.searchStore.$globalSearchRemoteResults) { newResults in
            guard let serverId = appState.activeServer?.id, !normalizedLocalQuery.isEmpty,
                  appState.globalSearchLastServerId == serverId,
                  appState.globalSearchLastFetchedQuery.lowercased() == normalizedLocalQuery,
                  remoteBucket.items != newResults else { return }
            remoteBucket = RemoteSearchResultBucket(serverId: serverId, normalizedQuery: normalizedLocalQuery, items: newResults)
            scheduleFilterSnapshot(debounceNanoseconds: 0)
        }
        .donbyOnChange(of: localQuery) { _ in
            showAllMediaFiles = false
            showAllIPTVChannels = false
            let normalized = normalizedLocalQuery
            let currentServerId = appState.activeServer?.id
            if !remoteBucket.matches(serverId: currentServerId, normalizedQuery: normalized) {
                remoteBucket = .empty
                if !appState.globalSearchRemoteResults.isEmpty {
                    appState.globalSearchRemoteResults = []
                }
                appState.globalSearchLastFetchedQuery = ""
            }
            if normalized.isEmpty {
                filterTask?.cancel()
                snapshot = .empty
                isSearchingRemote = false
            } else {
                scheduleFilterSnapshot(debounceNanoseconds: 150_000_000)
            }
        }
        .donbyOnChange(of: localFilterChip) { _ in
            scheduleFilterSnapshot(debounceNanoseconds: 0)
        }
        .donbyOnChange(of: appState.activeServer?.id) { newServerId in
            remoteBucket = .empty
            if !appState.globalSearchRemoteResults.isEmpty {
                appState.globalSearchRemoteResults = []
            }
            appState.globalSearchLastServerId = newServerId
            appState.globalSearchLastFetchedQuery = ""
            if !normalizedLocalQuery.isEmpty {
                scheduleFilterSnapshot(debounceNanoseconds: 0)
            }
        }
        .task(id: remoteTaskKey) {
            let trimmed = trimmedLocalQuery
            let normalized = trimmed.lowercased()
            guard !normalized.isEmpty,
                  let server = appState.activeServer,
                  !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                remoteBucket = .empty
                if !appState.globalSearchRemoteResults.isEmpty {
                    appState.globalSearchRemoteResults = []
                }
                appState.globalSearchLastFetchedQuery = ""
                isSearchingRemote = false
                return
            }
            if remoteBucket.matches(serverId: server.id, normalizedQuery: normalized) {
                isSearchingRemote = false
                return
            }
            remoteBucket = .empty
            if !appState.globalSearchRemoteResults.isEmpty {
                appState.globalSearchRemoteResults = []
            }
            appState.globalSearchLastFetchedQuery = ""
            isSearchingRemote = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let fetchedItems: [EmbyItem]
            if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                if let res = try? await ext.search(server: server, query: trimmed, limit: 48) {
                    fetchedItems = res.items
                } else {
                    fetchedItems = []
                }
            } else if let resp = try? await EmbyClient.shared.fetchItems(server: server, searchTerm: trimmed, limit: 48) {
                fetchedItems = resp.items
            } else {
                fetchedItems = []
            }

            guard !Task.isCancelled,
                  appState.activeServer?.id == server.id,
                  normalizedLocalQuery == normalized else {
                return
            }

            remoteBucket = RemoteSearchResultBucket(
                serverId: server.id,
                normalizedQuery: normalized,
                items: fetchedItems
            )
            appState.globalSearchRemoteResults = fetchedItems
            appState.globalSearchLastServerId = server.id
            appState.globalSearchLastFetchedQuery = normalized
            isSearchingRemote = false
            scheduleFilterSnapshot(debounceNanoseconds: 0)
        }
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Text("搜索历史")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
                Spacer()
                Button("清空") {
                    appState.clearSearchHistory()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }

            SearchHistoryFlowGrid(
                items: appState.searchHistory,
                isLightMode: appState.isLightMode,
                onSelect: { term in
                    localQuery = term
                    appState.globalSearchQuery = term
                    appState.recordSearchHistory(term)
                },
                onDelete: { term in
                    appState.removeSearchHistoryItem(term)
                }
            )
        }
    }

    private var recommendedDiscoverSection: some View {
        let items = Array(appState.allLoadedMediaItems.prefix(24))
        return Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
                    Text("搜索 Emby / UHDNow 媒体库、本地视频或直播频道")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("配置并连接服务器后，可在此实时检索影片")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 52)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("近期更新与推荐")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    DonbyDownloadStatusObserver(store: appState.downloadStatusStore) { statusIndex in
                        let appearance = appState.cardAppearance(downloadStatusIndex: statusIndex)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ForEach(items) { item in
                                PosterCardView(
                                    item: item,
                                    width: 150,
                                    appearance: appearance,
                                    onSelect: { appState.openDetail(for: item) },
                                    onPlay: { Task { await appState.startPlayback(item: item) } }
                                )
                                .equatable()
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptySearchPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("未找到与 “\(trimmedLocalQuery)” 相关的结果")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text("请尝试更换搜索关键词，或检查名称拼写")
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct SearchHistoryFlowGrid: View {
    let items: [String]
    let isLightMode: Bool
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        SearchHistoryChipLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(items, id: \.self) { term in
                SearchHistoryChip(
                    term: term,
                    isLightMode: isLightMode,
                    onSelect: { onSelect(term) },
                    onDelete: { onDelete(term) }
                )
            }
        }
    }
}

private struct SearchHistoryChip: View {
    let term: String
    let isLightMode: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(term)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isLightMode
                      ? Color.black.opacity(isHovered ? 0.08 : 0.05)
                      : Color.white.opacity(isHovered ? 0.13 : 0.08))
        )
        .overlay(
            Capsule()
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
    }
}

private struct SearchHistoryChipLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += sz.width + horizontalSpacing
            usedWidth = max(usedWidth, min(maxWidth, x - horizontalSpacing))
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + horizontalSpacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}

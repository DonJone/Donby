import SwiftUI
import DonbyCore
import DonbyNetwork

// MARK: - Global Search View
public struct GlobalSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isSearchingRemote: Bool = false

    private let filterChips = ["全部", "电影", "电视剧", "本地/网络"]

    public init() {}

    private var query: String { appState.globalSearchQuery }
    private var filterChip: String { appState.globalSearchFilterChip }
    private var remoteResults: [EmbyItem] { appState.globalSearchRemoteResults }

    private var searchResults: [EmbyItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty && filterChip != "本地/网络" else { return [] }

        let localMatches = appState.allLoadedMediaItems.filter { item in
            item.name.lowercased().contains(q) ||
            (item.originalTitle?.lowercased().contains(q) ?? false) ||
            (item.overview?.lowercased().contains(q) ?? false) ||
            (item.genres?.contains(where: { $0.lowercased().contains(q) }) ?? false)
        }

        var seen = Set<String>()
        var list: [EmbyItem] = []
        for item in (remoteResults + localMatches) where !seen.contains(item.id) {
            seen.insert(item.id)
            list.append(item)
        }

        if filterChip == "电影" {
            list = list.filter { $0.type?.lowercased() == "movie" }
        } else if filterChip == "电视剧" {
            list = list.filter { $0.type?.lowercased() == "series" || $0.type?.lowercased() == "episode" }
        }
        return list
    }

    private var matchingMediaFiles: [LocalOrURLMediaItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty && (filterChip == "全部" || filterChip == "本地/网络") else { return [] }
        return appState.urlMediaItems.filter {
            $0.name.lowercased().contains(q) || $0.urlString.lowercased().contains(q)
        }
    }

    private var matchingChannels: [IPTVChannelItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty && (filterChip == "全部" || filterChip == "本地/网络") else { return [] }
        return appState.iptvChannels.filter {
            $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q)
        }
    }

    private var totalResultCount: Int {
        searchResults.count + matchingMediaFiles.count + matchingChannels.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search Top Bar
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if appState.isSidebarCollapsed {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                appState.isSidebarCollapsed = false
                            }
                        } label: {
                            DonbyToolbarCircleView(systemName: "sidebar.left")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 54)
                    }

                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                    TextField("搜索电影、电视剧、演员、本地视频或 IPTV 频道...", text: $appState.globalSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .onSubmit {
                            appState.recordSearchHistory(appState.globalSearchQuery)
                        }

                    if isSearchingRemote {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !query.isEmpty {
                        Button {
                            appState.globalSearchQuery = ""
                            appState.globalSearchRemoteResults = []
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

                // Filter Chips
                HStack(spacing: 8) {
                    ForEach(filterChips, id: \.self) { chip in
                        let isSel = (filterChip == chip)
                        Button {
                            appState.globalSearchFilterChip = chip
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

                    if !query.isEmpty {
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
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        if !appState.searchHistory.isEmpty {
                            searchHistorySection
                        }
                        recommendedDiscoverSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                } else if totalResultCount == 0 && !isSearchingRemote {
                    emptySearchPlaceholder
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if !searchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("影视作品 (\(searchResults.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                                    ForEach(searchResults) { item in
                                        PosterCardView(
                                            item: item,
                                            width: 150,
                                            appearance: appState.cardAppearance,
                                            onSelect: {
                                                appState.recordSearchHistory(appState.globalSearchQuery)
                                                appState.openDetail(for: item)
                                            },
                                            onPlay: {
                                                appState.recordSearchHistory(appState.globalSearchQuery)
                                                Task { await appState.startPlayback(item: item) }
                                            }
                                        )
                                        .equatable()
                                    }
                                }
                            }
                        }

                        if !matchingMediaFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("本地与网络流 (\(matchingMediaFiles.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                ForEach(matchingMediaFiles) { file in
                                    HStack {
                                        Image(systemName: file.isLocalFile ? "film" : "link")
                                            .foregroundStyle(appState.accentColor)
                                        Text(file.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                        Spacer()
                                        Button("播放") {
                                            appState.recordSearchHistory(appState.globalSearchQuery)
                                            if let url = URL(string: file.urlString) {
                                                appState.playDirectURL(url: url, title: file.name)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
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
                        }

                        if !matchingChannels.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("IPTV 频道 (\(matchingChannels.count))")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                                ForEach(matchingChannels) { ch in
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
                                        Button("播放") {
                                            appState.recordSearchHistory(appState.globalSearchQuery)
                                            if let url = URL(string: ch.urlString) {
                                                appState.playDirectURL(url: url, title: ch.name)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
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
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .task(id: "\(appState.activeServer?.id.uuidString ?? "none")|\(appState.globalSearchQuery)") {
            let q = appState.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty,
                  let server = appState.activeServer,
                  !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                appState.globalSearchRemoteResults = []
                appState.globalSearchLastFetchedQuery = ""
                isSearchingRemote = false
                return
            }
            if q == appState.globalSearchLastFetchedQuery && server.id == appState.globalSearchLastServerId {
                isSearchingRemote = false
                return
            }
            isSearchingRemote = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if server.type == .uhdNative {
                if let items = try? await UHDStreamClient.shared.search(server: server, query: q, limit: 48),
                   !Task.isCancelled {
                    appState.globalSearchRemoteResults = items
                    appState.globalSearchLastServerId = server.id
                    appState.globalSearchLastFetchedQuery = q
                } else if !Task.isCancelled {
                    appState.globalSearchRemoteResults = []
                    appState.globalSearchLastServerId = server.id
                    appState.globalSearchLastFetchedQuery = q
                }
            } else if let resp = try? await EmbyClient.shared.fetchItems(server: server, searchTerm: q, limit: 48),
                      !Task.isCancelled {
                appState.globalSearchRemoteResults = resp.items
                appState.globalSearchLastServerId = server.id
                appState.globalSearchLastFetchedQuery = q
            } else if !Task.isCancelled {
                appState.globalSearchRemoteResults = []
                appState.globalSearchLastServerId = server.id
                appState.globalSearchLastFetchedQuery = q
            }
            if !Task.isCancelled {
                isSearchingRemote = false
            }
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            PosterCardView(
                                item: item,
                                width: 150,
                                appearance: appState.cardAppearance,
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

    private var emptySearchPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("未找到与 “\(query)” 相关的结果")
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

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
                .buttonStyle(.plain)
            }
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

import SwiftUI
import DonbyCore
import DonbyNetwork

// MARK: - Global Search View
public struct GlobalSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query: String = ""
    @State private var filterChip: String = "全部"
    @State private var remoteResults: [EmbyItem] = []
    @State private var isSearchingRemote: Bool = false

    private let filterChips = ["全部", "电影", "电视剧", "本地/网络"]

    public init() {}

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

                    TextField("搜索电影、电视剧、演员、本地视频或 IPTV 频道...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    if !query.isEmpty {
                        Button {
                            query = ""
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
                            filterChip = chip
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
                    recommendedDiscoverSection
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
                                            onSelect: { appState.openDetail(for: item) },
                                            onPlay: { Task { await appState.startPlayback(item: item) } }
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
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty,
                  let server = appState.activeServer,
                  !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                remoteResults = []
                isSearchingRemote = false
                return
            }
            isSearchingRemote = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if let resp = try? await EmbyClient.shared.fetchItems(server: server, searchTerm: q, limit: 48),
               !Task.isCancelled {
                remoteResults = resp.items
            } else if !Task.isCancelled {
                remoteResults = []
            }
            if !Task.isCancelled {
                isSearchingRemote = false
            }
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
                .padding(.vertical, 64)
            } else {
                VStack(alignment: .leading, spacing: 20) {
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
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
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

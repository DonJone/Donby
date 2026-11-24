import SwiftUI
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public struct EmbyMainView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared
    @State private var isSearchingInline: Bool = false
    @State private var showViewOptionsPopover: Bool = false

    public init() {}

    private var inlineSearchText: String { appState.embyInlineSearchQuery }
    private var remoteInlineSearchResults: [EmbyItem] { appState.embyInlineSearchResults }

    public var body: some View {
        let appearance = appState.cardAppearance
        Group {
            if let library = appState.selectedLibrary {
                MLibListView(library: library)
            } else {
                VStack(spacing: 0) {
                    embyTopToolbar

                    if let server = appState.activeServer, server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                unconfiguredServerHero(server: server)
                                    .padding(.horizontal, 24)
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 36)
                        }
                    } else if let err = appState.homeErrorMessage {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                errorBanner(message: err)
                                    .padding(.horizontal, 24)
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 36)
                        }
                    } else if appState.isLoadingHome && appState.libraryViews.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(appState.accentColor)
                            Text("正在连接服务端并加载媒体库...")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(white: 0.60))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !inlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                inlineSearchResultsSection
                                    .padding(.horizontal, 24)
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 36)
                        }
                    } else {
                        NativeEmbyHomeView(
                            carouselItems: appState.carouselItems,
                            showCarousel: appState.showCarousel,
                            shelves: homeShelves,
                            appearance: appearance,
                            appState: appState,
                            onSelectItem: { item in appState.openDetail(for: item) },
                            onPlayItem: { item in Task { await appState.startPlayback(item: item) } },
                            onOpenLibrary: { lib in withAnimation(.easeOut(duration: 0.18)) { appState.selectedLibrary = lib } }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
                .task(id: "\(appState.activeServer?.id.uuidString ?? "none")|\(appState.embyInlineSearchQuery)") {
                    let q = appState.embyInlineSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !q.isEmpty,
                          let server = appState.activeServer,
                          !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        appState.embyInlineSearchResults = []
                        appState.embyInlineSearchLastFetchedQuery = ""
                        isSearchingInline = false
                        return
                    }
                    if q == appState.embyInlineSearchLastFetchedQuery && server.id == appState.embyInlineSearchLastServerId {
                        isSearchingInline = false
                        return
                    }
                    isSearchingInline = true
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                        if let res = try? await ext.search(server: server, query: q, limit: 60),
                           !Task.isCancelled {
                            appState.embyInlineSearchResults = res.items
                            appState.embyInlineSearchTruncated = res.truncated
                            appState.embyInlineSearchLastServerId = server.id
                            appState.embyInlineSearchLastFetchedQuery = q
                        } else if !Task.isCancelled {
                            appState.embyInlineSearchResults = []
                            appState.embyInlineSearchTruncated = false
                            appState.embyInlineSearchLastServerId = server.id
                            appState.embyInlineSearchLastFetchedQuery = q
                        }
                    } else if let resp = try? await EmbyClient.shared.fetchItems(server: server, searchTerm: q, limit: 60),
                              !Task.isCancelled {
                        appState.embyInlineSearchResults = resp.items
                        appState.embyInlineSearchTruncated = false
                        appState.embyInlineSearchLastServerId = server.id
                        appState.embyInlineSearchLastFetchedQuery = q
                    } else if !Task.isCancelled {
                        appState.embyInlineSearchResults = []
                        appState.embyInlineSearchTruncated = false
                        appState.embyInlineSearchLastServerId = server.id
                        appState.embyInlineSearchLastFetchedQuery = q
                    }
                    if !Task.isCancelled {
                        isSearchingInline = false
                    }
                }
            }
        }
    }

    private var homeShelves: [HomeShelfSection] {
        var result: [HomeShelfSection] = []
        if appState.showMyMedia && !appState.libraryViews.isEmpty {
            var counts: [String: Int] = [:]
            for lib in appState.libraryViews {
                if let count = lib.childCount ?? appState.latestByLibrary[lib.id]?.count {
                    counts[lib.id] = count
                }
            }
            result.append(HomeShelfSection(
                id: "my_media",
                title: "我的媒体",
                kind: .library,
                items: appState.libraryViews,
                countsByLibrary: counts
            ))
        }
        if appState.showContinueWatching {
            var continueItems = appState.resumeItems
            if !appState.nextUpItems.isEmpty {
                var seenIds = Set(continueItems.map(\.id))
                var seenSeriesIds = Set(continueItems.compactMap { item -> String? in
                    if let sid = item.seriesId, !sid.isEmpty { return sid }
                    return item.isSeries ? item.id : nil
                })
                for candidate in appState.nextUpItems {
                    guard seenIds.insert(candidate.id).inserted else { continue }
                    if let sid = candidate.seriesId, !sid.isEmpty {
                        guard seenSeriesIds.insert(sid).inserted else { continue }
                    }
                    continueItems.append(candidate)
                }
            }
            if !continueItems.isEmpty {
                result.append(HomeShelfSection(
                    id: "continue_watching",
                    title: "继续观看",
                    kind: .landscape,
                    items: continueItems
                ))
            }
        }
        if appState.showFavorites && !appState.favoriteItems.isEmpty {
            result.append(HomeShelfSection(
                id: "my_favorites",
                title: "我的收藏",
                kind: .poster,
                items: appState.favoriteItems
            ))
        }
        if let extShelves = extCenter.plugin?.homeShelves(for: appState.activeServer) {
            result.append(contentsOf: extShelves)
        }
        for lib in appState.libraryViews {
            if let items = appState.latestByLibrary[lib.id], !items.isEmpty {
                result.append(HomeShelfSection(
                    id: "lib_\(lib.id)",
                    title: lib.name,
                    kind: .poster,
                    items: items,
                    library: lib
                ))
            }
        }
        return result
    }

    private var embyTopToolbar: some View {
        HStack(spacing: 9) {
            if appState.isSidebarCollapsed {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        appState.isSidebarCollapsed = false
                    }
                } label: {
                    DonbyToolbarCircleView(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.leading, appState.collapsedSidebarLeadingPadding)
            }

            if let server = appState.activeServer {
                HStack(spacing: 9) {
                    ServerIconView(server: server, size: 24)

                    Text(server.name)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            appState.presentServerEditor(for: server)
                        } label: {
                            Text("点击登录")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        ToolbarVectorButton(
                            tooltip: appState.isUsingUHDExtension(for: server)
                                ? "线路与测速 · \(server.activeLineName) (⌘L)"
                                : "切换线路 · \(server.activeLineName) (⌘L)",
                            action: { appState.linePickerServer = server }
                        ) { hovered in
                            let iconColor = appState.isLightMode
                                ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28))
                                : (hovered ? .white : Color(white: 0.88))
                            RouteSwitchVectorIcon(size: 14.5, color: iconColor)
                        }
                    }
                }
            }

            Spacer(minLength: 10)

            if let server = appState.activeServer {
                if let plugin = extCenter.plugin {
                    plugin.makeEmbyToolbarButtons(server: server)
                }

                ToolbarVectorButton(
                    tooltip: "刷新媒体库并同步云端线路 (⌘R)",
                    action: {
                        guard !appState.isLoadingHome else { return }
                        Task {
                            await appState.loadActiveServerHome(syncDomains: true)
                            appState.showToast("已刷新首页并同步云端线路", icon: "checkmark.circle.fill")
                        }
                    }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28)) : (hovered ? .white : Color(white: 0.88))
                    RefreshVectorIcon(
                        size: 15,
                        color: iconColor,
                        isSpinning: appState.isLoadingHome || appState.isSyncingDomains
                    )
                }

                ToolbarVectorButton(
                    tooltip: "首页显示与服务配置",
                    isActive: showViewOptionsPopover,
                    action: { showViewOptionsPopover.toggle() }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28)) : (hovered ? .white : Color(white: 0.88))
                    MoreDotsVectorIcon(size: 15, color: iconColor)
                }
                .popover(isPresented: $showViewOptionsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("首页模块显示")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Toggle("显示轮播大图", isOn: $appState.showCarousel)
                        Toggle("显示我的媒体", isOn: $appState.showMyMedia)
                        Toggle("显示继续观看", isOn: $appState.showContinueWatching)
                        Toggle("显示我的收藏", isOn: $appState.showFavorites)
                        Toggle("隐藏已观看项目", isOn: $appState.hideWatchedInLatest)
                        Divider()
                        Button {
                            showViewOptionsPopover = false
                            appState.presentServerEditor(for: server)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "slider.horizontal.3")
                                Text("服务配置与账号")
                                Spacer()
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .toggleStyle(
                        DonbyCheckboxToggleStyle(
                            isLightMode: appState.isLightMode,
                            accentColor: appState.accentColor,
                            accentTextColor: appState.accentTextColor
                        )
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(14)
                    .frame(width: 210)
                }
            }

            ToolbarVectorButton(
                tooltip: "搜索媒体",
                action: { appState.selectSidebarModule(.search) }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color(red: 0.08, green: 0.08, blue: 0.10) : Color(red: 0.25, green: 0.25, blue: 0.28)) : (hovered ? .white : Color(white: 0.88))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
    }

    private var inlineSearchResults: [EmbyItem] {
        let q = inlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let localMatches = appState.allLoadedMediaItems.filter { item in
            item.name.lowercased().contains(q) ||
            (item.originalTitle?.lowercased().contains(q) ?? false) ||
            (item.overview?.lowercased().contains(q) ?? false)
        }
        var seen = Set<String>()
        var list: [EmbyItem] = []
        for item in (remoteInlineSearchResults + localMatches) where !seen.contains(item.id) {
            seen.insert(item.id)
            list.append(item)
        }
        return list
    }

    private var inlineSearchResultsSection: some View {
        let results = inlineSearchResults
        let appearance = appState.cardAppearance
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SectionHeaderView(
                    title: "搜索结果",
                    subtitle: appState.embyInlineSearchTruncated
                        ? "已展示前 \(results.count) 条（结果已截断，建议补充关键词）"
                        : "共找到 \(results.count) 个"
                )
                if isSearchingInline {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    appState.embyInlineSearchQuery = ""
                    appState.embyInlineSearchResults = []
                    appState.embyInlineSearchLastFetchedQuery = ""
                } label: {
                    Text("清除搜索")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if results.isEmpty && !isSearchingInline {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Text("未在服务端找到包含 “\(inlineSearchText)” 的影视作品")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 180), spacing: 16)], alignment: .leading, spacing: 20) {
                    ForEach(results) { item in
                        PosterCardView(
                            item: item,
                            width: 152,
                            appearance: appearance,
                            onSelect: {
                                appState.recordSearchHistory(appState.embyInlineSearchQuery)
                                appState.openDetail(for: item)
                            },
                            onPlay: {
                                appState.recordSearchHistory(appState.embyInlineSearchQuery)
                                Task { await appState.startPlayback(item: item) }
                            }
                        )
                        .equatable()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Text("连接异常：\(message)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .lineLimit(2)
            Spacer()
            Button {
                Task { await appState.loadActiveServerHome(syncDomains: true) }
            } label: {
                HStack(spacing: 5) {
                    RefreshVectorIcon(
                        size: 12,
                        color: DonbyGlassPalette.primaryText(isLight: appState.isLightMode),
                        isSpinning: appState.isLoadingHome
                    )
                    Text("重试")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .donbyLiquidGlassCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if let server = appState.activeServer {
                if message.contains("401") || message.contains("凭证") || message.contains("登录") {
                    Button {
                        appState.presentServerEditor(for: server)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.badge.key.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("重新登录")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    appState.linePickerServer = server
                } label: {
                    HStack(spacing: 5) {
                        RouteSwitchVectorIcon(size: 12, color: appState.accentTextColor)
                        Text("切换线路")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(appState.accentTextColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.75)
        )
    }

    private func unconfiguredServerHero(server: EmbyServerConfig) -> some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [appState.accentColor.opacity(0.26), Color.clear],
                            center: .center,
                            startRadius: 16,
                            endRadius: 88
                        )
                    )
                    .frame(width: 170, height: 170)

                ServerIconView(server: server, size: 70)
            }

            VStack(spacing: 8) {
                Text("尚未登录 \(server.name)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                Text(appState.isUsingUHDExtension(for: server) ? "登录后自动接入优选节点并同步媒体库" : "配置服务器地址与账号后即可浏览媒体库")
                    .font(.system(size: 13))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button {
                    appState.presentServerEditor(for: server)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "person.badge.key")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("立即登录")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(appState.accentTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    appState.importServerFromClipboard(into: server)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("从剪贴板一键拉取账户")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
        .padding(.vertical, 48)
    }
}

public struct SectionHeaderView: View {
    @EnvironmentObject private var appState: AppState
    public let title: String
    public var subtitle: String? = nil
    public var actionTitle: String? = nil
    public var action: (() -> Void)? = nil

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode)) }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle).font(.system(size: 12.5, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

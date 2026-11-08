import SwiftUI
import DonbyCore
import DonbyNetwork
import DonbyKernelC

public struct EmbyMainView: View {
    @EnvironmentObject private var appState: AppState
    @State private var inlineSearchText: String = ""
    @State private var showViewOptionsPopover: Bool = false
    @State private var isLinePillHovered: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if let library = appState.selectedLibrary {
                MLibListView(library: library)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                            if let server = appState.activeServer, server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                unconfiguredServerHero(server: server)
                                    .padding(.horizontal, 24)
                            } else if let err = appState.homeErrorMessage {
                                errorBanner(message: err)
                                    .padding(.horizontal, 24)
                            } else if appState.isLoadingHome && appState.libraryViews.isEmpty {
                                VStack(spacing: 16) {
                                    ProgressView()
                                        .controlSize(.regular)
                                        .tint(appState.accentColor)
                                    Text("正在连接服务端并加载媒体库...")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color(white: 0.60))
                                }
                                .frame(maxWidth: .infinity, minHeight: 260)
                            }

                            if !inlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                inlineSearchResultsSection
                                    .padding(.horizontal, 24)
                            } else {
                                if appState.showCarousel && !appState.carouselItems.isEmpty {
                                    MainCarouselView(
                                        items: appState.carouselItems,
                                        onPlay: { item in Task { await appState.startPlayback(item: item) } },
                                        onSelectDetail: { item in appState.openDetail(for: item) }
                                    )
                                    .padding(.horizontal, 24)
                                }

                                if appState.showMyMedia && !appState.libraryViews.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        SectionHeaderView(title: "我的媒体")
                                            .padding(.horizontal, 24)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 14) {
                                                ForEach(appState.libraryViews) { lib in
                                                    LibraryCardView(library: lib, itemCount: lib.childCount ?? appState.latestByLibrary[lib.id]?.count) {
                                                        withAnimation(.easeOut(duration: 0.18)) { appState.selectedLibrary = lib }
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 8)
                                        }
                                    }
                                }

                                if appState.showContinueWatching && !appState.resumeItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        SectionHeaderView(title: "继续观看")
                                            .padding(.horizontal, 24)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 16) {
                                                ForEach(appState.resumeItems) { item in
                                                    LandscapeCardView(
                                                        item: item,
                                                        width: 248,
                                                        onPlay: { Task { await appState.startPlayback(item: item) } },
                                                        onDetail: { appState.openDetail(for: item) }
                                                    )
                                                }
                                            }
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 8)
                                        }
                                    }
                                }

                                if appState.showNextUp && !appState.nextUpItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        SectionHeaderView(title: "接下来观看")
                                            .padding(.horizontal, 24)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 16) {
                                                ForEach(appState.nextUpItems) { item in
                                                    LandscapeCardView(
                                                        item: item,
                                                        width: 248,
                                                        onPlay: { Task { await appState.startPlayback(item: item) } },
                                                        onDetail: { appState.openDetail(for: item) }
                                                    )
                                                }
                                            }
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 8)
                                        }
                                    }
                                }

                                ForEach(appState.libraryViews) { lib in
                                    if let items = appState.latestByLibrary[lib.id], !items.isEmpty {
                                        VStack(alignment: .leading, spacing: 8) {
                                            SectionHeaderView(title: lib.name, actionTitle: "更多") {
                                                withAnimation(.easeOut(duration: 0.18)) { appState.selectedLibrary = lib }
                                            }
                                            .padding(.horizontal, 24)
                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 15) {
                                                    ForEach(items) { item in
                                                        PosterCardView(
                                                            item: item,
                                                            width: 152,
                                                            onSelect: { appState.openDetail(for: item) },
                                                            onPlay: { Task { await appState.startPlayback(item: item) } }
                                                        )
                                                    }
                                                }
                                                .padding(.horizontal, 24)
                                                .padding(.vertical, 8)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 36)
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        embyTopToolbar
                    }
                    .background(DonbyGlassPalette.canvasBlack)
                }
            }
    }

    private var embyTopToolbar: some View {
        DonbyGlassContainer(spacing: 9) {
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
                .padding(.leading, 58)
            }

            if let server = appState.activeServer {
                HStack(spacing: 9) {
                    ServerIconView(server: server, size: 24)

                    Text(server.name)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.94))
                        .lineLimit(1)

                    if server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            appState.editingServer = server
                            appState.showAddServerSheet = true
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 5.5, height: 5.5)
                                Text("待配置账号")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.14))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            appState.linePickerServer = server
                        } label: {
                            HStack(spacing: 6) {
                                RouteSwitchVectorIcon(size: 12.5, color: appState.accentColor)

                                Text(server.activeLineName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(white: 0.92))
                                    .lineLimit(1)

                                if let ms = server.activeLineLatencyMs {
                                    let msCol: Color = ms < 100 ? Color(red: 0.22, green: 0.84, blue: 0.36) : (ms < 260 ? Color(red: 0.24, green: 0.74, blue: 0.98) : .orange)
                                    HStack(spacing: 3.5) {
                                        Circle()
                                            .fill(msCol)
                                            .frame(width: 5, height: 5)
                                        Text("\(ms)ms")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(msCol)
                                    }
                                } else {
                                    Circle()
                                        .fill(Color(red: 0.22, green: 0.84, blue: 0.36))
                                        .frame(width: 5.5, height: 5.5)
                                }

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(Color(white: 0.68))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .donbyLiquidGlassCapsule(tint: nil, interactive: true, isHovered: isLinePillHovered)
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .onHover { isLinePillHovered = $0 }
                        .help("切换服务器线路 (⌘L)")
                    }
                }
            }

            Spacer(minLength: 10)

            if let server = appState.activeServer {
                ToolbarVectorButton(
                    tooltip: "切换线路 (⌘L)",
                    action: { appState.linePickerServer = server }
                ) { hovered in
                    RouteSwitchVectorIcon(size: 15, color: hovered ? .white : Color(white: 0.88))
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
                    RefreshVectorIcon(
                        size: 15,
                        color: hovered ? .white : Color(white: 0.88),
                        isSpinning: appState.isLoadingHome || appState.isSyncingDomains
                    )
                }

                ToolbarVectorButton(
                    tooltip: "首页显示与服务配置",
                    isActive: showViewOptionsPopover,
                    action: { showViewOptionsPopover.toggle() }
                ) { hovered in
                    MoreDotsVectorIcon(size: 15, color: hovered ? .white : Color(white: 0.88))
                }
                .popover(isPresented: $showViewOptionsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("首页模块显示")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Toggle("显示轮播大图", isOn: $appState.showCarousel)
                        Toggle("显示我的媒体", isOn: $appState.showMyMedia)
                        Toggle("显示继续观看", isOn: $appState.showContinueWatching)
                        Toggle("显示接下来观看", isOn: $appState.showNextUp)
                        Toggle("隐藏已观看项目", isOn: $appState.hideWatchedInLatest)
                        Divider()
                        Button {
                            showViewOptionsPopover = false
                            appState.editingServer = server
                            appState.showAddServerSheet = true
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
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .padding(14)
                    .frame(width: 210)
                }
            }

            DonbySearchPillField(
                placeholder: "搜索媒体",
                text: $inlineSearchText,
                width: 185
            )
        }
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
        .background(
            LinearGradient(
                colors: [
                    DonbyGlassPalette.canvasBlack.opacity(0.84),
                    DonbyGlassPalette.canvasBlack.opacity(0.36),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var inlineSearchResultsSection: some View {
        let q = inlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allItems = appState.latestByLibrary.values.flatMap { $0 }
        var seen = Set<String>()
        let uniqueMatches = allItems.filter { item in
            guard !seen.contains(item.id) else { return false }
            let hit = item.name.lowercased().contains(q) || (item.originalTitle?.lowercased().contains(q) ?? false)
            if hit { seen.insert(item.id) }
            return hit
        }

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeaderView(title: "搜索结果", subtitle: "一共搜索到 \(uniqueMatches.count) 个")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 180), spacing: 16)], alignment: .leading, spacing: 20) {
                ForEach(uniqueMatches) { item in
                    PosterCardView(
                        item: item,
                        width: 152,
                        onSelect: { appState.openDetail(for: item) },
                        onPlay: { Task { await appState.startPlayback(item: item) } }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("连接异常：\(message)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.92))
                .lineLimit(2)
            Spacer()
            Button {
                Task { await appState.loadActiveServerHome(syncDomains: true) }
            } label: {
                HStack(spacing: 5) {
                    RefreshVectorIcon(size: 12, color: .white, isSpinning: appState.isLoadingHome)
                    Text("重试")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if let server = appState.activeServer {
                Button {
                    appState.linePickerServer = server
                } label: {
                    HStack(spacing: 5) {
                        RouteSwitchVectorIcon(size: 12, color: .white)
                        Text("切换线路")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(appState.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
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

                UHDNowVectorLogo(size: 74)
            }

            VStack(spacing: 8) {
                Text("尚未配置 UHDNow 服务器")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                Text("当前为预置 UHDNow 空槽，请填写服务器域名与账号信息，登录成功后将自动同步全部 ServerDomains 加速线路。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.60))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)
            }

            HStack(spacing: 12) {
                Button {
                    appState.editingServer = server
                    appState.showAddServerSheet = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("填写服务器与账号信息")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
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
                        Text("从剪贴板一键导入")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color(white: 0.90))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
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
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Color(white: 0.94))
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(white: 0.55)) }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle).font(.system(size: 12.5, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Color(white: 0.62))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

public struct MLibListView: View {
    @EnvironmentObject private var appState: AppState
    public let library: EmbyItem

    @State private var items: [EmbyItem] = []
    @State private var totalCount: Int = 0
    @State private var isLoading: Bool = false
    @State private var sortField: EmbySortField = .dateCreated
    @State private var ascending: Bool = false
    @State private var filterUnwatchedOnly: Bool = false
    @State private var filterFavoritesOnly: Bool = false
    @State private var searchQuery: String = ""
    @State private var showSortPopover: Bool = false

    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 182), spacing: 16)]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ToolbarVectorButton(
                    tooltip: "返回媒体库首页",
                    action: { withAnimation(.easeOut(duration: 0.18)) { appState.selectedLibrary = nil } }
                ) { hovered in
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(hovered ? .white : Color(white: 0.88))
                }
                .padding(.leading, appState.isSidebarCollapsed ? 58 : 0)

                Text(library.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(totalCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.56))

                Spacer()

                ToolbarVectorButton(
                    tooltip: "刷新列表",
                    action: { Task { await loadLibraryItems() } }
                ) { hovered in
                    RefreshVectorIcon(size: 14.5, color: hovered ? .white : Color(white: 0.88), isSpinning: isLoading)
                }

                ToolbarVectorButton(
                    tooltip: "排序与筛选",
                    isActive: showSortPopover,
                    action: { showSortPopover.toggle() }
                ) { hovered in
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hovered ? .white : Color(white: 0.88))
                }
                .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("排序方式")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("排序", selection: $sortField) {
                            ForEach(EmbySortField.allCases) { field in Text(field.title).tag(field) }
                        }
                        .labelsHidden()
                        Divider()
                        Toggle("升序排列", isOn: $ascending)
                        Toggle("仅显示未观看", isOn: $filterUnwatchedOnly)
                        Toggle("仅显示收藏", isOn: $filterFavoritesOnly)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .padding(14)
                    .frame(width: 200)
                }

                DonbySearchPillField(placeholder: "搜索", text: $searchQuery, width: 200)
            }
            .padding(.horizontal, 24)
            .frame(height: 54)

            if isLoading && items.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(filteredItems) { item in
                            PosterCardView(
                                item: item,
                                width: 152,
                                onSelect: { appState.openDetail(for: item) },
                                onPlay: { Task { await appState.startPlayback(item: item) } }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(DonbyGlassPalette.canvasBlack)
        .task(id: "\(library.id)|\(sortField.rawValue)|\(ascending)|\(filterUnwatchedOnly)|\(filterFavoritesOnly)") {
            await loadLibraryItems()
        }
    }
    private var filteredItems: [EmbyItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(q) || ($0.originalTitle?.lowercased().contains(q) ?? false) }
    }

    private func loadLibraryItems() async {
        guard let server = appState.activeServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp = try await EmbyClient.shared.fetchItems(
                server: server,
                parentId: library.id,
                sortBy: sortField.rawValue,
                sortOrder: ascending ? "Ascending" : "Descending",
                filters: filterUnwatchedOnly ? "IsUnplayed" : nil,
                isFavorite: filterFavoritesOnly ? true : nil,
                limit: 120
            )
            self.items = resp.items
            self.totalCount = resp.totalRecordCount ?? resp.items.count
        } catch {
            self.items = appState.latestByLibrary[library.id] ?? []
            self.totalCount = self.items.count
        }
    }
}

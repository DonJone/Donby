import SwiftUI
import DonbyCore
import DonbyNetwork

public struct MLibListView: View {
    @EnvironmentObject private var appState: AppState
    public let library: EmbyItem

    @State private var items: [EmbyItem] = []
    @State private var itemsRevision: Int = 0
    @State private var totalCount: Int = 0
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreItems: Bool = false
    @State private var startIndex: Int = 0
    @State private var nextCursor: String? = nil
    @State private var loadGeneration: Int = 0
    @State private var loadErrorMessage: String? = nil
    @State private var seenIds: Set<String> = []
    @State private var sortField: EmbySortField = .dateCreated
    @State private var ascending: Bool = false
    @State private var filterUnwatchedOnly: Bool = false
    @State private var filterFavoritesOnly: Bool = false
    @State private var selectedGenreFilter: String = ""
    @State private var availableGenreNames: [String] = []
    @State private var showSortPopover: Bool = false

    private var searchQuery: String {
        appState.librarySearchQueryById[library.id] ?? ""
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { appState.librarySearchQueryById[library.id] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    appState.librarySearchQueryById.removeValue(forKey: library.id)
                } else {
                    appState.librarySearchQueryById[library.id] = newValue
                }
            }
        )
    }

    private static let pageSize = 120

    public var body: some View {
        let appearance = appState.cardAppearance
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
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

                ToolbarVectorButton(
                    tooltip: "返回媒体库首页",
                    action: {
                        appState.librarySearchQueryById.removeValue(forKey: library.id)
                        withAnimation(.easeOut(duration: 0.18)) { appState.selectedLibrary = nil }
                    }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                Text(library.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .lineLimit(1)
                Text("\(totalCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                Spacer()

                ToolbarVectorButton(
                    tooltip: "刷新列表",
                    action: { Task { await loadLibraryItems(reset: true) } }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    RefreshVectorIcon(size: 14.5, color: iconColor, isSpinning: isLoading)
                }

                ToolbarVectorButton(
                    tooltip: "排序与筛选",
                    isActive: showSortPopover,
                    action: { showSortPopover.toggle() }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
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
                        if !availableGenreNames.isEmpty {
                            Divider()
                            Text("按类型筛选")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Picker("类型", selection: $selectedGenreFilter) {
                                Text("全部类型").tag("")
                                ForEach(availableGenreNames, id: \.self) { g in
                                    Text(g).tag(g)
                                }
                            }
                            .labelsHidden()
                        }
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
                    .frame(width: 215)
                }

                DonbySearchPillField(
                    placeholder: "搜索",
                    text: searchQueryBinding,
                    width: 200,
                    onSubmit: { appState.recordSearchHistory(searchQuery) }
                )
            }
            .padding(.horizontal, 24)
            .frame(height: 54)
            .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
            .overlay(
                Rectangle()
                    .fill(DonbyGlassPalette.separator(isLight: appState.isLightMode))
                    .frame(height: 0.6),
                alignment: .bottom
            )

            if isLoading && items.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errMsg = loadErrorMessage, items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("加载媒体库失败")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(errMsg)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    HStack(spacing: 10) {
                        if let srv = appState.activeServer {
                            Button("切换线路") {
                                appState.linePickerServer = srv
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("重试") {
                            Task { await loadLibraryItems(reset: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appState.accentColor)
                    }
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativePosterGridView(
                    items: items,
                    itemsRevision: itemsRevision,
                    totalCount: totalCount,
                    hasMoreItems: hasMoreItems,
                    isLoadingMore: isLoadingMore,
                    appearance: appearance,
                    downloadStatusStore: appState.downloadStatusStore,
                    onSelect: { item in
                        appState.recordSearchHistory(searchQuery)
                        appState.openDetail(for: item)
                    },
                    onPlay: { item in
                        appState.recordSearchHistory(searchQuery)
                        Task { await appState.startPlayback(item: item) }
                    },
                    onLoadMore: { Task { await loadLibraryItems(reset: false) } }
                )
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .task(id: "\(library.id)|\(sortField.rawValue)|\(ascending)|\(filterUnwatchedOnly)|\(filterFavoritesOnly)|\(selectedGenreFilter)|\(searchQuery)") {
            if !searchQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            await loadLibraryItems(reset: true)
        }
        .task(id: appState.activeServer?.id) {
            if let srv = appState.activeServer, availableGenreNames.isEmpty,
               let ext = DonbyAppExtensionCenter.shared.plugin, ext.isActive(for: srv),
               let genres = await ext.fetchAvailableGenres(for: srv) {
                availableGenreNames = genres
            }
        }
    }

    private func loadLibraryItems(reset: Bool) async {
        guard let server = appState.activeServer, !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            loadErrorMessage = "未配置可用服务器"
            return
        }
        if reset {
            loadGeneration &+= 1
            loadErrorMessage = nil
            isLoading = true
            isLoadingMore = false
        } else {
            guard !isLoading && !isLoadingMore && hasMoreItems else { return }
            isLoadingMore = true
        }
        let currentGen = loadGeneration
        let requestStart = reset ? 0 : startIndex
        defer {
            if currentGen == loadGeneration {
                if reset {
                    isLoading = false
                } else {
                    isLoadingMore = false
                }
            }
        }

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let ext = DonbyAppExtensionCenter.shared.plugin, ext.isActive(for: server) {
                let page = try await ext.fetchLibraryPage(
                    server: server,
                    library: library,
                    query: q,
                    sortField: sortField,
                    ascending: ascending,
                    filterUnwatchedOnly: filterUnwatchedOnly,
                    filterFavoritesOnly: filterFavoritesOnly,
                    selectedGenreFilter: selectedGenreFilter,
                    cursor: (reset || !q.isEmpty) ? nil : nextCursor
                )
                guard !Task.isCancelled, currentGen == loadGeneration else { return }
                if reset || !q.isEmpty {
                    self.items = page.items
                    self.seenIds = Set(page.items.map(\.id))
                } else {
                    var added: [EmbyItem] = []
                    for it in page.items where seenIds.insert(it.id).inserted { added.append(it) }
                    self.items.append(contentsOf: added)
                }
                self.itemsRevision &+= 1
                self.nextCursor = page.nextCursor
                self.hasMoreItems = page.hasMore
                self.totalCount = max(self.items.count, page.totalOverride ?? self.items.count)
                return
            }

            let resp = try await EmbyClient.shared.fetchItems(
                server: server,
                parentId: library.id,
                sortBy: sortField.rawValue,
                sortOrder: ascending ? "Ascending" : "Descending",
                filters: filterUnwatchedOnly ? "IsUnplayed" : nil,
                isFavorite: filterFavoritesOnly ? true : nil,
                searchTerm: q.isEmpty ? nil : q,
                startIndex: requestStart,
                limit: Self.pageSize
            )
            guard !Task.isCancelled, currentGen == loadGeneration else { return }
            if reset {
                self.items = resp.items
                self.seenIds = Set(resp.items.map(\.id))
                self.itemsRevision &+= 1
            } else {
                var added: [EmbyItem] = []
                for item in resp.items where seenIds.insert(item.id).inserted {
                    added.append(item)
                }
                self.items.append(contentsOf: added)
                self.itemsRevision &+= 1
            }
            self.startIndex = requestStart + resp.items.count
            if let total = resp.totalRecordCount {
                self.totalCount = max(self.items.count, total)
                self.hasMoreItems = resp.items.count >= Self.pageSize && self.startIndex < total
            } else {
                self.totalCount = self.items.count
                self.hasMoreItems = resp.items.count >= Self.pageSize
            }
        } catch {
            if Task.isCancelled || currentGen != loadGeneration { return }
            if reset && self.items.isEmpty && q.isEmpty && !filterUnwatchedOnly && !filterFavoritesOnly && selectedGenreFilter.isEmpty {
                let cached = appState.latestByLibrary[library.id] ?? []
                if !cached.isEmpty {
                    self.items = cached
                    self.seenIds = Set(cached.map(\.id))
                    self.itemsRevision &+= 1
                    self.totalCount = cached.count
                    self.hasMoreItems = false
                    return
                }
            }
            if self.items.isEmpty {
                self.loadErrorMessage = error.localizedDescription
            } else {
                appState.showToast("加载列表失败: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }
}

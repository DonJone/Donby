import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

public struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadManager = DonbyDownloadManager.shared

    @State private var unpinnedCacheBytes: Int64 = 0
    @State private var pinnedDownloadBytes: Int64 = 0
    @State private var cachedAssets: [CachedMediaSummary] = []
    @State private var statusFilter: DownloadTaskStatus? = nil
    @State private var displayMode: DownloadDisplayMode = .library
    @State private var offlineLibraryGroups: [OfflineLibraryGroup] = []
    @State private var displayedItems: [EmbyItem] = []
    @State private var gridRevision: Int = 1

    @State private var searchQuery: String = ""
    @State private var sortField: OfflineLibrarySortField = .title
    @State private var sortAscending: Bool = true
    @State private var mediaFilter: OfflineLibraryFilter = .all
    @State private var showSortPopover: Bool = false
    @State private var isRefreshing: Bool = false

    private enum DownloadDisplayMode: String, CaseIterable, Identifiable {
        case library = "海报墙"
        case queue = "下载队列"
        var id: String { rawValue }
    }

    private enum OfflineLibrarySortField: String, CaseIterable, Identifiable {
        case title = "名称"
        case kind = "类型"
        case size = "容量"
        var id: String { rawValue }
    }

    private enum OfflineLibraryFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case series = "仅剧集"
        case movies = "仅电影"
        var id: String { rawValue }
    }

    public init() {}

    private var activeOrAttentionEntries: [DownloadEntry] {
        downloadManager.entries.filter {
            $0.status == .downloading || $0.status == .queued || $0.status == .failed
        }
    }

    private var filteredEntries: [DownloadEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return downloadManager.entries.filter { entry in
            if let statusFilter, entry.status != statusFilter { return false }
            if q.isEmpty { return true }
            return entry.title.lowercased().contains(q)
                || (entry.subtitle?.lowercased().contains(q) ?? false)
                || entry.serverName.lowercased().contains(q)
        }
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if displayMode == .library {
                if !activeOrAttentionEntries.isEmpty {
                    compactActiveTransferStrip
                }

                if displayedItems.isEmpty && !isRefreshing {
                    libraryEmptyPlaceholder
                } else {
                    NativePosterGridView(
                        items: displayedItems,
                        itemsRevision: gridRevision,
                        totalCount: displayedItems.count,
                        hasMoreItems: false,
                        isLoadingMore: false,
                        appearance: appearance,
                        onSelect: { item in appState.openDetail(for: item, preferOfflineFocus: true) },
                        onPlay: { item in Task { await appState.startPlayback(item: item, preferOffline: true) } },
                        onLoadMore: {}
                    )
                }
            } else {
                queueManagementBody
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .onAppear {
            refreshDiskUsage(runMigration: true)
        }
        .onChange(of: downloadManager.statusIndex) { _, _ in
            refreshDiskUsage(runMigration: false)
        }
        .onChange(of: downloadManager.entries.count) { _, _ in
            refreshDiskUsage(runMigration: false)
        }
        .onChange(of: searchQuery) { _, _ in recomputeDisplayedItems() }
        .onChange(of: sortField) { _, _ in recomputeDisplayedItems() }
        .onChange(of: sortAscending) { _, _ in recomputeDisplayedItems() }
        .onChange(of: mediaFilter) { _, _ in recomputeDisplayedItems() }
    }

    // MARK: - 54px Top Header (Matches MLibListView Resource Library Aesthetic)

    private var headerBar: some View {
        HStack(spacing: 10) {
            if appState.isSidebarCollapsed {
                ToolbarVectorButton(
                    tooltip: "展开侧边栏",
                    action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            appState.isSidebarCollapsed = false
                        }
                    }
                ) { hovered in
                    let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .focusable(false)
                .padding(.leading, appState.collapsedSidebarLeadingPadding)
            }

            Text(displayMode == .library ? "已下载" : "下载队列与缓存")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .lineLimit(1)

            Text(displayMode == .library ? "\(displayedItems.count)" : "\(filteredEntries.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

            let activeCount = downloadManager.entries.filter { $0.status == .downloading || $0.status == .queued }.count
            if activeCount > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        displayMode = .queue
                    }
                } label: {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("\(activeCount) 下载中")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(appState.accentColor)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(appState.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            ToolbarVectorButton(
                tooltip: "刷新离线媒体库",
                action: { refreshDiskUsage(runMigration: true) }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                RefreshVectorIcon(size: 14.5, color: iconColor, isSpinning: isRefreshing)
            }

            ToolbarVectorButton(
                tooltip: displayMode == .library ? "下载队列与缓存管理" : "返回海报墙视图",
                isActive: displayMode == .queue,
                action: {
                    withAnimation(.easeOut(duration: 0.16)) {
                        displayMode = (displayMode == .library) ? .queue : .library
                    }
                }
            ) { hovered in
                let iconColor = displayMode == .queue
                    ? appState.accentColor
                    : (appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88)))
                if displayMode == .library {
                    DownloadVectorIcon(state: .idle, size: 14.5, color: iconColor)
                } else {
                    GridWallVectorIcon(size: 14.5, color: iconColor)
                }
            }

            ToolbarVectorButton(
                tooltip: "在文件中浏览",
                action: { appState.selectSidebarModule(.files) }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                FolderVectorIcon(size: 14.5, color: iconColor)
            }

            ToolbarVectorButton(
                tooltip: "在访达中打开 ~/Movies/Donby",
                action: {
                    DonbyOfflineLibraryStorage.ensureRootDirectories()
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: DonbyOfflineLibraryStorage.moviesDonbyRootURL.path)
                }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                FinderRevealVectorIcon(size: 14.5, color: iconColor)
            }

            ToolbarVectorButton(
                tooltip: "排序与筛选",
                isActive: showSortPopover,
                action: { showSortPopover.toggle() }
            ) { hovered in
                let iconColor = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.32)) : (hovered ? .white : Color(white: 0.88))
                SortArrowsVectorIcon(size: 14.5, color: iconColor)
            }
            .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if displayMode == .library {
                        Text("排序方式")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("排序", selection: $sortField) {
                            ForEach(OfflineLibrarySortField.allCases) { field in
                                Text(field.rawValue).tag(field)
                            }
                        }
                        .labelsHidden()

                        Toggle("升序排列", isOn: $sortAscending)
                            .toggleStyle(
                                DonbyCheckboxToggleStyle(
                                    isLightMode: appState.isLightMode,
                                    accentColor: appState.accentColor,
                                    accentTextColor: appState.accentTextColor
                                )
                            )

                        Divider()

                        Text("媒体类型")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(OfflineLibraryFilter.allCases) { f in
                                let isSel = (mediaFilter == f)
                                Button {
                                    mediaFilter = f
                                } label: {
                                    HStack(spacing: 8) {
                                        ZStack {
                                            Circle()
                                                .strokeBorder(isSel ? appState.accentColor : DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 1.3)
                                                .frame(width: 14, height: 14)
                                            if isSel {
                                                Circle()
                                                    .fill(appState.accentColor)
                                                    .frame(width: 7, height: 7)
                                            }
                                        }
                                        Text(f.rawValue)
                                            .font(.system(size: 12.5, weight: isSel ? .semibold : .regular))
                                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        Text("任务状态筛选")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Button("全部任务 (\(downloadManager.entries.count))") { statusFilter = nil; showSortPopover = false }
                        Button("下载中") { statusFilter = .downloading; showSortPopover = false }
                        Button("已完成") { statusFilter = .completed; showSortPopover = false }
                        Button("已暂停") { statusFilter = .paused; showSortPopover = false }
                        Button("失败") { statusFilter = .failed; showSortPopover = false }
                    }
                }
                .font(.system(size: 12.5))
                .padding(14)
                .frame(width: 210)
            }

            DonbySearchPillField(placeholder: "搜索", text: $searchQuery, width: 200)
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
    }

    // MARK: - Compact Live Transfer Strip (Shown in Poster Grid Only When Active/Failed Tasks Exist)

    private var compactActiveTransferStrip: some View {
        VStack(spacing: 6) {
            ForEach(activeOrAttentionEntries.prefix(3)) { entry in
                HStack(spacing: 10) {
                    Circle()
                        .fill(entry.status == .failed ? Color.red : appState.accentColor)
                        .frame(width: 7, height: 7)
                    Text(entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ProgressView(value: min(1.0, max(0.0, entry.progressFraction)))
                        .frame(width: 110)
                        .tint(entry.status == .failed ? .red : appState.accentColor)
                    if entry.status == .downloading && entry.speedMBs > 0.01 {
                        Text(String(format: "%.1f MB/s", entry.speedMBs))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(appState.accentColor)
                            .frame(width: 68, alignment: .trailing)
                    } else {
                        Text(entry.status.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(entry.status == .failed ? Color.red : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 68, alignment: .trailing)
                    }
                    if entry.status == .downloading || entry.status == .queued {
                        Button {
                            DonbyDownloadManager.shared.pauseDownload(assetKey: entry.assetKey)
                        } label: {
                            HStack(spacing: 4) {
                                PauseVectorIcon(size: 10.5, color: DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                Text("暂停")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .donbyLiquidGlassCapsule()
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            let server = appState.servers.first(where: { $0.id == entry.serverId })
                            let budget = server.map { appState.effectiveDownloadConnectionBudget(for: $0) } ?? 6
                            DonbyDownloadManager.shared.resumeDownload(assetKey: entry.assetKey, connectionBudgetPerTask: budget)
                        } label: {
                            HStack(spacing: 4) {
                                DownloadVectorIcon(state: .idle, size: 11, color: appState.accentTextColor)
                                Text("继续")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(appState.accentTextColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(appState.accentColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Queue & Cache Management Body

    private var queueManagementBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            storageSummaryBanner
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 10)

            filterChipBar
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            if filteredEntries.isEmpty && (statusFilter != nil || cachedAssets.isEmpty) {
                queueEmptyPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredEntries) { entry in
                            let server = appState.servers.first(where: { $0.id == entry.serverId })
                            DownloadEntryRowCard(
                                entry: entry,
                                server: server,
                                isLightMode: appState.isLightMode,
                                accentColor: appState.accentColor,
                                accentTextColor: appState.accentTextColor,
                                onOpenDetail: { appState.openDetail(for: entry.hydratedItemSnapshot, preferOfflineFocus: true) },
                                onPlayOffline: { appState.playOfflineDownload(entry) },
                                onRevealInFinder: {
                                    let targetPath = entry.localVideoFilePath ?? entry.localFolderPath ?? DonbyOfflineLibraryStorage.moviesDonbyRootURL.path
                                    if FileManager.default.fileExists(atPath: targetPath) {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: targetPath)])
                                    } else {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: DonbyOfflineLibraryStorage.moviesDonbyRootURL.path)
                                    }
                                },
                                onPause: { DonbyDownloadManager.shared.pauseDownload(assetKey: entry.assetKey) },
                                onResume: {
                                    let budget = server.map { appState.effectiveDownloadConnectionBudget(for: $0) } ?? 6
                                    DonbyDownloadManager.shared.resumeDownload(assetKey: entry.assetKey, connectionBudgetPerTask: budget)
                                },
                                onRemove: {
                                    DonbyDownloadManager.shared.removeDownload(assetKey: entry.assetKey)
                                    refreshDiskUsage(runMigration: false)
                                }
                            )
                        }

                        if statusFilter == nil && !cachedAssets.isEmpty {
                            cachedAssetsSection
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private var storageSummaryBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(appState.accentColor.opacity(0.12))
                DownloadVectorIcon(state: .completed, size: 16.5, color: appState.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 14) {
                    Text("离线媒体库 (~/Movies/Donby)：\(formatBytes(pinnedDownloadBytes))")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("临时缓存：\(formatBytes(unpinnedCacheBytes)) / \(appState.turboDiskCacheMB) MB")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Text("离线内容保存在 ~/Movies/Donby，下载时优先复用已缓存分片")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }

            Spacer()

            Button {
                DonbyTurboCacheEngine.shared.clearAllUnpinnedCache()
                refreshDiskUsage(runMigration: false)
                appState.showToast("已清理临时分片缓存（已下载内容已保留）", icon: "sparkles")
            } label: {
                Text("清理临时缓存")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
            }
            .buttonStyle(.plain)
            .disabled(unpinnedCacheBytes == 0)
        }
        .padding(12)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.7)
        )
    }

    private var filterChipBar: some View {
        HStack(spacing: 8) {
            filterChip(title: "全部 (\(downloadManager.entries.count))", status: nil)
            filterChip(title: "下载中", status: .downloading)
            filterChip(title: "已完成", status: .completed)
            filterChip(title: "已暂停", status: .paused)
            filterChip(title: "失败", status: .failed)
            Spacer()
        }
    }

    private func filterChip(title: String, status: DownloadTaskStatus?) -> some View {
        let isSelected = statusFilter == status
        return Button {
            statusFilter = status
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? appState.accentTextColor : DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 13)
                .padding(.vertical, 5.5)
                .background(isSelected ? appState.accentColor : (appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.07)))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var libraryEmptyPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.05))
                    .frame(width: 64, height: 64)
                DownloadVectorIcon(
                    state: .idle,
                    size: 26,
                    color: DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.65)
                )
            }
            Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无离线影视" : "未找到匹配的离线影视")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text("在任意电影或剧集详情页点击下载按钮即可缓存至 ~/Movies/Donby")
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            if !downloadManager.entries.isEmpty {
                Button {
                    displayMode = .queue
                } label: {
                    Text("打开下载队列 (\(downloadManager.entries.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueEmptyPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 38))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.55))
            Text("暂无符合条件的下载任务")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshDiskUsage(runMigration: Bool) {
        let usage = DonbyTurboCacheEngine.shared.calculateDiskUsage()
        unpinnedCacheBytes = usage.unpinnedCacheBytes
        pinnedDownloadBytes = usage.pinnedDownloadBytes
        let excludedKeys = Set(downloadManager.entries.map(\.assetKey))
        cachedAssets = DonbyTurboCacheEngine.shared.listUnpinnedCachedAssets(excludingAssetKeys: excludedKeys)

        if runMigration {
            isRefreshing = true
            let serversSnapshot = appState.servers
            Task {
                await DonbyDownloadManager.shared.migrateLegacyCompletedDownloads(servers: serversSnapshot)
                let entries = DonbyDownloadManager.shared.entries
                let scanned = await Task.detached(priority: .utility) {
                    DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: entries)
                }.value
                await MainActor.run {
                    let latestUsage = DonbyTurboCacheEngine.shared.calculateDiskUsage()
                    self.unpinnedCacheBytes = latestUsage.unpinnedCacheBytes
                    self.pinnedDownloadBytes = latestUsage.pinnedDownloadBytes
                    self.cachedAssets = DonbyTurboCacheEngine.shared.listUnpinnedCachedAssets(excludingAssetKeys: Set(entries.map(\.assetKey)))
                    self.offlineLibraryGroups = scanned
                    self.recomputeDisplayedItems()
                    self.isRefreshing = false
                }
            }
        } else {
            let entries = downloadManager.entries
            Task.detached(priority: .utility) {
                let scanned = DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: entries)
                await MainActor.run {
                    self.offlineLibraryGroups = scanned
                    self.recomputeDisplayedItems()
                }
            }
        }
    }

    private var cachedAssetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("可转存的播放缓存 (\(cachedAssets.count))")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Text("在线播放写入的分片缓存可直接从断点转为离线文件")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                Spacer()
            }
            .padding(.top, 10)

            ForEach(cachedAssets) { cached in
                CachedAssetRowCard(
                    summary: cached,
                    server: appState.servers.first(where: { $0.id == cached.serverId }),
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    onPromoteToOffline: {
                        Task {
                            await appState.promoteCachedAssetToOffline(cached)
                            refreshDiskUsage(runMigration: false)
                        }
                    },
                    onRemoveCache: {
                        DonbyTurboCacheEngine.shared.removeAsset(assetKey: cached.assetKey, forceIncludePinned: false)
                        refreshDiskUsage(runMigration: false)
                    }
                )
            }
        }
    }

    private func recomputeDisplayedItems() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = offlineLibraryGroups.filter { group in
            switch mediaFilter {
            case .all: break
            case .series: if !group.isSeries { return false }
            case .movies: if group.isSeries { return false }
            }
            if q.isEmpty { return true }
            return group.displayItem.name.lowercased().contains(q)
                || (group.displayItem.originalTitle?.lowercased().contains(q) ?? false)
                || group.serverName.lowercased().contains(q)
        }

        let sorted = filtered.sorted { a, b in
            let asc = sortAscending
            switch sortField {
            case .title:
                let cmp = a.displayItem.name.localizedStandardCompare(b.displayItem.name)
                return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .kind:
                if a.isSeries != b.isSeries {
                    return asc ? a.isSeries : !a.isSeries
                }
                let cmp = a.displayItem.name.localizedStandardCompare(b.displayItem.name)
                return cmp == .orderedAscending
            case .size:
                if a.totalSizeBytes != b.totalSizeBytes {
                    return asc ? (a.totalSizeBytes < b.totalSizeBytes) : (a.totalSizeBytes > b.totalSizeBytes)
                }
                let cmp = a.displayItem.name.localizedStandardCompare(b.displayItem.name)
                return cmp == .orderedAscending
            }
        }

        displayedItems = sorted.map(\.displayItem)
        gridRevision &+= 1
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork

// MARK: - Files Module View
public struct FilesModuleView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloadManager = DonbyDownloadManager.shared
    @State var isDropTargeted: Bool = false
    @State var showDirectURLSheet: Bool = false
    @State var directURLInput: String = ""
    @State var directNameInput: String = ""
    @State var folderHierarchyByPath: [String: (subfolders: [LocalMediaFolder], videos: [LocalVideoFileInfo])] = [:]
    @State var folderCountsById: [UUID: Int] = [:]
    @State var folderNavStack: [LocalMediaFolder] = []

    @State private var searchQuery: String = ""
    @State private var filterChip: String = "全部"
    @State private var offlineGroups: [OfflineLibraryGroup] = []
    private let filterChips = ["全部", "剧集", "电影", "文件夹与直链"]

    private let supportedTypes: [UTType] = [
        .movie, .video, .quickTimeMovie, .mpeg4Movie,
        UTType(filenameExtension: "mkv") ?? .movie,
        UTType(filenameExtension: "avi") ?? .movie,
        UTType(filenameExtension: "webm") ?? .movie,
        UTType(filenameExtension: "ts") ?? .movie,
        UTType(filenameExtension: "flv") ?? .movie,
        UTType(filenameExtension: "m4v") ?? .movie
    ]

    public init() {}

    private var activeBrowseFolder: LocalMediaFolder? {
        folderNavStack.last ?? appState.browsingFolder
    }

    private var filteredOfflineGroups: [OfflineLibraryGroup] {
        guard filterChip != "文件夹与直链" else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return offlineGroups.filter { group in
            if filterChip == "剧集" && !group.isSeries { return false }
            if filterChip == "电影" && group.isSeries { return false }
            if q.isEmpty { return true }
            let item = group.displayItem
            return item.name.lowercased().contains(q)
                || (item.originalTitle?.lowercased().contains(q) ?? false)
                || (item.overview?.lowercased().contains(q) ?? false)
                || (item.genres?.contains(where: { $0.lowercased().contains(q) }) ?? false)
        }
    }

    private var filteredFolders: [LocalMediaFolder] {
        guard filterChip == "全部" || filterChip == "文件夹与直链" else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return appState.localFolders }
        return appState.localFolders.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    private var filteredRecentItems: [LocalOrURLMediaItem] {
        guard filterChip == "全部" || filterChip == "文件夹与直链" else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return appState.urlMediaItems }
        return appState.urlMediaItems.filter {
            $0.name.lowercased().contains(q) || $0.urlString.lowercased().contains(q)
        }
    }

    public var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                if let folder = activeBrowseFolder {
                    folderDetailHeader(folder)
                } else {
                    filesMainTopBar
                    filesSearchAndFilterBar
                }

                Divider().opacity(appState.isLightMode ? 0.35 : 0.12)

                if let folder = activeBrowseFolder {
                    folderDetailContent(folder)
                } else {
                    filesOverviewContent
                }
            }
            .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
            .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
                return true
            }

            if isDropTargeted {
                dropOverlay
            }
        }
        .sheet(isPresented: $showDirectURLSheet) {
            directURLSheetContent
        }
        .onChange(of: appState.browsingFolder?.id) { _, _ in
            folderNavStack = []
        }
        .task(id: downloadManager.statusIndex) {
            let entries = downloadManager.entries
            let scanned = await Task.detached(priority: .userInitiated) {
                DonbyOfflineLibraryStorage.scanOfflineLibrary(entries: entries)
            }.value
            self.offlineGroups = scanned
        }
        .task(id: appState.localFolders.map(\.id)) {
            let folders = appState.localFolders
            let counts = await Task.detached(priority: .utility) {
                await withTaskGroup(of: (UUID, Int).self) { group in
                    for folder in folders {
                        group.addTask {
                            (folder.id, AppState.countFolderVideos(path: folder.path))
                        }
                    }
                    var map: [UUID: Int] = [:]
                    for await (id, count) in group {
                        map[id] = count
                    }
                    return map
                }
            }.value
            folderCountsById = counts
        }
        .task(id: activeBrowseFolder?.path) {
            guard let folder = activeBrowseFolder else { return }
            let folderId = folder.id
            let folderPath = folder.path
            let result = await Task.detached(priority: .userInitiated) {
                (AppState.scanFolderHierarchy(path: folderPath), AppState.countFolderVideos(path: folderPath))
            }.value
            folderHierarchyByPath[folderPath] = result.0
            if folderNavStack.isEmpty {
                folderCountsById[folderId] = result.1
            }
        }
    }

    private var filesMainTopBar: some View {
        HStack(alignment: .center, spacing: 14) {
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
                .padding(.leading, appState.isWindowFullScreen ? 0 : 54)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("文件与离线媒体库")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Text("离线影片按剧/季/集归档至 ~/Movies/Donby，并保存海报与外挂字幕元数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }

            Spacer()

            Button {
                openAddFolderDialog()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("添加文件夹")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(appState.accentTextColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(appState.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("添加包含视频的本地文件夹或移动硬盘目录")

            Button {
                openLocalFileDialog()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("打开单文件")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                directURLInput = ""
                directNameInput = ""
                showDirectURLSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("网络直链")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var filesSearchAndFilterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                TextField("检索已下载影视海报库、本地文件夹或最近播放流...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(.system(size: 14.5))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
            )

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

                Button {
                    appState.selectSidebarModule(.downloads)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11.5))
                        Text("下载队列")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    DonbyOfflineLibraryStorage.ensureRootDirectories()
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: DonbyOfflineLibraryStorage.moviesDonbyRootURL.path)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11.5))
                        Text("~/Movies/Donby")
                            .font(.system(size: 11.5, design: .monospaced))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var filesOverviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 1. Offline Downloaded Media Poster Grid (Search Page Aesthetic)
                if filterChip != "文件夹与直链" {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("已下载影视库 (\(filteredOfflineGroups.count))")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            Text("包含本地海报、分季结构与外挂字幕")
                                .font(.system(size: 12))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            Spacer()
                            Button("浏览 ~/Movies/Donby 目录") {
                                DonbyOfflineLibraryStorage.ensureRootDirectories()
                                appState.browsingFolder = LocalMediaFolder(
                                    name: "Donby 离线影视库",
                                    path: DonbyOfflineLibraryStorage.moviesDonbyRootURL.path
                                )
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(appState.accentColor)
                        }

                        if filteredOfflineGroups.isEmpty {
                            HStack(spacing: 14) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 24))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.65))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(searchQuery.isEmpty ? "暂无已下载离线影视" : "未找到匹配的已下载影视")
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                    Text("在影片详情页点击下载后，视频、海报、背景图与字幕将按 剧/季/集 结构自动保存至此，并以海报墙展示")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.7)
                            )
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                                ForEach(filteredOfflineGroups) { group in
                                    PosterCardView(
                                        item: group.displayItem,
                                        width: 150,
                                        appearance: appState.cardAppearance,
                                        onSelect: { appState.openDetail(for: group.displayItem) },
                                        onPlay: { Task { await appState.startPlayback(item: group.displayItem) } }
                                    )
                                    .equatable()
                                    .contextMenu {
                                        Button {
                                            appState.openDetail(for: group.displayItem)
                                        } label: {
                                            Label("打开详情与选集", systemImage: "info.circle")
                                        }
                                        Button {
                                            Task { await appState.startPlayback(item: group.displayItem) }
                                        } label: {
                                            Label("离线播放", systemImage: "play.fill")
                                        }
                                        Button {
                                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.folderURL.path)
                                        } label: {
                                            Label("在访达中打开所在目录", systemImage: "folder")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 2. Local Folders Section (including auto-linked ~/Movies/Donby)
                if filterChip == "全部" || filterChip == "文件夹与直链" {
                    HStack(alignment: .firstTextBaseline) {
                        Text("媒体文件夹")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("共 \(filteredFolders.count) 个目录")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        Spacer()
                        Button {
                            openAddFolderDialog()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11))
                                Text("添加文件夹")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)

                    if filteredFolders.isEmpty {
                        emptyFolderPlaceholderCard
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                            ForEach(filteredFolders) { folder in
                                localFolderCard(folder)
                            }
                        }
                    }

                    dropZoneCard

                    HStack(alignment: .firstTextBaseline) {
                        Text("最近播放与直链")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text("共 \(filteredRecentItems.count) 项")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        Spacer()
                    }
                    .padding(.top, 6)

                    if filteredRecentItems.isEmpty {
                        emptyFilesPlaceholder
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                            ForEach(filteredRecentItems) { media in
                                fileMediaCard(media)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    func openLocalFileDialog() {
        let panel = NSOpenPanel()
        panel.title = "选择本地视频文件"
        panel.allowedContentTypes = supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let title = url.deletingPathExtension().lastPathComponent
            appState.playDirectURL(url: url, title: title)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        if let url = item as? URL {
                            DispatchQueue.main.async {
                                self.handleDroppedURL(url)
                            }
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        self.handleDroppedURL(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            self.handleDroppedURL(url)
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            self.handleDroppedURL(url)
                        }
                    }
                }
            }
        }
    }

    private func handleDroppedURL(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            appState.addLocalFolder(url: url)
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        appState.playDirectURL(url: url, title: title.isEmpty ? "本地视频" : title)
    }

    func formatBadgeFor(_ urlStr: String, isLocal: Bool) -> String {
        if isLocal {
            let ext = (urlStr as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "FILE" : ext
        }
        if urlStr.lowercased().contains(".m3u8") { return "HLS" }
        if urlStr.lowercased().contains(".mpd") { return "DASH" }
        let ext = (urlStr as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "LIVE" : ext
    }
}

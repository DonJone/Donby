import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork

// MARK: - Files Module View
public struct FilesModuleView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadManager = DonbyDownloadManager.shared
    @State private var isDropTargeted: Bool = false
    @State private var showDirectURLSheet: Bool = false
    @State private var directURLInput: String = ""
    @State private var directNameInput: String = ""
    @State private var folderHierarchyByPath: [String: (subfolders: [LocalMediaFolder], videos: [LocalVideoFileInfo])] = [:]
    @State private var folderCountsById: [UUID: Int] = [:]
    @State private var folderNavStack: [LocalMediaFolder] = []

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

    private func folderDetailHeader(_ folder: LocalMediaFolder) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                if !folderNavStack.isEmpty {
                    folderNavStack.removeLast()
                } else {
                    appState.browsingFolder = nil
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(folderNavStack.isEmpty ? "返回媒体库" : "上一级文件夹")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(folder.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    if folderNavStack.isEmpty && folder.id.uuidString == appState.defaultFilesFolderId {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.orange.opacity(0.9))
                            Text("默认打开")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                }
                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if folderNavStack.isEmpty, appState.localFolders.contains(where: { $0.id == folder.id }) {
                Button {
                    appState.setPresetDefaultFolder(id: folder.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: folder.id.uuidString == appState.defaultFilesFolderId ? "star.slash" : "star.fill")
                            .font(.system(size: 12))
                        Text(folder.id.uuidString == appState.defaultFilesFolderId ? "取消默认" : "设为默认打开")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("设为此模块或启动时默认打开的文件夹")
            }

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("在访达中显示")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func folderDetailContent(_ folder: LocalMediaFolder) -> some View {
        let hierarchy = folderHierarchyByPath[folder.path]
        let subfolders = hierarchy?.subfolders ?? []
        let videos = hierarchy?.videos ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if hierarchy == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if subfolders.isEmpty && videos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
                        Text("此文件夹内暂未扫描到子目录或视频文件")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        Text("支持 MP4、MKV、MOV、WebM、AVI、TS、FLV、ISO 等常见格式")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    if !subfolders.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("子目录 (\(subfolders.count))")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                Spacer()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                                ForEach(subfolders) { sub in
                                    subfolderNavigationCard(sub)
                                }
                            }
                        }
                    }

                    if !videos.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("视频文件")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                Text("共 \(videos.count) 个文件")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                                Spacer()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                                ForEach(videos) { video in
                                    folderVideoCard(video)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    private func subfolderNavigationCard(_ subfolder: LocalMediaFolder) -> some View {
        let posterFile = URL(fileURLWithPath: subfolder.path).appendingPathComponent("poster.jpg")
        return Button {
            folderNavStack.append(subfolder)
        } label: {
            HStack(spacing: 12) {
                LocalFileThumbView(url: posterFile, width: 40, height: 56, cornerRadius: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                            .frame(width: 44, height: 44)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(appState.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(subfolder.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                    Text("点击打开下级目录")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            }
            .padding(12)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.65)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func folderVideoCard(_ video: LocalVideoFileInfo) -> some View {
        let videoURL = URL(fileURLWithPath: video.path)
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let thumbURL = videoURL.deletingLastPathComponent().appendingPathComponent("\(stem)-thumb.jpg")
        let matchingOffline = downloadManager.entries.first { $0.localVideoFilePath == video.path && $0.status == .completed }

        return Button {
            if let offlineEntry = matchingOffline {
                appState.playOfflineDownload(offlineEntry)
            } else {
                appState.playDirectURL(url: videoURL, title: video.name)
            }
        } label: {
            HStack(spacing: 12) {
                LocalFileThumbView(url: thumbURL, width: 68, height: 42, cornerRadius: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                            .frame(width: 44, height: 44)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(appState.isLightMode ? Color(white: 0.25) : Color(white: 0.85))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(video.fileExtension)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 3))

                        Text(formatByteCount(video.fileSizeBytes))
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))

                        if matchingOffline != nil {
                            DonbyDownloadedBadgePill(
                                text: "已下载",
                                isCompleted: true,
                                accentColor: appState.accentColor,
                                fontSize: 9.0
                            )
                        }
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let offlineEntry = matchingOffline {
                Button {
                    appState.openDetail(for: offlineEntry.hydratedItemSnapshot)
                } label: {
                    Label("查看详情与字幕", systemImage: "info.circle")
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([videoURL])
            } label: {
                Label("在访达中显示视频文件", systemImage: "folder")
            }
        }
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

    private var emptyFolderPlaceholderCard: some View {
        Button {
            openAddFolderDialog()
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("暂未添加媒体文件夹")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("添加本地视频目录，浏览并直接播放")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Spacer()
                Text("添加文件夹")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            }
            .padding(14)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func localFolderCard(_ folder: LocalMediaFolder) -> some View {
        let isDefault = (folder.id.uuidString == appState.defaultFilesFolderId)
        let countText = folderCountsById[folder.id].map { "\($0) 个视频" } ?? "扫描中…"
        return Button {
            appState.browsingFolder = folder
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.07))
                        .frame(width: 44, height: 44)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isDefault ? (appState.isLightMode ? Color(white: 0.16) : .white) : (appState.isLightMode ? Color(white: 0.38) : Color(white: 0.72)))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(folder.name)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                            .lineLimit(1)

                        if isDefault {
                            HStack(spacing: 2.5) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(appState.accentColor)
                                Text("默认")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(appState.accentColor)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(appState.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        Text(countText)
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        Text("·")
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        Text(folder.path)
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Menu {
                    Button {
                        appState.setPresetDefaultFolder(id: folder.id)
                    } label: {
                        Label(isDefault ? "取消默认打开" : "设为默认打开文件夹", systemImage: isDefault ? "star.slash" : "star.fill")
                    }

                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        appState.removeLocalFolder(id: folder.id)
                    } label: {
                        Label("移出列表", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .padding(14)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isDefault ? appState.accentColor.opacity(0.35) : DonbyGlassPalette.separator(isLight: appState.isLightMode),
                        lineWidth: isDefault ? 1.1 : 0.7
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openAddFolderDialog() {
        let panel = NSOpenPanel()
        panel.title = "添加包含视频的媒体文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加文件夹"
        if panel.runModal() == .OK {
            for url in panel.urls {
                appState.addLocalFolder(url: url)
            }
        }
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
        return "\(bytes / 1024) KB"
    }

    private var dropZoneCard: some View {
        Button {
            openLocalFileDialog()
        } label: {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                        .frame(width: 48, height: 48)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(appState.isLightMode ? Color(white: 0.35) : Color(white: 0.75))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("拖拽视频文件至此，或点击直接选取")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("支持 MP4、MKV、MOV、WebM、AVI、M3U8 等常见格式")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                HStack(spacing: 5) {
                    Text("选取视频")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .padding(18)
            .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? appState.accentColor : DonbyGlassPalette.separator(isLight: appState.isLightMode),
                        lineWidth: isDropTargeted ? 2 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(appState.accentColor)
                Text("松开鼠标以立即播放视频")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func fileMediaCard(_ media: LocalOrURLMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                        .frame(width: 38, height: 38)
                    Image(systemName: media.isLocalFile ? "film" : "link")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appState.isLightMode ? Color(white: 0.35) : Color(white: 0.75))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                    Text(media.urlString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(formatBadgeFor(media.urlString, isLocal: media.isLocalFile))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(appState.isLightMode ? Color.black : Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(appState.isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(media.isLocalFile ? "本地文件" : "网络直链")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(media.urlString, forType: .string)
                        appState.showToast("已复制直链", icon: "doc.on.doc.fill")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("复制直链")

                    Button {
                        appState.deleteRecentMedia(id: media.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 24, height: 24)
                            .background(appState.isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("移除记录")

                    Button {
                        let url = AppState.resolveMediaURL(from: media.urlString)
                        appState.playDirectURL(url: url, title: media.name)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("播放")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private var emptyFilesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("暂无最近播放的本地或网络流")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var directURLSheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("输入网络直链播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

            VStack(alignment: .leading, spacing: 6) {
                Text("媒体名称 (选填)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("选填自定义标题", text: $directNameInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("流媒体 URL (支持 MP4, M3U8, MKV 等)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("https://example.com/video.m3u8", text: $directURLInput)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消") {
                    showDirectURLSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("立即播放") {
                    let raw = directURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: raw), !raw.isEmpty else {
                        appState.showToast("请输入有效网络 URL", icon: "exclamationmark.triangle", isError: true)
                        return
                    }
                    let title = directNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? (url.lastPathComponent.isEmpty ? "网络直链" : url.deletingPathExtension().lastPathComponent)
                        : directNameInput
                    showDirectURLSheet = false
                    appState.playDirectURL(url: url, title: title)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
    }

    private func openLocalFileDialog() {
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

    private func formatBadgeFor(_ urlStr: String, isLocal: Bool) -> String {
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

private struct LocalFileThumbView<Placeholder: View>: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage? = nil

    private var cacheKey: String { "local_file_thumb|\(url.path)" }

    var body: some View {
        Group {
            if let img = image ?? ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                placeholder()
            }
        }
        .task(id: url.path) {
            if let mem = ArtworkImageCache.shared.imageFromMemory(for: cacheKey) {
                image = mem
                return
            }
            let targetURL = url
            let key = cacheKey
            let loaded: NSImage? = await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: targetURL.path),
                      let img = NSImage(contentsOf: targetURL) else { return nil }
                ArtworkImageCache.shared.store(img, for: key)
                return img
            }.value
            if !Task.isCancelled, let loaded {
                image = loaded
            }
        }
    }
}

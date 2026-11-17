import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork

// MARK: - Files Module View
public struct FilesModuleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDropTargeted: Bool = false
    @State private var showDirectURLSheet: Bool = false
    @State private var directURLInput: String = ""
    @State private var directNameInput: String = ""
    @State private var folderVideosById: [UUID: [LocalVideoFileInfo]] = [:]
    @State private var folderCountsById: [UUID: Int] = [:]

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

    public var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                if let folder = appState.browsingFolder {
                    folderDetailHeader(folder)
                } else {
                    filesMainTopBar
                }

                Divider().opacity(0.12)

                if let folder = appState.browsingFolder {
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
        .task(id: appState.browsingFolder?.id) {
            guard let folder = appState.browsingFolder else { return }
            let folderId = folder.id
            let folderPath = folder.path
            let videos = await Task.detached(priority: .userInitiated) {
                AppState.scanFolderVideos(path: folderPath)
            }.value
            folderVideosById[folderId] = videos
            folderCountsById[folderId] = videos.count
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
                .padding(.leading, 54)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("本地与文件夹")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                Text("管理本地与外接硬盘媒体目录，支持 4K 原画直解与秒开")
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
        .padding(.bottom, 18)
    }

    private func folderDetailHeader(_ folder: LocalMediaFolder) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                appState.browsingFolder = nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("全部文件夹")
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

                    if folder.id.uuidString == appState.defaultFilesFolderId {
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
                Text(folder.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .lineLimit(1)
            }

            Spacer()

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
        let videos = folderVideosById[folder.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("包含视频")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text(videos.map { "共 \($0.count) 个文件" } ?? "正在扫描...")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                }

                if let videos, videos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
                        Text("此文件夹内暂未扫描到视频文件")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        Text("支持 MP4、MKV、MOV、WebM、AVI、TS、FLV、ISO 等常见格式")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else if let videos {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(videos) { video in
                            folderVideoCard(video)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    private func folderVideoCard(_ video: LocalVideoFileInfo) -> some View {
        Button {
            let url = URL(fileURLWithPath: video.path)
            appState.playDirectURL(url: url, title: video.name)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(appState.isLightMode ? Color(white: 0.25) : Color(white: 0.85))
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
    }

    private var filesOverviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Folders Section
                HStack(alignment: .firstTextBaseline) {
                    Text("媒体文件夹")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("共 \(appState.localFolders.count) 个目录")
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

                if appState.localFolders.isEmpty {
                    emptyFolderPlaceholderCard
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(appState.localFolders) { folder in
                            localFolderCard(folder)
                        }
                    }
                }

                // Drag & Drop Hero Zone (restrained SenPlayer aesthetic)
                dropZoneCard

                // Recent Items Section
                HStack(alignment: .firstTextBaseline) {
                    Text("最近播放与直链")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("共 \(appState.urlMediaItems.count) 项")
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                }
                .padding(.top, 6)

                if appState.urlMediaItems.isEmpty {
                    emptyFilesPlaceholder
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                        ForEach(appState.urlMediaItems) { media in
                            fileMediaCard(media)
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
                    Text("点击添加本地影视、下载或外接硬盘目录，自动归类并支持一键预设默认打开")
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
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
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
                    Text("支持 MP4、MKV、MOV、WebM、AVI、HLS m3u8 等超清原画直解")
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

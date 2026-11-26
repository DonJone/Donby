import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork

extension FilesModuleView {
    func folderDetailHeader(_ folder: LocalMediaFolder) -> some View {
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
                                .foregroundStyle(appState.accentColor)
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

    func folderDetailContent(_ folder: LocalMediaFolder) -> some View {
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

    func formatByteCount(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
        return "\(bytes / 1024) KB"
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

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DonbyCore
import DonbyNetwork

extension FilesModuleView {
    var emptyFolderPlaceholderCard: some View {
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

    func localFolderCard(_ folder: LocalMediaFolder) -> some View {
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

    func openAddFolderDialog() {
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

    var dropZoneCard: some View {
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

    var dropOverlay: some View {
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

    func fileMediaCard(_ media: LocalOrURLMediaItem) -> some View {
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

    var emptyFilesPlaceholder: some View {
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

    var directURLSheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("输入网络直链播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

            VStack(alignment: .leading, spacing: 6) {
                Text("媒体名称 (选填)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("选填自定义标题", text: $directNameInput)
                    .font(.system(size: 13))
                    .donbyFlatTextField(isLight: appState.isLightMode)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("流媒体 URL (支持 MP4, M3U8, MKV 等)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                TextField("https://example.com/video.m3u8", text: $directURLInput)
                    .font(.system(size: 13, design: .monospaced))
                    .donbyFlatTextField(isLight: appState.isLightMode)
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    showDirectURLSheet = false
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
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
                } label: {
                    Text("立即播放")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
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
}

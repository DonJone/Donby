import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

struct DownloadEntryRowCard: View {
    let entry: DownloadEntry
    let server: EmbyServerConfig?
    let isLightMode: Bool
    let accentColor: Color
    let accentTextColor: Color
    let onOpenDetail: () -> Void
    let onPlayOffline: () -> Void
    let onRevealInFinder: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            MediaArtworkView(server: server, item: entry.hydratedItemSnapshot, kind: .primary, maxWidth: 160)
                .frame(width: 48, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.5)
                )
                .onTapGesture { onOpenDetail() }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                        .lineLimit(1)
                    if let badge = entry.resolutionBadge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    if entry.origin == .autoArchivedFromCache {
                        Text("自动归档")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    Text(entry.serverName)
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }

                if let sub = entry.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                        .lineLimit(1)
                }

                ProgressView(value: min(1.0, max(0.0, entry.progressFraction)))
                    .tint(colorForStatus)

                HStack(spacing: 12) {
                    Text(entry.status.displayTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colorForStatus)
                    Text("\(ByteCountFormatter.string(fromByteCount: entry.downloadedBytes, countStyle: .file)) / \(entry.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: entry.totalBytes, countStyle: .file) : "计算中")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    if entry.status == .downloading && entry.speedMBs > 0.01 {
                        Text(String(format: "%.2f MB/s", entry.speedMBs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(accentColor)
                    }
                    if !entry.offlineSubtitles.isEmpty {
                        Text("已含 \(entry.offlineSubtitles.count) 份字幕")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    }
                    if let localPath = entry.localVideoFilePath {
                        Text(localPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let err = entry.errorMessage, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if entry.origin == .autoArchivedFromCache {
                    ToolbarVectorButton(
                        tooltip: "转为手动保留（播毕不自动删除）",
                        action: {
                            DonbyDownloadManager.shared.promoteToManualDownload(assetKey: entry.assetKey)
                        }
                    ) { _ in
                        BookmarkVectorIcon(size: 13.5, color: .orange)
                    }
                }

                ToolbarVectorButton(
                    tooltip: "在访达中显示文件",
                    action: { onRevealInFinder() }
                ) { hovered in
                    let col = isLightMode ? (hovered ? Color.black : Color(white: 0.34)) : (hovered ? .white : Color(white: 0.85))
                    FinderRevealVectorIcon(size: 13.5, color: col)
                }

                if entry.status == .completed {
                    Button {
                        onPlayOffline()
                    } label: {
                        HStack(spacing: 6) {
                            PlayVectorIcon(size: 11.5, color: accentTextColor)
                            Text("离线播放")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(accentTextColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if entry.status == .downloading || entry.status == .queued {
                    Button {
                        onPause()
                    } label: {
                        HStack(spacing: 5) {
                            PauseVectorIcon(size: 11, color: DonbyGlassPalette.primaryText(isLight: isLightMode))
                            Text("暂停")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6.5)
                        .donbyLiquidGlassCapsule()
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        onResume()
                    } label: {
                        HStack(spacing: 5) {
                            DownloadVectorIcon(state: .idle, size: 12.5, color: accentTextColor)
                            Text("继续下载")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(accentTextColor)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6.5)
                        .background(accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                ToolbarVectorButton(
                    tooltip: "删除离线任务与本地缓存文件",
                    action: { onRemove() }
                ) { hovered in
                    TrashVectorIcon(size: 13.5, color: hovered ? .red : .red.opacity(0.85))
                }
            }
        }
        .padding(14)
        .background(DonbyGlassPalette.cardBackground(isLight: isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.7)
        )
    }

    private var colorForStatus: Color {
        switch entry.status {
        case .queued: return .orange
        case .downloading: return accentColor
        case .paused: return .secondary
        case .completed: return .green
        case .failed: return .red
        }
    }
}

struct CachedAssetRowCard: View {
    let summary: CachedMediaSummary
    let server: EmbyServerConfig?
    let isLightMode: Bool
    let accentColor: Color
    let accentTextColor: Color
    let onPromoteToOffline: () -> Void
    let onRemoveCache: () -> Void

    var body: some View {
        let previewItem = summary.itemSnapshot ?? EmbyItem(
            id: summary.itemId ?? summary.assetKey,
            name: summary.displayTitle,
            type: "Movie",
            uhdPosterURL: summary.posterURLString
        )

        HStack(spacing: 14) {
            MediaArtworkView(server: server, item: previewItem, kind: .primary, maxWidth: 160)
                .frame(width: 48, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(summary.displayTitle)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                        .lineLimit(1)
                    Text(summary.isFullyCached ? "已完整缓存" : "播放缓存")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(summary.isFullyCached ? Color.green : accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((summary.isFullyCached ? Color.green : accentColor).opacity(0.12))
                        .clipShape(Capsule())
                    if let srvName = server?.name, !srvName.isEmpty {
                        Text(srvName)
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                    }
                }

                if let sub = summary.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                        .lineLimit(1)
                }

                ProgressView(value: summary.progressFraction)
                    .tint(summary.isFullyCached ? .green : accentColor)

                HStack(spacing: 10) {
                    Text(String(format: "%.0f%% 已缓存", summary.progressFraction * 100))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(summary.isFullyCached ? Color.green : accentColor)
                    Text("\(ByteCountFormatter.string(fromByteCount: summary.cachedBytes, countStyle: .file)) / \(summary.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file) : "未知大小")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onPromoteToOffline()
                } label: {
                    HStack(spacing: 5.5) {
                        DownloadVectorIcon(
                            state: summary.isFullyCached ? .completed : .idle,
                            size: 12.5,
                            color: accentTextColor
                        )
                        Text(summary.isFullyCached ? "转存离线" : "从缓存下载")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(accentTextColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                ToolbarVectorButton(
                    tooltip: "清理此项临时分片缓存",
                    action: { onRemoveCache() }
                ) { hovered in
                    TrashVectorIcon(size: 13.5, color: hovered ? .red : .red.opacity(0.85))
                }
            }
        }
        .padding(14)
        .background(DonbyGlassPalette.cardBackground(isLight: isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.7)
        )
    }
}

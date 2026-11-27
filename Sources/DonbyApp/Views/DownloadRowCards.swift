import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

@MainActor
private enum DownloadRowByteFormatter {
    static let file: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(from byteCount: Int64) -> String {
        file.string(fromByteCount: max(0, byteCount))
    }
}

private struct DownloadLiveProgressSample: Equatable {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speedMBs: Double

    init(_ entry: DownloadEntry) {
        self.downloadedBytes = entry.downloadedBytes
        self.totalBytes = entry.totalBytes
        self.speedMBs = entry.speedMBs
    }
}

struct DownloadEntryRowCard: View, Equatable {
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry
            && lhs.server == rhs.server
            && lhs.isLightMode == rhs.isLightMode
            && lhs.accentColor == rhs.accentColor
            && lhs.accentTextColor == rhs.accentTextColor
    }

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

                if entry.status == .downloading || entry.status == .queued {
                    ActiveDownloadEntryProgressMetrics(
                        entry: entry,
                        isLightMode: isLightMode,
                        accentColor: accentColor
                    )
                } else {
                    DownloadEntryMetricsContent(
                        status: entry.status,
                        isYieldingForPlayback: false,
                        downloadedBytes: entry.downloadedBytes,
                        totalBytes: entry.totalBytes,
                        speedMBs: entry.speedMBs,
                        progressFraction: entry.progressFraction,
                        offlineSubtitlesCount: entry.offlineSubtitles.count,
                        localVideoFilePath: entry.localVideoFilePath,
                        errorMessage: entry.errorMessage,
                        isLightMode: isLightMode,
                        accentColor: accentColor
                    )
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
                        .frame(minHeight: 24)
                        .background(accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
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
                        .frame(minHeight: 24)
                        .donbyLiquidGlassCapsule()
                        .contentShape(Capsule())
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
                        .frame(minHeight: 24)
                        .background(accentColor)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
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
}

private struct ActiveDownloadEntryProgressMetrics: View {
    @ObservedObject private var downloadManager = DonbyDownloadManager.shared
    let entry: DownloadEntry
    let isLightMode: Bool
    let accentColor: Color

    @State private var liveSample: DownloadLiveProgressSample? = nil

    private var effectiveDownloadedBytes: Int64 {
        liveSample?.downloadedBytes ?? entry.downloadedBytes
    }

    private var effectiveTotalBytes: Int64 {
        liveSample?.totalBytes ?? entry.totalBytes
    }

    private var effectiveSpeedMBs: Double {
        liveSample?.speedMBs ?? entry.speedMBs
    }

    private var effectiveProgressFraction: Double {
        guard effectiveTotalBytes > 0 else { return entry.status == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(effectiveDownloadedBytes) / Double(effectiveTotalBytes)))
    }

    var body: some View {
        DownloadEntryMetricsContent(
            status: entry.status,
            isYieldingForPlayback: downloadManager.isYieldingForPlayback,
            downloadedBytes: effectiveDownloadedBytes,
            totalBytes: effectiveTotalBytes,
            speedMBs: effectiveSpeedMBs,
            progressFraction: effectiveProgressFraction,
            offlineSubtitlesCount: entry.offlineSubtitles.count,
            localVideoFilePath: entry.localVideoFilePath,
            errorMessage: entry.errorMessage,
            isLightMode: isLightMode,
            accentColor: accentColor
        )
        .onAppear {
            if let current = DonbyDownloadManager.shared.entry(for: entry.assetKey) {
                let sample = DownloadLiveProgressSample(current)
                if sample != liveSample {
                    liveSample = sample
                }
            }
        }
        .onReceive(DonbyDownloadManager.shared.$entries) { entries in
            guard let current = entries.first(where: { $0.assetKey == entry.assetKey }) else { return }
            let sample = DownloadLiveProgressSample(current)
            if sample != liveSample {
                liveSample = sample
            }
        }
    }
}

private struct DownloadEntryMetricsContent: View {
    let status: DownloadTaskStatus
    let isYieldingForPlayback: Bool
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speedMBs: Double
    let progressFraction: Double
    let offlineSubtitlesCount: Int
    let localVideoFilePath: String?
    let errorMessage: String?
    let isLightMode: Bool
    let accentColor: Color

    private var isYieldingActive: Bool {
        isYieldingForPlayback && (status == .downloading || status == .queued)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: min(1.0, max(0.0, progressFraction)))
                .tint(colorForStatus)

            HStack(spacing: 12) {
                Text(isYieldingActive ? "已为播放让路" : status.displayTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colorForStatus)
                Text("\(DownloadRowByteFormatter.string(from: downloadedBytes)) / \(totalBytes > 0 ? DownloadRowByteFormatter.string(from: totalBytes) : "计算中")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                if !isYieldingActive && status == .downloading && speedMBs > 0.01 {
                    Text(String(format: "%.2f MB/s", speedMBs))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(accentColor)
                }
                if offlineSubtitlesCount > 0 {
                    Text("已含 \(offlineSubtitlesCount) 份字幕")
                        .font(.system(size: 11))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                }
                if let localPath = localVideoFilePath {
                    Text(localPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLightMode))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let err = errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
    }

    private var colorForStatus: Color {
        if isYieldingActive { return .orange }
        switch status {
        case .queued: return .orange
        case .downloading: return accentColor
        case .paused: return .secondary
        case .completed: return .green
        case .failed: return .red
        }
    }
}

struct CachedAssetRowCard: View, Equatable {
    let summary: CachedMediaSummary
    let server: EmbyServerConfig?
    let isLightMode: Bool
    let accentColor: Color
    let accentTextColor: Color
    let onPromoteToOffline: () -> Void
    let onRemoveCache: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.summary == rhs.summary
            && lhs.server == rhs.server
            && lhs.isLightMode == rhs.isLightMode
            && lhs.accentColor == rhs.accentColor
            && lhs.accentTextColor == rhs.accentTextColor
    }

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
                    Text("\(DownloadRowByteFormatter.string(from: summary.cachedBytes)) / \(summary.totalBytes > 0 ? DownloadRowByteFormatter.string(from: summary.totalBytes) : "未知大小")")
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
                    .frame(minHeight: 24)
                    .background(accentColor)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
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

struct CompactActiveTransferStripView: View {
    @ObservedObject private var downloadManager = DonbyDownloadManager.shared
    let isLightMode: Bool
    let accentColor: Color
    let accentTextColor: Color
    let onPause: (String) -> Void
    let onResume: (DownloadEntry) -> Void

    private var activeOrAttentionEntries: [DownloadEntry] {
        downloadManager.entries.filter {
            $0.status == .downloading || $0.status == .queued || $0.status == .failed
        }
    }

    var body: some View {
        let items = Array(activeOrAttentionEntries.prefix(3))
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { entry in
                    let isYielding = downloadManager.isYieldingForPlayback && (entry.status == .downloading || entry.status == .queued)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(entry.status == .failed ? Color.red : (isYielding ? Color.orange : accentColor))
                            .frame(width: 7, height: 7)
                        Text(entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        ProgressView(value: min(1.0, max(0.0, entry.progressFraction)))
                            .frame(width: 110)
                            .tint(entry.status == .failed ? .red : (isYielding ? .orange : accentColor))
                        if isYielding {
                            Text("已为播放让路")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                                .frame(width: 82, alignment: .trailing)
                        } else if entry.status == .downloading && entry.speedMBs > 0.01 {
                            Text(String(format: "%.1f MB/s", entry.speedMBs))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(accentColor)
                                .frame(width: 82, alignment: .trailing)
                        } else {
                            Text(entry.status.displayTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(entry.status == .failed ? Color.red : DonbyGlassPalette.secondaryText(isLight: isLightMode))
                                .frame(width: 82, alignment: .trailing)
                        }
                        if entry.status == .downloading || entry.status == .queued {
                            Button {
                                onPause(entry.assetKey)
                            } label: {
                                HStack(spacing: 4) {
                                    PauseVectorIcon(size: 10.5, color: DonbyGlassPalette.primaryText(isLight: isLightMode))
                                    Text("暂停")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLightMode))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(minHeight: 24)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                onResume(entry)
                            } label: {
                                HStack(spacing: 4) {
                                    DownloadVectorIcon(state: .idle, size: 11, color: accentTextColor)
                                    Text("继续")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(accentTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(minHeight: 24)
                                .background(accentColor)
                                .clipShape(Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DonbyGlassPalette.cardBackground(isLight: isLightMode))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }
}

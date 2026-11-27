import SwiftUI
import DonbyCore

// MARK: - Records View (Watch History & Progress)
public struct RecordsView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        RecordsContentView(watchHistoryStore: appState.watchHistoryStore)
    }
}

private struct DisplayWatchRecord: Identifiable {
    let record: WatchRecordItem
    let displayTitle: String
    let displaySubtitle: String?
    var id: WatchRecordItem.ID { record.id }
}

private struct RecordsContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var watchHistoryStore: DonbyWatchHistoryStore
    @State private var filterMode: String = "全部"
    @State private var filteredRecords: [DisplayWatchRecord] = []
    @State private var showClearAlert: Bool = false

    private static func resolveDisplayTitles(
        for record: WatchRecordItem,
        cachedSeriesNames: [String: String]
    ) -> (String, String?) {
        if record.sourceType == "本地文件" || (record.streamURLString?.hasPrefix("/") == true) || record.title.contains(".mkv") || record.title.contains(".mp4") {
            let parsed = MediaTitleParser.parse(rawName: record.title)
            return (parsed.mainTitle, parsed.subTitle)
        }
        if record.title.hasPrefix("第") && (record.title.hasSuffix("集") || record.title.contains("集")),
           let sName = cachedSeriesNames[record.embyItemId ?? ""], !sName.isEmpty {
            let epSub = (record.subtitle != nil && !record.subtitle!.isEmpty) ? "\(record.subtitle!) · \(record.title)" : record.title
            return (sName, epSub)
        }
        if record.title.hasPrefix("第") && (record.title.hasSuffix("集") || record.title.contains("集")),
           let sub = record.subtitle, sub.contains(" · ") {
            let parts = sub.components(separatedBy: " · ")
            let showName = parts[0]
            let remaining = parts.dropFirst().joined(separator: " · ")
            return (showName, "\(remaining) · \(record.title)")
        }
        return (record.title, record.subtitle)
    }

    private func recomputeFilteredRecords() {
        var list = watchHistoryStore.watchHistory
        if filterMode == "Emby" {
            list = list.filter { $0.sourceType == "Emby" || $0.sourceType == "UHDNow" || $0.embyItemId != nil }
        } else if filterMode == "本地与直链" {
            list = list.filter { $0.embyItemId == nil && ($0.sourceType == "本地文件" || $0.sourceType == "网络直链" || $0.sourceType == "Local") }
        }
        let seriesCache = appState.cachedSeriesNames
        filteredRecords = list.map { record in
            let (title, subtitle) = Self.resolveDisplayTitles(for: record, cachedSeriesNames: seriesCache)
            return DisplayWatchRecord(record: record, displayTitle: title, displaySubtitle: subtitle)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Bar
            HStack(spacing: 14) {
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
                    Text("观看记录")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("跨 Emby 服务器、本地文件与网络直链的历史进度")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                DonbySegmentedControl(
                    options: ["全部", "Emby", "本地与直链"],
                    selection: $filterMode,
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    fontSize: 12,
                    horizontalPadding: 11,
                    verticalPadding: 5,
                    title: { $0 }
                )

                Button {
                    showClearAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("清除历史")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(watchHistoryStore.watchHistory.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().opacity(0.12)

            ScrollView {
                if filteredRecords.isEmpty {
                    emptyRecordsPlaceholder
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRecords) { item in
                            watchRecordRow(item)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .onAppear {
            recomputeFilteredRecords()
        }
        .task(id: watchHistoryStore.watchHistory.count) {
            let pendingIDs: [String] = watchHistoryStore.watchHistory.compactMap { record in
                guard record.title.hasPrefix("第"),
                      record.title.hasSuffix("集") || record.title.contains("集"),
                      let itemId = record.embyItemId,
                      appState.cachedSeriesNames[itemId] == nil else {
                    return nil
                }
                return itemId
            }
            guard !pendingIDs.isEmpty else { return }
            var resolvedAny = false
            for itemId in Set(pendingIDs) {
                guard !Task.isCancelled else { return }
                if let name = await appState.resolveSeriesName(for: itemId), !name.isEmpty {
                    resolvedAny = true
                }
            }
            if resolvedAny && !Task.isCancelled {
                recomputeFilteredRecords()
            }
        }
        .donbyOnChange(of: filterMode) { _ in
            recomputeFilteredRecords()
        }
        .donbyOnChange(of: watchHistoryStore.watchHistory) { _ in
            recomputeFilteredRecords()
        }
        .alert("清除观看记录", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清除全部", role: .destructive) {
                appState.clearWatchHistory()
            }
        } message: {
            Text("确定要清除所有播放历史与进度记录吗？此操作无法撤销。")
        }
    }

    private func watchRecordRow(_ item: DisplayWatchRecord) -> some View {
        let record = item.record
        let displayTitle = item.displayTitle
        let displaySubtitle = item.displaySubtitle

        return HStack(spacing: 16) {
            // Artwork / Poster Thumbnail
            RecordArtworkThumbnailView(
                record: record,
                server: appState.activeServer,
                isLightMode: appState.isLightMode
            )

            // Info and Progress
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    Text(record.sourceType)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer()

                    Text(timeAgoDisplay(record.lastWatchedAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                if let sub = displaySubtitle {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                // Progress Bar
                VStack(alignment: .leading, spacing: 4) {
                    FractionalProgressBar(
                        fraction: record.progressRatio,
                        color: appState.accentColor,
                        height: 3.5,
                        trackColor: appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.10)
                    )
                    .padding(.top, 4)

                    HStack {
                        Text("观看进度 \(record.progressPercentageString)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(appState.accentColor)

                        Spacer()

                        Text(record.remainingMinutesString)
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
                .padding(.top, 2)

                // Actions
                HStack(spacing: 10) {
                    Button {
                        appState.resumePlaybackFromRecord(record)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("继续观看")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(appState.accentTextColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(appState.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.playFromBeginning(record)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 9))
                            Text("从头播放")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(appState.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        appState.deleteWatchRecord(id: record.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .buttonStyle(.plain)
                    .help("删除此条记录")
                }
                .padding(.top, 4)
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

    private var emptyRecordsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode).opacity(0.6))
            Text("暂无观看历史记录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
            Text("播放影片或本地视频后，将自动在此记录播放断点")
                .font(.system(size: 12))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func timeAgoDisplay(_ date: Date) -> String {
        let sec = Int(-date.timeIntervalSinceNow)
        if sec < 60 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        if sec < 86400 { return "\(sec / 3600) 小时前" }
        return "\(sec / 86400) 天前"
    }
}

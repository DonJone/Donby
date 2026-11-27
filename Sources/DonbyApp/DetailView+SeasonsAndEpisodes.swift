import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork

extension DetailView {
    var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Episodes Section Header: [ Season Picker ]  ...  [ <- -> More ]
            HStack {
                Menu {
                    if seasons.count > 1 {
                        ForEach(Array(seasons.enumerated()), id: \.element.id) { idx, season in
                            let sNum = season.indexNumber ?? (idx + 1)
                            Button {
                                triggerSeasonLoad(season, seasonNumber: sNum)
                            } label: {
                                if selectedSeasonIndex == sNum {
                                    Label(season.name, systemImage: "checkmark")
                                } else {
                                    Text(season.name)
                                }
                            }
                        }
                    } else {
                        Button("第 1 季 (当前)") {}
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.isSeries ? "第 \(selectedSeasonIndex) 季" : "选集列表")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        scrollEpisodes(direction: -1)
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        scrollEpisodes(direction: 1)
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)

            if episodes.isEmpty {
                if isLoadingDetails || isLoadingSeasonEpisodes {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                        .frame(width: 256, height: 144)
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                        .frame(width: 140, height: 14)
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                                        .frame(width: 96, height: 12)
                                }
                                .frame(width: 256)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                    }
                    .frame(height: 214)
                } else if let errMsg = detailLoadError {
                    detailErrorBanner(message: errMsg)
                        .padding(.horizontal, 28)
                        .frame(minHeight: 214, alignment: .center)
                } else {
                    HStack(spacing: 12) {
                        Text("暂无分季剧集")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button {
                            detailRefreshToken &+= 1
                        } label: {
                            Text("重试")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(minHeight: 24)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 214, alignment: .leading)
                }
            } else {
                let statusMap = buildEpisodeStatusMap(for: episodes)
                ScrollViewReader { proxy in
                    ZStack(alignment: .leading) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(episodes) { ep in
                                let isSelected = (ep.id == (focusedEpisodeId ?? episodes.first?.id))
                                episodeCardItem(ep, isSelected: isSelected, status: statusMap[ep.id])
                                    .id(ep.id)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                    }

                    // Floating < and > glass buttons on the carousel
                    HStack {
                        if (currentFocusedIndex ?? 0) > 0 {
                            Button {
                                scrollEpisodes(direction: -1)
                            } label: {
                                ZStack {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                }
                                .frame(width: 32, height: 32)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 14)
                        }

                        Spacer()

                        if (currentFocusedIndex ?? 0) < episodes.count - 1 {
                            Button {
                                scrollEpisodes(direction: 1)
                            } label: {
                                ZStack {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(appState.isLightMode ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white)
                                }
                                .frame(width: 32, height: 32)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 14)
                        }
                    }
                    }
                    .onAppear {
                        if let target = focusedEpisodeId ?? episodes.first?.id {
                            DispatchQueue.main.async {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    .donbyOnChange(of: focusedEpisodeId) { newId in
                        if let newId {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                            if let focusedEp = episodes.first(where: { $0.id == newId }) {
                                stageHoveredOrFocusedEpisode(focusedEp)
                            }
                        }
                    }
                    .donbyOnChange(of: episodes.map(\.id)) { _ in
                        if let target = focusedEpisodeId ?? episodes.first?.id {
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var currentFocusedIndex: Int? {
        let targetId = focusedEpisodeId ?? episodes.first?.id
        return episodes.firstIndex(where: { $0.id == targetId })
    }

    private func scrollEpisodes(direction: Int) {
        guard !episodes.isEmpty else { return }
        let cur = currentFocusedIndex ?? 0
        let nextIdx = max(0, min(episodes.count - 1, cur + direction))
        let nextEp = episodes[nextIdx]
        userDidPickEpisodeLocally = true
        focusedEpisodeId = nextEp.id
        appState.rememberDetailFocusedEpisode(
            seriesKey: detailSeriesKey,
            seasonNumber: nextEp.parentIndexNumber ?? selectedSeasonIndex,
            episodeId: nextEp.id
        )
    }

    private struct EpisodeCardStatus {
        let downloadEntry: DownloadEntry?
        let isWatched: Bool
        let cachedSummary: CachedMediaSummary?
    }

    private func buildEpisodeStatusMap(for eps: [EmbyItem]) -> [String: EpisodeCardStatus] {
        var downloadByItemId: [String: DownloadEntry] = [:]
        for entry in DonbyDownloadManager.shared.entries {
            if entry.status == .completed {
                downloadByItemId[entry.itemId] = entry
            } else if (entry.status == .downloading || entry.status == .queued),
                      downloadByItemId[entry.itemId] == nil {
                downloadByItemId[entry.itemId] = entry
            }
        }

        var firstRatioByItemId: [String: Double] = [:]
        var firstRatioByLocalPath: [String: Double] = [:]
        for rec in appState.watchHistoryStore.watchHistory {
            if let eid = rec.embyItemId, firstRatioByItemId[eid] == nil {
                firstRatioByItemId[eid] = rec.progressRatio
            }
            if let lp = rec.streamURLString, !lp.isEmpty {
                let norm = lp.hasPrefix("file://") ? (URL(string: lp)?.path ?? lp) : lp
                if firstRatioByLocalPath[norm] == nil {
                    firstRatioByLocalPath[norm] = rec.progressRatio
                }
            }
        }

        let serverId = effectiveDetailServer?.id
        var cachedByItemId: [String: CachedMediaSummary] = [:]
        for summary in cachedUnpinnedAssets where serverId == nil || summary.serverId == serverId {
            if let itemId = summary.itemId, cachedByItemId[itemId] == nil {
                cachedByItemId[itemId] = summary
            }
        }

        var result: [String: EpisodeCardStatus] = [:]
        result.reserveCapacity(eps.count)
        for ep in eps {
            let dlEntry = downloadByItemId[ep.id]
            let isDlDone = dlEntry?.status == .completed
            let isDlActive = dlEntry?.status == .downloading || dlEntry?.status == .queued

            let watched: Bool = {
                if ep.userData?.played == true || ep.progressFraction >= 0.90 { return true }
                if let snap = dlEntry?.itemSnapshot,
                   snap.userData?.played == true || snap.progressFraction >= 0.90 {
                    return true
                }
                if let r = firstRatioByItemId[ep.id] { return r >= 0.90 }
                if let lp = dlEntry?.localVideoFilePath, !lp.isEmpty,
                   let r = firstRatioByLocalPath[lp] {
                    return r >= 0.90
                }
                return false
            }()

            let cached = (!isDlDone && !isDlActive) ? cachedByItemId[ep.id] : nil
            result[ep.id] = EpisodeCardStatus(
                downloadEntry: dlEntry,
                isWatched: watched,
                cachedSummary: cached
            )
        }
        return result
    }

    private func episodeCardItem(_ ep: EmbyItem, isSelected: Bool, status: EpisodeCardStatus?) -> some View {
        let epDownloadEntry = status?.downloadEntry
        let isEpDownloaded = (epDownloadEntry?.status == .completed)
        let isEpDownloading = (epDownloadEntry?.status == .downloading || epDownloadEntry?.status == .queued)
        let isEpWatched = status?.isWatched ?? (ep.userData?.played == true || ep.progressFraction >= 0.90)
        let epCachedSummary = status?.cachedSummary

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(server: effectiveDetailServer, item: ep, kind: .thumb, maxWidth: 560)
                    .frame(width: 256, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.40)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Badges overlay
                VStack {
                    HStack(spacing: 6) {
                        if let code = ep.episodeCodeString {
                            Text(code)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.70))
                                .clipShape(Capsule())
                        }
                        if isEpDownloaded {
                            DonbyDownloadedBadgePill(
                                text: "已下载",
                                isCompleted: true,
                                accentColor: appState.overlayAccentColor,
                                fontSize: 9.5
                            )
                        } else if isEpDownloading, let entry = epDownloadEntry {
                            DonbyDownloadedBadgePill(
                                text: String(format: "%.0f%%", entry.progressFraction * 100),
                                isCompleted: false,
                                accentColor: appState.overlayAccentColor,
                                fontSize: 9.5
                            )
                        }
                        Spacer()
                        if isEpWatched {
                            DonbyWatchedBadgeView(size: 19)
                        }
                        if let duration = ep.runtimeMinutesString {
                            Text(duration)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.70))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(8)

                    Spacer()

                    // Theme-aware progress line at bottom
                    if ep.progressFraction > 0 {
                        FractionalProgressBar(
                            fraction: ep.progressFraction,
                            color: appState.isMonochromeTheme ? .white : appState.accentColor,
                            height: 3,
                            trackColor: Color.white.opacity(0.35)
                        )
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(width: 256, height: 144)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? (appState.isLightMode ? appState.accentColor : Color.white)
                            : (appState.isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.08)),
                        lineWidth: isSelected ? 2.2 : 0.75
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    stageHoveredOrFocusedEpisode(ep)
                }
            }
            .onTapGesture {
                userDidPickEpisodeLocally = true
                focusedEpisodeId = ep.id
                appState.rememberDetailFocusedEpisode(
                    seriesKey: detailSeriesKey,
                    seasonNumber: ep.parentIndexNumber ?? selectedSeasonIndex,
                    episodeId: ep.id
                )
                let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                Task {
                    await appState.startPlayback(
                        item: targetEp,
                        episodesQueue: episodes,
                        audioStreamIndex: selectedAudioIndex,
                        subtitleStreamIndex: selectedSubtitleIndex,
                        subtitleExplicitlyOff: didUserDisableSubtitle
                    )
                }
            }
            .contextMenu {
                Button {
                    userDidPickEpisodeLocally = true
                    focusedEpisodeId = ep.id
                    appState.rememberDetailFocusedEpisode(
                        seriesKey: detailSeriesKey,
                        seasonNumber: ep.parentIndexNumber ?? selectedSeasonIndex,
                        episodeId: ep.id
                    )
                    let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                    Task {
                        await appState.startPlayback(
                            item: targetEp,
                            episodesQueue: episodes,
                            audioStreamIndex: selectedAudioIndex,
                            subtitleStreamIndex: selectedSubtitleIndex,
                            subtitleExplicitlyOff: didUserDisableSubtitle
                        )
                    }
                } label: {
                    Label(isEpDownloaded ? "离线播放本集" : "立即播放", systemImage: "play.fill")
                }

                if isEpDownloaded, let doneEntry = epDownloadEntry {
                    if let videoPath = doneEntry.localVideoFilePath, !videoPath.isEmpty {
                        Button {
                            if FileManager.default.fileExists(atPath: videoPath) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: videoPath)])
                            } else {
                                appState.showToast("本地文件不存在或已被移动", icon: "exclamationmark.triangle.fill", isError: true)
                            }
                        } label: {
                            Label("在访达中显示视频文件", systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        DonbyDownloadManager.shared.removeDownload(assetKey: doneEntry.assetKey)
                    } label: {
                        Label("删除本地离线文件", systemImage: "trash")
                    }
                } else if !isEpDownloading, let srv = effectiveDetailServer, !srv.host.isEmpty {
                    let targetEp = (ep.seriesName == nil || ep.seriesName!.isEmpty) ? ep.withSeriesName(item.name) : ep
                    Button {
                        Task {
                            await appState.enqueueDownload(
                                server: srv,
                                item: targetEp,
                                seriesItemHint: item
                            )
                        }
                    } label: {
                        if let cached = epCachedSummary {
                            Label(String(format: "下载此集 (已缓存 %.0f%%)", cached.progressFraction * 100), systemImage: "arrow.down.circle")
                        } else {
                            Label("下载此集", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }

            // Bottom title row: Primary title, subtitle, and (i) info button
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.seriesName ?? item.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .lineLimit(1)

                    Text(ep.name)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    selectedEpisodeForInfo = ep
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 256)
        }
        .frame(width: 256)
    }

    private static func localizedPersonSubtitle(for person: EmbyPerson) -> String? {
        if let role = person.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            return role
        }
        switch person.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "director": return "导演"
        case "writer", "screenplay": return "编剧"
        case "producer", "executive producer": return "制片"
        case "composer": return "配乐"
        case "gueststar", "guest star": return "客串"
        default: return nil
        }
    }

    func castSection(people: [EmbyPerson]) -> some View {
        let canOpenPerson = DonbyAppExtensionCenter.shared.isActive(for: effectiveDetailServer)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: "演职人员")
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(people.prefix(20)) { person in
                        let subtitle = Self.localizedPersonSubtitle(for: person)
                        if canOpenPerson {
                            Button {
                                if let srv = effectiveDetailServer {
                                    DonbyAppExtensionCenter.shared.plugin?.openPersonSheet(server: srv, person: person)
                                }
                            } label: {
                                castPersonCard(person: person, subtitle: subtitle)
                            }
                            .buttonStyle(.plain)
                            .help("查看 \(person.name) 的库内作品")
                        } else {
                            castPersonCard(person: person, subtitle: subtitle)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 6)
            }
        }
    }

    private func castPersonCard(person: EmbyPerson, subtitle: String?) -> some View {
        VStack(spacing: 8) {
            PersonAvatarView(
                server: effectiveDetailServer,
                person: person,
                width: 78,
                height: 100,
                accentColor: appState.accentColor
            )

            VStack(spacing: 2) {
                Text(person.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .lineLimit(1)
                Text(subtitle ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    .opacity(subtitle == nil ? 0 : 1)
                    .lineLimit(1)
            }
            .frame(width: 82)
        }
        .contentShape(Rectangle())
    }
}

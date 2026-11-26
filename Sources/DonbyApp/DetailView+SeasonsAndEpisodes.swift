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
                                selectedSeasonIndex = sNum
                                Task { await loadEpisodesForSeason(season, seasonNumber: sNum) }
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

                    Text("更多")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
            }
            .padding(.horizontal, 28)

            if episodes.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载分季剧集...").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .leading) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(episodes) { ep in
                                let isSelected = (ep.id == (focusedEpisodeId ?? episodes.first?.id))
                                episodeCardItem(ep, isSelected: isSelected)
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
                    .onChange(of: focusedEpisodeId) { _, newId in
                        if let newId {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: episodes.map(\.id)) { _, _ in
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

    private func episodeCardItem(_ ep: EmbyItem, isSelected: Bool) -> some View {
        let epDownloadEntry = downloadManager.activeOrCompletedEntry(for: ep.id)
        let isEpDownloaded = (epDownloadEntry?.status == .completed)
        let isEpDownloading = (epDownloadEntry?.status == .downloading || epDownloadEntry?.status == .queued)
        let isEpWatched = appState.isItemWatchedOfflineOrLocal(ep, localVideoPath: epDownloadEntry?.localVideoFilePath)
        let epCachedSummary = (!isEpDownloaded && !isEpDownloading) ? cachedProgressSnapshot(
            forItemId: ep.id,
            serverId: effectiveDetailServer?.id
        ) : nil

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
                            : (appState.isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.06)),
                        lineWidth: isSelected ? 2.2 : 0.65
                    )
            )
            .shadow(
                color: Color.black.opacity(isSelected ? 0.28 : (appState.isLightMode ? 0.10 : 0.30)),
                radius: isSelected ? 10 : 6,
                y: isSelected ? 4 : 3
            )
            .contentShape(Rectangle())
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
                    if let videoPath = doneEntry.localVideoFilePath,
                       FileManager.default.fileExists(atPath: videoPath) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: videoPath)])
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

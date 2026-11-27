import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

extension PlayerView {
    // MARK: - Deterministic FFmpeg AVStream <-> Emby MediaSource Track Resolution

    var embyAudioStreams: [MediaStream] {
        let sourceStreams = currentResource.mediaSource.mediaStreams ?? currentItem.allStreams
        return sourceStreams.filter { $0.type?.lowercased() == "audio" }
    }

    var embySubtitleStreams: [MediaStream] {
        let sourceStreams = currentResource.mediaSource.mediaStreams ?? currentItem.allStreams
        return sourceStreams.filter { $0.type?.lowercased() == "subtitle" }
    }

    var resolvedAudioOptions: [PlayerAudioTrackOption] {
        let embyAudios = embyAudioStreams
        if !kernelAudioTracks.isEmpty {
            return kernelAudioTracks.enumerated().map { ord, kStream in
                let avIdx = kStream.index ?? ord
                let matchedEmby = embyAudios.indices.contains(ord)
                    ? embyAudios[ord]
                    : embyAudios.first(where: { $0.index == avIdx })
                let label = matchedEmby?.readableLabel ?? kStream.readableLabel
                return PlayerAudioTrackOption(
                    avStreamIndex: avIdx,
                    embyIndex: matchedEmby?.index,
                    label: label
                )
            }
        }
        return embyAudios.compactMap { eStream in
            guard let idx = eStream.index else { return nil }
            return PlayerAudioTrackOption(avStreamIndex: idx, embyIndex: idx, label: eStream.readableLabel)
        }
    }

    var resolvedSubtitleOptions: [PlayerSubtitleTrackOption] {
        var options: [PlayerSubtitleTrackOption] = []
        let embyEmbeddedSubs = embySubtitleStreams.filter { $0.isExternal != true }

        // 1. Embedded subtitle tracks backed by real FFmpeg AVStream indices
        for (ord, kStream) in kernelSubtitleTracks.enumerated() {
            guard let avIdx = kStream.index else { continue }
            let matchedEmby = embyEmbeddedSubs.indices.contains(ord)
                ? embyEmbeddedSubs[ord]
                : embyEmbeddedSubs.first(where: { $0.index == avIdx })
            let label = matchedEmby?.readableLabel ?? kStream.readableLabel
            let codecTag = (kStream.codec ?? matchedEmby?.codec)?.uppercased()
            options.append(PlayerSubtitleTrackOption(
                id: "emb-\(avIdx)",
                selection: .embedded(avStreamIndex: avIdx),
                embyIndex: matchedEmby?.index,
                label: label,
                badge: codecTag,
                externalItem: nil,
                language: matchedEmby?.language ?? kStream.language,
                codec: matchedEmby?.codec ?? kStream.codec,
                isDefault: (matchedEmby?.isDefault ?? kStream.isDefault) == true
            ))
        }

        // 2. External text subtitle tracks (or fallback remote tracks when container has no embedded subs)
        let extCandidates = kernelSubtitleTracks.isEmpty
            ? currentResource.subtitleURLs
            : currentResource.subtitleURLs.filter(\.isExternal)
        var seenURLs = Set<String>()
        for ext in extCandidates {
            guard seenURLs.insert(ext.url.absoluteString).inserted else { continue }
            options.append(PlayerSubtitleTrackOption(
                id: "ext-\(ext.id)",
                selection: .remoteExternal(url: ext.url),
                embyIndex: ext.streamIndex,
                label: ext.name,
                badge: "外挂",
                externalItem: ext,
                language: nil,
                codec: ext.codec,
                isDefault: false
            ))
        }

        // 3. Currently loaded local subtitle file (if any)
        if case .localExternal(let localURL) = activeSubtitleSelection {
            options.append(PlayerSubtitleTrackOption(
                id: "local-\(localURL.absoluteString)",
                selection: .localExternal(url: localURL),
                embyIndex: nil,
                label: localExternalSubtitleName ?? localURL.lastPathComponent,
                badge: "本地",
                externalItem: nil,
                language: nil,
                codec: localURL.pathExtension.lowercased(),
                isDefault: true
            ))
        }

        return options
    }


    static func queryKernelTracks(handle: OpaquePointer) -> (
        audio: [MediaStream],
        subtitles: [MediaStream],
        selectedAudioIndex: Int?,
        selectedSubIndex: Int?
    ) {
        var audios: [MediaStream] = []
        var selAudio: Int? = nil
        let aCount = dk_player_get_track_count(handle, 1)
        for ord in 0..<aCount {
            var info = DKTrackInfo()
            guard dk_player_get_track_info(handle, 1, ord, &info) else { continue }
            let idx = Int(info.stream_index)
            let codec = cString(from: info.codec)
            let lang = cString(from: info.language)
            let title = cString(from: info.title)
            let chLayout: String? = info.channels >= 8 ? "7.1" : (info.channels == 6 ? "5.1" : (info.channels > 0 ? "\(info.channels).0" : nil))
            if info.is_selected { selAudio = idx }
            audios.append(MediaStream(
                index: idx,
                type: "Audio",
                codec: codec.isEmpty ? nil : codec,
                language: lang.isEmpty ? nil : lang,
                title: title.isEmpty ? nil : title,
                isDefault: info.is_default,
                channels: Int(info.channels),
                channelLayout: chLayout
            ))
        }

        var subs: [MediaStream] = []
        var selSub: Int? = nil
        let sCount = dk_player_get_track_count(handle, 2)
        for ord in 0..<sCount {
            var info = DKTrackInfo()
            guard dk_player_get_track_info(handle, 2, ord, &info) else { continue }
            let idx = Int(info.stream_index)
            let codec = cString(from: info.codec)
                .replacingOccurrences(of: "hdmv_pgs_subtitle", with: "PGS")
                .replacingOccurrences(of: "subrip", with: "SRT")
            let lang = cString(from: info.language)
            let title = cString(from: info.title)
            if info.is_selected { selSub = idx }
            subs.append(MediaStream(
                index: idx,
                type: "Subtitle",
                codec: codec.isEmpty ? nil : codec,
                language: lang.isEmpty ? nil : lang,
                title: title.isEmpty ? nil : title,
                isDefault: info.is_default,
                isForced: info.is_forced
            ))
        }

        return (audios, subs, selAudio, selSub)
    }

    func selectAudioOption(_ option: PlayerAudioTrackOption) {
        activeAudioAVIndex = option.avStreamIndex
        selectedAudioIdx = option.embyIndex ?? option.avStreamIndex
        if let handle = playerHandle {
            dk_player_select_track(handle, 1, Int32(option.avStreamIndex))
            applyKernelSubtitleStyle()
            activeTurboHandle?.wakeWaitingReads()
            appState.showToast("已切换音轨: \(option.label)", icon: "speaker.wave.2.fill")
        }
    }

    func disableSubtitles(showFeedback: Bool, persist: Bool = true) {
        cancelActiveSubtitleAlignment(showToast: false)
        explicitSubtitleOff = true
        selectedSubIdx = nil
        activeSubtitleSelection = .off
        localExternalSubtitleName = nil
        if persist {
            appState.recordPrimarySubtitleChoice(
                serverId: session.server.id,
                item: currentItem,
                preference: .disabled,
                updateGlobal: false
            )
        }
        if let handle = playerHandle {
            dk_player_select_track(handle, 2, -1)
            if showFeedback {
                appState.showToast("已关闭字幕", icon: "captions.bubble")
            }
        }
    }

    func applySubtitleOptionOnStartup(
        _ option: PlayerSubtitleTrackOption,
        handle: OpaquePointer,
        defaultSelectedAV: Int?,
        generation: Int,
        prefetchedExternalTask: Task<(url: URL, text: String, isAss: Bool)?, Never>? = nil
    ) {
        explicitSubtitleOff = false
        switch option.selection {
        case .off:
            activeSubtitleSelection = .off
            dk_player_select_track(handle, 2, -1)
        case .embedded(let avIdx):
            activeSubtitleSelection = .embedded(avStreamIndex: avIdx)
            selectedSubIdx = option.embyIndex ?? avIdx
            if defaultSelectedAV != avIdx {
                dk_player_select_track(handle, 2, Int32(avIdx))
            }
            applyKernelSubtitleStyle()
        case .remoteExternal(let extURL):
            if let preTask = prefetchedExternalTask {
                selectedSubIdx = option.embyIndex
                activeSubtitleSelection = .remoteExternal(url: extURL)
                let fallbackItem = option.externalItem
                let fallbackEmbyIdx = option.embyIndex
                Task { @MainActor in
                    let pre = await preTask.value
                    guard self.activePlaybackGeneration == generation,
                          let currentHandle = self.playerHandle,
                          case .remoteExternal(let curURL) = self.activeSubtitleSelection,
                          curURL == extURL else { return }
                    if let pre, pre.url == extURL {
                        dk_player_load_external_subtitle(currentHandle, pre.text, pre.isAss)
                        self.applyKernelSubtitleStyle()
                    } else if let fallbackItem {
                        self.loadRemoteExternalSubtitle(item: fallbackItem, embyStreamIndex: fallbackEmbyIdx, silentToast: true)
                    }
                }
            } else if let ext = option.externalItem {
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: true)
            }
        case .localExternal:
            break
        }
    }

    func selectSubtitleOption(_ option: PlayerSubtitleTrackOption) {
        cancelActiveSubtitleAlignment(showToast: false)
        explicitSubtitleOff = false
        selectedSubIdx = option.embyIndex
        switch option.selection {
        case .off:
            disableSubtitles(showFeedback: true)
        case .embedded(let avIdx):
            localExternalSubtitleName = nil
            activeSubtitleSelection = .embedded(avStreamIndex: avIdx)
            appState.recordPrimarySubtitleChoice(
                serverId: session.server.id,
                item: currentItem,
                preference: option.toPreference()
            )
            if let handle = playerHandle {
                dk_player_select_track(handle, 2, Int32(avIdx))
                applyKernelSubtitleStyle()
                appState.showToast("已切换字幕: \(option.label)", icon: "captions.bubble.fill")
            }
        case .remoteExternal:
            if let ext = option.externalItem {
                localExternalSubtitleName = nil
                appState.recordPrimarySubtitleChoice(
                    serverId: session.server.id,
                    item: currentItem,
                    preference: option.toPreference()
                )
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: false)
            }
        case .localExternal:
            break
        }
    }

    func secondarySubtitleStatusTitle(options: [PlayerSubtitleTrackOption]) -> String {
        switch activeSecondarySubtitleSelection {
        case .off:
            return "关闭副字幕"
        case .localExternal(let url):
            return "副: \(secondaryLocalSubtitleName ?? url.lastPathComponent)"
        default:
            if let matched = options.first(where: { $0.selection == activeSecondarySubtitleSelection }) {
                return "副: \(matched.label)"
            }
            return "关闭副字幕"
        }
    }

    func disableSecondarySubtitle() {
        cancelActiveSubtitleAlignment(showToast: false)
        activeSecondarySubtitleSelection = .off
        secondaryLocalSubtitleName = nil
        secondarySubtitleTimeScale = 1.0
        isSecondaryAlignedToPrimary = false
        if appState.subtitleStyle.secondaryDelaySeconds != 0 {
            appState.subtitleStyle.secondaryDelaySeconds = 0
        }
        appState.recordSecondarySubtitleChoice(
            serverId: session.server.id,
            item: currentItem,
            preference: .disabled
        )
        if let handle = playerHandle {
            dk_player_select_secondary_subtitle_track(handle, -1)
        }
        appState.showToast("已关闭副字幕", icon: "captions.bubble")
    }

    func selectSecondarySubtitleOption(_ option: PlayerSubtitleTrackOption) {
        cancelActiveSubtitleAlignment(showToast: false)
        switch option.selection {
        case .off:
            disableSecondarySubtitle()
        case .embedded(let avIdx):
            secondaryLocalSubtitleName = nil
            secondarySubtitleTimeScale = 1.0
            isSecondaryAlignedToPrimary = false
            if appState.subtitleStyle.secondaryDelaySeconds != 0 {
                appState.subtitleStyle.secondaryDelaySeconds = 0
            }
            activeSecondarySubtitleSelection = .embedded(avStreamIndex: avIdx)
            appState.recordSecondarySubtitleChoice(
                serverId: session.server.id,
                item: currentItem,
                preference: option.toPreference()
            )
            if let handle = playerHandle {
                dk_player_select_secondary_subtitle_track(handle, Int32(avIdx))
                applyKernelSubtitleStyle()
                appState.showToast("已开启双语副字幕: \(option.label)", icon: "captions.bubble.fill")
            }
        case .remoteExternal:
            if let ext = option.externalItem {
                appState.recordSecondarySubtitleChoice(
                    serverId: session.server.id,
                    item: currentItem,
                    preference: option.toPreference()
                )
                loadRemoteExternalSubtitle(item: ext, embyStreamIndex: option.embyIndex, silentToast: false, asSecondary: true)
            }
        case .localExternal:
            break
        }
    }
}

import Foundation
import DonbyCore
import DonbyNetwork

extension AppState {
    func loadWatchHistoryFromDisk() {
        if let data = UserDefaults.standard.data(forKey: watchHistoryStorageKey),
           let decoded = try? jsonDecoder.decode([WatchRecordItem].self, from: data) {
            var sanitizedMap: [String: WatchRecordItem] = [:]
            var order: [String] = []

            for var item in decoded {
                let isLocal = item.sourceType == "本地文件" ||
                              item.sourceType == "Local" ||
                              (item.streamURLString?.hasPrefix("/") == true) ||
                              (item.streamURLString?.hasPrefix("file://") == true) ||
                              (item.sourceType == "原画直链" && item.embyItemId == nil && (item.title.contains(".mkv") || item.title.contains(".mp4")))

                if isLocal {
                    item.sourceType = "本地文件"
                    item.embyItemId = nil
                    if let s = item.streamURLString, s.hasPrefix("file://") {
                        item.streamURLString = URL(string: s)?.path ?? s
                    }
                    let parsed = MediaTitleParser.parse(rawName: item.title)
                    if parsed.mainTitle != item.title {
                        item.title = parsed.mainTitle
                        item.subtitle = parsed.subTitle
                    }
                } else if item.sourceType == "原画直链" || item.embyItemId != nil {
                    item.sourceType = "Emby"
                    if item.title.hasPrefix("第") && (item.title.hasSuffix("集") || item.title.contains("集")),
                       let itemId = item.embyItemId, let sName = cachedSeriesNames[itemId], !sName.isEmpty {
                        let epSub = (item.subtitle != nil && !item.subtitle!.isEmpty) ? "\(item.subtitle!) · \(item.title)" : item.title
                        item.title = sName
                        item.subtitle = epSub
                    }
                }

                let dedupKey: String
                if item.sourceType == "本地文件" {
                    let normPath = item.streamURLString ?? item.title
                    dedupKey = "local:\(normPath)"
                } else if let embyId = item.embyItemId, !embyId.isEmpty {
                    dedupKey = "emby:\(embyId)"
                } else {
                    dedupKey = "url:\(item.streamURLString ?? item.title)"
                }
                item.id = dedupKey

                if let existing = sanitizedMap[dedupKey] {
                    var merged = existing
                    if item.positionSeconds > existing.positionSeconds {
                        merged.positionSeconds = item.positionSeconds
                    }
                    if item.lastWatchedAt > existing.lastWatchedAt {
                        merged.lastWatchedAt = item.lastWatchedAt
                    }
                    if merged.subtitle == nil || merged.subtitle?.isEmpty == true {
                        merged.subtitle = item.subtitle
                    }
                    merged.mediaType = merged.mediaType ?? item.mediaType
                    merged.seriesId = merged.seriesId ?? item.seriesId
                    sanitizedMap[dedupKey] = merged
                } else {
                    sanitizedMap[dedupKey] = item
                    order.append(dedupKey)
                }
            }
            self.watchHistory = Array(order.compactMap { sanitizedMap[$0] }.prefix(Self.maxWatchHistoryCount))
        } else {
            self.watchHistory = []
        }
    }

    private func saveWatchHistoryToDisk() {
        scheduleSaveWatchHistory(immediate: true)
    }

    private nonisolated static func persistWatchHistorySnapshot(_ snapshot: [WatchRecordItem], storageKey: String) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func loadCachedSeriesNamesFromDisk() {
        if let dict = UserDefaults.standard.dictionary(forKey: cachedSeriesNamesStorageKey) as? [String: String] {
            self.cachedSeriesNames = dict
        } else {
            self.cachedSeriesNames = [:]
        }
    }

    func saveCachedSeriesNamesToDisk() {
        UserDefaults.standard.set(cachedSeriesNames, forKey: cachedSeriesNamesStorageKey)
    }

    private func findLoadedSeriesName(for itemId: String) -> String? {
        let topLists = [carouselItems, resumeItems, nextUpItems, favoriteItems]
        for list in topLists {
            if let s = list.first(where: { $0.id == itemId })?.seriesName, !s.isEmpty {
                return s
            }
        }
        for list in latestByLibrary.values {
            if let s = list.first(where: { $0.id == itemId })?.seriesName, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    public func resolveSeriesName(for itemId: String) async -> String? {
        if let cached = cachedSeriesNames[itemId], !cached.isEmpty {
            return cached
        }
        if let found = findLoadedSeriesName(for: itemId) {
            cachedSeriesNames[itemId] = found
            saveCachedSeriesNamesToDisk()
            return found
        }
        if let existingTask = inFlightSeriesNameTasks[itemId] {
            return await existingTask.value
        }
        guard let server = activeServer, !server.host.isEmpty else { return nil }
        let task = Task<String?, Never> {
            let fetched: EmbyItem? = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                try? await ext.fetchItemDetail(
                    server: server,
                    item: EmbyItem(id: itemId, name: "", type: "Episode", uhdMediaType: nil)
                )
            } else {
                try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId)
            }
            guard let fetched, let s = fetched.seriesName, !s.isEmpty else {
                return nil
            }
            return s
        }
        inFlightSeriesNameTasks[itemId] = task
        let resolved = await task.value
        inFlightSeriesNameTasks.removeValue(forKey: itemId)
        if let resolved, !resolved.isEmpty {
            cachedSeriesNames[itemId] = resolved
            saveCachedSeriesNamesToDisk()
        }
        return resolved
    }

    public func updateRecordTitles(id: String, newTitle: String, newSubtitle: String?) {
        var updated = watchHistory
        guard let idx = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[idx].title = newTitle
        if let newSubtitle {
            updated[idx].subtitle = newSubtitle
        }
        watchHistory = updated
        scheduleSaveWatchHistory(immediate: true)
    }

    public func formattedWatchRecordMetadata(
        for item: EmbyItem,
        resolvedSeriesName: String? = nil
    ) -> (title: String, subtitle: String?) {
        if item.isEpisode {
            let seriesName = [
                resolvedSeriesName,
                item.seriesName,
                cachedSeriesNames[item.id],
                item.seriesId.flatMap { cachedSeriesNames[$0] }
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

            let recTitle = seriesName ?? item.name
            var subParts: [String] = []
            if let code = item.episodeCodeString, !code.isEmpty {
                subParts.append(code)
            }
            if !item.name.isEmpty && !subParts.contains(item.name) && item.name != recTitle {
                subParts.append(item.name)
            }
            let recSubtitle = subParts.isEmpty ? item.resolutionBadge : subParts.joined(separator: " · ")
            return (recTitle, recSubtitle)
        }
        let recSubtitle = item.displaySubtitle.isEmpty ? item.resolutionBadge : item.displaySubtitle
        return (item.name, recSubtitle)
    }

    public func flushWatchHistory() {
        saveWatchHistoryTask?.cancel()
        saveWatchHistoryTask = nil
        dispatchWatchHistoryWriteOffMainActor()
    }

    func flushWatchHistorySync() {
        saveWatchHistoryTask?.cancel()
        saveWatchHistoryTask = nil
        Self.persistWatchHistorySnapshot(watchHistory, storageKey: watchHistoryStorageKey)
    }

    private func dispatchWatchHistoryWriteOffMainActor() {
        let snapshot = watchHistory
        let key = watchHistoryStorageKey
        let previousTask = inFlightWatchHistorySaveTask
        inFlightWatchHistorySaveTask = Task.detached(priority: .utility) {
            _ = await previousTask?.value
            Self.persistWatchHistorySnapshot(snapshot, storageKey: key)
        }
    }

    public func scheduleSaveWatchHistory(immediate: Bool = false) {
        if immediate {
            flushWatchHistory()
            return
        }
        if saveWatchHistoryTask != nil { return }
        saveWatchHistoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveWatchHistoryTask = nil
            self.dispatchWatchHistoryWriteOffMainActor()
        }
    }

    public func recordWatch(
        title: String,
        subtitle: String? = nil,
        posterKey: String? = nil,
        posterURL: String? = nil,
        position: Double,
        duration: Double,
        sourceType: String = "Emby",
        streamURLString: String? = nil,
        embyItemId: String? = nil,
        resolutionTag: String? = "4K UHD",
        mediaType: String? = nil,
        seriesId: String? = nil
    ) {
        guard duration > 0 || position > 0 else { return }

        let isLocal = (sourceType == "本地文件" || sourceType == "Local") ||
                      (streamURLString?.hasPrefix("/") == true) ||
                      (streamURLString?.hasPrefix("file://") == true)

        let normStreamPath: String? = {
            guard let s = streamURLString else { return nil }
            if s.hasPrefix("file://") { return URL(string: s)?.path ?? s }
            return s
        }()

        let cleanSourceType = isLocal ? "本地文件" : (sourceType == "原画直链" ? "Emby" : sourceType)
        let cleanEmbyId = isLocal ? nil : embyItemId

        let recId: String
        if isLocal {
            recId = "local:\(normStreamPath ?? title)"
        } else if let eId = cleanEmbyId, !eId.isEmpty {
            recId = "emby:\(eId)"
        } else {
            recId = "url:\(normStreamPath ?? title)"
        }

        let now = Date()
        if lastRecordedWatchItemId == recId,
           abs(position - lastRecordedWatchPosition) < 3.0,
           now.timeIntervalSince(lastRecordedWatchDate) < 4.0 {
            return
        }
        lastRecordedWatchItemId = recId
        lastRecordedWatchPosition = position
        lastRecordedWatchDate = now

        func matchesExisting(_ existing: WatchRecordItem) -> Bool {
            if existing.id == recId { return true }
            if isLocal {
                if let exStream = existing.streamURLString {
                    let exNorm = exStream.hasPrefix("file://") ? (URL(string: exStream)?.path ?? exStream) : exStream
                    return exNorm == normStreamPath
                }
                return existing.sourceType == "本地文件" && existing.title == title && existing.subtitle == subtitle
            } else if let eId = cleanEmbyId {
                if existing.embyItemId == eId { return true }
            } else if let normStreamPath, !normStreamPath.isEmpty, let exStream = existing.streamURLString {
                if exStream == normStreamPath { return true }
            }
            return false
        }

        var updatedHistory = watchHistory
        let previousMatch = updatedHistory.first(where: matchesExisting)
        updatedHistory.removeAll(where: matchesExisting)

        let record = WatchRecordItem(
            id: recId,
            title: title,
            subtitle: subtitle,
            posterKey: posterKey,
            posterURL: posterURL,
            positionSeconds: position,
            durationSeconds: duration,
            lastWatchedAt: now,
            sourceType: cleanSourceType,
            streamURLString: normStreamPath,
            embyItemId: cleanEmbyId,
            resolutionTag: resolutionTag,
            mediaType: mediaType ?? previousMatch?.mediaType,
            seriesId: seriesId ?? previousMatch?.seriesId
        )
        updatedHistory.insert(record, at: 0)
        if updatedHistory.count > Self.maxWatchHistoryCount {
            updatedHistory.removeLast(updatedHistory.count - Self.maxWatchHistoryCount)
        }
        watchHistory = updatedHistory
        scheduleSaveWatchHistory(immediate: false)
        let thumbKey = "record_thumb_\(recId)_\(posterURL ?? "")"
        if ArtworkImageCache.shared.imageFromMemory(for: thumbKey) == nil {
            if let posterURL, !posterURL.isEmpty {
                ArtworkImageCache.shared.aliasKeys([thumbKey], to: posterURL)
            } else if let embyItemId, !embyItemId.isEmpty {
                ArtworkImageCache.shared.aliasKeys([thumbKey], to: "item_\(embyItemId)_primary")
            }
        }
    }

    public func clearWatchHistory() {
        watchHistory.removeAll()
        flushWatchHistory()
        showToast("已清空全部观看记录", icon: "trash.fill")
    }

    public func deleteWatchRecord(id: String) {
        watchHistory.removeAll { $0.id == id }
        scheduleSaveWatchHistory(immediate: true)
    }

    private func makeWatchRecordStubItem(_ record: WatchRecordItem, itemId: String) -> EmbyItem {
        let isEpisode = (record.mediaType?.lowercased() == "episode") || (record.seriesId?.isEmpty == false)
        let embyType = isEpisode ? "Episode" : ((record.mediaType?.isEmpty == false) ? record.mediaType : "Movie")
        let explicitKind: String? = if isEpisode {
            "episode"
        } else if record.mediaType?.lowercased() == "movie" {
            "movie"
        } else {
            nil
        }
        return EmbyItem(
            id: itemId,
            name: record.title,
            type: embyType,
            seriesId: record.seriesId,
            uhdMediaType: explicitKind
        )
    }

    public func resumePlaybackFromRecord(_ record: WatchRecordItem) {
        if let itemId = record.embyItemId, let server = activeServer, !server.host.isEmpty {
            if let cached = allLoadedMediaItems.first(where: { $0.id == itemId }) {
                var resumingItem = cached
                var uData = resumingItem.userData ?? EmbyUserData()
                uData.playbackPositionTicks = Int64(record.positionSeconds * 10_000_000.0)
                resumingItem.userData = uData
                Task { await startPlayback(item: resumingItem) }
                return
            }
            let stubItem = makeWatchRecordStubItem(record, itemId: itemId)
            Task {
                let fetchedItem: EmbyItem? = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                    try? await ext.fetchItemDetail(server: server, item: stubItem)
                } else {
                    try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId)
                }
                if var fetched = fetchedItem {
                    var uData = fetched.userData ?? EmbyUserData()
                    uData.playbackPositionTicks = Int64(record.positionSeconds * 10_000_000.0)
                    fetched.userData = uData
                    await startPlayback(item: fetched)
                } else if let urlStr = record.streamURLString {
                    let url = Self.resolveMediaURL(from: urlStr)
                    playDirectURL(url: url, title: record.title, startSeconds: record.positionSeconds)
                }
            }
            return
        }
        if let urlStr = record.streamURLString {
            let url = Self.resolveMediaURL(from: urlStr)
            playDirectURL(url: url, title: record.title, startSeconds: record.positionSeconds)
            return
        }
    }

    public func playFromBeginning(_ record: WatchRecordItem) {
        if let itemId = record.embyItemId, let server = activeServer, !server.host.isEmpty {
            if let cached = allLoadedMediaItems.first(where: { $0.id == itemId }) {
                Task { await startPlayback(item: cached, fromBeginning: true) }
                return
            }
            let stubItem = makeWatchRecordStubItem(record, itemId: itemId)
            Task {
                let fetchedItem: EmbyItem? = if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                    try? await ext.fetchItemDetail(server: server, item: stubItem)
                } else {
                    try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: itemId)
                }
                if let fetched = fetchedItem {
                    await startPlayback(item: fetched, fromBeginning: true)
                } else if let urlStr = record.streamURLString {
                    let url = Self.resolveMediaURL(from: urlStr)
                    playDirectURL(url: url, title: record.title, startSeconds: 0)
                }
            }
            return
        }
        if let urlStr = record.streamURLString {
            let url = Self.resolveMediaURL(from: urlStr)
            playDirectURL(url: url, title: record.title, startSeconds: 0)
            return
        }
    }

    public static func resolveMediaURL(from string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://") {
            let withoutScheme = String(trimmed.dropFirst(7))
            let path = withoutScheme.removingPercentEncoding ?? withoutScheme
            return URL(fileURLWithPath: path)
        } else if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        } else if let parsed = URL(string: trimmed), parsed.scheme != nil {
            return parsed
        } else {
            return URL(fileURLWithPath: trimmed)
        }
    }

    public func isItemWatchedOfflineOrLocal(_ item: EmbyItem, localVideoPath: String? = nil) -> Bool {
        if item.userData?.played == true { return true }
        if item.progressFraction >= 0.90 { return true }

        let matchingEntry = DonbyDownloadManager.shared.entry(forItemId: item.id)
        if let dlSnapshot = matchingEntry?.itemSnapshot {
            if dlSnapshot.userData?.played == true || dlSnapshot.progressFraction >= 0.90 {
                return true
            }
        }

        let resolvedLocalPath = localVideoPath ?? matchingEntry?.localVideoFilePath
        if let record = watchHistory.first(where: { rec in
            if rec.embyItemId == item.id { return true }
            if let lp = resolvedLocalPath, !lp.isEmpty,
               let recURL = rec.streamURLString {
                let norm = recURL.hasPrefix("file://") ? (URL(string: recURL)?.path ?? recURL) : recURL
                if norm == lp { return true }
            }
            return false
        }) {
            return record.progressRatio >= 0.90
        }
        return false
    }
}

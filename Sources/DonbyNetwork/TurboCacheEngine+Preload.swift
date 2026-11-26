import Foundation
import DonbyCore

// MARK: - Detail-Page Full Preload & Episode Micro-Stage Preloader

extension DonbyTurboCacheEngine {
    private func clearDetailPreloadIfMatching(_ signature: String) {
        lock.lock()
        if activeDetailPreloadKey == signature {
            activeDetailPreloadTask = nil
            activeDetailPreloadKey = nil
        }
        lock.unlock()
    }

    private func clearMicroStageIfMatching(_ signature: String) {
        lock.lock()
        if activeMicroStageKey == signature {
            activeMicroStageTask = nil
            activeMicroStageKey = nil
        }
        lock.unlock()
    }

    /// Cancels both background detail-page preload and any hover/next-episode micro-stage task
    /// so active playback immediately owns 100% of network bandwidth.
    public func cancelDetailPreload() {
        lock.lock()
        let detailTask = activeDetailPreloadTask
        let microTask = activeMicroStageTask
        activeDetailPreloadTask = nil
        activeDetailPreloadKey = nil
        activeMicroStageTask = nil
        activeMicroStageKey = nil
        lock.unlock()
        detailTask?.cancel()
        microTask?.cancel()
    }

    public func cancelMicroStagePreload() {
        lock.lock()
        let microTask = activeMicroStageTask
        activeMicroStageTask = nil
        activeMicroStageKey = nil
        lock.unlock()
        microTask?.cancel()
    }

    /// Computes the minimal aligned tail chunk range covering at least the final ~256-512 KiB of EOF Cues/moov.
    private static func compactTailChunkWindow(totalBytes: Int64, chunkSize: Int64, totalChunks: Int) -> (start: Int, count: Int)? {
        guard totalBytes > chunkSize * 3, totalChunks > 3, chunkSize > 0 else { return nil }
        let lastChunkBytes = totalBytes - Int64(totalChunks - 1) * chunkSize
        let count = (lastChunkBytes < 262_144 && totalChunks >= 4) ? 2 : 1
        return (totalChunks - count, count)
    }

    /// Lightweight micro-stage preloader (`1.5 - 2.5 MiB` total) for hovered/focused episodes and near-end next-episode handoff:
    /// warms `Chunk 0..1` (1 MiB), final `512 KiB` EOF Cues, optional resume/auto-intro-skip anchor (`1 MiB`), and 302 edge route.
    public func startMicroStagePreload(
        assetKey: String,
        streamURL: URL,
        cachedRedirectURL: URL?,
        headers: [String: String],
        knownTotalSize: Int64?,
        durationSeconds: Double,
        startPositionSeconds: Double = 0,
        maxMemoryBytes: Int = 268_435_456,
        onResolvedRedirectURL: (@Sendable (URL) -> Void)? = nil
    ) {
        let signature = "\(assetKey)|micro|\(Int(startPositionSeconds))"
        lock.lock()
        if activeDetailPreloadKey?.hasPrefix("\(assetKey)|") == true {
            lock.unlock()
            return
        }
        if activeMicroStageKey == signature && activeMicroStageTask != nil {
            lock.unlock()
            return
        }
        let prevMicro = activeMicroStageTask
        activeMicroStageTask = nil
        activeMicroStageKey = signature
        lock.unlock()
        prevMicro?.cancel()

        let store = self.store(for: assetKey, maxMemoryBytes: max(64 * 1024 * 1024, maxMemoryBytes), persistDisk: true)
        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                self?.clearMicroStageIfMatching(signature)
            }
            await Self.runSharedRangePreload(
                store: store,
                streamURL: streamURL,
                cachedRedirectURL: cachedRedirectURL,
                headers: headers,
                knownTotalSize: knownTotalSize,
                durationSeconds: durationSeconds,
                resumePositionSeconds: startPositionSeconds,
                preloadSeconds: 0,
                maxMemoryBytes: maxMemoryBytes,
                parallelLanes: 3,
                microStageOnly: true,
                onResolvedRedirectURL: onResolvedRedirectURL
            )
        }

        lock.lock()
        activeMicroStageTask = task
        lock.unlock()
    }

    /// Background detail-page preloader: writes Chunk 0..3, Tail-First EOF Cues, and target playhead duration
    /// directly into the shared TieredAssetChunkStore via warm streaming lanes.
    public func startDetailPreload(
        assetKey: String,
        streamURL: URL,
        cachedRedirectURL: URL?,
        headers: [String: String],
        knownTotalSize: Int64?,
        durationSeconds: Double,
        resumePositionSeconds: Double,
        preloadSeconds: Int,
        maxMemoryBytes: Int = 524_288_000,
        connectionBudget: Int = 3,
        onResolvedRedirectURL: (@Sendable (URL) -> Void)? = nil
    ) {
        let clampedSeconds = max(15, min(300, preloadSeconds))
        let preloadSignature = "\(assetKey)|\(Int(resumePositionSeconds))|\(clampedSeconds)"

        lock.lock()
        if activeDetailPreloadKey == preloadSignature && activeDetailPreloadTask != nil {
            lock.unlock()
            return
        }
        let previous = activeDetailPreloadTask
        activeDetailPreloadTask = nil
        activeDetailPreloadKey = preloadSignature
        lock.unlock()
        previous?.cancel()

        let store = self.store(for: assetKey, maxMemoryBytes: max(64 * 1024 * 1024, maxMemoryBytes), persistDisk: true)
        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }

        let parallelLanes = max(1, min(3, connectionBudget))
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                self?.clearDetailPreloadIfMatching(preloadSignature)
            }
            await Self.runSharedRangePreload(
                store: store,
                streamURL: streamURL,
                cachedRedirectURL: cachedRedirectURL,
                headers: headers,
                knownTotalSize: knownTotalSize,
                durationSeconds: durationSeconds,
                resumePositionSeconds: resumePositionSeconds,
                preloadSeconds: clampedSeconds,
                maxMemoryBytes: maxMemoryBytes,
                parallelLanes: parallelLanes,
                microStageOnly: false,
                onResolvedRedirectURL: onResolvedRedirectURL
            )
        }

        lock.lock()
        activeDetailPreloadTask = task
        lock.unlock()
    }

    private static func runSharedRangePreload(
        store: TieredAssetChunkStore,
        streamURL: URL,
        cachedRedirectURL: URL?,
        headers: [String: String],
        knownTotalSize: Int64?,
        durationSeconds: Double,
        resumePositionSeconds: Double,
        preloadSeconds: Int,
        maxMemoryBytes: Int,
        parallelLanes: Int,
        microStageOnly: Bool,
        onResolvedRedirectURL: (@Sendable (URL) -> Void)?
    ) async {
        let urlStateLock = NSLock()
        var activeURL = cachedRedirectURL ?? streamURL
        var totalSize = max(knownTotalSize ?? 0, store.currentMeta().totalSize)
        let chunkSize = Int64(store.currentMeta().chunkSize)
        guard chunkSize > 0 else { return }

        func currentRoute() -> (url: URL, total: Int64) {
            urlStateLock.lock()
            defer { urlStateLock.unlock() }
            return (activeURL, totalSize)
        }

        func record206Metadata(resp: URLResponse, startByte: Int64, dataCount: Int) {
            var notifiedURL: URL? = nil
            urlStateLock.lock()
            if let finalURL = resp.url, finalURL != activeURL {
                activeURL = finalURL
                notifiedURL = finalURL
            }
            if let http = resp as? HTTPURLResponse,
               let parsedTotal = TurboStreamByteHandle.parseTotalSize(from: http, startByte: startByte, dataCount: dataCount),
               parsedTotal > 0 {
                totalSize = parsedTotal
                urlStateLock.unlock()
                store.setTotalSize(parsedTotal, sourceURL: streamURL.absoluteString)
            } else {
                urlStateLock.unlock()
            }
            if let notifiedURL {
                onResolvedRedirectURL?(notifiedURL)
                TurboStreamingSessionHub.shared.prewarmEdgeOrigin(notifiedURL, laneCount: 4)
            }
        }

        func fetchRange(startByte: Int64, endByte: Int64, laneIndex: Int) async -> (data: Data, status: Int)? {
            guard !Task.isCancelled, endByte >= startByte else { return nil }
            let session = TurboStreamingSessionHub.shared.warmStreamSession(forLane: laneIndex)
            let route = currentRoute()
            let req = TurboStreamingSessionHub.makeRangeRequest(
                url: route.url,
                originHost: streamURL.host,
                headers: headers,
                startByte: startByte,
                endByte: endByte,
                timeout: 12
            )
            do {
                let (data, resp) = try await session.data(for: req)
                guard !Task.isCancelled, let http = resp as? HTTPURLResponse else { return nil }
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if !TurboStreamingSessionHub.isLikelyNonMediaErrorContentType(contentType),
                   http.statusCode == 206 {
                    record206Metadata(resp: resp, startByte: startByte, dataCount: data.count)
                    return (data, 206)
                }
                if route.url != streamURL && (http.statusCode == 403 || http.statusCode == 404 || http.statusCode == 410 || http.statusCode == 200) {
                    urlStateLock.withLock {
                        if activeURL == route.url { activeURL = streamURL }
                    }
                    let retryReq = TurboStreamingSessionHub.makeRangeRequest(
                        url: streamURL,
                        originHost: streamURL.host,
                        headers: headers,
                        startByte: startByte,
                        endByte: endByte,
                        timeout: 12
                    )
                    let (retryData, retryResp) = try await session.data(for: retryReq)
                    guard !Task.isCancelled,
                          let retryHttp = retryResp as? HTTPURLResponse,
                          !TurboStreamingSessionHub.isLikelyNonMediaErrorContentType(retryHttp.value(forHTTPHeaderField: "Content-Type") ?? ""),
                          retryHttp.statusCode == 206 else {
                        return nil
                    }
                    record206Metadata(resp: retryResp, startByte: startByte, dataCount: retryData.count)
                    return (retryData, 206)
                }
                return (Data(), http.statusCode)
            } catch {
                return nil
            }
        }

        func storeAlignedRange(startChunk: Int, chunkCount: Int, batchChunks: Int = 8, laneIndex: Int = 0) async -> Bool {
            var idx = startChunk
            let endExcl = startChunk + chunkCount
            while idx < endExcl {
                if Task.isCancelled { return false }
                let metaNow = store.currentMeta()
                if metaNow.totalChunks > 0 && idx >= metaNow.totalChunks { break }
                if store.hasChunk(idx) {
                    idx += 1
                    continue
                }
                var batchEnd = idx + 1
                let maxBatch = min(endExcl, idx + max(1, batchChunks))
                while batchEnd < maxBatch {
                    if metaNow.totalChunks > 0 && batchEnd >= metaNow.totalChunks { break }
                    if store.hasChunk(batchEnd) { break }
                    batchEnd += 1
                }
                let startByte = Int64(idx) * chunkSize
                var endByte = Int64(batchEnd) * chunkSize - 1
                let curTotal = currentRoute().total
                if curTotal > 0 {
                    endByte = min(endByte, curTotal - 1)
                }
                guard endByte >= startByte else { break }
                guard let res = await fetchRange(startByte: startByte, endByte: endByte, laneIndex: laneIndex),
                      res.status == 206, !res.data.isEmpty else {
                    return false
                }
                var cursor = 0
                var cIdx = idx
                while cursor < res.data.count && cIdx < batchEnd {
                    let expected = store.expectedChunkLength(for: cIdx)
                    let take = expected > 0 ? min(expected, res.data.count - cursor) : min(Int(chunkSize), res.data.count - cursor)
                    if take <= 0 { break }
                    if expected == 0 || take == expected {
                        store.storeChunk(index: cIdx, data: Data(res.data[cursor..<(cursor + take)]))
                    }
                    cursor += take
                    cIdx += 1
                }
                idx = batchEnd
            }
            return true
        }

        let initialHeadChunks = microStageOnly ? 2 : ((resumePositionSeconds <= 2.5) ? 4 : 2)
        let headMissing = (0..<initialHeadChunks).contains(where: { !store.hasChunk($0) })
        if headMissing && (cachedRedirectURL == nil || currentRoute().total <= 0 || parallelLanes <= 1) {
            guard await storeAlignedRange(startChunk: 0, chunkCount: initialHeadChunks, batchChunks: initialHeadChunks, laneIndex: 0) else { return }
        }
        guard !Task.isCancelled else { return }

        let metaAfterHead = store.currentMeta()
        let knownTotalNow = max(currentRoute().total, metaAfterHead.totalSize)
        let tailWindow = Self.compactTailChunkWindow(
            totalBytes: knownTotalNow,
            chunkSize: chunkSize,
            totalChunks: metaAfterHead.totalChunks
        )

        if microStageOnly {
            var anchorStart: Int? = nil
            if resumePositionSeconds > 2.5, knownTotalNow > 0, durationSeconds > 10 {
                let frac = max(0.0, min(0.98, resumePositionSeconds / durationSeconds))
                let estChunk = Int(Int64(frac * Double(knownTotalNow)) / chunkSize)
                if estChunk > 4 {
                    anchorStart = estChunk - 1
                }
            }
            await withTaskGroup(of: Void.self) { group in
                if (0..<initialHeadChunks).contains(where: { !store.hasChunk($0) }) {
                    group.addTask {
                        _ = await storeAlignedRange(startChunk: 0, chunkCount: initialHeadChunks, batchChunks: 2, laneIndex: 0)
                    }
                }
                if let tw = tailWindow, (tw.start..<(tw.start + tw.count)).contains(where: { !store.hasChunk($0) }) {
                    group.addTask {
                        _ = await storeAlignedRange(startChunk: tw.start, chunkCount: tw.count, batchChunks: tw.count, laneIndex: 1)
                    }
                }
                if let anchorStart, (anchorStart..<(anchorStart + 2)).contains(where: { !store.hasChunk($0) }) {
                    group.addTask {
                        _ = await storeAlignedRange(startChunk: anchorStart, chunkCount: 2, batchChunks: 2, laneIndex: 2)
                    }
                }
            }
            return
        }

        let bytesPerSec: Double = (knownTotalNow > 0 && durationSeconds > 10)
            ? (Double(knownTotalNow) / durationSeconds)
            : 2_500_000.0
        let rawTargetBytes = Int64(Double(preloadSeconds) * bytesPerSec)
        let maxBudgetBytes = min(Int64(maxMemoryBytes / 2), 384 * 1024 * 1024)
        let clampedBytes = max(4 * 1024 * 1024, min(maxBudgetBytes, rawTargetBytes))
        let targetChunkCount = max(8, Int((clampedBytes + chunkSize - 1) / chunkSize))

        var playheadChunk = 0
        var preloadChunks = targetChunkCount
        if resumePositionSeconds > 2.5, knownTotalNow > 0, durationSeconds > 10 {
            let frac = max(0.0, min(0.98, resumePositionSeconds / durationSeconds))
            let estByte = Int64(frac * Double(knownTotalNow))
            let estChunk = Int(estByte / chunkSize)
            if estChunk > 4 {
                playheadChunk = estChunk - 4
                preloadChunks = targetChunkCount + 4
            }
        }

        let openingRunwayChunks = min(preloadChunks, 8)
        if parallelLanes >= 2 {
            await withTaskGroup(of: Void.self) { group in
                if (0..<initialHeadChunks).contains(where: { !store.hasChunk($0) }) {
                    group.addTask {
                        _ = await storeAlignedRange(startChunk: 0, chunkCount: initialHeadChunks, batchChunks: 4, laneIndex: 0)
                    }
                }
                if let tw = tailWindow, (tw.start..<(tw.start + tw.count)).contains(where: { !store.hasChunk($0) }) {
                    group.addTask {
                        _ = await storeAlignedRange(startChunk: tw.start, chunkCount: tw.count, batchChunks: tw.count, laneIndex: 1)
                    }
                }
                if playheadChunk >= initialHeadChunks || openingRunwayChunks > initialHeadChunks {
                    let runwayLane = parallelLanes >= 3 ? 2 : 0
                    group.addTask {
                        _ = await storeAlignedRange(startChunk: playheadChunk, chunkCount: openingRunwayChunks, batchChunks: 4, laneIndex: runwayLane)
                    }
                }
            }
        } else if let tw = tailWindow, (tw.start..<(tw.start + tw.count)).contains(where: { !store.hasChunk($0) }) {
            _ = await storeAlignedRange(startChunk: tw.start, chunkCount: tw.count, batchChunks: tw.count, laneIndex: 0)
        }
        guard !Task.isCancelled else { return }

        let ok = await storeAlignedRange(startChunk: playheadChunk, chunkCount: preloadChunks, batchChunks: 8, laneIndex: 0)
        if ok && !Task.isCancelled {
            DonbyLogger.shared.log(
                "详情页预加载完成: 起点 \(String(format: "%.0fs", resumePositionSeconds)), 预读 \(preloadSeconds)s (\(preloadChunks) 分片 / 约 \(clampedBytes / (1024 * 1024)) MB, 起点分片 #\(playheadChunk))",
                level: .info,
                subsystem: "Turbo"
            )
        }
    }
}

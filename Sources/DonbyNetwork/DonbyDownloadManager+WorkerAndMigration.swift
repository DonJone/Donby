import Foundation
import DonbyCore

// MARK: - Download Batch Coordinator, Range Worker & Legacy Migration

private actor DownloadBatchCoordinator {
    enum BatchLease {
        case batch(startChunk: Int, endChunk: Int, requestURL: URL, originHost: String?, usedCDN: Bool, redirectEpoch: UInt64)
        case wait(TimeInterval)
        case done
    }

    private var missingQueue: [Int]
    private var activeWorkerCount: Int = 0
    private var workerCap: Int
    private let maxWorkerCap: Int
    private var batchSizeChunks: Int
    private let maxBatchSizeChunks: Int

    private var originURL: URL
    private let fallbackOriginURL: URL?
    private var didSwitchToFallbackOrigin = false
    private var hasAnyCompletedBatch = false
    private var cachedCDNURL: URL?
    private var redirectEpoch: UInt64 = 0

    private var backoffUntil: TimeInterval = 0
    private var last429StepDownTime: TimeInterval = 0
    private var cleanBatchesSince429: Int = 0
    private var batchHardRetries: [Int: Int] = [:]
    private var batch429Retries: [Int: Int] = [:]
    private var batchCDNResets: [Int: Int] = [:]

    private(set) var failedError: String?

    init(
        missingChunks: [Int],
        initialOriginURL: URL,
        fallbackOriginURL: URL?,
        initialCDNURL: URL?,
        maxWorkerCap: Int,
        totalSize: Int64
    ) {
        self.missingQueue = missingChunks
        self.originURL = initialOriginURL
        self.fallbackOriginURL = (fallbackOriginURL?.absoluteString != initialOriginURL.absoluteString) ? fallbackOriginURL : nil
        self.cachedCDNURL = initialCDNURL
        self.redirectEpoch = initialCDNURL != nil ? 1 : 0
        self.maxWorkerCap = maxWorkerCap
        self.workerCap = maxWorkerCap
        // Larger contiguous ranges (16-24 MiB) amortize 1-2s cross-border TTFB while tail-splitting near EOF.
        if totalSize >= 64 * 1024 * 1024 {
            self.batchSizeChunks = 32
            self.maxBatchSizeChunks = 48
        } else {
            self.batchSizeChunks = 16
            self.maxBatchSizeChunks = 32
        }
    }

    func leaseNextBatch() -> BatchLease {
        if failedError != nil { return .done }
        if missingQueue.isEmpty {
            return activeWorkerCount > 0 ? .wait(0.15) : .done
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now < backoffUntil {
            return .wait(min(1.5, max(0.05, backoffUntil - now)))
        }
        if activeWorkerCount >= workerCap {
            return .wait(0.08)
        }

        // Dynamic tail splitting: when remaining work fits within one round of active workers,
        // divide evenly so all workers finish together without a single-worker tail straggler.
        let remaining = missingQueue.count
        let effectiveBatchLimit: Int
        if remaining < workerCap * batchSizeChunks && workerCap > 1 {
            effectiveBatchLimit = max(4, min(batchSizeChunks, (remaining + workerCap - 1) / workerCap))
        } else {
            effectiveBatchLimit = batchSizeChunks
        }

        let start = missingQueue.removeFirst()
        var end = start
        let limit = min(effectiveBatchLimit, missingQueue.count + 1)
        var taken = 1
        while taken < limit, let peek = missingQueue.first, peek == end + 1 {
            missingQueue.removeFirst()
            end = peek
            taken += 1
        }

        activeWorkerCount += 1
        let useCDN = (cachedCDNURL != nil)
        return .batch(
            startChunk: start,
            endChunk: end,
            requestURL: cachedCDNURL ?? originURL,
            originHost: originURL.host,
            usedCDN: useCDN,
            redirectEpoch: useCDN ? redirectEpoch : 0
        )
    }

    func updateResolvedRedirectURL(_ finalURL: URL?, usedCDN: Bool, epoch: UInt64) {
        guard let finalURL else { return }
        if !usedCDN, finalURL.absoluteString != originURL.absoluteString {
            if cachedCDNURL?.absoluteString != finalURL.absoluteString {
                cachedCDNURL = finalURL
                redirectEpoch &+= 1
            }
        } else if usedCDN, epoch == redirectEpoch, finalURL.absoluteString != cachedCDNURL?.absoluteString {
            cachedCDNURL = finalURL
            redirectEpoch &+= 1
        }
    }

    func finishBatchSuccess() {
        activeWorkerCount = max(0, activeWorkerCount - 1)
        hasAnyCompletedBatch = true
        let now = ProcessInfo.processInfo.systemUptime
        if now >= backoffUntil + 2.0 {
            cleanBatchesSince429 += 1
            if cleanBatchesSince429 >= 3 {
                cleanBatchesSince429 = 0
                if batchSizeChunks < maxBatchSizeChunks {
                    batchSizeChunks = min(maxBatchSizeChunks, batchSizeChunks + 16)
                } else if workerCap < maxWorkerCap {
                    workerCap = min(maxWorkerCap, workerCap + 1)
                }
            }
        }
    }

    private func insertSortedChunks(_ chunks: ClosedRange<Int>) {
        // Keep missingQueue in ascending chunk order so the contiguous head frontier advances first
        // and out-of-order `.chk` spill files remain minimal.
        let unstored = Array(chunks)
        if missingQueue.isEmpty || unstored.last! < missingQueue.first! {
            missingQueue.insert(contentsOf: unstored, at: 0)
            return
        }
        if unstored.first! > missingQueue.last! {
            missingQueue.append(contentsOf: unstored)
            return
        }
        // Binary search insertion point for ascending order
        var lo = 0
        var hi = missingQueue.count
        let target = unstored[0]
        while lo < hi {
            let mid = (lo + hi) / 2
            if missingQueue[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        missingQueue.insert(contentsOf: unstored, at: lo)
    }

    func requeueBatchFailure(
        resumeFromChunk: Int,
        endChunk: Int,
        statusCode: Int,
        usedCDN: Bool,
        epoch: UInt64,
        retryAfterHeader: String?,
        wasStallRecycle: Bool = false
    ) {
        activeWorkerCount = max(0, activeWorkerCount - 1)
        if resumeFromChunk <= endChunk {
            insertSortedChunks(resumeFromChunk...endChunk)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if wasStallRecycle {
            // Transient socket stall/crawl recycled by watchdog; allow immediate retry on fresh socket
            // while bounding retries so permanently dead links still fail cleanly.
            let hardCount = (batchHardRetries[resumeFromChunk] ?? 0) + 1
            batchHardRetries[resumeFromChunk] = hardCount
            if hardCount >= 6, failedError == nil {
                failedError = "分片 #\(resumeFromChunk) 多次下载超时卡顿"
            }
            return
        }

        // If primary /download/ endpoint rejects before any batch succeeded, fall back transparently to /play/ streamURL.
        if !hasAnyCompletedBatch && !didSwitchToFallbackOrigin,
           let fallback = fallbackOriginURL,
           (statusCode == 403 || statusCode == 404 || statusCode == 405 || statusCode == 501) {
            didSwitchToFallbackOrigin = true
            originURL = fallback
            cachedCDNURL = nil
            redirectEpoch &+= 1
            DonbyLogger.shared.log("下载直链返回 HTTP \(statusCode)，自动回退至流媒体源继续下载", level: .warning, subsystem: "Download")
            return
        }

        if statusCode == 429 {
            cleanBatchesSince429 = 0
            let headerDelay = retryAfterHeader.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let r = (batch429Retries[resumeFromChunk] ?? 0) + 1
            batch429Retries[resumeFromChunk] = r
            let waitSec = min(6.0, max(0.8, headerDelay ?? (0.7 * Double(min(r, 6)))))
            backoffUntil = max(backoffUntil, now + waitSec)
            if now >= last429StepDownTime + 1.5 {
                last429StepDownTime = now
                if workerCap > 1 {
                    workerCap = max(1, workerCap - 1)
                    DonbyLogger.shared.log("离线下载触发 HTTP 429 限流，自动降并发至 \(workerCap) 并退避 \(String(format: "%.1fs", waitSec))", level: .warning, subsystem: "Download")
                } else if batchSizeChunks > 8 {
                    batchSizeChunks = max(8, batchSizeChunks / 2)
                }
            }
            if r >= 12, failedError == nil {
                failedError = "分片 #\(resumeFromChunk) 触发服务器持续限流 (429)"
            }
            return
        }

        if usedCDN && (statusCode == 200 || statusCode >= 400) && statusCode != 416 {
            let resets = (batchCDNResets[resumeFromChunk] ?? 0) + 1
            batchCDNResets[resumeFromChunk] = resets
            if epoch == redirectEpoch {
                cachedCDNURL = nil
            }
            if resets <= 3 {
                backoffUntil = max(backoffUntil, now + 0.25 * Double(resets))
                return
            }
        }

        let hardCount = (batchHardRetries[resumeFromChunk] ?? 0) + 1
        batchHardRetries[resumeFromChunk] = hardCount
        if hardCount >= 5 {
            if failedError == nil {
                let codeDesc = statusCode > 0 ? "HTTP \(statusCode)" : "网络错误"
                failedError = "分片 #\(resumeFromChunk) 多次拉取失败 (\(codeDesc))"
            }
        } else {
            backoffUntil = max(backoffUntil, now + min(2.0, 0.35 * Double(hardCount)))
        }
    }
}

extension DonbyDownloadManager {
    private nonisolated static func makeDedicatedWorkerSession(delegate: DownloadRangeStreamDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Dedicated ephemeral session per worker gives independent TCP/TLS flows over HTTP/2 edges,
        // avoiding single-TCP BDP / head-of-line ceilings on high-RTT links.
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 18
        cfg.timeoutIntervalForResource = 180
        let opQueue = OperationQueue()
        opQueue.name = "com.donby.download.worker"
        opQueue.maxConcurrentOperationCount = 2
        opQueue.qualityOfService = .utility
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: opQueue)
    }

    func startDownloadWorker(for entrySnapshot: DownloadEntry, connectionBudget: Int) {
        let assetKey = entrySnapshot.assetKey
        workerTasks[assetKey]?.cancel()

        let task = Task.detached(priority: .utility) {
            let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
            store.setPinned(true)
            defer { store.flushMeta() }

            let primaryURL = URL(string: entrySnapshot.downloadURLString) ?? URL(string: entrySnapshot.streamURLString)
            let fallbackURL = URL(string: entrySnapshot.streamURLString)
            guard let targetURL = primaryURL ?? fallbackURL else {
                await MainActor.run {
                    DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: "无效的下载 URL")
                }
                return
            }

            let workers = max(1, min(6, connectionBudget))
            var originURL = targetURL
            var resolvedCDNURL: URL? = nil
            let headers = entrySnapshot.headers

            // 1. Only run a serial probe when totalSize is unknown; when totalSize is already known
            //    from MediaSource metadata or resume meta.json, launch full multi-TCP workers immediately!
            let probeChunkSize = store.currentMeta().chunkSize
            if store.totalSizeFast() <= 0 {
                let probeCfg = URLSessionConfiguration.ephemeral
                probeCfg.urlCache = nil
                probeCfg.requestCachePolicy = .reloadIgnoringLocalCacheData
                probeCfg.timeoutIntervalForRequest = 18
                let probeSession = URLSession(configuration: probeCfg)
                defer { probeSession.invalidateAndCancel() }

                var probeData: Data?
                var probeResp: HTTPURLResponse?
                for candidate in [targetURL, fallbackURL].compactMap({ $0 }) {
                    if Task.isCancelled { return }
                    let req = TurboStreamingSessionHub.makeRangeRequest(
                        url: candidate,
                        originHost: candidate.host,
                        headers: headers,
                        startByte: 0,
                        endByte: Int64(probeChunkSize - 1),
                        timeout: 18
                    )
                    if let (d, r) = try? await probeSession.data(for: req),
                       let http = r as? HTTPURLResponse,
                       (http.statusCode == 206 || http.statusCode == 200) {
                        originURL = candidate
                        probeData = d
                        probeResp = http
                        break
                    }
                }

                guard let firstData = probeData, let firstHttp = probeResp else {
                    await MainActor.run {
                        DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: "连接下载源失败或无下载权限")
                    }
                    return
                }
                if let finalRespURL = firstHttp.url, finalRespURL.absoluteString != originURL.absoluteString {
                    resolvedCDNURL = finalRespURL
                }
                if let total = TurboStreamByteHandle.parseTotalSize(from: firstHttp, startByte: 0, dataCount: firstData.count), total > 0 {
                    store.setTotalSize(total, sourceURL: originURL.absoluteString)
                }
                let slice = firstData.count > probeChunkSize ? Data(firstData.prefix(probeChunkSize)) : firstData
                store.storeChunk(index: 0, data: slice, cacheInMemory: true)
            }

            let meta = store.currentMeta()
            let totalChunks = meta.totalChunks
            guard totalChunks > 0 else {
                await MainActor.run {
                    DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: "无法解析媒体文件总大小 (需支持 HTTP Range)")
                }
                return
            }

            let missingChunks = (0..<totalChunks).filter { !store.hasChunk($0) }
            if missingChunks.isEmpty {
                store.flushMeta()
                if let destPath = entrySnapshot.localVideoFilePath {
                    let destURL = URL(fileURLWithPath: destPath)
                    Self.materializeAndCleanupIfIdle(store: store, assetKey: assetKey, destinationURL: destURL, expectedSize: meta.totalSize)
                }
                await MainActor.run {
                    DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: meta.totalSize)
                }
                return
            }

            let chunkSize = meta.chunkSize
            let totalSize = meta.totalSize
            let speedMeter = SlidingWindowSpeedMeter(windowDuration: 2.5, bucketDuration: 0.10)
            let byteCounter = LiveDownloadByteCounter(initialCommittedBytes: meta.cachedBytes)
            let coordinator = DownloadBatchCoordinator(
                missingChunks: missingChunks,
                initialOriginURL: originURL,
                fallbackOriginURL: fallbackURL,
                initialCDNURL: resolvedCDNURL,
                maxWorkerCap: workers,
                totalSize: totalSize
            )

            // Decoupled 0.5s progress ticker: keeps UI speed smooth, decays cleanly to 0.0 MB/s during
            // TTFB/stalls/429 backoff, and never blocks TCP packet reception on MainActor.
            let progressTicker = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { break }
                    let liveSpeed = speedMeter.speedMBs()
                    let liveBytes = max(store.cachedBytesFast(), byteCounter.liveBytes(cappedAt: totalSize))
                    await MainActor.run {
                        DonbyDownloadManager.shared.updateProgress(
                            assetKey: assetKey,
                            downloadedBytes: liveBytes,
                            totalBytes: totalSize,
                            speedMBs: liveSpeed
                        )
                    }
                }
            }
            defer { progressTicker.cancel() }

            await withTaskGroup(of: Void.self) { group in
                for workerId in 0..<workers {
                    group.addTask {
                        var streamDelegate = DownloadRangeStreamDelegate()
                        var workerSession = Self.makeDedicatedWorkerSession(delegate: streamDelegate)
                        defer { workerSession.invalidateAndCancel() }

                        func recycleWorkerSession() {
                            workerSession.invalidateAndCancel()
                            streamDelegate = DownloadRangeStreamDelegate()
                            workerSession = Self.makeDedicatedWorkerSession(delegate: streamDelegate)
                        }

                        while !Task.isCancelled {
                            switch await coordinator.leaseNextBatch() {
                            case .done:
                                return
                            case .wait(let delaySec):
                                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                            case .batch(let startChunk, let endChunk, let requestURL, let originHost, let usedCDN, let redirectEpoch):
                                let batchStartByte = Int64(startChunk) * Int64(chunkSize)
                                let batchEndByte = min(totalSize - 1, Int64(endChunk + 1) * Int64(chunkSize) - 1)
                                let req = TurboStreamingSessionHub.makeRangeRequest(
                                    url: requestURL,
                                    originHost: originHost,
                                    headers: headers,
                                    startByte: batchStartByte,
                                    endByte: batchEndByte,
                                    timeout: 18
                                )

                                var currentChunkIdx = startChunk
                                var statusCode = -1
                                var retryAfterHeader: String? = nil
                                let monitor = WorkerTransferMonitor()

                                do {
                                    let (http, byteStream, cancelStream) = try await streamDelegate.openStream(
                                        session: workerSession,
                                        request: req,
                                        allowStatus200: (startChunk == 0 && batchStartByte == 0)
                                    )
                                    statusCode = http.statusCode
                                    retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
                                    monitor.markHeadersReceived()

                                    if statusCode == 206 || (statusCode == 200 && startChunk == 0) {
                                        await coordinator.updateResolvedRedirectURL(http.url, usedCDN: usedCDN, epoch: redirectEpoch)

                                        // Watchdog cancels stalled (>12s silence) or crawling (<150 KB/s while peers healthy) TCP sockets.
                                        let watchdog = Task.detached(priority: .utility) {
                                            while !Task.isCancelled {
                                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                                if Task.isCancelled { break }
                                                let now = ProcessInfo.processInfo.systemUptime
                                                let snap = monitor.snapshot()
                                                let idle = now - snap.lastByteUptime
                                                let transferSec = now - snap.headersUptime
                                                let avgBps = Double(snap.receivedBytes) / max(0.5, transferSec)
                                                let isStalled = idle >= 12.0
                                                let isCrawling = (workers > 1 && transferSec >= 10.0 && avgBps < 150_000.0 && speedMeter.speedMBs(at: now) >= 2.0)
                                                if isStalled || isCrawling {
                                                    monitor.markStallCancelled()
                                                    cancelStream()
                                                    break
                                                }
                                            }
                                        }
                                        defer { watchdog.cancel() }

                                        var acc = Data()
                                        acc.reserveCapacity(chunkSize * 2)
                                        var readCursor = 0

                                        func flushReadyChunks() {
                                            while currentChunkIdx <= endChunk {
                                                let expectedLen = min(
                                                    chunkSize,
                                                    Int(max(0, totalSize - Int64(currentChunkIdx) * Int64(chunkSize)))
                                                )
                                                guard acc.count - readCursor >= expectedLen else { break }
                                                let endPos = readCursor + expectedLen
                                                let keepInRam = (store.activeReaderCount > 0 || currentChunkIdx < 4)
                                                store.storeChunk(index: currentChunkIdx, data: Data(acc[readCursor..<endPos]), cacheInMemory: keepInRam)
                                                byteCounter.commitChunk(workerId: workerId, bytes: expectedLen)
                                                readCursor = endPos
                                                currentChunkIdx += 1
                                            }
                                        }

                                        for try await netSlice in byteStream {
                                            if Task.isCancelled { break }
                                            acc.append(netSlice)
                                            let now = ProcessInfo.processInfo.systemUptime
                                            monitor.recordBytes(netSlice.count, at: now)
                                            speedMeter.recordBytes(netSlice.count, at: now)
                                            byteCounter.addInFlight(workerId: workerId, delta: netSlice.count)

                                            flushReadyChunks()
                                            if readCursor >= chunkSize {
                                                acc.removeSubrange(0..<readCursor)
                                                readCursor = 0
                                            }
                                        }

                                        watchdog.cancel()
                                        byteCounter.clearWorkerInFlight(workerId: workerId)

                                        if Task.isCancelled {
                                            await coordinator.requeueBatchFailure(
                                                resumeFromChunk: currentChunkIdx,
                                                endChunk: endChunk,
                                                statusCode: -1,
                                                usedCDN: usedCDN,
                                                epoch: redirectEpoch,
                                                retryAfterHeader: nil
                                            )
                                            return
                                        }

                                        flushReadyChunks()
                                        if currentChunkIdx > endChunk {
                                            await coordinator.finishBatchSuccess()
                                        } else {
                                            let recycled = monitor.wasStallCancelled
                                            if recycled { recycleWorkerSession() }
                                            await coordinator.requeueBatchFailure(
                                                resumeFromChunk: currentChunkIdx,
                                                endChunk: endChunk,
                                                statusCode: statusCode,
                                                usedCDN: usedCDN,
                                                epoch: redirectEpoch,
                                                retryAfterHeader: retryAfterHeader,
                                                wasStallRecycle: recycled
                                            )
                                        }
                                    } else {
                                        byteCounter.clearWorkerInFlight(workerId: workerId)
                                        await coordinator.requeueBatchFailure(
                                            resumeFromChunk: currentChunkIdx,
                                            endChunk: endChunk,
                                            statusCode: statusCode,
                                            usedCDN: usedCDN,
                                            epoch: redirectEpoch,
                                            retryAfterHeader: retryAfterHeader
                                        )
                                    }
                                } catch {
                                    byteCounter.clearWorkerInFlight(workerId: workerId)
                                    if Task.isCancelled { return }
                                    let recycled = monitor.wasStallCancelled
                                    if recycled { recycleWorkerSession() }
                                    await coordinator.requeueBatchFailure(
                                        resumeFromChunk: currentChunkIdx,
                                        endChunk: endChunk,
                                        statusCode: statusCode,
                                        usedCDN: usedCDN,
                                        epoch: redirectEpoch,
                                        retryAfterHeader: retryAfterHeader,
                                        wasStallRecycle: recycled
                                    )
                                }
                            }
                        }
                    }
                }
            }

            progressTicker.cancel()
            if Task.isCancelled { return }
            store.flushMeta()
            if let err = await coordinator.failedError {
                await MainActor.run {
                    DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: err)
                }
            } else if store.currentMeta().isFullyCached {
                let finalTotal = store.currentMeta().totalSize
                if let destPath = entrySnapshot.localVideoFilePath {
                    let destURL = URL(fileURLWithPath: destPath)
                    Self.materializeAndCleanupIfIdle(store: store, assetKey: assetKey, destinationURL: destURL, expectedSize: finalTotal)
                }
                await MainActor.run {
                    DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: finalTotal)
                }
            }
        }
        workerTasks[assetKey] = task
    }

    /// Migrates previously completed downloads from cache bins (`ChunkStore`) or legacy split folders
    /// into the unified `~/Movies/Donby` hierarchy along with artwork, subtitles, and metadata sidecars.
    public func migrateLegacyCompletedDownloads(servers: [EmbyServerConfig]) async {
        DonbyOfflineLibraryStorage.ensureRootDirectories()
        let fm = FileManager.default
        var didMutate = false

        let snapshotEntries = entries
        for entry in snapshotEntries where entry.status == .completed {
            let server = servers.first(where: { $0.id == entry.serverId })
            let fallbackServer = server ?? EmbyServerConfig(
                id: entry.serverId,
                name: entry.serverName,
                host: "",
                username: ""
            )

            var resolvedSeries: EmbyItem? = nil
            if entry.itemSnapshot.isEpisode, let sid = entry.itemSnapshot.seriesId, !sid.isEmpty {
                if let existingSeriesFolder = entry.localSeriesFolderPath {
                    let sMeta = URL(fileURLWithPath: existingSeriesFolder).appendingPathComponent("donby.series.json")
                    if let d = try? Data(contentsOf: sMeta),
                       let decoded = try? JSONDecoder().decode(OfflineSeriesSidecar.self, from: d) {
                        resolvedSeries = decoded.seriesItem
                    }
                }
                if resolvedSeries == nil, let server {
                    if let extProvider = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                        resolvedSeries = try? await extProvider.fetchItemDetail(
                            server: server,
                            item: EmbyItem(
                                id: sid,
                                name: entry.itemSnapshot.seriesName ?? "",
                                type: "Series",
                                uhdMediaType: "tv"
                            )
                        )
                    } else if !(server.type == .uhdNative && DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)) {
                        resolvedSeries = try? await EmbyClient.shared.fetchItemDetail(server: server, itemId: sid)
                    }
                }
            }

            let streamURL = URL(string: entry.streamURLString)
                ?? URL(fileURLWithPath: entry.localVideoFilePath ?? "/tmp/video.mkv")
            let layout = DonbyOfflineLibraryStorage.makeLayoutPaths(
                item: entry.itemSnapshot,
                seriesItem: resolvedSeries,
                mediaSource: entry.mediaSourceSnapshot,
                streamURL: streamURL
            )

            var hasVideoOnDisk = fm.fileExists(atPath: layout.videoFileURL.path)

            if !hasVideoOnDisk, let oldPath = entry.localVideoFilePath, fm.fileExists(atPath: oldPath) {
                let oldVideoURL = URL(fileURLWithPath: oldPath)
                let oldItemDir = oldVideoURL.deletingLastPathComponent()
                if oldVideoURL.standardizedFileURL.path != layout.videoFileURL.standardizedFileURL.path {
                    try? fm.createDirectory(at: layout.itemFolderURL, withIntermediateDirectories: true)
                    if let seriesDir = layout.seriesFolderURL {
                        try? fm.createDirectory(at: seriesDir, withIntermediateDirectories: true)
                    }
                    if (try? fm.moveItem(at: oldVideoURL, to: layout.videoFileURL)) != nil {
                        hasVideoOnDisk = true
                        didMutate = true
                    }
                    if let oldFiles = try? fm.contentsOfDirectory(at: oldItemDir, includingPropertiesForKeys: nil) {
                        for srcFile in oldFiles {
                            let dstFile = layout.itemFolderURL.appendingPathComponent(srcFile.lastPathComponent)
                            if !fm.fileExists(atPath: dstFile.path) {
                                try? fm.moveItem(at: srcFile, to: dstFile)
                            }
                        }
                    }
                    if let oldSeriesPath = entry.localSeriesFolderPath,
                       let newSeriesDir = layout.seriesFolderURL {
                        let oldSeriesURL = URL(fileURLWithPath: oldSeriesPath)
                        if oldSeriesURL.standardizedFileURL.path != newSeriesDir.standardizedFileURL.path {
                            for name in ["poster.jpg", "backdrop.jpg", "clearlogo.png", "donby.series.json"] {
                                let src = oldSeriesURL.appendingPathComponent(name)
                                let dst = newSeriesDir.appendingPathComponent(name)
                                if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                                    try? fm.moveItem(at: src, to: dst)
                                }
                            }
                            if let rem = try? fm.contentsOfDirectory(atPath: oldItemDir.path),
                               rem.filter({ $0 != ".DS_Store" }).isEmpty {
                                try? fm.removeItem(at: oldItemDir)
                            }
                            if let remSeries = try? fm.contentsOfDirectory(atPath: oldSeriesURL.path),
                               remSeries.filter({ $0 != ".DS_Store" }).isEmpty {
                                try? fm.removeItem(at: oldSeriesURL)
                            }
                        }
                    } else if let rem = try? fm.contentsOfDirectory(atPath: oldItemDir.path),
                              rem.filter({ $0 != ".DS_Store" }).isEmpty {
                        try? fm.removeItem(at: oldItemDir)
                    }
                }
            }

            if !hasVideoOnDisk {
                let store = DonbyTurboCacheEngine.shared.store(for: entry.assetKey, persistDisk: true)
                let meta = store.currentMeta()
                let isCompleteInStore = meta.isFullyCached ||
                    (entry.totalBytes > 0 && entry.downloadedBytes >= entry.totalBytes && fm.fileExists(atPath: store.dataFileURL.path))
                if isCompleteInStore && fm.fileExists(atPath: store.dataFileURL.path) {
                    let expectedSize = max(meta.totalSize, entry.totalBytes)
                    try? fm.createDirectory(at: layout.itemFolderURL, withIntermediateDirectories: true)
                    if let seriesDir = layout.seriesFolderURL {
                        try? fm.createDirectory(at: seriesDir, withIntermediateDirectories: true)
                    }
                    let legacySubDir = store.assetDirectory.appendingPathComponent("subtitles", isDirectory: true)
                    if let subFiles = try? fm.contentsOfDirectory(at: legacySubDir, includingPropertiesForKeys: nil) {
                        for srcSub in subFiles {
                            let dstSub = layout.itemFolderURL.appendingPathComponent(srcSub.lastPathComponent)
                            if !fm.fileExists(atPath: dstSub.path) {
                                try? fm.moveItem(at: srcSub, to: dstSub)
                            }
                        }
                    }
                    if Self.materializeAndCleanupIfIdle(store: store, assetKey: entry.assetKey, destinationURL: layout.videoFileURL, expectedSize: expectedSize) {
                        hasVideoOnDisk = true
                        didMutate = true
                    }
                }
            }

            guard hasVideoOnDisk else { continue }

            let needsPathUpdate = entry.localVideoFilePath != layout.videoFileURL.path ||
                entry.localFolderPath != layout.itemFolderURL.path ||
                entry.localSeriesFolderPath != layout.seriesFolderURL?.path ||
                entry.localPosterPath != layout.primaryPosterFileURL.path
            let needsMetadataOrArtwork = !fm.fileExists(atPath: layout.metadataFileURL.path) ||
                !fm.fileExists(atPath: layout.primaryPosterFileURL.path) ||
                (layout.seriesMetadataFileURL.map { !fm.fileExists(atPath: $0.path) } ?? false)

            if needsPathUpdate, let idx = entries.firstIndex(where: { $0.assetKey == entry.assetKey }) {
                entries[idx].applyLayoutPaths(layout)
                didMutate = true
            }

            if needsMetadataOrArtwork {
                let targetItem = entry.itemSnapshot
                let itemPoster: URL?
                let itemBackdrop: URL?
                let itemThumb: URL?
                let itemLogo: URL?
                let seasonPoster: URL?
                let seriesPoster: URL?
                let seriesBackdrop: URL?
                let seriesLogo: URL?

                if let server {
                    let isUHD = (server.type == .uhdNative && DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative))
                    let p = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .primary, maxWidth: 800)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .primary, maxWidth: 800))
                        ?? entry.posterURLString.flatMap { URL(string: $0) }
                    itemPoster = p
                    itemBackdrop = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .backdrop, maxWidth: 1920)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .backdrop, maxWidth: 1920))
                    itemThumb = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .thumb, maxWidth: 800)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .thumb, maxWidth: 800))
                    itemLogo = EmbyClient.shared.imageURL(server: server, item: targetItem, kind: .logo, maxWidth: 800)
                        ?? (isUHD ? nil : EmbyClient.shared.imageURL(server: server, itemId: targetItem.id, kind: .logo, maxWidth: 800))
                    seasonPoster = isUHD ? nil : targetItem.seasonId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 600) }

                    seriesPoster = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .primary, maxWidth: 800) }
                        ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .primary, maxWidth: 800) })
                        ?? p
                    seriesBackdrop = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .backdrop, maxWidth: 1920) }
                        ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .backdrop, maxWidth: 1920) })
                    seriesLogo = resolvedSeries.flatMap { EmbyClient.shared.imageURL(server: server, item: $0, kind: .logo, maxWidth: 800) }
                        ?? (isUHD ? nil : targetItem.seriesId.flatMap { EmbyClient.shared.imageURL(server: server, itemId: $0, kind: .logo, maxWidth: 800) })
                } else {
                    let p = entry.posterURLString.flatMap { URL(string: $0) }
                    itemPoster = p
                    itemBackdrop = targetItem.uhdBackdropURL.flatMap { URL(string: $0) }
                    itemThumb = targetItem.uhdThumbURL.flatMap { URL(string: $0) }
                    itemLogo = targetItem.uhdLogoURL.flatMap { URL(string: $0) }
                    seasonPoster = nil
                    seriesPoster = resolvedSeries?.uhdPosterURL.flatMap { URL(string: $0) } ?? p
                    seriesBackdrop = resolvedSeries?.uhdBackdropURL.flatMap { URL(string: $0) }
                    seriesLogo = resolvedSeries?.uhdLogoURL.flatMap { URL(string: $0) }
                }

                await downloadMetadataAndArtwork(
                    assetKey: entry.assetKey,
                    server: fallbackServer,
                    item: targetItem,
                    seriesItem: resolvedSeries,
                    mediaSource: entry.mediaSourceSnapshot,
                    layout: layout,
                    headers: entry.headers,
                    itemArtworkURLs: (poster: itemPoster, backdrop: itemBackdrop, thumb: itemThumb, logo: itemLogo, seasonPoster: seasonPoster),
                    seriesArtworkURLs: (poster: seriesPoster, backdrop: seriesBackdrop, logo: seriesLogo)
                )
                didMutate = true
            }
        }

        DonbyOfflineLibraryStorage.ensureRootDirectories()
        if didMutate {
            saveToDisk()
        }
    }
}

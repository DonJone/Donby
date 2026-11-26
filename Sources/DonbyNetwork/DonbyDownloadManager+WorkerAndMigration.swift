import Foundation
import DonbyCore

// MARK: - Download Batch Coordinator, Range Worker & Legacy Migration

private final class ActiveWorkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Int = 0

    func increment() {
        lock.lock(); active += 1; lock.unlock()
    }

    func decrement() {
        lock.lock(); active = max(0, active - 1); lock.unlock()
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }; return active
    }
}

private actor DownloadBatchCoordinator {
    enum BatchLease {
        case batch(startChunk: Int, bound: ActiveSegmentBound, requestURL: URL, originHost: String?, usedCDN: Bool, redirectEpoch: UInt64)
        case wait(TimeInterval)
        case done
    }

    private var missingQueue: [Int]
    private var activeWorkerCount: Int = 0
    private var activeBounds: [Int: ActiveSegmentBound] = [:]
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
    private var routeSettled: Bool
    private var routeProbeWorkerId: Int? = nil
    private let routeProbeStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var consecutiveCDNStalls: Int = 0

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
        self.routeSettled = (initialCDNURL != nil || maxWorkerCap <= 1)
        self.maxWorkerCap = maxWorkerCap
        self.workerCap = maxWorkerCap
        // Large continuous segments (64-128 MiB) keep TCP cwnd and origin prefetch pipelines warm
        // while dynamic work-stealing eliminates tail stragglers near EOF.
        if totalSize >= 128 * 1024 * 1024 {
            self.batchSizeChunks = 128   // 64 MiB
            self.maxBatchSizeChunks = 256 // 128 MiB
        } else if totalSize >= 16 * 1024 * 1024 {
            self.batchSizeChunks = 32    // 16 MiB
            self.maxBatchSizeChunks = 64 // 32 MiB
        } else {
            self.batchSizeChunks = 16
            self.maxBatchSizeChunks = 32
        }
    }

    func leaseNextBatch(forWorker workerId: Int) -> BatchLease {
        if failedError != nil { return .done }
        let now = ProcessInfo.processInfo.systemUptime
        if now < backoffUntil {
            return .wait(min(1.5, max(0.05, backoffUntil - now)))
        }
        // Let Worker 0 resolve the 302 CDN redirect (or /download -> /play fallback) once before
        // fanning out all sibling TCP workers, avoiding a 6-worker origin 302 burst & 429 storm.
        if !routeSettled {
            if routeProbeWorkerId == nil {
                routeProbeWorkerId = workerId
            } else if routeProbeWorkerId != workerId {
                if (now - routeProbeStartUptime) < 1.5 {
                    return .wait(0.06)
                }
                routeSettled = true
            }
        }
        if activeWorkerCount >= workerCap {
            return .wait(0.08)
        }

        if missingQueue.isEmpty {
            // Dynamic work-stealing: if peers still hold a large active segment, steal its back half.
            if activeWorkerCount > 0, let stolen = stealLargestActiveTail() {
                let bound = ActiveSegmentBound(startChunk: stolen.lowerBound, endChunk: stolen.upperBound)
                activeBounds[workerId] = bound
                activeWorkerCount += 1
                let useCDN = (cachedCDNURL != nil)
                return .batch(
                    startChunk: stolen.lowerBound,
                    bound: bound,
                    requestURL: cachedCDNURL ?? originURL,
                    originHost: originURL.host,
                    usedCDN: useCDN,
                    redirectEpoch: useCDN ? redirectEpoch : 0
                )
            }
            return activeWorkerCount > 0 ? .wait(0.15) : .done
        }

        // Dynamic tail splitting: when remaining work fits within one round of active workers,
        // divide evenly so all workers finish together without stragglers.
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

        let bound = ActiveSegmentBound(startChunk: start, endChunk: end)
        activeBounds[workerId] = bound
        activeWorkerCount += 1
        let useCDN = (cachedCDNURL != nil)
        return .batch(
            startChunk: start,
            bound: bound,
            requestURL: cachedCDNURL ?? originURL,
            originHost: originURL.host,
            usedCDN: useCDN,
            redirectEpoch: useCDN ? redirectEpoch : 0
        )
    }

    private func stealLargestActiveTail() -> ClosedRange<Int>? {
        let sorted = activeBounds.values.sorted { $0.remainingChunks() > $1.remainingChunks() }
        for peerBound in sorted {
            if let stolen = peerBound.tryStealTail(minRemaining: 6) { return stolen }
        }
        return nil
    }

    func markRouteSettled() {
        routeSettled = true
    }

    func updateResolvedRedirectURL(_ finalURL: URL?, usedCDN: Bool, epoch: UInt64) {
        guard let finalURL else { return }
        if !usedCDN, finalURL.absoluteString != originURL.absoluteString {
            if cachedCDNURL?.absoluteString != finalURL.absoluteString {
                cachedCDNURL = finalURL
                redirectEpoch &+= 1
                consecutiveCDNStalls = 0
            }
            routeSettled = true
        } else if usedCDN, epoch == redirectEpoch, finalURL.absoluteString != cachedCDNURL?.absoluteString {
            cachedCDNURL = finalURL
            redirectEpoch &+= 1
            consecutiveCDNStalls = 0
            routeSettled = true
        }
    }

    func finishBatchSuccess(workerId: Int) {
        activeBounds.removeValue(forKey: workerId)
        activeWorkerCount = max(0, activeWorkerCount - 1)
        hasAnyCompletedBatch = true
        routeSettled = true
        consecutiveCDNStalls = 0
        let now = ProcessInfo.processInfo.systemUptime
        if now >= backoffUntil + 2.0 {
            cleanBatchesSince429 += 1
            if cleanBatchesSince429 >= 2 {
                cleanBatchesSince429 = 0
                if batchSizeChunks < maxBatchSizeChunks {
                    batchSizeChunks = min(maxBatchSizeChunks, batchSizeChunks * 2)
                } else if workerCap < maxWorkerCap {
                    workerCap = min(maxWorkerCap, workerCap + 1)
                }
            }
        }
    }

    private func insertSortedChunks(_ chunks: ClosedRange<Int>) {
        let unstored = Array(chunks)
        if missingQueue.isEmpty || unstored.last! < missingQueue.first! {
            missingQueue.insert(contentsOf: unstored, at: 0)
            return
        }
        if unstored.first! > missingQueue.last! {
            missingQueue.append(contentsOf: unstored)
            return
        }
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
        workerId: Int,
        startChunk: Int,
        resumeFromChunk: Int,
        endChunk: Int,
        statusCode: Int,
        usedCDN: Bool,
        epoch: UInt64,
        retryAfterHeader: String?,
        wasStallRecycle: Bool = false
    ) {
        activeBounds.removeValue(forKey: workerId)
        activeWorkerCount = max(0, activeWorkerCount - 1)
        if resumeFromChunk <= endChunk {
            insertSortedChunks(resumeFromChunk...endChunk)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let madeForwardProgress = resumeFromChunk > startChunk
        if wasStallRecycle {
            if usedCDN {
                consecutiveCDNStalls += 1
                // Escape a degraded CDN edge node after repeated stall recycles by re-resolving origin 302.
                if consecutiveCDNStalls >= 2 && epoch == redirectEpoch {
                    cachedCDNURL = nil
                    consecutiveCDNStalls = 0
                    routeSettled = false
                    routeProbeWorkerId = nil
                }
            }
            if !madeForwardProgress {
                let hardCount = (batchHardRetries[resumeFromChunk] ?? 0) + 1
                batchHardRetries[resumeFromChunk] = hardCount
                if hardCount >= 8, failedError == nil {
                    failedError = "分片 #\(resumeFromChunk) 多次下载超时卡顿"
                }
            }
            return
        }

        if !hasAnyCompletedBatch && !didSwitchToFallbackOrigin,
           let fallback = fallbackOriginURL,
           (statusCode == 403 || statusCode == 404 || statusCode == 405 || statusCode == 501) {
            didSwitchToFallbackOrigin = true
            originURL = fallback
            cachedCDNURL = nil
            redirectEpoch &+= 1
            routeSettled = false
            routeProbeWorkerId = nil
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
                } else if batchSizeChunks > 16 {
                    batchSizeChunks = max(16, batchSizeChunks / 2)
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
            if epoch == redirectEpoch { cachedCDNURL = nil }
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
        // and serial delegateQueue (maxConcurrentOperationCount = 1) guarantees strict TCP byte order.
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 14
        cfg.timeoutIntervalForResource = 600
        let opQueue = OperationQueue()
        opQueue.name = "com.donby.download.worker"
        opQueue.maxConcurrentOperationCount = 1
        opQueue.qualityOfService = .userInitiated
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: opQueue)
    }

    func startDownloadWorker(for entrySnapshot: DownloadEntry, connectionBudget: Int) {
        let assetKey = entrySnapshot.assetKey
        workerTasks[assetKey]?.cancel()

        let task = Task.detached(priority: .userInitiated) {
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

            let workers = max(1, min(8, connectionBudget))
            var originURL = targetURL
            var resolvedCDNURL: URL? = nil
            let headers = entrySnapshot.headers

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
            let activeCounter = ActiveWorkerCounter()
            let coordinator = DownloadBatchCoordinator(
                missingChunks: missingChunks,
                initialOriginURL: originURL,
                fallbackOriginURL: fallbackURL,
                initialCDNURL: resolvedCDNURL,
                maxWorkerCap: workers,
                totalSize: totalSize
            )

            let progressTicker = Task.detached(priority: .userInitiated) {
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
                            switch await coordinator.leaseNextBatch(forWorker: workerId) {
                            case .done:
                                return
                            case .wait(let delaySec):
                                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                            case .batch(let startChunk, let bound, let requestURL, let originHost, let usedCDN, let redirectEpoch):
                                let initialEnd = bound.currentEnd()
                                let batchStartByte = Int64(startChunk) * Int64(chunkSize)
                                let batchEndByte = min(totalSize - 1, Int64(initialEnd + 1) * Int64(chunkSize) - 1)
                                let req = TurboStreamingSessionHub.makeRangeRequest(
                                    url: requestURL,
                                    originHost: originHost,
                                    headers: headers,
                                    startByte: batchStartByte,
                                    endByte: batchEndByte,
                                    timeout: 12
                                )

                                var currentChunkIdx = startChunk
                                var statusCode = -1
                                var retryAfterHeader: String? = nil
                                let monitor = WorkerTransferMonitor()

                                do {
                                    let (http, byteStream, cancelStream) = try await streamDelegate.openStream(
                                        session: workerSession,
                                        request: req,
                                        allowStatus200: (startChunk == 0 && batchStartByte == 0),
                                        onRedirectResolved: { finalURL in
                                            Task {
                                                await coordinator.updateResolvedRedirectURL(finalURL, usedCDN: usedCDN, epoch: redirectEpoch)
                                            }
                                        }
                                    )
                                    statusCode = http.statusCode
                                    retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
                                    monitor.markHeadersReceived()

                                    if statusCode == 206 || (statusCode == 200 && startChunk == 0) {
                                        await coordinator.updateResolvedRedirectURL(http.url, usedCDN: usedCDN, epoch: redirectEpoch)
                                        await coordinator.markRouteSettled()
                                        activeCounter.increment()
                                        defer { activeCounter.decrement() }

                                        // Watchdog cancels stalled (>8s silence) or peer-relative crawling TCP sockets.
                                        let watchdog = Task.detached(priority: .userInitiated) {
                                            while !Task.isCancelled {
                                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                                if Task.isCancelled { break }
                                                let now = ProcessInfo.processInfo.systemUptime
                                                let snap = monitor.snapshot()
                                                let idle = now - snap.lastByteUptime
                                                let transferSec = now - snap.headersUptime
                                                let isStalled = idle >= 8.0
                                                var isCrawling = false
                                                let livePeers = activeCounter.count()
                                                if workers > 1 && livePeers > 1 && transferSec >= 6.0 {
                                                    let workerBps = monitor.recentBytesPerSecond(at: now)
                                                    let aggBps = speedMeter.speedMBs(at: now) * 1_048_576.0
                                                    let peerAvgBps = max(0.0, (aggBps - workerBps) / Double(livePeers - 1))
                                                    let relativeCrawl = (peerAvgBps >= 600_000.0 && workerBps < max(250_000.0, peerAvgBps * 0.28))
                                                    let stragglerCrawl = (transferSec >= 9.0 && aggBps >= 800_000.0 && speedMeter.peakSpeedMBs() >= 1.5 && workerBps < 180_000.0)
                                                    isCrawling = relativeCrawl || stragglerCrawl
                                                }
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
                                        var hitDynamicBound = false

                                        func flushReadyChunks() {
                                            while currentChunkIdx <= bound.currentEnd() {
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
                                                bound.advanceCurrent(to: currentChunkIdx)
                                            }
                                            if currentChunkIdx > bound.currentEnd() {
                                                hitDynamicBound = true
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
                                            if hitDynamicBound {
                                                cancelStream()
                                                break
                                            }
                                            if readCursor >= chunkSize {
                                                acc.removeSubrange(0..<readCursor)
                                                readCursor = 0
                                            }
                                        }

                                        watchdog.cancel()
                                        byteCounter.clearWorkerInFlight(workerId: workerId)

                                        if Task.isCancelled {
                                            await coordinator.requeueBatchFailure(workerId: workerId, startChunk: startChunk, resumeFromChunk: currentChunkIdx, endChunk: bound.currentEnd(), statusCode: -1, usedCDN: usedCDN, epoch: redirectEpoch, retryAfterHeader: nil)
                                            return
                                        }

                                        flushReadyChunks()
                                        if currentChunkIdx > bound.currentEnd() {
                                            await coordinator.finishBatchSuccess(workerId: workerId)
                                        } else {
                                            let recycled = monitor.wasStallCancelled
                                            if recycled { recycleWorkerSession() }
                                            await coordinator.requeueBatchFailure(workerId: workerId, startChunk: startChunk, resumeFromChunk: currentChunkIdx, endChunk: bound.currentEnd(), statusCode: statusCode, usedCDN: usedCDN, epoch: redirectEpoch, retryAfterHeader: retryAfterHeader, wasStallRecycle: recycled)
                                        }
                                    } else {
                                        byteCounter.clearWorkerInFlight(workerId: workerId)
                                        await coordinator.requeueBatchFailure(workerId: workerId, startChunk: startChunk, resumeFromChunk: currentChunkIdx, endChunk: bound.currentEnd(), statusCode: statusCode, usedCDN: usedCDN, epoch: redirectEpoch, retryAfterHeader: retryAfterHeader)
                                    }
                                } catch {
                                    byteCounter.clearWorkerInFlight(workerId: workerId)
                                    if Task.isCancelled { return }
                                    if currentChunkIdx > bound.currentEnd() {
                                        await coordinator.finishBatchSuccess(workerId: workerId)
                                        continue
                                    }
                                    let recycled = monitor.wasStallCancelled || statusCode <= 0
                                    if recycled { recycleWorkerSession() }
                                    await coordinator.requeueBatchFailure(workerId: workerId, startChunk: startChunk, resumeFromChunk: currentChunkIdx, endChunk: bound.currentEnd(), statusCode: statusCode, usedCDN: usedCDN, epoch: redirectEpoch, retryAfterHeader: retryAfterHeader, wasStallRecycle: monitor.wasStallCancelled)
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
}

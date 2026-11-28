import Foundation
import DonbyCore
import DonbyKernelC

// MARK: - TurboStreamByteHandle Attempt Completion, 429 Recovery & Header Size Parsing

extension TurboStreamByteHandle {
    func commitCompletedChunkSliceLocked(
        chunkIndex: Int,
        skip: Int,
        storeChunkSize: Int,
        data: Data,
        attemptId: UInt64,
        now: TimeInterval
    ) {
        if skip == 0 {
            store.storeChunk(index: chunkIndex, data: data)
        } else {
            let sliceStartOffset = Int64(chunkIndex) * Int64(storeChunkSize) + Int64(skip)
            appendDirectSliceLocked(startOffset: sliceStartOffset, data: data)
        }
        inFlightChunks.remove(chunkIndex)
        rescueChunks.remove(chunkIndex)
        chunkStartTime.removeValue(forKey: chunkIndex)
        chunkFirstBlockedUptime.removeValue(forKey: chunkIndex)
        chunkNextRetryTime.removeValue(forKey: chunkIndex)
        chunk429Retries.removeValue(forKey: chunkIndex)
        failedCount.removeValue(forKey: chunkIndex)
        if activeDisplayAttempt[chunkIndex] == attemptId {
            activeDisplayAttempt.removeValue(forKey: chunkIndex)
        }
        if chunkIndex == 0 {
            chunk0HeadersReceived = true
        }
        recordCleanCompletionAndRecoverConcurrencyLocked(now: now)
    }

    func cancelCompetingAttemptsLocked(
        forChunk curIdx: Int,
        winnerAttemptId: UInt64,
        winnerIsRescue: Bool,
        now: TimeInterval,
        competingTasksToCancel: inout [URLSessionDataTask]
    ) {
        let competingIds = activeAttempts.values
            .filter { other in
                guard other.attemptId != winnerAttemptId && other.currentChunkIndex == curIdx else { return false }
                // Whenever a rescue attempt beats an existing attempt on `curIdx`, cancel the slower
                // original attempt immediately so its remaining span releases back to healthy lanes.
                if other.isRescue || winnerIsRescue || other.endChunkExclusive == curIdx + 1 { return true }
                return false
            }
            .map(\.attemptId)
        for cid in competingIds {
            if let cRec = activeAttempts.removeValue(forKey: cid) {
                if let t = cRec.task { competingTasksToCancel.append(t) }
                if cRec.currentChunkIndex >= 0 {
                    for relIdx in cRec.currentChunkIndex..<cRec.endChunkExclusive {
                        if activeDisplayAttempt[relIdx] == cid {
                            activeDisplayAttempt.removeValue(forKey: relIdx)
                        }
                        if !activeAttempts.values.contains(where: { $0.covers(relIdx) }) {
                            inFlightChunks.remove(relIdx)
                            rescueChunks.remove(relIdx)
                            chunkStartTime.removeValue(forKey: relIdx)
                        }
                    }
                }
            }
            attemptBuffers.removeValue(forKey: cid)
            if let rawBridge { dk_net_bridge_remove_attempt(rawBridge, cid) }
        }
    }

    func handleRateLimit429Locked(now: TimeInterval) {
        cleanSuccessesSinceLast429 = 0
        last429BackoffUntil = max(last429BackoffUntil, now + 0.9)
        if now >= last429StepDownUptime + 1.5 {
            last429StepDownUptime = now
            if dynamicConcurrencyCap > 1 {
                dynamicConcurrencyCap = max(1, dynamicConcurrencyCap - 1)
                DonbyLogger.shared.log("Turbo 分片引擎检测到 HTTP 429 限流，自动降并发至 \(dynamicConcurrencyCap) 并退避", level: .warning, subsystem: "TurboCache")
            }
        }
    }

    func recordCleanCompletionAndRecoverConcurrencyLocked(now: TimeInterval) {
        guard dynamicConcurrencyCap < configuredConcurrencyBudget else { return }
        guard now >= last429BackoffUntil + 2.5 else { return }
        cleanSuccessesSinceLast429 += 1
        if cleanSuccessesSinceLast429 >= 8 {
            cleanSuccessesSinceLast429 = 0
            dynamicConcurrencyCap = min(configuredConcurrencyBudget, dynamicConcurrencyCap + 1)
            DonbyLogger.shared.log("Turbo 分片引擎限流缓解，并发恢复至 \(dynamicConcurrencyCap)", level: .info, subsystem: "TurboCache")
        }
    }

    func appendDirectSliceLocked(startOffset: Int64, data: Data) {
        directSlices.removeAll { $0.startOffset == startOffset }
        directSlices.append((startOffset: startOffset, data: data))
        if directSlices.count > 16 {
            directSlices.removeFirst()
        }
        if let rawBridge {
            data.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), !raw.isEmpty else { return }
                dk_net_bridge_ingest_direct(rawBridge, startOffset, ptr, Int32(raw.count))
            }
        }
    }

    func finishDirectRangeAttempt(
        attemptId: UInt64,
        startOffset: Int64,
        usedRedirectedURL: Bool,
        redirectEpoch: UInt64,
        totalSize: Int64?,
        statusCode: Int,
        succeeded: Bool,
        wasCancelled: Bool
    ) {
        if let totalSize, totalSize > 0 {
            store.setTotalSize(totalSize, sourceURL: streamURL.absoluteString)
        }
        let now = ProcessInfo.processInfo.systemUptime
        var didInvalidateRedirect = false
        condition.lock()
        activeAttempts.removeValue(forKey: attemptId)
        if directInFlightStarts[startOffset] == attemptId {
            directInFlightStarts.removeValue(forKey: startOffset)
            directInFlightEndOffsets.removeValue(forKey: startOffset)
        }
        let data = attemptBuffers.removeValue(forKey: attemptId)
        if succeeded, let data, !data.isEmpty {
            directFailedStarts.removeValue(forKey: startOffset)
            direct429Retries.removeValue(forKey: startOffset)
            directNextRetryTime.removeValue(forKey: startOffset)
            directHedgedOffsets.remove(startOffset)
            appendDirectSliceLocked(startOffset: startOffset, data: data)
            let curMeta = store.currentMeta()
            let cs = Int64(curMeta.chunkSize)
            if cs > 0 && curMeta.totalSize > 0 {
                let firstAlignedChunk = Int((startOffset + cs - 1) / cs)
                let sliceEnd = startOffset + Int64(data.count)
                var cIdx = firstAlignedChunk
                while cIdx < curMeta.totalChunks {
                    let cStart = Int64(cIdx) * cs
                    let expected = Int64(store.expectedChunkLength(for: cIdx))
                    guard expected > 0, cStart >= startOffset, cStart + expected <= sliceEnd else { break }
                    let relStart = Int(cStart - startOffset)
                    store.storeChunk(index: cIdx, data: Data(data[relStart..<(relStart + Int(expected))]))
                    cIdx += 1
                }
            }
            recordCleanCompletionAndRecoverConcurrencyLocked(now: now)
        } else if !wasCancelled {
            if statusCode == 429 {
                handleRateLimit429Locked(now: now)
                let r = (direct429Retries[startOffset] ?? 0) + 1
                direct429Retries[startOffset] = r
                directNextRetryTime[startOffset] = now + min(2.0, 0.45 * Double(r))
            } else if usedRedirectedURL && (statusCode == 200 || statusCode >= 400) && statusCode != 416 {
                if redirectEpoch == effectiveRedirectEpoch {
                    effectiveStreamURL = nil
                    didInvalidateRedirect = true
                }
                directNextRetryTime[startOffset] = now + 0.05
            } else if statusCode != 416 {
                let f = (directFailedStarts[startOffset] ?? 0) + 1
                directFailedStarts[startOffset] = f
                directNextRetryTime[startOffset] = now + min(1.5, 0.15 * Double(f))
            }
        }
        condition.broadcast()
        condition.unlock()
        if didInvalidateRedirect {
            onInvalidatedRedirectURL?()
        }
    }

    func finishStreamingAttempt(
        attemptId: UInt64,
        index: Int,
        isUrgent: Bool,
        isRescue: Bool,
        usedRedirectedURL: Bool,
        redirectEpoch: UInt64,
        totalSize: Int64?,
        statusCode: Int,
        succeeded: Bool,
        wasCancelled: Bool
    ) {
        if let totalSize, totalSize > 0 {
            store.setTotalSize(totalSize, sourceURL: streamURL.absoluteString)
        }

        let now = ProcessInfo.processInfo.systemUptime
        var competingTasksToCancel: [URLSessionDataTask] = []
        var scheduleNext = false
        var didInvalidateRedirect = false

        condition.lock()
        let removedRec = activeAttempts.removeValue(forKey: attemptId)
        var buf = attemptBuffers.removeValue(forKey: attemptId) ?? Data()
        var curIdx = removedRec?.currentChunkIndex ?? index
        let endExcl = removedRec?.endChunkExclusive ?? (index + 1)
        let startIdx = removedRec?.startChunkIndex ?? index
        let initialSkip = removedRec?.initialByteSkip ?? 0
        let storeChunkSize = store.currentMeta().chunkSize
        var completedAnyInFinish = false
        if buf.isEmpty, let rawBridge {
            var flushedChunk: Int32 = -1
            if dk_net_bridge_flush_final_attempt(rawBridge, attemptId, succeeded, &flushedChunk), flushedChunk >= 0 {
                let cIdx = Int(flushedChunk)
                inFlightChunks.remove(cIdx)
                rescueChunks.remove(cIdx)
                chunkStartTime.removeValue(forKey: cIdx)
                chunkFirstBlockedUptime.removeValue(forKey: cIdx)
                chunkNextRetryTime.removeValue(forKey: cIdx)
                chunk429Retries.removeValue(forKey: cIdx)
                failedCount.removeValue(forKey: cIdx)
                if activeDisplayAttempt[cIdx] == attemptId { activeDisplayAttempt.removeValue(forKey: cIdx) }
                if cIdx == 0 { chunk0HeadersReceived = true }
                recordCleanCompletionAndRecoverConcurrencyLocked(now: now)
                cancelCompetingAttemptsLocked(forChunk: cIdx, winnerAttemptId: attemptId, winnerIsRescue: isRescue, now: now, competingTasksToCancel: &competingTasksToCancel)
                curIdx = max(curIdx, cIdx + 1)
                completedAnyInFinish = true
                store.recordChunkCompletedFromNative(index: cIdx)
            }
        }

        while curIdx < endExcl && !buf.isEmpty {
            let skip = (curIdx == startIdx) ? initialSkip : 0
            let expectedLen = store.expectedChunkLength(for: curIdx)
            let neededLen = max(0, expectedLen - skip)
            let canCommitFull = (neededLen > 0 && buf.count >= neededLen)
            let canCommitFinal = (succeeded && curIdx == endExcl - 1 && !buf.isEmpty && (store.currentMeta().totalSize <= 0 || buf.count == neededLen))
            guard canCommitFull || canCommitFinal else { break }

            let sliceLen = canCommitFull ? neededLen : buf.count
            let completedData = Data(buf.prefix(sliceLen))
            buf.removeFirst(sliceLen)

            commitCompletedChunkSliceLocked(
                chunkIndex: curIdx,
                skip: skip,
                storeChunkSize: storeChunkSize,
                data: completedData,
                attemptId: attemptId,
                now: now
            )
            completedAnyInFinish = true
            cancelCompetingAttemptsLocked(
                forChunk: curIdx,
                winnerAttemptId: attemptId,
                winnerIsRescue: isRescue,
                now: now,
                competingTasksToCancel: &competingTasksToCancel
            )
            curIdx += 1
        }

        let completedAnyOverall = completedAnyInFinish || ((removedRec?.currentChunkIndex ?? index) > (removedRec?.startChunkIndex ?? index))

        if curIdx < endExcl {
            for remIdx in curIdx..<endExcl {
                if activeDisplayAttempt[remIdx] == attemptId {
                    let fallbackAttempt = activeAttempts.values
                        .filter { $0.currentChunkIndex == remIdx }
                        .max { attemptBufferedCount($0.attemptId) < attemptBufferedCount($1.attemptId) }
                    if let fallbackAttempt {
                        activeDisplayAttempt[remIdx] = fallbackAttempt.attemptId
                    } else {
                        activeDisplayAttempt.removeValue(forKey: remIdx)
                    }
                }
                let hasOtherAttempt = activeAttempts.values.contains { $0.covers(remIdx) }
                if !hasOtherAttempt {
                    if !isRescue || remIdx > curIdx { inFlightChunks.remove(remIdx) }
                    rescueChunks.remove(remIdx)
                    chunkStartTime.removeValue(forKey: remIdx)
                } else if isRescue {
                    rescueChunks.remove(remIdx)
                }
            }

            if !wasCancelled && !completedAnyOverall {
                if statusCode == 429 {
                    handleRateLimit429Locked(now: now)
                    let r = (chunk429Retries[curIdx] ?? 0) + 1
                    chunk429Retries[curIdx] = r
                    chunkNextRetryTime[curIdx] = now + min(2.4, 0.45 * Double(r))
                } else if usedRedirectedURL && (statusCode == 200 || statusCode >= 400) && statusCode != 416 {
                    if redirectEpoch == effectiveRedirectEpoch {
                        effectiveStreamURL = nil
                        didInvalidateRedirect = true
                    }
                    chunkNextRetryTime[curIdx] = now + 0.05
                } else if statusCode != 416 {
                    let f = (failedCount[curIdx] ?? 0) + 1
                    failedCount[curIdx] = f
                    chunkNextRetryTime[curIdx] = now + min(1.5, 0.15 * Double(f))
                    if f == 1 || f == 6 {
                        DonbyLogger.shared.log(
                            "Turbo 分片拉取失败 (chunk=\(curIdx), status=\(statusCode), retry=\(f)/6, redirected=\(usedRedirectedURL))",
                            level: .warning,
                            subsystem: "Turbo"
                        )
                    }
                }
            }
        }

        scheduleNext = !isAborted && !isClosed && (completedAnyOverall || !wasCancelled)
        condition.broadcast()
        condition.unlock()

        if let rawBridge {
            dk_net_bridge_remove_attempt(rawBridge, attemptId)
        }

        for t in competingTasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(t, intentional: true)
        }
        if didInvalidateRedirect {
            onInvalidatedRedirectURL?()
        }

        if scheduleNext {
            _ = stepBulkPrefetchSchedule()
        }
    }

    public static func parseTotalSize(from response: HTTPURLResponse?, startByte: Int64, dataCount: Int) -> Int64? {
        guard let response else { return nil }
        if let cr = response.value(forHTTPHeaderField: "Content-Range") ?? response.value(forHTTPHeaderField: "content-range") {
            if let slashIdx = cr.lastIndex(of: "/") {
                let totalStr = cr[cr.index(after: slashIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let total = Int64(totalStr), total > 0 {
                    return total
                }
            }
        }
        if response.statusCode == 200, response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return nil
    }

    public func abort() {
        var tasksToCancel: [URLSessionDataTask] = []
        condition.lock()
        isAborted = true
        for (_, rec) in activeAttempts {
            if let task = rec.task {
                tasksToCancel.append(task)
            }
        }
        condition.broadcast()
        condition.unlock()
        coordinatorTask?.cancel()
        for task in tasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(task, intentional: true)
        }
    }

    public func close() {
        var tasksToCancel: [URLSessionDataTask] = []
        condition.lock()
        if isClosed {
            condition.unlock()
            return
        }
        isAborted = true
        isClosed = true
        shouldYieldReadHandler = nil
        for (_, rec) in activeAttempts {
            if let task = rec.task {
                tasksToCancel.append(task)
            }
        }
        activeAttempts.removeAll()
        attemptBuffers.removeAll()
        activeDisplayAttempt.removeAll()
        chunkNextRetryTime.removeAll()
        chunkFirstBlockedUptime.removeAll()
        chunk429Retries.removeAll()
        directSlices.removeAll()
        directInFlightStarts.removeAll()
        directInFlightEndOffsets.removeAll()
        directFailedStarts.removeAll()
        direct429Retries.removeAll()
        directNextRetryTime.removeAll()
        directHedgedOffsets.removeAll()
        condition.broadcast()
        condition.unlock()

        coordinatorTask?.cancel()
        coordinatorTask = nil
        for task in tasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(task, intentional: true)
        }
        dk_net_update_playback_companion_state(-1, 0, false, false, false, 0, 0)

        store.flushMeta()
        let remainingReaders = store.releaseReader()
        if remainingReaders == 0 {
            store.trimIdleMemoryKeepingPinned()
            let key = assetKey
            Task { @MainActor in
                DonbyDownloadManager.shared.cleanupRedundantCacheIfMaterialized(assetKey: key)
            }
        }
    }

    func appendChunkPartialBytes(attemptId: UInt64, index: Int, ptr: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        guard let rawBridge else {
            appendChunkPartialData(attemptId: attemptId, index: index, delta: Data(bytes: ptr, count: count))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var completed = [Int32](repeating: -1, count: 64)
        let nCompleted = completed.withUnsafeMutableBufferPointer { buf in
            Int(dk_net_bridge_ingest_partial(rawBridge, attemptId, ptr, Int32(count), buf.baseAddress, Int32(buf.count)))
        }
        var competingTasksToCancel: [URLSessionDataTask] = []
        condition.lock()
        guard !isAborted && !isClosed, var rec = activeAttempts[attemptId] else {
            condition.unlock()
            return
        }
        rec.lastByteTimestamp = now
        for i in 0..<nCompleted {
            let cIdx = Int(completed[i])
            guard cIdx >= 0 else { continue }
            inFlightChunks.remove(cIdx)
            rescueChunks.remove(cIdx)
            chunkStartTime.removeValue(forKey: cIdx)
            chunkFirstBlockedUptime.removeValue(forKey: cIdx)
            chunkNextRetryTime.removeValue(forKey: cIdx)
            chunk429Retries.removeValue(forKey: cIdx)
            failedCount.removeValue(forKey: cIdx)
            if activeDisplayAttempt[cIdx] == attemptId { activeDisplayAttempt.removeValue(forKey: cIdx) }
            if cIdx == 0 { chunk0HeadersReceived = true }
            recordCleanCompletionAndRecoverConcurrencyLocked(now: now)
            cancelCompetingAttemptsLocked(forChunk: cIdx, winnerAttemptId: attemptId, winnerIsRescue: rec.isRescue, now: now, competingTasksToCancel: &competingTasksToCancel)
            rec.currentChunkIndex = max(rec.currentChunkIndex, cIdx + 1)
            rec.chunkStartTimestamp = now
            if rec.currentChunkIndex < rec.endChunkExclusive { chunkStartTime[rec.currentChunkIndex] = now }
        }
        if rec.trimmedEarly && rec.currentChunkIndex >= rec.endChunkExclusive {
            rec.trimmedEarly = false
            if let t = rec.task { competingTasksToCancel.append(t) }
        }
        activeAttempts[attemptId] = rec
        wireSpeedMeter.recordBytes(count, at: now)
        let smoothWire = wireSpeedMeter.speedMBs(at: now)
        if smoothWire > 0.05 { measuredWireSpeedMBs = smoothWire }
        condition.broadcast()
        condition.unlock()

        for i in 0..<nCompleted {
            let cIdx = Int(completed[i])
            if cIdx >= 0 { store.recordChunkCompletedFromNative(index: cIdx) }
        }
        for t in competingTasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(t, intentional: true)
        }
    }

    func appendDirectRangePartial(attemptId: UInt64, startOffset: Int64, delta: Data) {
        guard !delta.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        condition.lock()
        guard !isAborted && !isClosed, activeAttempts[attemptId] != nil else {
            condition.unlock()
            return
        }
        var buf = attemptBuffers[attemptId] ?? Data()
        buf.append(delta)
        attemptBuffers[attemptId] = buf
        activeAttempts[attemptId]?.lastByteTimestamp = now
        wireSpeedMeter.recordBytes(delta.count, at: now)
        condition.broadcast()
        condition.unlock()
    }

    func tryCopyPartialOrDirectLockedOut(
        currentOffset: Int64,
        targetChunk: Int,
        offsetInChunk: Int,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        if let copied = tryCopyPartialLocked(targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
            return copied
        }
        return tryCopyDirectTailLocked(at: currentOffset, into: buffer, count: count)
    }

    func tryCopyPartialLocked(
        targetChunk: Int,
        offsetInChunk: Int,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
        if let rawBridge {
            let n = Int(dk_net_bridge_try_read_partial_or_direct(rawBridge, cursorOffset, Int32(targetChunk), Int32(offsetInChunk), buffer, Int32(count)))
            if n > 0 {
                cursorOffset += Int64(n)
                dk_net_bridge_set_cursor(rawBridge, cursorOffset)
                condition.broadcast()
                return n
            }
        }
        func tryFromAttempt(_ aid: UInt64) -> Int? {
            guard let rec = activeAttempts[aid],
                  rec.currentChunkIndex == targetChunk,
                  let partial = attemptBuffers[aid] else {
                return nil
            }
            let skip = (rec.currentChunkIndex == rec.startChunkIndex) ? rec.initialByteSkip : 0
            guard offsetInChunk >= skip else { return nil }
            let rel = offsetInChunk - skip
            guard rel < partial.count else { return nil }
            let toCopy = copySlice(partial, offset: rel, into: buffer, maxCount: count)
            cursorOffset += Int64(toCopy)
            if let rawBridge { dk_net_bridge_set_cursor(rawBridge, cursorOffset) }
            condition.broadcast()
            return toCopy
        }

        if let dispAttempt = activeDisplayAttempt[targetChunk],
           let copied = tryFromAttempt(dispAttempt) {
            return copied
        }
        for (aid, rec) in activeAttempts where rec.currentChunkIndex == targetChunk {
            if let copied = tryFromAttempt(aid) {
                return copied
            }
        }
        return nil
    }
}

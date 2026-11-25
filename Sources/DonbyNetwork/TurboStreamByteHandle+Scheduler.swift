import Foundation
import DonbyCore

// MARK: - TurboStreamByteHandle Range Scheduling, Rescue & Delegate Callbacks

extension TurboStreamByteHandle {
    func markProtocolMultiplexed(_ multiplexed: Bool) {
        condition.lock()
        if isMultiplexedProtocol != multiplexed {
            isMultiplexedProtocol = multiplexed
        }
        condition.unlock()
    }

    func requestUrgentChunk(_ chunkIndex: Int, offsetInChunk: Int = 0) {
        condition.lock()
        let nearbyStream = activeAttempts.values.first {
            $0.covers(chunkIndex, offsetInChunk: offsetInChunk) && (chunkIndex - $0.currentChunkIndex <= 3)
        }
        if nearbyStream == nil && !isAborted && !isClosed {
            let desiredSkip = computeInitialByteSkipLocked(chunkIndex: chunkIndex, offsetInChunk: offsetInChunk)
            inFlightChunks.insert(chunkIndex)
            chunkStartTime[chunkIndex] = ProcessInfo.processInfo.systemUptime
            spawnChunkFetchLocked(index: chunkIndex, isUrgent: true, isRescue: false, initialByteSkip: desiredSkip)
        } else if let nearbyStream, let task = nearbyStream.task {
            task.priority = URLSessionTask.highPriority
        }
        let shouldLaunchLookaheadNow = !inOpenProbePhase && chunkIndex > 0 && !isAborted && !isClosed
        condition.broadcast()
        condition.unlock()
        if shouldLaunchLookaheadNow {
            _ = stepBulkPrefetchSchedule()
        }
    }

    func startCoordinatorLoop() {
        coordinatorTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldStop = self.stepBulkPrefetchSchedule()
                if shouldStop { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    func stepBulkPrefetchSchedule() -> Bool {
        condition.lock()
        if isAborted || isClosed {
            condition.unlock()
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if inOpenProbePhase && (now - openedUptime > 6.0) {
            inOpenProbePhase = false
        }
        if now < last429BackoffUntil {
            condition.unlock()
            return false
        }

        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let currentChunk = Int(max(0, cursorOffset) / Int64(chunkSize))
        if inOpenProbePhase && currentChunk >= 3 && currentChunk < max(4, meta.totalChunks - 2) {
            inOpenProbePhase = false
        }

        let totalChunks = meta.totalChunks
        let ahead = prefetchAheadChunks

        var leadCachedChunks = 0
        while leadCachedChunks < 6 {
            let probeIdx = currentChunk + leadCachedChunks
            if totalChunks > 0 && probeIdx >= totalChunks {
                leadCachedChunks = 6
                break
            }
            if store.hasChunk(probeIdx) {
                leadCachedChunks += 1
            } else {
                break
            }
        }

        let playheadAttempt = activeAttempts.values.first {
            $0.currentChunkIndex >= 0 && $0.covers(currentChunk) && (currentChunk - $0.currentChunkIndex <= 3)
        }
        let playheadReceivingBytes: Bool = {
            guard let rec = playheadAttempt else { return leadCachedChunks > 0 }
            let bufCount = attemptBuffers[rec.attemptId]?.count ?? 0
            return bufCount > 0 || rec.currentChunkIndex > rec.startChunkIndex
        }()

        let inInitialSeekBurst = !playheadReceivingBytes && leadCachedChunks == 0 && lastSeekUptime > 0 && (now - lastSeekUptime) < 0.55
        let effectiveCap: Int
        if inOpenProbePhase {
            effectiveCap = chunk0HeadersReceived ? min(2, dynamicConcurrencyCap) : 0
        } else if inInitialSeekBurst {
            // Brief 0.55s seek-burst gate: focuses initial CWND on Stream #1 + Stream #2 and halves H2 RST_STREAM
            // churn during rapid scrubbing, then immediately opens full pipeline without deadlocking on slow CDNs.
            effectiveCap = min(2, dynamicConcurrencyCap)
        } else if isMultiplexedProtocol {
            let needsPerStreamBoost = (measuredWireSpeedMBs > 0.1 && measuredWireSpeedMBs < 4.5 && leadCachedChunks < 6)
            effectiveCap = min(needsPerStreamBoost ? 5 : 4, dynamicConcurrencyCap)
        } else {
            let inPostSeekRamp = (lastSeekUptime > 0) && ((now - lastSeekUptime) < 3.5) && (leadCachedChunks < 6)
            effectiveCap = inPostSeekRamp ? min(4, dynamicConcurrencyCap) : dynamicConcurrencyCap
        }

        // Dynamically promote HTTP/2 stream priority well ahead of playhead consumption
        for rec in activeAttempts.values where rec.currentChunkIndex >= 0 && rec.currentChunkIndex < rec.endChunkExclusive {
            guard let task = rec.task else { continue }
            let dist = rec.currentChunkIndex - currentChunk
            let desiredPriority: Float
            if rec.isUrgent || rec.isRescue || dist <= 12 {
                desiredPriority = 1.0
            } else if dist <= 28 {
                desiredPriority = 0.75
            } else {
                desiredPriority = 0.35
            }
            if abs(task.priority - desiredPriority) > 0.05 {
                task.priority = desiredPriority
            }
        }

        // Check genuinely stalled or slow-crawling streams near cursor using adaptive CDN TTFB so slow edges
        // never trigger rescue storms while throttled playhead streams get rescued before audio underruns.
        let adaptiveColdRescue: TimeInterval = max(2.2, min(4.5, smoothedResponseTTFB * 2.5))
        var stalledTasksToCancel: [URLSessionDataTask] = []
        for rec in activeAttempts.values where rec.currentChunkIndex >= currentChunk && rec.currentChunkIndex <= currentChunk + 2 && rec.currentChunkIndex < rec.endChunkExclusive {
            let idx = rec.currentChunkIndex
            if !rescueChunks.contains(idx) {
                let byteIdle = now - rec.lastByteTimestamp
                let partialBytes = attemptBuffers[rec.attemptId]?.count ?? 0
                let hasReceivedAny = (rec.currentChunkIndex > rec.startChunkIndex) || (partialBytes > 0)
                let isImmediatePlayhead = (idx <= currentChunk + 1)
                let threshold: TimeInterval = hasReceivedAny ? (isImmediatePlayhead ? 1.1 : 1.6) : adaptiveColdRescue
                let chunkElapsed = now - rec.chunkStartTimestamp
                let isSlowPlayheadCrawl = (dynamicConcurrencyCap > 1) && hasReceivedAny && isImmediatePlayhead && chunkElapsed > 1.25 && (Double(partialBytes) / max(0.1, chunkElapsed) < 360_000.0)
                if byteIdle > threshold || isSlowPlayheadCrawl {
                    if dynamicConcurrencyCap <= 1 {
                        if let t = rec.task { stalledTasksToCancel.append(t) }
                        activeAttempts.removeValue(forKey: rec.attemptId)
                        attemptBuffers.removeValue(forKey: rec.attemptId)
                        for relIdx in rec.currentChunkIndex..<rec.endChunkExclusive where relIdx > idx {
                            if activeDisplayAttempt[relIdx] == rec.attemptId { activeDisplayAttempt.removeValue(forKey: relIdx) }
                            if !activeAttempts.values.contains(where: { $0.covers(relIdx) }) {
                                inFlightChunks.remove(relIdx)
                                rescueChunks.remove(relIdx)
                                chunkStartTime.removeValue(forKey: relIdx)
                            }
                        }
                    }
                    rescueChunks.insert(idx)
                    chunkStartTime[idx] = now
                    let rescueSkip = (idx == currentChunk) ? computeInitialByteSkipLocked(chunkIndex: idx, offsetInChunk: Int(max(0, cursorOffset) % Int64(chunkSize))) : 0
                    spawnChunkFetchLocked(index: idx, isUrgent: true, isRescue: true, initialByteSkip: rescueSkip)
                }
            }
        }

        var totalStreamsInFlight = activeAttempts.values.filter {
            $0.currentChunkIndex >= 0 && $0.currentChunkIndex < $0.endChunkExclusive && !$0.isRescue && !$0.trimmedEarly
        }.count

        if totalStreamsInFlight < effectiveCap {
            let maxChunk = totalChunks > 0 ? min(totalChunks - 1, currentChunk + ahead) : (currentChunk + min(ahead, 16))
            if maxChunk >= currentChunk {
                var candidate = currentChunk
                while candidate <= maxChunk && totalStreamsInFlight < effectiveCap {
                    if inFlightChunks.contains(candidate) || store.hasChunk(candidate) {
                        candidate += 1
                        continue
                    }
                    if (failedCount[candidate] ?? 0) >= 6 || (chunk429Retries[candidate] ?? 0) >= 12 || now < (chunkNextRetryTime[candidate] ?? 0) {
                        candidate += 1
                        continue
                    }
                    let isPlayheadImmediate = (candidate == currentChunk)
                    inFlightChunks.insert(candidate)
                    totalStreamsInFlight += 1
                    chunkStartTime[candidate] = now
                    spawnChunkFetchLocked(index: candidate, isUrgent: isPlayheadImmediate, isRescue: false)
                    candidate += 1
                }
            }
        }
        condition.unlock()
        for t in stalledTasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(t, intentional: true)
        }
        return false
    }

    func spawnDirectRangeFetchLocked(startOffset: Int64, totalSize: Int64, length: Int64 = 524_288) {
        let clampedLen = max(1, min(1_048_576, length))
        let endByte = min(totalSize - 1, startOffset + clampedLen - 1)
        guard endByte >= startOffset else { return }

        let usedRedirected = (effectiveStreamURL != nil)
        let targetURL = effectiveStreamURL ?? streamURL
        let req = TurboStreamingSessionHub.makeRangeRequest(url: targetURL, originHost: streamURL.host, headers: headers, startByte: startOffset, endByte: endByte, timeout: 10.0)

        let attemptId = nextAttemptId
        nextAttemptId &+= 1
        let now = ProcessInfo.processInfo.systemUptime

        let ctx = StreamingChunkContext(
            attemptId: attemptId,
            chunkIndex: -1,
            chunkSize: Int(endByte - startOffset + 1),
            startByte: startOffset,
            isUrgent: true,
            isRescue: false,
            isDirectRange: true,
            requestOriginURL: targetURL,
            usedRedirectedURL: usedRedirected,
            redirectEpoch: usedRedirected ? effectiveRedirectEpoch : 0,
            owner: self
        )

        var buf = Data()
        buf.reserveCapacity(Int(endByte - startOffset + 1))
        attemptBuffers[attemptId] = buf
        directInFlightStarts[startOffset] = attemptId
        directInFlightEndOffsets[startOffset] = endByte
        let task = TurboStreamingSessionHub.shared.startTask(request: req, context: ctx, priority: 1.0)
        activeAttempts[attemptId] = ActiveAttemptRecord(
            attemptId: attemptId,
            startChunkIndex: -1,
            currentChunkIndex: -1,
            endChunkExclusive: -1,
            initialByteSkip: 0,
            isUrgent: true,
            isRescue: false,
            task: task,
            lastByteTimestamp: now,
            chunkStartTimestamp: now
        )
    }

    func spawnChunkFetchLocked(index: Int, isUrgent: Bool, isRescue: Bool, initialByteSkip: Int = 0) {
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let safeSkip = (index > 0 && meta.totalSize > 0 && initialByteSkip > 0 && initialByteSkip < chunkSize - 16_384) ? initialByteSkip : 0
        let startByte = Int64(index) * Int64(chunkSize) + Int64(safeSkip)
        if meta.totalSize > 0 && startByte >= meta.totalSize {
            if !isRescue { inFlightChunks.remove(index) } else { rescueChunks.remove(index) }
            condition.broadcast()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let cursorChunk = Int(max(0, cursorOffset) / Int64(chunkSize))
        let aheadFromCursor = max(0, index - cursorChunk)
        let singleStreamMode = !inOpenProbePhase && dynamicConcurrencyCap <= 1
        let maxSpanChunks: Int = {
            if index == 0 && !chunk0HeadersReceived { return 2 }              // 1 MiB fast initial probe (Chunk 0..1) so Stream #2 can parallelize Chunk 2..3
            if isRescue { return 2 }                                          // 1 MiB ultra-fast rescue span
            if singleStreamMode && index > 0 {
                let singleDesired = measuredWireSpeedMBs >= 5.0 ? 48 : (measuredWireSpeedMBs >= 2.0 ? 32 : 16)
                return min(singleDesired, min(64, max(2, prefetchAheadChunks)))
            }
            let shallowPlayhead = !(0..<4).allSatisfy { store.hasChunk(cursorChunk + $0) }
            let desired: Int
            if aheadFromCursor <= 1 {
                desired = safeSkip >= 262_144 ? 5 : 4  // >= 2.0 MiB usable playhead sprint
            } else if aheadFromCursor <= 6 {
                desired = (dynamicConcurrencyCap == 2 && !shallowPlayhead) ? 8 : 4
            } else if aheadFromCursor <= 22 {
                desired = shallowPlayhead ? 4 : 8   // 4 MiB near lookahead (compact while playhead is cold)
            } else {
                desired = shallowPlayhead ? 4 : 12  // 6 MiB steady-state bulk lookahead
            }
            return min(desired, max(2, prefetchAheadChunks))
        }()

        var spanEnd = index + 1
        if meta.totalSize > 0 {
            let totalChunks = meta.totalChunks
            let horizonChunk = (index == 0 && !chunk0HeadersReceived)
                ? totalChunks
                : (Int(max(0, cursorOffset) / Int64(chunkSize)) + prefetchAheadChunks + 1)
            let spanBound = ((isUrgent && !singleStreamMode) || isRescue || index == 0) ? totalChunks : min(totalChunks, horizonChunk)
            let limit = min(spanBound, index + max(1, maxSpanChunks))
            while spanEnd < limit && !store.hasChunk(spanEnd) && !inFlightChunks.contains(spanEnd) {
                inFlightChunks.insert(spanEnd)
                chunkStartTime[spanEnd] = now
                spanEnd += 1
            }
        }

        let endByte: Int64 = {
            if meta.totalSize > 0 {
                return min(meta.totalSize - 1, Int64(spanEnd) * Int64(chunkSize) - 1)
            }
            return startByte + Int64(chunkSize) - 1
        }()
        let requestByteLength = Int(max(1, endByte - startByte + 1))

        let usedRedirected = (effectiveStreamURL != nil)
        let targetURL = effectiveStreamURL ?? streamURL
        let req = TurboStreamingSessionHub.makeRangeRequest(url: targetURL, originHost: streamURL.host, headers: headers, startByte: startByte, endByte: endByte, timeout: isUrgent ? 14.0 : 20.0)

        let attemptId = nextAttemptId
        nextAttemptId &+= 1

        let ctx = StreamingChunkContext(
            attemptId: attemptId,
            chunkIndex: index,
            chunkSize: requestByteLength,
            startByte: startByte,
            isUrgent: isUrgent,
            isRescue: isRescue,
            requestOriginURL: targetURL,
            usedRedirectedURL: usedRedirected,
            redirectEpoch: usedRedirected ? effectiveRedirectEpoch : 0,
            owner: self
        )

        var buf = Data()
        buf.reserveCapacity(min(requestByteLength, chunkSize * 2))
        attemptBuffers[attemptId] = buf
        if activeDisplayAttempt[index] == nil {
            activeDisplayAttempt[index] = attemptId
        }
        let taskPriority: Float = {
            if isUrgent || isRescue || aheadFromCursor <= 12 { return 1.0 }
            if aheadFromCursor <= 28 { return 0.75 }
            return 0.35
        }()
        let task = TurboStreamingSessionHub.shared.startTask(request: req, context: ctx, priority: taskPriority)
        activeAttempts[attemptId] = ActiveAttemptRecord(
            attemptId: attemptId,
            startChunkIndex: index,
            currentChunkIndex: index,
            endChunkExclusive: spanEnd,
            initialByteSkip: safeSkip,
            isUrgent: isUrgent,
            isRescue: isRescue,
            task: task,
            lastByteTimestamp: now,
            chunkStartTimestamp: now
        )
    }

    func maybePrefetchOpenProbeTailLocked() {
        guard inOpenProbePhase, !didTriggerProbeTailPrefetch, !isAborted, !isClosed else { return }
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let totalChunks = meta.totalChunks
        guard totalChunks > 3, meta.totalSize > Int64(chunkSize * 3) else { return }
        let tailChunkCount = meta.totalSize > 4_294_967_296 ? 2 : 1
        let tailStartChunk = max(2, totalChunks - tailChunkCount)
        let allTailCachedOnDisk = (tailStartChunk..<totalChunks).allSatisfy { store.hasChunk($0) }
        didTriggerProbeTailPrefetch = true
        if allTailCachedOnDisk {
            return
        }
        let tailStartOffset = Int64(tailStartChunk) * Int64(chunkSize)
        let tailLength = meta.totalSize - tailStartOffset
        let alreadyCovered = directSlices.contains { $0.startOffset <= tailStartOffset && ($0.startOffset + Int64($0.data.count)) >= meta.totalSize }
            || directInFlightStarts.keys.contains { startOff in
                let endOff = directInFlightEndOffsets[startOff] ?? (startOff + tailLength - 1)
                return startOff <= tailStartOffset && endOff >= meta.totalSize - 1
            }
        if !alreadyCovered && tailLength > 0 {
            spawnDirectRangeFetchLocked(startOffset: tailStartOffset, totalSize: meta.totalSize, length: tailLength)
        }
    }

    private func recordResolvedRedirectLocked(finalURL: URL, originURL: URL) -> URL? {
        guard finalURL.absoluteString != originURL.absoluteString,
              finalURL.absoluteString != streamURL.absoluteString else {
            return nil
        }
        if effectiveStreamURL?.absoluteString != finalURL.absoluteString {
            effectiveStreamURL = finalURL
            effectiveRedirectEpoch &+= 1
        }
        guard !didNotifyRedirectCallback else { return nil }
        didNotifyRedirectCallback = true
        return finalURL
    }

    func handleEarlyRedirectResolved(chunkIndex: Int, finalURL: URL, originURL: URL) {
        let knownMultiplexed = TurboStreamingSessionHub.shared.isHostKnownMultiplexed(finalURL)
        condition.lock()
        if knownMultiplexed {
            isMultiplexedProtocol = true
        }
        let notifyRedirectURL = recordResolvedRedirectLocked(finalURL: finalURL, originURL: originURL)
        guard effectiveStreamURL?.absoluteString == finalURL.absoluteString else {
            condition.unlock()
            return
        }
        if chunkIndex == 0 {
            maybePrefetchOpenProbeTailLocked()
        }
        let shouldStepNow = !inOpenProbePhase && !isAborted && !isClosed
        condition.broadcast()
        condition.unlock()

        if let notifyRedirectURL {
            onResolvedRedirectURL?(notifyRedirectURL)
        }
        if shouldStepNow {
            _ = stepBulkPrefetchSchedule()
        }
    }

    func handleChunkResponseHeaders(
        attemptId: UInt64,
        index: Int,
        statusCode: Int,
        parsedTotalSize: Int64?,
        finalURL: URL?,
        originURL: URL
    ) {
        if let parsedTotalSize, parsedTotalSize > 0 {
            store.setTotalSize(parsedTotalSize, sourceURL: streamURL.absoluteString)
        }
        let knownMultiplexed = TurboStreamingSessionHub.shared.isHostKnownMultiplexed(finalURL ?? originURL)
        let now = ProcessInfo.processInfo.systemUptime

        condition.lock()
        if knownMultiplexed {
            isMultiplexedProtocol = true
        }
        if var rec = activeAttempts[attemptId], rec.currentChunkIndex == rec.startChunkIndex {
            let ttfb = now - rec.chunkStartTimestamp
            if ttfb > 0.02 && ttfb < 8.0 {
                smoothedResponseTTFB = smoothedResponseTTFB * 0.65 + ttfb * 0.35
            }
            // Reset chunkStartTimestamp to response-header arrival so slow-crawl detection measures
            // post-TTFB body transfer rate rather than conflating cold TTFB.
            rec.chunkStartTimestamp = now
            activeAttempts[attemptId] = rec
        }
        if index == 0 {
            chunk0HeadersReceived = true
        }
        let notifyRedirectURL = finalURL.flatMap { recordResolvedRedirectLocked(finalURL: $0, originURL: originURL) }
        if index == 0 {
            maybePrefetchOpenProbeTailLocked()
        }
        condition.broadcast()
        condition.unlock()

        if let notifyRedirectURL {
            onResolvedRedirectURL?(notifyRedirectURL)
        }
        if index == 0 {
            _ = stepBulkPrefetchSchedule()
        }
    }

    private func commitCompletedChunkSliceLocked(
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

    private func cancelCompetingAttemptsLocked(
        forChunk curIdx: Int,
        winnerAttemptId: UInt64,
        winnerIsRescue: Bool,
        now: TimeInterval,
        competingTasksToCancel: inout [URLSessionDataTask]
    ) {
        let competingIds = activeAttempts.values
            .filter { other in
                guard other.attemptId != winnerAttemptId && other.currentChunkIndex == curIdx else { return false }
                if other.isRescue || other.endChunkExclusive == curIdx + 1 { return true }
                if winnerIsRescue && (now - other.lastByteTimestamp) > 1.5 { return true }
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
        }
    }

    func appendChunkPartialData(attemptId: UInt64, index: Int, delta: Data) {
        guard !delta.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var competingTasksToCancel: [URLSessionDataTask] = []

        condition.lock()
        guard !isAborted && !isClosed, var rec = activeAttempts[attemptId] else {
            condition.unlock()
            return
        }
        var buf = attemptBuffers[attemptId] ?? Data()
        buf.append(delta)
        rec.lastByteTimestamp = now

        let storeChunkSize = store.currentMeta().chunkSize
        while rec.currentChunkIndex < rec.endChunkExclusive {
            let curIdx = rec.currentChunkIndex
            let skip = (curIdx == rec.startChunkIndex) ? rec.initialByteSkip : 0
            let expectedLen = store.expectedChunkLength(for: curIdx)
            let neededLen = expectedLen - skip
            guard neededLen > 0, buf.count >= neededLen else { break }
            let completedSlice = Data(buf.prefix(neededLen))
            buf.removeFirst(neededLen)

            commitCompletedChunkSliceLocked(
                chunkIndex: curIdx,
                skip: skip,
                storeChunkSize: storeChunkSize,
                data: completedSlice,
                attemptId: attemptId,
                now: now
            )
            cancelCompetingAttemptsLocked(
                forChunk: curIdx,
                winnerAttemptId: attemptId,
                winnerIsRescue: rec.isRescue,
                now: now,
                competingTasksToCancel: &competingTasksToCancel
            )

            rec.currentChunkIndex += 1
            rec.chunkStartTimestamp = now
            if rec.currentChunkIndex < rec.endChunkExclusive {
                chunkStartTime[rec.currentChunkIndex] = now
            }
        }

        if rec.trimmedEarly && rec.currentChunkIndex >= rec.endChunkExclusive {
            rec.trimmedEarly = false
            buf.removeAll(keepingCapacity: false)
            if let t = rec.task {
                competingTasksToCancel.append(t)
            }
        }

        let activeIdx = rec.currentChunkIndex
        attemptBuffers[attemptId] = buf
        activeAttempts[attemptId] = rec

        if activeIdx < rec.endChunkExclusive {
            if let curDisp = activeDisplayAttempt[activeIdx] {
                if curDisp != attemptId && (attemptBuffers[curDisp]?.count ?? 0) < buf.count {
                    activeDisplayAttempt[activeIdx] = attemptId
                }
            } else {
                activeDisplayAttempt[activeIdx] = attemptId
            }
        }

        recentWireBytes += Int64(delta.count)
        let dt = now - recentWireTimestamp
        if dt >= 0.30 {
            let instMBs = (Double(recentWireBytes) / (1024.0 * 1024.0)) / dt
            measuredWireSpeedMBs = measuredWireSpeedMBs > 0.05
                ? (measuredWireSpeedMBs * 0.35 + instMBs * 0.65)
                : instMBs
            recentWireBytes = 0
            recentWireTimestamp = now
        }

        condition.broadcast()
        condition.unlock()

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
        condition.broadcast()
        condition.unlock()
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

        condition.lock()
        let removedRec = activeAttempts.removeValue(forKey: attemptId)
        var buf = attemptBuffers.removeValue(forKey: attemptId) ?? Data()
        var curIdx = removedRec?.currentChunkIndex ?? index
        let endExcl = removedRec?.endChunkExclusive ?? (index + 1)
        let startIdx = removedRec?.startChunkIndex ?? index
        let initialSkip = removedRec?.initialByteSkip ?? 0
        let storeChunkSize = store.currentMeta().chunkSize
        var completedAnyInFinish = false

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
                        .max { (attemptBuffers[$0.attemptId]?.count ?? 0) < (attemptBuffers[$1.attemptId]?.count ?? 0) }
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

        for t in competingTasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(t, intentional: true)
        }

        if scheduleNext {
            _ = stepBulkPrefetchSchedule()
        }
    }
}

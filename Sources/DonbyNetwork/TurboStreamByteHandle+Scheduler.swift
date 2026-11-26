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

        let isRapidScrubStreak = recentSeekStreakCount >= 2 && lastSeekUptime > 0 && (now - lastSeekUptime) < 0.35
        let inInitialScrubGate = isRapidScrubStreak && !playheadReceivingBytes && leadCachedChunks == 0
        let effectiveCap: Int
        if inOpenProbePhase {
            effectiveCap = (redirectResolved || chunk0HeadersReceived) ? min(2, dynamicConcurrencyCap) : 0
        } else if inInitialScrubGate {
            // 0.35s 2-stream gate activates ONLY on rapid consecutive scrub streaks (>= 2 seeks within 450ms)
            // to prevent HTTP/2 RST_STREAM storms while letting single-click seeks immediately use warm lanes.
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

        // Work-Stealing Tail-Trim: if a stream holding >= 2 chunks near the playhead crawls below
        // max(480 KB/s, 0.4 * fastestLaneSpeed), trim its trailing chunks immediately so fast lanes take over.
        if dynamicConcurrencyCap > 1 {
            let fastestLaneBps = max(
                TurboStreamingSessionHub.shared.fastestHealthyLaneSpeedBps(),
                measuredWireSpeedMBs * 1_048_576.0 * 0.55
            )
            let trimFloorBps = max(480_000.0, 0.40 * fastestLaneBps)
            let focusChunk = urgentWaitingChunk ?? currentChunk
            let candidateIds = Array(activeAttempts.keys)
            for aid in candidateIds {
                guard let rec = activeAttempts[aid],
                      !rec.trimmedEarly,
                      rec.currentChunkIndex >= 0,
                      (rec.endChunkExclusive - rec.currentChunkIndex) >= 2,
                      focusChunk >= rec.currentChunkIndex - 2 else { continue }
                let partialBytes = attemptBuffers[aid]?.count ?? 0
                let hasStartedBody = rec.responseHeadersReceived || partialBytes > 0 || rec.currentChunkIndex > rec.startChunkIndex
                let elapsed = now - rec.chunkStartTimestamp
                guard hasStartedBody && elapsed >= 0.22 else { continue }
                let rateBps = Double(partialBytes) / max(0.05, elapsed)
                if rateBps < trimFloorBps {
                    trimSlowAttemptTailLocked(attemptId: aid)
                }
            }
        }

        // Check genuinely stalled or slow-crawling streams near cursor using adaptive CDN TTFB so slow edges
        // never trigger rescue storms while throttled playhead streams get rescued before audio underruns.
        let adaptiveColdRescue: TimeInterval = max(2.2, min(4.5, smoothedResponseTTFB * 2.5))
        let crawlFloorBps: Double = measuredWireSpeedMBs >= 1.5 ? 480_000.0 : 360_000.0
        var stalledTasksToCancel: [URLSessionDataTask] = []
        var stalledLanesToReport: [Int] = []
        let activeHost = (effectiveStreamURL ?? streamURL).host
        for rec in activeAttempts.values where rec.currentChunkIndex >= currentChunk && rec.currentChunkIndex <= currentChunk + 2 && rec.currentChunkIndex < rec.endChunkExclusive {
            let idx = rec.currentChunkIndex
            if !rescueChunks.contains(idx) {
                let byteIdle = now - rec.lastByteTimestamp
                let partialBytes = attemptBuffers[rec.attemptId]?.count ?? 0
                let hasReceivedAny = rec.responseHeadersReceived || (rec.currentChunkIndex > rec.startChunkIndex) || (partialBytes > 0)
                let isImmediatePlayhead = (idx <= currentChunk + 1)
                let isReaderBlockedHere = (urgentWaitingChunk == idx)
                let waitElapsed = isReaderBlockedHere ? max(0, now - urgentWaitStartUptime) : 0
                let chunkElapsed = now - rec.chunkStartTimestamp
                let rateBps = Double(partialBytes) / max(0.05, chunkElapsed)

                var shouldHedgeOrRescue = false
                if isReaderBlockedHere && dynamicConcurrencyCap > 1 {
                    if hasReceivedAny && waitElapsed >= 0.30 {
                        let expectedLen = store.expectedChunkLength(for: idx)
                        let skip = (idx == rec.startChunkIndex) ? rec.initialByteSkip : 0
                        let remBytes = max(0, expectedLen - skip - partialBytes)
                        let predictedRem = Double(remBytes) / max(1.0, rateBps)
                        if predictedRem > 0.35 || byteIdle > 1.0 {
                            shouldHedgeOrRescue = true
                        }
                    } else if !hasReceivedAny {
                        let hasFastAlt = TurboStreamingSessionHub.shared.hasVerifiedFastAlternateLane(forHost: activeHost, excludingLane: rec.laneIndex)
                        let coldThreshold = hasFastAlt ? max(0.95, smoothedResponseTTFB * 1.4) : adaptiveColdRescue
                        if waitElapsed > coldThreshold || byteIdle > coldThreshold {
                            shouldHedgeOrRescue = true
                        }
                    }
                }
                if !shouldHedgeOrRescue {
                    let threshold: TimeInterval = hasReceivedAny ? (isImmediatePlayhead ? 1.1 : 1.6) : adaptiveColdRescue
                    let isSlowPlayheadCrawl = (dynamicConcurrencyCap > 1) && hasReceivedAny && isImmediatePlayhead && chunkElapsed > 1.2 && (rateBps < crawlFloorBps)
                    shouldHedgeOrRescue = (byteIdle > threshold) || isSlowPlayheadCrawl
                }

                if shouldHedgeOrRescue {
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
                    } else {
                        trimSlowAttemptTailLocked(attemptId: rec.attemptId)
                    }
                    rescueChunks.insert(idx)
                    chunkStartTime[idx] = now
                    if byteIdle > 1.5 || !isReaderBlockedHere {
                        stalledLanesToReport.append(rec.laneIndex)
                    }
                    let rescueSkip = (idx == currentChunk) ? computeInitialByteSkipLocked(chunkIndex: idx, offsetInChunk: Int(max(0, cursorOffset) % Int64(chunkSize))) : 0
                    spawnChunkFetchLocked(
                        index: idx,
                        isUrgent: true,
                        isRescue: true,
                        initialByteSkip: rescueSkip,
                        excludeLane: rec.laneIndex,
                        singleChunkMicroHedge: isReaderBlockedHere
                    )
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
        for lane in stalledLanesToReport {
            TurboStreamingSessionHub.shared.reportLaneStall(laneIndex: lane)
        }
        return false
    }

    func trimSlowAttemptTailLocked(attemptId: UInt64) {
        guard var rec = activeAttempts[attemptId],
              !rec.trimmedEarly,
              rec.currentChunkIndex >= 0,
              rec.endChunkExclusive > rec.currentChunkIndex + 1 else { return }
        let keepEnd = rec.currentChunkIndex + 1
        for relIdx in keepEnd..<rec.endChunkExclusive {
            if activeDisplayAttempt[relIdx] == attemptId {
                activeDisplayAttempt.removeValue(forKey: relIdx)
            }
        }
        rec.endChunkExclusive = keepEnd
        rec.trimmedEarly = true
        activeAttempts[attemptId] = rec
        for relIdx in keepEnd..<(keepEnd + 64) {
            if inFlightChunks.contains(relIdx) && !activeAttempts.values.contains(where: { $0.covers(relIdx) }) {
                inFlightChunks.remove(relIdx)
                rescueChunks.remove(relIdx)
                chunkStartTime.removeValue(forKey: relIdx)
            }
        }
    }

    func spawnDirectRangeFetchLocked(
        startOffset: Int64,
        totalSize: Int64,
        length: Int64 = 524_288,
        excludeLane: Int? = nil
    ) {
        let clampedLen = max(1, min(2_097_152, length))
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
        let (task, laneIdx) = TurboStreamingSessionHub.shared.startTask(
            request: req,
            context: ctx,
            priority: 1.0,
            excludeLane: excludeLane
        )
        activeAttempts[attemptId] = ActiveAttemptRecord(
            attemptId: attemptId,
            startChunkIndex: -1,
            currentChunkIndex: -1,
            endChunkExclusive: -1,
            initialByteSkip: 0,
            isUrgent: true,
            isRescue: false,
            laneIndex: laneIdx,
            task: task,
            lastByteTimestamp: now,
            chunkStartTimestamp: now
        )
    }

    func spawnChunkFetchLocked(
        index: Int,
        isUrgent: Bool,
        isRescue: Bool,
        initialByteSkip: Int = 0,
        excludeLane: Int? = nil,
        singleChunkMicroHedge: Bool = false
    ) {
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
        let inSingleClickSeekSprint = !singleStreamMode
            && recentSeekStreakCount <= 1
            && lastSeekUptime > 0
            && (now - lastSeekUptime) < 1.2
            && aheadFromCursor < 8
        let maxSpanChunks: Int = {
            if singleChunkMicroHedge { return 1 }                             // 512 KiB exact blocked-reader micro-hedge
            if index == 0 && !chunk0HeadersReceived { return 2 }              // 1 MiB Chunk 0..1 head probe (commits Chunk 0 progressively at 512 KiB)
            if inOpenProbePhase && (index == 1 || index == 2) { return 2 }    // 1 MiB Chunk 2..3 parallel open head runway
            if inOpenProbePhase && index == resumeAnchorStartChunk { return 3 } // 1.5 MiB speculative resume/intro-skip anchor
            if isRescue { return 2 }                                          // 1 MiB fast rescue span
            if singleStreamMode && index > 0 {
                let singleDesired = measuredWireSpeedMBs >= 5.0 ? 48 : (measuredWireSpeedMBs >= 2.0 ? 32 : 16)
                return min(singleDesired, min(64, max(2, prefetchAheadChunks)))
            }
            if inSingleClickSeekSprint {
                return safeSkip >= 262_144 ? 3 : 2                            // 1 MiB fine-grained 2-chunk stripes across warm lanes on single seek
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
        let allowSpeculativeOpenSpan = (inOpenProbePhase && (index == 1 || index == 2) && redirectResolved && dynamicConcurrencyCap >= 2)
        if meta.totalSize > 0 || allowSpeculativeOpenSpan {
            let totalChunks = meta.totalSize > 0 ? meta.totalChunks : max(4, index + maxSpanChunks)
            let horizonChunk = (index == 0 && !chunk0HeadersReceived)
                ? totalChunks
                : (Int(max(0, cursorOffset) / Int64(chunkSize)) + prefetchAheadChunks + 1)
            let spanBound = ((isUrgent && !singleStreamMode) || isRescue || index == 0 || allowSpeculativeOpenSpan) ? totalChunks : min(totalChunks, horizonChunk)
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
            return Int64(spanEnd) * Int64(chunkSize) - 1
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
        let (task, laneIdx) = TurboStreamingSessionHub.shared.startTask(
            request: req,
            context: ctx,
            priority: taskPriority,
            excludeLane: excludeLane
        )
        activeAttempts[attemptId] = ActiveAttemptRecord(
            attemptId: attemptId,
            startChunkIndex: index,
            currentChunkIndex: index,
            endChunkExclusive: spanEnd,
            initialByteSkip: safeSkip,
            isUrgent: isUrgent,
            isRescue: isRescue,
            laneIndex: laneIdx,
            task: task,
            lastByteTimestamp: now,
            chunkStartTimestamp: now
        )
    }

    /// Launches parallel 1-RTT open fan-out across warm lanes once the direct/302 edge URL is known:
    /// Lane 1 -> Chunk 1..2 (1 MiB head runway), Lane 2 -> Exact EOF 512 KiB Cues, Lane 3 -> Resume Anchor (1.5 MiB).
    func launchOpenParallelFanOutLocked() {
        maybePrefetchOpenHeadRunwayLocked()
        maybePrefetchOpenProbeTailLocked()
        maybePrefetchResumeAnchorLocked()
    }

    func maybePrefetchOpenHeadRunwayLocked() {
        guard inOpenProbePhase,
              !didTriggerOpenHeadRunwayPrefetch,
              (redirectResolved || chunk0HeadersReceived),
              dynamicConcurrencyCap >= 2,
              !isAborted,
              !isClosed else { return }
        let meta = store.currentMeta()
        let runwayStart = (!store.hasChunk(1) && !inFlightChunks.contains(1)) ? 1 : 2
        if meta.totalSize > 0 && meta.totalChunks <= runwayStart + 1 { return }
        if dynamicConcurrencyCap == 2, meta.totalSize > Int64(meta.chunkSize * 4) {
            let eofStart = max(0, meta.totalSize - 524_288)
            let eofChunk = Int(eofStart / Int64(max(1, meta.chunkSize)))
            if !store.hasChunk(eofChunk) && !chunk0HeadersReceived {
                return
            }
        }
        didTriggerOpenHeadRunwayPrefetch = true
        guard !store.hasChunk(runwayStart) && !inFlightChunks.contains(runwayStart) else { return }
        let lane0ToExclude = activeAttempts.values.first(where: { $0.startChunkIndex == 0 })?.laneIndex
        let now = ProcessInfo.processInfo.systemUptime
        inFlightChunks.insert(runwayStart)
        chunkStartTime[runwayStart] = now
        spawnChunkFetchLocked(index: runwayStart, isUrgent: true, isRescue: false, excludeLane: lane0ToExclude)
    }

    func maybePrefetchOpenProbeTailLocked() {
        guard inOpenProbePhase, !didTriggerProbeTailPrefetch, dynamicConcurrencyCap >= 2, !isAborted, !isClosed else { return }
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let totalChunks = meta.totalChunks
        guard totalChunks > 3, meta.totalSize > Int64(chunkSize * 3) else { return }
        // Tail-First Cues Sprint: fetch ONLY the exact final 512 KiB ([max(0, totalSize - 512 KiB), totalSize - 1])
        // so 95%+ MKV Cues / MP4 moov arrive in <120ms without crawling through 1.5+ MiB of preceding tail video clusters.
        let exactTailLength: Int64 = min(524_288, meta.totalSize)
        let tailStartOffset = max(Int64(chunkSize * 2), meta.totalSize - exactTailLength)
        let firstTailChunk = Int(tailStartOffset / Int64(chunkSize))
        let allExactTailCached = (tailStartOffset % Int64(chunkSize) == 0)
            && (firstTailChunk..<totalChunks).allSatisfy { store.hasChunk($0) }
        didTriggerProbeTailPrefetch = true
        if allExactTailCached {
            return
        }
        let fetchLen = meta.totalSize - tailStartOffset
        let alreadyCovered = directSlices.contains { $0.startOffset <= tailStartOffset && ($0.startOffset + Int64($0.data.count)) >= meta.totalSize }
            || directInFlightStarts.keys.contains { startOff in
                let endOff = directInFlightEndOffsets[startOff] ?? (startOff + fetchLen - 1)
                return startOff <= tailStartOffset && endOff >= meta.totalSize - 1
            }
        if !alreadyCovered && fetchLen > 0 {
            let lane0ToExclude = activeAttempts.values.first(where: { $0.startChunkIndex == 0 })?.laneIndex
            spawnDirectRangeFetchLocked(
                startOffset: tailStartOffset,
                totalSize: meta.totalSize,
                length: fetchLen,
                excludeLane: lane0ToExclude
            )
        }
    }

    /// Speculatively prefetches the estimated resume window in parallel with Chunk 0 & EOF Cues
    /// so cold resume playback collapses 3 serial RTTs (header -> Cues -> resume jump) into 1 RTT.
    func maybePrefetchResumeAnchorLocked() {
        guard inOpenProbePhase,
              !didTriggerResumeAnchorPrefetch,
              initialStartFraction > 0.005,
              dynamicConcurrencyCap >= 3,
              !isAborted,
              !isClosed else { return }
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let totalChunks = meta.totalChunks
        guard meta.totalSize > 0, chunkSize > 0, totalChunks > 12 else { return }
        let estChunk = Int(Int64(initialStartFraction * Double(meta.totalSize)) / Int64(chunkSize))
        let tailGuard = Self.tailProbeChunkCount(for: meta.totalSize)
        guard estChunk > 6, estChunk < totalChunks - tailGuard else { return }
        let anchorChunk = max(4, estChunk - 2)
        didTriggerResumeAnchorPrefetch = true
        resumeAnchorStartChunk = anchorChunk
        if store.hasChunk(anchorChunk) || inFlightChunks.contains(anchorChunk) {
            return
        }
        let lane0ToExclude = activeAttempts.values.first(where: { $0.startChunkIndex == 0 })?.laneIndex
        let now = ProcessInfo.processInfo.systemUptime
        inFlightChunks.insert(anchorChunk)
        chunkStartTime[anchorChunk] = now
        spawnChunkFetchLocked(index: anchorChunk, isUrgent: true, isRescue: false, excludeLane: lane0ToExclude)
    }

    private func recordResolvedRedirectLocked(finalURL: URL, originURL: URL) -> URL? {
        guard finalURL.absoluteString != originURL.absoluteString,
              finalURL.absoluteString != streamURL.absoluteString else {
            return nil
        }
        redirectResolved = true
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
            launchOpenParallelFanOutLocked()
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
            rec.responseHeadersReceived = true
            activeAttempts[attemptId] = rec
        }
        if index == 0 {
            chunk0HeadersReceived = true
            redirectResolved = true
        }
        let notifyRedirectURL = finalURL.flatMap { recordResolvedRedirectLocked(finalURL: $0, originURL: originURL) }
        if index == 0 {
            launchOpenParallelFanOutLocked()
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

        wireSpeedMeter.recordBytes(delta.count, at: now)
        let smoothWire = wireSpeedMeter.speedMBs(at: now)
        if smoothWire > 0.05 {
            measuredWireSpeedMBs = smoothWire
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
        wireSpeedMeter.recordBytes(delta.count, at: now)
        condition.broadcast()
        condition.unlock()
    }
}

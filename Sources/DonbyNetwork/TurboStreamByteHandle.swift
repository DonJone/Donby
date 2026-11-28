import Foundation
import DonbyCore
import DonbyKernelC

private func dkTurboBridgeReadCB(_ opaque: UnsafeMutableRawPointer?, _ buf: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buf, size > 0 else { return -1 }
    return Int32(Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeUnretainedValue().read(into: buf, count: Int(size)))
}

private func dkTurboBridgeSeekCB(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
}

private func dkTurboBridgeAbortCB(_ opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    Unmanaged<TurboStreamByteHandle>.fromOpaque(opaque).takeUnretainedValue().abort()
}

// MARK: - Custom AVIO Byte-Stream Handle

public final class TurboStreamByteHandle: @unchecked Sendable {
    public let assetKey: String
    public let streamURL: URL
    public let headers: [String: String]
    public let store: TieredAssetChunkStore
    let onResolvedRedirectURL: (@Sendable (URL) -> Void)?
    let onInvalidatedRedirectURL: (@Sendable () -> Void)?

    let condition = NSCondition()
    var cursorOffset: Int64 = 0
    var isAborted: Bool = false
    var isClosed: Bool = false
    var effectiveStreamURL: URL? = nil
    var effectiveRedirectEpoch: UInt64 = 0
    var didNotifyRedirectCallback: Bool = false
    var redirectResolved: Bool = false

    var inOpenProbePhase: Bool = true
    var chunk0HeadersReceived: Bool = false
    var didTriggerOpenHeadRunwayPrefetch: Bool = false
    var didTriggerProbeTailPrefetch: Bool = false
    var didTriggerResumeAnchorPrefetch: Bool = false
    var resumeAnchorStartChunk: Int = -1
    let initialStartFraction: Double
    let openedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var lastSeekUptime: TimeInterval = 0
    var recentSeekStreakCount: Int = 0
    var urgentWaitingChunk: Int? = nil
    var urgentWaitStartUptime: TimeInterval = 0
    var chunkFirstBlockedUptime: [Int: TimeInterval] = [:]
    var isMultiplexedProtocol: Bool = false

    var nextAttemptId: UInt64 = 1
    var shouldYieldReadHandler: (@Sendable () -> Bool)? = nil
    var inFlightChunks: Set<Int> = []
    var rescueChunks: Set<Int> = []
    var chunkStartTime: [Int: TimeInterval] = [:]
    var chunkNextRetryTime: [Int: TimeInterval] = [:]
    var chunk429Retries: [Int: Int] = [:]
    var failedCount: [Int: Int] = [:]
    var configuredConcurrencyBudget: Int
    var dynamicConcurrencyCap: Int
    var prefetchAheadChunks: Int
    var last429BackoffUntil: TimeInterval = 0
    var last429StepDownUptime: TimeInterval = 0
    var cleanSuccessesSinceLast429: Int = 0
    var measuredWireSpeedMBs: Double = 0.0
    var smoothedResponseTTFB: TimeInterval = 0.6
    let wireSpeedMeter = SlidingWindowSpeedMeter(windowDuration: 2.5, bucketDuration: 0.10)
    var lastStallLogUptime: TimeInterval = 0

    struct ActiveAttemptRecord {
        let attemptId: UInt64
        let startChunkIndex: Int
        var currentChunkIndex: Int
        var endChunkExclusive: Int
        let initialByteSkip: Int
        let isUrgent: Bool
        let isRescue: Bool
        let laneIndex: Int
        weak var task: URLSessionDataTask?
        var lastByteTimestamp: TimeInterval
        var chunkStartTimestamp: TimeInterval
        var responseHeadersReceived: Bool = false
        var trimmedEarly: Bool = false

        var chunkIndex: Int { currentChunkIndex }

        func covers(_ idx: Int, offsetInChunk: Int = 0) -> Bool {
            guard idx >= currentChunkIndex && idx < endChunkExclusive else { return false }
            if idx == startChunkIndex && initialByteSkip > 0 {
                return offsetInChunk >= initialByteSkip
            }
            return true
        }
    }

    var activeAttempts: [UInt64: ActiveAttemptRecord] = [:]
    var attemptBuffers: [UInt64: Data] = [:]
    var activeDisplayAttempt: [Int: UInt64] = [:]
    var directSlices: [(startOffset: Int64, data: Data)] = []
    var directInFlightStarts: [Int64: UInt64] = [:]
    var directInFlightEndOffsets: [Int64: Int64] = [:]
    var directFailedStarts: [Int64: Int] = [:]
    var direct429Retries: [Int64: Int] = [:]
    var directNextRetryTime: [Int64: TimeInterval] = [:]
    var directHedgedOffsets: Set<Int64> = []

    var coordinatorTask: Task<Void, Never>?
    public private(set) var rawBridge: OpaquePointer? = nil

    func attemptBufferedCount(_ attemptId: UInt64) -> Int {
        let swiftCount = attemptBuffers[attemptId]?.count ?? 0
        guard let rawBridge else { return swiftCount }
        return max(swiftCount, Int(dk_net_bridge_attempt_buffered_bytes(rawBridge, attemptId)))
    }

    public init(
        assetKey: String,
        streamURL: URL,
        initialRedirectedURL: URL? = nil,
        headers: [String: String],
        store: TieredAssetChunkStore,
        knownTotalSize: Int64? = nil,
        connectionBudget: Int = 4,
        prefetchAheadChunks: Int = 72,
        initialStartSeconds: Double = 0,
        knownDurationSeconds: Double = 0,
        onResolvedRedirectURL: (@Sendable (URL) -> Void)? = nil,
        onInvalidatedRedirectURL: (@Sendable () -> Void)? = nil
    ) {
        self.assetKey = assetKey
        self.streamURL = streamURL
        if initialStartSeconds > 5.0 && knownDurationSeconds > 10.0 {
            self.initialStartFraction = max(0.0, min(0.98, initialStartSeconds / knownDurationSeconds))
        } else {
            self.initialStartFraction = 0.0
        }
        if let initialRedirectedURL, initialRedirectedURL.absoluteString != streamURL.absoluteString {
            self.effectiveStreamURL = initialRedirectedURL
            self.effectiveRedirectEpoch = 1
        }
        let pathLower = streamURL.path.lowercased()
        let looksLikeOriginRedirectEndpoint = pathLower.contains("/emby/") || pathLower.contains("/videos/") || pathLower.contains("/play/video/")
        self.redirectResolved = (self.effectiveStreamURL != nil) || !looksLikeOriginRedirectEndpoint
        self.isMultiplexedProtocol = TurboStreamingSessionHub.shared.isHostKnownMultiplexed(initialRedirectedURL ?? streamURL)
        self.headers = headers
        self.store = store
        let clampedBudget = max(1, min(TurboStreamingSessionHub.maxStreamLaneCount, connectionBudget))
        self.configuredConcurrencyBudget = clampedBudget
        self.dynamicConcurrencyCap = clampedBudget
        self.prefetchAheadChunks = max(4, min(360, prefetchAheadChunks))
        self.onResolvedRedirectURL = onResolvedRedirectURL
        self.onInvalidatedRedirectURL = onInvalidatedRedirectURL

        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }
        let hasChunk0 = store.hasChunk(0)
        if hasChunk0 {
            self.chunk0HeadersReceived = true
        }
        store.retainReader()
        self.rawBridge = dk_net_bridge_create(
            store.rawStore,
            Unmanaged.passUnretained(self).toOpaque(),
            dkTurboBridgeReadCB,
            dkTurboBridgeSeekCB,
            dkTurboBridgeAbortCB,
            nil
        )
        dk_net_update_playback_companion_state(1, 0, true, false, false, 0, store.currentMeta().estimatedBitrateBps)

        // Immediately start Chunk 0 (or urgent Chunk 1 when Chunk 0 is already warm on disk/L1 so warm-header
        // opens don't stall after exhausting Chunk 0's ~1.5s payload on high-TTFB edges).
        if !hasChunk0 {
            requestUrgentChunk(0)
        } else if !store.hasChunk(1) {
            requestUrgentChunk(1)
        }
        if self.redirectResolved || hasChunk0 {
            condition.lock()
            launchOpenParallelFanOutLocked()
            condition.unlock()
        }
        startCoordinatorLoop()
    }

    deinit {
        close()
        if let rawBridge {
            dk_net_bridge_release(rawBridge)
            self.rawBridge = nil
        }
    }

    public var currentWireSpeedMBs: Double {
        wireSpeedMeter.speedMBs()
    }

    public func updateTuning(connectionBudget: Int, prefetchAheadChunks: Int) {
        condition.lock()
        let clampedBudget = max(1, min(8, connectionBudget))
        self.configuredConcurrencyBudget = clampedBudget
        self.dynamicConcurrencyCap = clampedBudget
        self.prefetchAheadChunks = max(4, min(360, prefetchAheadChunks))
        condition.broadcast()
        condition.unlock()
        _ = stepBulkPrefetchSchedule()
    }

    /// Registers a lock-free kernel predicate queried during blocking reads so superseded pre-seek reads yield immediately without racing new seeks.
    public func setShouldYieldReadHandler(_ handler: (@Sendable () -> Bool)?) {
        condition.lock()
        shouldYieldReadHandler = handler
        condition.broadcast()
        condition.unlock()
    }

    /// Wakes any blocked read so it re-evaluates `shouldYieldReadHandler` immediately after a seek request.
    public func wakeWaitingReads() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    private func shouldYieldReadAtOffsetLocked(_ offset: Int64, totalSize: Int64, chunkSize: Int) -> Bool {
        if isAborted || isClosed { return true }
        // Never abort a near-tail container index read (e.g. 64+ KB..2 MiB Matroska Cues at the end of a 4K Remux)
        // on an intermediate seek, because FFmpeg sets `cues_parsing_deferred = 0` before reading Cues.
        let tailChunks = Self.tailProbeChunkCount(for: totalSize)
        if totalSize > Int64(chunkSize * (tailChunks + 2)) && offset >= totalSize - Int64(chunkSize * tailChunks) {
            return false
        }
        return shouldYieldReadHandler?() ?? false
    }

    static func tailProbeChunkCount(for totalSize: Int64) -> Int {
        totalSize > 4_294_967_296 ? 4 : 2
    }

    /// Signals that FFmpeg header/stream probing has finished so full multi-connection lookahead may engage.
    public func markInitialOpenCompleted() {
        condition.lock()
        if inOpenProbePhase {
            inOpenProbePhase = false
            condition.broadcast()
        }
        condition.unlock()
        if let rawBridge { dk_net_bridge_set_in_open_probe(rawBridge, false) }
        _ = stepBulkPrefetchSchedule()
    }

    /// Synchronous read entry point called by FFmpeg `AVIOContext.read_packet` on `demux_thread`.
    public func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        condition.lock()
        if isAborted || isClosed {
            condition.unlock()
            return -1
        }
        if let rawBridge {
            let nativeCursor = dk_net_bridge_get_cursor(rawBridge)
            if nativeCursor != cursorOffset { cursorOffset = nativeCursor }
        }
        let currentOffset = cursorOffset
        condition.unlock()

        let meta = store.currentMeta()
        if meta.totalSize > 0 && currentOffset >= meta.totalSize {
            return 0 // EOF
        }

        let chunkSize = meta.chunkSize
        let targetChunk = Int(currentOffset / Int64(chunkSize))
        let offsetInChunk = Int(currentOffset % Int64(chunkSize))

        // Fast path 1: completed chunk already in L1 SlabPool or L2 media.bin (zero-alloc pread)
        let nFast = store.readChunkBytes(index: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count)
        if nFast > 0 {
            condition.lock()
            cursorOffset += Int64(nFast)
            let updatedCursor = cursorOffset
            condition.unlock()
            if let rawBridge { dk_net_bridge_set_cursor(rawBridge, updatedCursor) }
            store.evictBehindCursor(cursorChunk: targetChunk)
            return nFast
        }

        // Fast path 2: progressive bytes already streamed into active partial buffer or direct exact-offset slice
        if let partialCopied = tryCopyPartialOrDirectLockedOut(currentOffset: currentOffset, targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
            return partialCopied
        }

        // Fast path 3: exact-offset EOF tail read (bypasses slow multi-MiB crawl when probing Cues/moov)
        let tailWindowBytes: Int64 = Int64(Self.tailProbeChunkCount(for: meta.totalSize)) * Int64(chunkSize)
        if meta.totalSize > 0, currentOffset >= meta.totalSize - tailWindowBytes {
            condition.lock()
            if let copied = tryCopyDirectTailLocked(at: currentOffset, into: buffer, count: count) {
                condition.unlock()
                return copied
            }
            let hasDirectInFlight = directInFlightStarts.keys.contains { startOff in
                let endOff = directInFlightEndOffsets[startOff] ?? (startOff + tailWindowBytes - 1)
                return startOff <= currentOffset && currentOffset <= endOff
            }
            let chunkInFlight = inFlightChunks.contains(targetChunk)
            let probePhase = inOpenProbePhase
            condition.unlock()
            if hasDirectInFlight || probePhase || (offsetInChunk >= 16_384 && !chunkInFlight) {
                return readDirectTailRange(at: currentOffset, totalSize: meta.totalSize, into: buffer, count: count)
            }
        }

        condition.lock()
        if shouldYieldReadAtOffsetLocked(currentOffset, totalSize: meta.totalSize, chunkSize: chunkSize) {
            condition.unlock()
            return -1
        }
        condition.unlock()

        // Urgent path: trigger urgent streaming fetch (with exact-offset zero-waste skip when unaligned) & wake coordinator
        requestUrgentChunk(targetChunk, offsetInChunk: offsetInChunk)

        let waitStart = ProcessInfo.processInfo.systemUptime
        let hardDeadline = Date().addingTimeInterval(26.0)
        var stallDeadline = Date().addingTimeInterval(15.0)
        condition.lock()
        let firstBlockedStart = chunkFirstBlockedUptime[targetChunk] ?? waitStart
        chunkFirstBlockedUptime[targetChunk] = firstBlockedStart
        urgentWaitingChunk = targetChunk
        urgentWaitStartUptime = firstBlockedStart
        while !shouldYieldReadAtOffsetLocked(currentOffset, totalSize: meta.totalSize, chunkSize: chunkSize) {
            if let partialCopied = tryCopyPartialLocked(targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                clearUrgentWaitLocked(for: targetChunk)
                condition.unlock()
                return partialCopied
            }
            if let directCopied = tryCopyDirectTailLocked(at: currentOffset, into: buffer, count: count) {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                clearUrgentWaitLocked(for: targetChunk)
                condition.unlock()
                return directCopied
            }
            if (failedCount[targetChunk] ?? 0) >= 6 || (chunk429Retries[targetChunk] ?? 0) >= 12 {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                clearUrgentWaitLocked(for: targetChunk)
                condition.unlock()
                return -1
            }
            let nowDate = Date()
            if nowDate >= stallDeadline || nowDate >= hardDeadline {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                clearUrgentWaitLocked(for: targetChunk)
                condition.unlock()
                return -1
            }
            let now = ProcessInfo.processInfo.systemUptime
            let coveringAttempt: ActiveAttemptRecord? = {
                if let dispId = activeDisplayAttempt[targetChunk], let rec = activeAttempts[dispId], rec.covers(targetChunk, offsetInChunk: offsetInChunk) {
                    return rec
                }
                return activeAttempts.values.first { $0.covers(targetChunk, offsetInChunk: offsetInChunk) }
            }()
            let partialBytes = coveringAttempt.map { attemptBufferedCount($0.attemptId) } ?? 0
            let headersArrived = coveringAttempt?.responseHeadersReceived ?? false
            let receivedAnyBytes = headersArrived || (partialBytes > 0) || (coveringAttempt.map { $0.currentChunkIndex > $0.startChunkIndex } ?? false)
            let stalledTime: TimeInterval = coveringAttempt.map { now - $0.lastByteTimestamp } ?? (chunkStartTime[targetChunk].map { now - $0 } ?? 0)
            if (partialBytes > 0 || (coveringAttempt.map { $0.currentChunkIndex > $0.startChunkIndex } ?? false)) && stalledTime < 2.5 {
                stallDeadline = min(hardDeadline, nowDate.addingTimeInterval(12.0))
            }
            // If no active stream covers (targetChunk, offsetInChunk) closely, trigger a direct urgent stream right at currentOffset.
            let hasNearbyCoveringStream = activeAttempts.values.contains {
                $0.covers(targetChunk, offsetInChunk: offsetInChunk) && (targetChunk - $0.currentChunkIndex <= 3)
            }
            if !hasNearbyCoveringStream,
               now >= (chunkNextRetryTime[targetChunk] ?? 0) {
                let desiredSkip = computeInitialByteSkipLocked(chunkIndex: targetChunk, offsetInChunk: offsetInChunk)
                inFlightChunks.insert(targetChunk)
                chunkStartTime[targetChunk] = now
                spawnChunkFetchLocked(index: targetChunk, isUrgent: true, isRescue: false, initialByteSkip: desiredSkip)
                condition.unlock()
                let nFast1 = store.readChunkBytes(index: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count)
                if nFast1 > 0 {
                    condition.lock()
                    clearUrgentWaitLocked(for: targetChunk)
                    cursorOffset += Int64(nFast1)
                    let updated = cursorOffset
                    condition.unlock()
                    if let rawBridge { dk_net_bridge_set_cursor(rawBridge, updated) }
                    return nFast1
                }
                condition.lock()
                continue
            }

            // Blocked-Reader Micro-Hedge & Adaptive TTFB Rescue:
            if now >= last429BackoffUntil && !rescueChunks.contains(targetChunk), let cov = coveringAttempt {
                let cumulativeChunkWait = now - (chunkFirstBlockedUptime[targetChunk] ?? waitStart)
                let activeHost = (effectiveStreamURL ?? streamURL).host
                var shouldMicroHedge = false
                if dynamicConcurrencyCap > 1 && cov.currentChunkIndex == targetChunk && receivedAnyBytes && cumulativeChunkWait >= 0.30 {
                    let expectedLen = store.expectedChunkLength(for: targetChunk)
                    let skip = (cov.currentChunkIndex == cov.startChunkIndex) ? cov.initialByteSkip : 0
                    let remBytes = max(0, expectedLen - skip - partialBytes)
                    let transferElapsed = max(0.05, now - cov.chunkStartTimestamp)
                    let rateBps = Double(partialBytes) / transferElapsed
                    let predictedRemSec = Double(remBytes) / max(1.0, rateBps)
                    if predictedRemSec > 0.35 || stalledTime > 1.1 {
                        shouldMicroHedge = true
                    }
                } else if dynamicConcurrencyCap > 1 && !receivedAnyBytes {
                    let hasFastAlt = TurboStreamingSessionHub.shared.hasVerifiedFastAlternateLane(forHost: activeHost, excludingLane: cov.laneIndex)
                    let coldThreshold = hasFastAlt
                        ? max(0.95, smoothedResponseTTFB * 1.4)
                        : max(2.2, min(4.5, smoothedResponseTTFB * 2.5))
                    if cumulativeChunkWait > coldThreshold || stalledTime > coldThreshold {
                        shouldMicroHedge = true
                    }
                } else {
                    let coldRescueThreshold: TimeInterval = max(2.2, min(4.5, smoothedResponseTTFB * 2.5))
                    let rescueThreshold: TimeInterval = receivedAnyBytes ? 1.5 : coldRescueThreshold
                    let allowSingleRescue = !receivedAnyBytes || stalledTime > 2.5
                    if allowSingleRescue && stalledTime > rescueThreshold {
                        shouldMicroHedge = true
                    }
                }

                if shouldMicroHedge && activeAttempts.count < dynamicConcurrencyCap + 1 {
                    trimSlowAttemptTailLocked(attemptId: cov.attemptId)
                    let desiredSkip = computeInitialByteSkipLocked(chunkIndex: targetChunk, offsetInChunk: offsetInChunk)
                    let stalledLane = cov.laneIndex
                    rescueChunks.insert(targetChunk)
                    chunkStartTime[targetChunk] = now
                    spawnChunkFetchLocked(
                        index: targetChunk,
                        isUrgent: true,
                        isRescue: true,
                        initialByteSkip: desiredSkip,
                        excludeLane: stalledLane,
                        singleChunkMicroHedge: true
                    )
                    if stalledTime > 1.5 {
                        TurboStreamingSessionHub.shared.reportLaneStall(laneIndex: stalledLane)
                    }
                }
            }

            condition.wait(until: Date().addingTimeInterval(0.025))
            condition.unlock()
            let nFast2 = store.readChunkBytes(index: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count)
            if nFast2 > 0 {
                condition.lock()
                if ProcessInfo.processInfo.systemUptime - waitStart >= 1.0 {
                    logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                }
                clearUrgentWaitLocked(for: targetChunk)
                cursorOffset += Int64(nFast2)
                let updated = cursorOffset
                condition.unlock()
                if let rawBridge { dk_net_bridge_set_cursor(rawBridge, updated) }
                return nFast2
            }
            let curMeta = store.currentMeta()
            if curMeta.totalSize > 0 && currentOffset >= curMeta.totalSize {
                condition.lock()
                clearUrgentWaitLocked(for: targetChunk)
                condition.unlock()
                return 0
            }
            condition.lock()
        }
        clearUrgentWaitLocked(for: targetChunk)
        condition.unlock()
        return -1
    }

    private func clearUrgentWaitLocked(for targetChunk: Int) {
        if urgentWaitingChunk == targetChunk {
            urgentWaitingChunk = nil
            urgentWaitStartUptime = 0
        }
    }

    private func logSlowReadIfNeededLocked(chunk: Int, waitStart: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let waitSec = now - waitStart
        guard waitSec >= 1.0, now - lastStallLogUptime >= 3.0 else { return }
        lastStallLogUptime = now
        DonbyLogger.shared.log(
            "Turbo 读取等待较久 (chunk=\(chunk), wait=\(Int(waitSec * 1000))ms, wire=\(String(format: "%.2f", measuredWireSpeedMBs))MB/s, ttfb=\(Int(smoothedResponseTTFB * 1000))ms, inFlight=\(activeAttempts.count), cap=\(dynamicConcurrencyCap))",
            level: .warning,
            subsystem: "TurboCache"
        )
    }

    func computeInitialByteSkipLocked(chunkIndex: Int, offsetInChunk: Int) -> Int {
        guard chunkIndex > 0, offsetInChunk >= 65_536 else { return 0 }
        let expectedLen = store.expectedChunkLength(for: chunkIndex)
        guard expectedLen > 0, offsetInChunk < expectedLen - 16_384 else { return 0 }
        return offsetInChunk
    }

    func copySlice(_ data: Data, offset: Int, into buffer: UnsafeMutablePointer<UInt8>, maxCount: Int) -> Int {
        let toCopy = min(maxCount, data.count - offset)
        guard toCopy > 0 else { return 0 }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                buffer.update(from: base.advanced(by: offset), count: toCopy)
            }
        }
        return toCopy
    }

    private func readDirectTailRange(
        at offset: Int64,
        totalSize: Int64,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int {
        let deadline = Date().addingTimeInterval(15.0)
        condition.lock()
        while !isAborted && !isClosed {
            if let copied = tryCopyDirectTailLocked(at: offset, into: buffer, count: count) {
                condition.unlock()
                return copied
            }
            if (directFailedStarts[offset] ?? 0) >= 5 || (direct429Retries[offset] ?? 0) >= 10 || Date() >= deadline {
                condition.unlock()
                return -1
            }
            let now = ProcessInfo.processInfo.systemUptime
            let activeHost = (effectiveStreamURL ?? streamURL).host
            var slowCoveringLane: Int? = nil
            var stalledDirectLane: Int? = nil
            let coveredSoonByInFlight = directInFlightStarts.contains { (startOff, aid) in
                let endOff = directInFlightEndOffsets[startOff] ?? (startOff + 524_287)
                guard startOff <= offset && offset <= endOff else { return false }
                let rec = activeAttempts[aid]
                let received = Int64(attemptBuffers[aid]?.count ?? 0)
                let dist = offset - (startOff + received)
                let byteIdle = now - (rec?.lastByteTimestamp ?? now)
                let hasHeaders = rec?.responseHeadersReceived ?? false
                let hasFastAlt = TurboStreamingSessionHub.shared.hasVerifiedFastAlternateLane(forHost: activeHost, excludingLane: rec?.laneIndex)
                let coldThreshold = hasFastAlt ? max(1.2, smoothedResponseTTFB * 1.6) : max(2.0, min(4.0, smoothedResponseTTFB * 2.5))
                let isStalled = (received == 0 && !hasHeaders && byteIdle > coldThreshold) || ((received > 0 || hasHeaders) && byteIdle > 2.5)
                if !isStalled && (dist <= 196_608 || dynamicConcurrencyCap <= 1) {
                    return true
                }
                slowCoveringLane = rec?.laneIndex
                if isStalled { stalledDirectLane = rec?.laneIndex }
                return false
            }
            let canHedgeStalled = directInFlightStarts[offset] != nil
                && !directHedgedOffsets.contains(offset)
                && dynamicConcurrencyCap > 1
                && now >= last429BackoffUntil
                && activeAttempts.count < dynamicConcurrencyCap + 1
            if now >= (directNextRetryTime[offset] ?? 0),
               !coveredSoonByInFlight,
               (directInFlightStarts[offset] == nil || canHedgeStalled) {
                if directInFlightStarts[offset] != nil {
                    directHedgedOffsets.insert(offset)
                }
                let exactTailLen = max(65_536, min(524_288, totalSize - offset))
                spawnDirectRangeFetchLocked(
                    startOffset: offset,
                    totalSize: totalSize,
                    length: exactTailLen,
                    excludeLane: slowCoveringLane
                )
                if let lane = stalledDirectLane {
                    condition.unlock()
                    TurboStreamingSessionHub.shared.reportLaneStall(laneIndex: lane)
                    condition.lock()
                    continue
                }
            }
            condition.wait(until: Date().addingTimeInterval(0.025))
        }
        condition.unlock()
        return -1
    }

    func tryCopyDirectTailLocked(
        at offset: Int64,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
        for slice in directSlices where offset >= slice.startOffset {
            let rel = Int(offset - slice.startOffset)
            if rel < slice.data.count {
                let toCopy = copySlice(slice.data, offset: rel, into: buffer, maxCount: count)
                cursorOffset += Int64(toCopy)
                if let rawBridge { dk_net_bridge_set_cursor(rawBridge, cursorOffset) }
                condition.broadcast()
                return toCopy
            }
        }
        for (startOff, attemptId) in directInFlightStarts where offset >= startOff {
            if let buf = attemptBuffers[attemptId] {
                let rel = Int(offset - startOff)
                if rel < buf.count {
                    let toCopy = copySlice(buf, offset: rel, into: buffer, maxCount: count)
                    cursorOffset += Int64(toCopy)
                    if let rawBridge { dk_net_bridge_set_cursor(rawBridge, cursorOffset) }
                    condition.broadcast()
                    return toCopy
                }
            }
        }
        return nil
    }

    /// Synchronous seek entry point called by FFmpeg `AVIOContext.seek` on `demux_thread`.
    public func seek(offset: Int64, whence: Int32) -> Int64 {
        let avSeekSizeFlag: Int32 = 0x10000
        let meta = store.currentMeta()

        if (whence & avSeekSizeFlag) != 0 {
            if meta.totalSize > 0 {
                return meta.totalSize
            }
            requestUrgentChunk(0)
            let waitUntil = Date().addingTimeInterval(6.0)
            condition.lock()
            while !isAborted && !isClosed && store.currentMeta().totalSize <= 0 && Date() < waitUntil {
                condition.wait(until: Date().addingTimeInterval(0.03))
            }
            condition.unlock()
            let updated = store.currentMeta().totalSize
            return updated > 0 ? updated : -1
        }

        let cleanWhence = whence & ~0x20000 // strip AVSEEK_FORCE
        condition.lock()
        let oldChunk = Int(max(0, cursorOffset) / Int64(meta.chunkSize))
        let total = store.currentMeta().totalSize
        let newPos: Int64
        switch cleanWhence {
        case SEEK_SET:
            newPos = offset
        case SEEK_CUR:
            newPos = cursorOffset + offset
        case SEEK_END:
            guard total > 0 else {
                condition.broadcast()
                condition.unlock()
                return -1
            }
            newPos = total + offset
        default:
            condition.broadcast()
            condition.unlock()
            return -1
        }
        guard newPos >= 0 else {
            condition.broadcast()
            condition.unlock()
            return -1
        }
        cursorOffset = (total > 0 && newPos > total) ? total : newPos
        if let rawBridge { dk_net_bridge_set_cursor(rawBridge, cursorOffset) }

        let newChunk = Int(max(0, cursorOffset) / Int64(meta.chunkSize))
        var tasksToCancel: [URLSessionDataTask] = []
        let totalChunks = total > 0 ? Int((total + Int64(meta.chunkSize) - 1) / Int64(meta.chunkSize)) : 0
        let tailProbeChunks = Self.tailProbeChunkCount(for: total)
        let isNearTailProbe = totalChunks > tailProbeChunks && newChunk >= totalChunks - tailProbeChunks
        let isReturningFromTailProbe = totalChunks > tailProbeChunks && oldChunk >= totalChunks - tailProbeChunks && newChunk <= 2
        let isContainerProbeSeek = isNearTailProbe || isReturningFromTailProbe
        if inOpenProbePhase && chunk0HeadersReceived && !isNearTailProbe && newChunk >= 4 {
            inOpenProbePhase = false
        }
        if abs(newChunk - oldChunk) > 2 {
            if !isContainerProbeSeek {
                let nowSeek = ProcessInfo.processInfo.systemUptime
                if lastSeekUptime > 0 && (nowSeek - lastSeekUptime) < 0.45 {
                    recentSeekStreakCount += 1
                } else {
                    recentSeekStreakCount = 1
                }
                lastSeekUptime = nowSeek
                chunkFirstBlockedUptime.removeAll()
            }
            let aggressiveKeepEnd = newChunk + min(prefetchAheadChunks, 24)
            var attemptIdsToPurge: [UInt64] = []
            for (aid, rec) in activeAttempts {
                if rec.currentChunkIndex == 0 && !store.hasChunk(0) {
                    // Always allow the 512 KiB Chunk 0 header to complete & persist to L2 disk so warm reopens
                    // start in <20ms, but trim any trailing chunks (1..<end) immediately when jumping away.
                    if !inOpenProbePhase && !isContainerProbeSeek && rec.endChunkExclusive > 1 {
                        for relIdx in 1..<rec.endChunkExclusive {
                            if activeDisplayAttempt[relIdx] == aid {
                                activeDisplayAttempt.removeValue(forKey: relIdx)
                            }
                            inFlightChunks.remove(relIdx)
                            rescueChunks.remove(relIdx)
                            chunkStartTime.removeValue(forKey: relIdx)
                        }
                        var trimmed = rec
                        trimmed.endChunkExclusive = 1
                        trimmed.trimmedEarly = true
                        activeAttempts[aid] = trimmed
                        if let rawBridge { dk_net_bridge_update_attempt_end(rawBridge, aid, 1) }
                    }
                    continue
                }
                if rec.startChunkIndex == 0 && inOpenProbePhase { continue }
                if rec.currentChunkIndex < 0 && (inOpenProbePhase || isContainerProbeSeek) { continue }
                if isContainerProbeSeek { continue }
                let coversTargetSoon = rec.covers(newChunk) && (newChunk - rec.currentChunkIndex <= 2)
                let inNearForwardWindow = (rec.currentChunkIndex >= newChunk && rec.currentChunkIndex <= aggressiveKeepEnd)
                if !coversTargetSoon && !inNearForwardWindow {
                    attemptIdsToPurge.append(aid)
                }
            }
            for aid in attemptIdsToPurge {
                if let removed = activeAttempts.removeValue(forKey: aid) {
                    if let task = removed.task {
                        tasksToCancel.append(task)
                    }
                    attemptBuffers.removeValue(forKey: aid)
                    if let rawBridge { dk_net_bridge_remove_attempt(rawBridge, aid) }
                    if removed.currentChunkIndex < 0 {
                        let matchingStarts = directInFlightStarts.compactMap { $0.value == aid ? $0.key : nil }
                        for sOff in matchingStarts {
                            directInFlightStarts.removeValue(forKey: sOff)
                            directInFlightEndOffsets.removeValue(forKey: sOff)
                            directHedgedOffsets.remove(sOff)
                        }
                    } else if removed.currentChunkIndex >= 0 {
                        for cIdx in removed.currentChunkIndex..<removed.endChunkExclusive {
                            if activeDisplayAttempt[cIdx] == aid {
                                activeDisplayAttempt.removeValue(forKey: cIdx)
                            }
                            if !activeAttempts.values.contains(where: { $0.covers(cIdx) }) {
                                inFlightChunks.remove(cIdx)
                                rescueChunks.remove(cIdx)
                                chunkStartTime.removeValue(forKey: cIdx)
                            }
                        }
                    }
                }
            }

            // Give the newly seeked target window a clean retry budget immediately
            let resetEnd = totalChunks > 0 ? min(max(newChunk, totalChunks - 1), newChunk + 8) : newChunk
            for c in newChunk...resetEnd {
                failedCount.removeValue(forKey: c)
                chunk429Retries.removeValue(forKey: c)
                chunkNextRetryTime.removeValue(forKey: c)
            }
        }
        let resultPos = cursorOffset
        condition.broadcast()
        condition.unlock()

        for task in tasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(task, intentional: true)
        }
        if abs(newChunk - oldChunk) > 48 && !isNearTailProbe {
            store.evictDistantChunks(aroundChunk: newChunk)
        }
        return resultPos
    }
}

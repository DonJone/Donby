import Foundation
import DonbyCore

// MARK: - Custom AVIO Byte-Stream Handle

public final class TurboStreamByteHandle: @unchecked Sendable {
    public let assetKey: String
    public let streamURL: URL
    public let headers: [String: String]
    public let store: TieredAssetChunkStore
    let onResolvedRedirectURL: (@Sendable (URL) -> Void)?

    let condition = NSCondition()
    var cursorOffset: Int64 = 0
    var isAborted: Bool = false
    var isClosed: Bool = false
    var effectiveStreamURL: URL? = nil
    var effectiveRedirectEpoch: UInt64 = 0
    var didNotifyRedirectCallback: Bool = false

    var inOpenProbePhase: Bool = true
    var chunk0HeadersReceived: Bool = false
    var didTriggerProbeTailPrefetch: Bool = false
    var didTriggerResumeAnchorPrefetch: Bool = false
    let initialStartFraction: Double
    let openedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var lastSeekUptime: TimeInterval = 0
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

    var coordinatorTask: Task<Void, Never>?

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
        onResolvedRedirectURL: (@Sendable (URL) -> Void)? = nil
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
        self.isMultiplexedProtocol = TurboStreamingSessionHub.shared.isHostKnownMultiplexed(initialRedirectedURL ?? streamURL)
        self.headers = headers
        self.store = store
        let clampedBudget = max(1, min(8, connectionBudget))
        self.configuredConcurrencyBudget = clampedBudget
        self.dynamicConcurrencyCap = clampedBudget
        self.prefetchAheadChunks = max(4, min(360, prefetchAheadChunks))
        self.onResolvedRedirectURL = onResolvedRedirectURL

        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }
        let hasChunk0 = store.hasChunk(0)
        if hasChunk0 {
            self.chunk0HeadersReceived = true
        }
        store.retainReader()

        // Immediately start Chunk 0 (or urgent Chunk 1 when Chunk 0 is already warm on disk/L1 so warm-header
        // opens don't stall after exhausting Chunk 0's ~1.5s payload on high-TTFB edges).
        if !hasChunk0 {
            requestUrgentChunk(0)
        } else if !store.hasChunk(1) {
            requestUrgentChunk(1)
        }
        let pathLower = streamURL.path.lowercased()
        let looksLikeOriginRedirectEndpoint = pathLower.contains("/emby/") || pathLower.contains("/videos/") || pathLower.contains("/play/video/")
        if self.effectiveStreamURL != nil || !looksLikeOriginRedirectEndpoint || hasChunk0 {
            condition.lock()
            maybePrefetchOpenProbeTailLocked()
            maybePrefetchResumeAnchorLocked()
            condition.unlock()
        }
        startCoordinatorLoop()
    }

    deinit {
        close()
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
        let currentOffset = cursorOffset
        condition.unlock()

        let meta = store.currentMeta()
        if meta.totalSize > 0 && currentOffset >= meta.totalSize {
            return 0 // EOF
        }

        let chunkSize = meta.chunkSize
        let targetChunk = Int(currentOffset / Int64(chunkSize))
        let offsetInChunk = Int(currentOffset % Int64(chunkSize))

        // Fast path 1: completed chunk already in L1 memory or L2 disk
        if let chunkData = store.readChunk(index: targetChunk) {
            return copyOut(from: chunkData, offsetInChunk: offsetInChunk, into: buffer, count: count, targetChunk: targetChunk)
        }

        // Fast path 2: progressive bytes already streamed into active partial buffer or direct exact-offset slice
        if let partialCopied = tryCopyPartialOrDirectLockedOut(currentOffset: currentOffset, targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
            return partialCopied
        }

        // Fast path 3: exact-offset unaligned EOF tail read (hit pre-fetched direct slices or wait for in-flight tail fetch)
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
            condition.unlock()
            if hasDirectInFlight || (offsetInChunk >= 16_384 && !chunkInFlight) {
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
        while !shouldYieldReadAtOffsetLocked(currentOffset, totalSize: meta.totalSize, chunkSize: chunkSize) {
            if let partialCopied = tryCopyPartialLocked(targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                condition.unlock()
                return partialCopied
            }
            if let directCopied = tryCopyDirectTailLocked(at: currentOffset, into: buffer, count: count) {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                condition.unlock()
                return directCopied
            }
            if (failedCount[targetChunk] ?? 0) >= 6 || (chunk429Retries[targetChunk] ?? 0) >= 12 {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                condition.unlock()
                return -1
            }
            let nowDate = Date()
            if nowDate >= stallDeadline || nowDate >= hardDeadline {
                logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
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
            let partialBytes = coveringAttempt.flatMap { attemptBuffers[$0.attemptId]?.count } ?? 0
            let receivedAnyBytes = (partialBytes > 0) || (coveringAttempt.map { $0.currentChunkIndex > $0.startChunkIndex } ?? false)
            let stalledTime: TimeInterval = coveringAttempt.map { now - $0.lastByteTimestamp } ?? (chunkStartTime[targetChunk].map { now - $0 } ?? 0)
            if receivedAnyBytes && stalledTime < 2.5 {
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
                if let chunkData = store.readChunk(index: targetChunk) {
                    return copyOut(from: chunkData, offsetInChunk: offsetInChunk, into: buffer, count: count, targetChunk: targetChunk)
                }
                condition.lock()
                continue
            }
            // Spawn a racing rescue request only when a stream genuinely stalls beyond adaptive CDN TTFB.
            let coldRescueThreshold: TimeInterval = max(2.2, min(4.5, smoothedResponseTTFB * 2.5))
            let rescueThreshold: TimeInterval = receivedAnyBytes ? 1.5 : coldRescueThreshold
            let allowRescue = dynamicConcurrencyCap > 1 || !receivedAnyBytes || stalledTime > 2.5
            if allowRescue &&
                now >= last429BackoffUntil &&
                (chunkStartTime[targetChunk] != nil) &&
                stalledTime > rescueThreshold &&
                !rescueChunks.contains(targetChunk) {
                let desiredSkip = computeInitialByteSkipLocked(chunkIndex: targetChunk, offsetInChunk: offsetInChunk)
                let stalledLane = coveringAttempt?.laneIndex
                rescueChunks.insert(targetChunk)
                chunkStartTime[targetChunk] = now
                spawnChunkFetchLocked(index: targetChunk, isUrgent: true, isRescue: true, initialByteSkip: desiredSkip, excludeLane: stalledLane)
                if let stalledLane {
                    TurboStreamingSessionHub.shared.reportLaneStall(laneIndex: stalledLane)
                }
            }
            condition.wait(until: Date().addingTimeInterval(0.03))
            condition.unlock()
            if let chunkData = store.readChunk(index: targetChunk) {
                if ProcessInfo.processInfo.systemUptime - waitStart >= 1.0 {
                    condition.lock()
                    logSlowReadIfNeededLocked(chunk: targetChunk, waitStart: waitStart)
                    condition.unlock()
                }
                return copyOut(from: chunkData, offsetInChunk: offsetInChunk, into: buffer, count: count, targetChunk: targetChunk)
            }
            let curMeta = store.currentMeta()
            if curMeta.totalSize > 0 && currentOffset >= curMeta.totalSize {
                return 0
            }
            condition.lock()
        }
        condition.unlock()
        return -1
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

    private func copySlice(_ data: Data, offset: Int, into buffer: UnsafeMutablePointer<UInt8>, maxCount: Int) -> Int {
        let toCopy = min(maxCount, data.count - offset)
        guard toCopy > 0 else { return 0 }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                buffer.update(from: base.advanced(by: offset), count: toCopy)
            }
        }
        return toCopy
    }

    private func tryCopyPartialOrDirectLockedOut(
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

    private func tryCopyPartialLocked(
        targetChunk: Int,
        offsetInChunk: Int,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
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

    private func copyOut(
        from chunkData: Data,
        offsetInChunk: Int,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int,
        targetChunk: Int
    ) -> Int {
        guard offsetInChunk < chunkData.count else {
            return 0
        }
        let toCopy = copySlice(chunkData, offset: offsetInChunk, into: buffer, maxCount: count)
        condition.lock()
        cursorOffset += Int64(toCopy)
        condition.broadcast()
        condition.unlock()

        if targetChunk % 16 == 0 {
            store.evictBehindCursor(cursorChunk: targetChunk, keepBackChunks: 16)
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
            let coveredByInFlight = directInFlightStarts.keys.contains { startOff in
                let endOff = directInFlightEndOffsets[startOff] ?? (startOff + 524_287)
                return startOff <= offset && offset <= endOff
            }
            if now >= (directNextRetryTime[offset] ?? 0),
               directInFlightStarts[offset] == nil,
               !coveredByInFlight {
                let remainingToEOF = max(262_144, min(2_097_152, totalSize - offset))
                spawnDirectRangeFetchLocked(startOffset: offset, totalSize: totalSize, length: remainingToEOF)
            }
            condition.wait(until: Date().addingTimeInterval(0.03))
        }
        condition.unlock()
        return -1
    }

    private func tryCopyDirectTailLocked(
        at offset: Int64,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
        for slice in directSlices where offset >= slice.startOffset {
            let rel = Int(offset - slice.startOffset)
            if rel < slice.data.count {
                let toCopy = copySlice(slice.data, offset: rel, into: buffer, maxCount: count)
                cursorOffset += Int64(toCopy)
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
                lastSeekUptime = ProcessInfo.processInfo.systemUptime
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
                    if removed.currentChunkIndex < 0 {
                        let matchingStarts = directInFlightStarts.compactMap { $0.value == aid ? $0.key : nil }
                        for sOff in matchingStarts {
                            directInFlightStarts.removeValue(forKey: sOff)
                            directInFlightEndOffsets.removeValue(forKey: sOff)
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
        chunk429Retries.removeAll()
        directSlices.removeAll()
        directInFlightStarts.removeAll()
        directInFlightEndOffsets.removeAll()
        directFailedStarts.removeAll()
        direct429Retries.removeAll()
        directNextRetryTime.removeAll()
        condition.broadcast()
        condition.unlock()

        coordinatorTask?.cancel()
        coordinatorTask = nil
        for task in tasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(task, intentional: true)
        }

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
}

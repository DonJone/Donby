import Foundation
import DonbyCore

// MARK: - Task B.4: Priority API Request Gate (Playback vs Normal Lanes)

public actor APIRequestGate {
    public static let shared = APIRequestGate()

    public enum Priority: Sendable {
        case normal
        case playback
    }

    private let totalLimit: Int = 10
    private let normalLimit: Int = 6
    private var activeTotal: Int = 0
    private var activeNormal: Int = 0
    private var playbackWaiters: [CheckedContinuation<Void, Never>] = []
    private var normalWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    public func acquire(priority: Priority) async {
        switch priority {
        case .playback:
            if activeTotal < totalLimit {
                activeTotal += 1
                return
            }
            await withCheckedContinuation { cont in
                playbackWaiters.append(cont)
            }
        case .normal:
            if activeTotal < totalLimit && activeNormal < normalLimit && playbackWaiters.isEmpty {
                activeTotal += 1
                activeNormal += 1
                return
            }
            await withCheckedContinuation { cont in
                normalWaiters.append(cont)
            }
        }
    }

    public func release(priority: Priority) {
        if priority == .normal {
            activeNormal = max(0, activeNormal - 1)
        }
        activeTotal = max(0, activeTotal - 1)

        if !playbackWaiters.isEmpty && activeTotal < totalLimit {
            activeTotal += 1
            let next = playbackWaiters.removeFirst()
            next.resume()
            return
        }

        if !normalWaiters.isEmpty && activeTotal < totalLimit && activeNormal < normalLimit {
            activeTotal += 1
            activeNormal += 1
            let next = normalWaiters.removeFirst()
            next.resume()
        }
    }

    public func withPermit<T: Sendable>(priority: Priority, operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(priority: priority)
        defer { release(priority: priority) }
        return try await operation()
    }
}

// MARK: - UHD Subscription & Emby Download / Concurrency Permission Models

public struct ServerDeliveryCapabilities: Codable, Equatable, Sendable {
    public var allowDownload: Bool
    public var activeVideoDeliveryLimit: Int
    public var planName: String?
    public var displayUnlimitedTraffic: Bool
    public var trafficLimitBytes: Int64?
    public var checkedAt: Date

    public init(
        allowDownload: Bool = true,
        activeVideoDeliveryLimit: Int = 4,
        planName: String? = nil,
        displayUnlimitedTraffic: Bool = true,
        trafficLimitBytes: Int64? = nil,
        checkedAt: Date = Date()
    ) {
        self.allowDownload = allowDownload
        self.activeVideoDeliveryLimit = max(1, activeVideoDeliveryLimit)
        self.planName = planName
        self.displayUnlimitedTraffic = displayUnlimitedTraffic
        self.trafficLimitBytes = trafficLimitBytes
        self.checkedAt = checkedAt
    }
}

// MARK: - Task C: ChunkStore Metadata & Disk/Memory Tiered Storage

public struct ChunkStoreMeta: Codable, Equatable, Sendable {
    public var assetKey: String
    public var totalSize: Int64
    public var chunkSize: Int
    public var completedChunks: Set<Int>
    public var lastAccess: Date
    public var pinned: Bool
    public var sourceURLString: String
    public var estimatedBitrateBps: Int64

    public init(
        assetKey: String,
        totalSize: Int64 = 0,
        chunkSize: Int = 1_048_576,
        completedChunks: Set<Int> = [],
        lastAccess: Date = Date(),
        pinned: Bool = false,
        sourceURLString: String = "",
        estimatedBitrateBps: Int64 = 25_000_000
    ) {
        self.assetKey = assetKey
        self.totalSize = totalSize
        self.chunkSize = max(65_536, chunkSize)
        self.completedChunks = completedChunks
        self.lastAccess = lastAccess
        self.pinned = pinned
        self.sourceURLString = sourceURLString
        self.estimatedBitrateBps = estimatedBitrateBps
    }

    public var totalChunks: Int {
        guard totalSize > 0, chunkSize > 0 else { return 0 }
        return Int((totalSize + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    public var isFullyCached: Bool {
        let total = totalChunks
        return total > 0 && completedChunks.count >= total
    }

    public var cachedBytes: Int64 {
        guard totalSize > 0 else {
            return Int64(completedChunks.count) * Int64(chunkSize)
        }
        let lastIdx = totalChunks - 1
        var bytes: Int64 = 0
        for idx in completedChunks {
            if idx == lastIdx {
                let rem = totalSize - Int64(lastIdx) * Int64(chunkSize)
                bytes += max(0, rem)
            } else {
                bytes += Int64(chunkSize)
            }
        }
        return min(totalSize, bytes)
    }
}

public final class TieredAssetChunkStore: @unchecked Sendable {
    public let assetKey: String
    public let assetDirectory: URL
    public let dataFileURL: URL
    public let metaFileURL: URL

    private let lock = NSLock()
    private var meta: ChunkStoreMeta
    private var memoryChunks: [Int: Data] = [:]
    private var memoryOrder: [Int] = []
    private var memoryBytes: Int = 0
    private var maxMemoryBytes: Int
    private var persistDisk: Bool
    private var readHandle: FileHandle?
    private var writeHandle: FileHandle?
    private var dirtyMetaOps: Int = 0

    public init(
        assetKey: String,
        rootDirectory: URL,
        chunkSize: Int = 1_048_576,
        maxMemoryBytes: Int = 524_288_000,
        persistDisk: Bool = true
    ) {
        self.assetKey = assetKey
        self.assetDirectory = rootDirectory.appendingPathComponent(assetKey, isDirectory: true)
        self.dataFileURL = assetDirectory.appendingPathComponent("media.bin")
        self.metaFileURL = assetDirectory.appendingPathComponent("meta.json")
        self.maxMemoryBytes = max(32 * 1024 * 1024, min(2_147_483_648, maxMemoryBytes))
        self.persistDisk = persistDisk

        try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metaFileURL),
           let loaded = try? JSONDecoder().decode(ChunkStoreMeta.self, from: data) {
            self.meta = loaded
        } else {
            self.meta = ChunkStoreMeta(assetKey: assetKey, chunkSize: chunkSize)
        }
        self.meta.lastAccess = Date()
    }

    deinit {
        flushMeta()
        try? readHandle?.close()
        try? writeHandle?.close()
    }

    public func currentMeta() -> ChunkStoreMeta {
        lock.lock()
        defer { lock.unlock() }
        return meta
    }

    public func updateConfiguration(maxMemoryBytes: Int, persistDisk: Bool) {
        lock.lock()
        self.maxMemoryBytes = max(32 * 1024 * 1024, min(2_147_483_648, maxMemoryBytes))
        self.persistDisk = persistDisk || meta.pinned
        evictMemoryLockedIfNeeded(incomingBytes: 0)
        lock.unlock()
    }

    public func setPinned(_ pinned: Bool) {
        lock.lock()
        meta.pinned = pinned
        if pinned {
            persistDisk = true
        }
        saveMetaLocked()
        lock.unlock()
    }

    public func setTotalSize(_ totalSize: Int64, sourceURL: String? = nil) {
        lock.lock()
        if totalSize > 0 && meta.totalSize != totalSize {
            meta.totalSize = totalSize
            if let sourceURL, !sourceURL.isEmpty {
                meta.sourceURLString = sourceURL
            }
            saveMetaLocked()
        }
        lock.unlock()
    }

    public func hasChunk(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if memoryChunks[index] != nil { return true }
        return meta.completedChunks.contains(index)
    }

    public func expectedChunkLength(for index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard meta.totalSize > 0 else { return meta.chunkSize }
        let start = Int64(index) * Int64(meta.chunkSize)
        if start >= meta.totalSize { return 0 }
        return Int(min(Int64(meta.chunkSize), meta.totalSize - start))
    }

    public func storeChunk(index: Int, data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        meta.lastAccess = Date()
        // 1. Store in L1 Memory cache
        if let prev = memoryChunks.removeValue(forKey: index) {
            memoryBytes = max(0, memoryBytes - prev.count)
            memoryOrder.removeAll { $0 == index }
        }
        evictMemoryLockedIfNeeded(incomingBytes: data.count)
        if data.count <= maxMemoryBytes {
            memoryChunks[index] = data
            memoryOrder.append(index)
            memoryBytes += data.count
        }

        // 2. Store in L2 Disk cache if enabled or pinned
        if persistDisk || meta.pinned {
            ensureFileHandlesLocked()
            if let wh = writeHandle {
                let offset = UInt64(index) * UInt64(meta.chunkSize)
                do {
                    try wh.seek(toOffset: offset)
                    try wh.write(contentsOf: data)
                    meta.completedChunks.insert(index)
                    dirtyMetaOps += 1
                    if dirtyMetaOps >= 8 || meta.isFullyCached {
                        dirtyMetaOps = 0
                        saveMetaLocked()
                    }
                } catch {
                    // Ignore transient disk write error and keep L1 memory copy
                }
            }
        }
    }

    public func readChunk(index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if let mem = memoryChunks[index] {
            return mem
        }
        guard meta.completedChunks.contains(index) else { return nil }
        ensureFileHandlesLocked()
        guard let rh = readHandle else { return nil }
        let offset = UInt64(index) * UInt64(meta.chunkSize)
        let len = expectedChunkLenLocked(index: index)
        guard len > 0 else { return nil }
        do {
            try rh.seek(toOffset: offset)
            if let data = try rh.read(upToCount: len), !data.isEmpty {
                // Promote into L1 memory cache
                evictMemoryLockedIfNeeded(incomingBytes: data.count)
                if data.count <= maxMemoryBytes {
                    memoryChunks[index] = data
                    memoryOrder.append(index)
                    memoryBytes += data.count
                }
                return data
            }
        } catch {
            meta.completedChunks.remove(index)
        }
        return nil
    }

    /// Sliding window eviction behind playhead cursor (skips disk eviction if `pinned == true`).
    public func evictBehindCursor(cursorChunk: Int, keepBackChunks: Int = 8) {
        lock.lock()
        defer { lock.unlock() }
        let threshold = cursorChunk - max(2, keepBackChunks)
        guard threshold > 0 else { return }

        let keysToRemove = memoryOrder.filter { $0 < threshold }
        for k in keysToRemove {
            if let removed = memoryChunks.removeValue(forKey: k) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
        if !keysToRemove.isEmpty {
            memoryOrder.removeAll { $0 < threshold }
        }
    }

    public func flushMeta() {
        lock.lock()
        saveMetaLocked()
        lock.unlock()
    }

    public func closeFileHandles() {
        lock.lock()
        saveMetaLocked()
        try? readHandle?.close()
        readHandle = nil
        try? writeHandle?.close()
        writeHandle = nil
        lock.unlock()
    }

    private func expectedChunkLenLocked(index: Int) -> Int {
        guard meta.totalSize > 0 else { return meta.chunkSize }
        let start = Int64(index) * Int64(meta.chunkSize)
        if start >= meta.totalSize { return 0 }
        return Int(min(Int64(meta.chunkSize), meta.totalSize - start))
    }

    private func evictMemoryLockedIfNeeded(incomingBytes: Int) {
        while memoryBytes + incomingBytes > maxMemoryBytes && !memoryOrder.isEmpty {
            let oldest = memoryOrder.removeFirst()
            if let removed = memoryChunks.removeValue(forKey: oldest) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
    }

    private func ensureFileHandlesLocked() {
        if !FileManager.default.fileExists(atPath: dataFileURL.path) {
            try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dataFileURL.path, contents: nil)
        }
        if writeHandle == nil {
            writeHandle = try? FileHandle(forWritingTo: dataFileURL)
        }
        if readHandle == nil {
            readHandle = try? FileHandle(forReadingFrom: dataFileURL)
        }
    }

    private func saveMetaLocked() {
        guard persistDisk || meta.pinned else { return }
        try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: metaFileURL, options: .atomic)
        }
    }
}

// MARK: - Task C: Multi-Connection Turbo Stream Session & Custom AVIO Byte Handle

public final class TurboStreamByteHandle: @unchecked Sendable {
    public let assetKey: String
    public let streamURL: URL
    public let headers: [String: String]
    public let store: TieredAssetChunkStore

    private let condition = NSCondition()
    private var cursorOffset: Int64 = 0
    private var isAborted: Bool = false
    private var isClosed: Bool = false
    private var inFlightChunks: Set<Int> = []
    private var rescueChunks: Set<Int> = []
    private var chunkStartTime: [Int: TimeInterval] = [:]
    private var failedCount: [Int: Int] = [:]
    private var activeBulkWorkers: Int = 0
    private var dynamicConcurrencyCap: Int
    private var prefetchAheadChunks: Int
    private var last429BackoffUntil: TimeInterval = 0
    private var measuredWireSpeedMBs: Double = 0.0
    private var recentWireBytes: Int64 = 0
    private var recentWireTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime

    private let urlSession: URLSession
    private var coordinatorTask: Task<Void, Never>?

    public init(
        assetKey: String,
        streamURL: URL,
        headers: [String: String],
        store: TieredAssetChunkStore,
        knownTotalSize: Int64? = nil,
        connectionBudget: Int = 4,
        prefetchAheadChunks: Int = 36
    ) {
        self.assetKey = assetKey
        self.streamURL = streamURL
        self.headers = headers
        self.store = store
        self.dynamicConcurrencyCap = max(1, min(8, connectionBudget))
        self.prefetchAheadChunks = max(8, min(240, prefetchAheadChunks))

        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 10
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 45
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: cfg)

        startCoordinatorLoop()
    }

    deinit {
        close()
    }

    public var currentWireSpeedMBs: Double {
        condition.lock()
        defer { condition.unlock() }
        return measuredWireSpeedMBs
    }

    public func updateTuning(connectionBudget: Int, prefetchAheadChunks: Int) {
        condition.lock()
        self.dynamicConcurrencyCap = max(1, min(8, connectionBudget))
        self.prefetchAheadChunks = max(8, min(240, prefetchAheadChunks))
        condition.broadcast()
        condition.unlock()
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

        // Ensure total size is known (or at least chunk 0 is fetched)
        let meta = store.currentMeta()
        if meta.totalSize > 0 && currentOffset >= meta.totalSize {
            return 0 // EOF
        }

        let chunkSize = meta.chunkSize
        let targetChunk = Int(currentOffset / Int64(chunkSize))
        let offsetInChunk = Int(currentOffset % Int64(chunkSize))

        // Fast path: chunk already in L1 memory or L2 disk
        if let chunkData = store.readChunk(index: targetChunk) {
            return copyOut(from: chunkData, offsetInChunk: offsetInChunk, into: buffer, count: count, targetChunk: targetChunk)
        }

        // Urgent path: trigger urgent fetch & wake coordinator
        requestUrgentChunk(targetChunk)

        let deadline = Date().addingTimeInterval(15.0)
        condition.lock()
        while !isAborted && !isClosed {
            condition.unlock()
            if let chunkData = store.readChunk(index: targetChunk) {
                return copyOut(from: chunkData, offsetInChunk: offsetInChunk, into: buffer, count: count, targetChunk: targetChunk)
            }
            let curMeta = store.currentMeta()
            if curMeta.totalSize > 0 && currentOffset >= curMeta.totalSize {
                return 0
            }
            condition.lock()
            if (failedCount[targetChunk] ?? 0) >= 4 {
                condition.unlock()
                return -1
            }
            if Date() >= deadline {
                condition.unlock()
                return -1
            }
            // Check if urgent chunk needs a racing rescue request after 2.4s stall
            let now = ProcessInfo.processInfo.systemUptime
            if let started = chunkStartTime[targetChunk],
               now - started > 2.4,
               !rescueChunks.contains(targetChunk) {
                rescueChunks.insert(targetChunk)
                spawnChunkFetch(index: targetChunk, isUrgent: true, isRescue: true)
            }
            condition.wait(until: Date().addingTimeInterval(0.08))
        }
        condition.unlock()
        return -1
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
        let available = chunkData.count - offsetInChunk
        let toCopy = min(count, available)
        chunkData.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                buffer.update(from: base.advanced(by: offsetInChunk), count: toCopy)
            }
        }
        condition.lock()
        cursorOffset += Int64(toCopy)
        condition.broadcast()
        condition.unlock()

        if targetChunk % 12 == 0 {
            store.evictBehindCursor(cursorChunk: targetChunk, keepBackChunks: 10)
        }
        return toCopy
    }

    /// Synchronous seek entry point called by FFmpeg `AVIOContext.seek` on `demux_thread`.
    public func seek(offset: Int64, whence: Int32) -> Int64 {
        let avSeekSizeFlag: Int32 = 0x10000
        let meta = store.currentMeta()

        if (whence & avSeekSizeFlag) != 0 {
            if meta.totalSize > 0 {
                return meta.totalSize
            }
            // Probe chunk 0 synchronously if size is not yet known
            requestUrgentChunk(0)
            let waitUntil = Date().addingTimeInterval(6.0)
            condition.lock()
            while !isAborted && !isClosed && store.currentMeta().totalSize <= 0 && Date() < waitUntil {
                condition.wait(until: Date().addingTimeInterval(0.05))
            }
            condition.unlock()
            let updated = store.currentMeta().totalSize
            return updated > 0 ? updated : -1
        }

        let cleanWhence = whence & ~0x20000 // strip AVSEEK_FORCE
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        let total = store.currentMeta().totalSize
        let newPos: Int64
        switch cleanWhence {
        case SEEK_SET:
            newPos = offset
        case SEEK_CUR:
            newPos = cursorOffset + offset
        case SEEK_END:
            guard total > 0 else { return -1 }
            newPos = total + offset
        default:
            return -1
        }
        guard newPos >= 0 else { return -1 }
        if total > 0 && newPos > total {
            cursorOffset = total
        } else {
            cursorOffset = newPos
        }
        return cursorOffset
    }

    public func abort() {
        condition.lock()
        isAborted = true
        condition.broadcast()
        condition.unlock()
        coordinatorTask?.cancel()
    }

    public func close() {
        condition.lock()
        if isClosed {
            condition.unlock()
            return
        }
        isAborted = true
        isClosed = true
        condition.broadcast()
        condition.unlock()
        coordinatorTask?.cancel()
        coordinatorTask = nil
        urlSession.invalidateAndCancel()
        store.flushMeta()
    }

    private func requestUrgentChunk(_ chunkIndex: Int) {
        condition.lock()
        let alreadyInFlight = inFlightChunks.contains(chunkIndex)
        if !alreadyInFlight && !isAborted && !isClosed {
            inFlightChunks.insert(chunkIndex)
            chunkStartTime[chunkIndex] = ProcessInfo.processInfo.systemUptime
            spawnChunkFetch(index: chunkIndex, isUrgent: true, isRescue: false)
        }
        condition.broadcast()
        condition.unlock()
    }

    private func startCoordinatorLoop() {
        coordinatorTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldStop = self.stepBulkPrefetchSchedule()
                if shouldStop { break }
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
        }
    }

    private func stepBulkPrefetchSchedule() -> Bool {
        condition.lock()
        if isAborted || isClosed {
            condition.unlock()
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now < last429BackoffUntil {
            condition.unlock()
            return false
        }
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let currentChunk = Int(max(0, cursorOffset) / Int64(chunkSize))
        let totalChunks = meta.totalChunks
        let cap = dynamicConcurrencyCap
        let ahead = prefetchAheadChunks

        // Check for stalled bulk chunks needing rescue (> 3.5s for near-cursor chunks)
        for idx in inFlightChunks where idx >= currentChunk && idx <= currentChunk + 2 {
            if let started = chunkStartTime[idx], now - started > 3.5, !rescueChunks.contains(idx) {
                rescueChunks.insert(idx)
                spawnChunkFetch(index: idx, isUrgent: true, isRescue: true)
            }
        }

        var launched = 0
        if activeBulkWorkers < cap {
            let maxChunk = totalChunks > 0 ? min(totalChunks - 1, currentChunk + ahead) : (currentChunk + min(ahead, 12))
            if maxChunk >= currentChunk {
                for candidate in currentChunk...maxChunk {
                    if activeBulkWorkers >= cap { break }
                    if inFlightChunks.contains(candidate) { continue }
                    if (failedCount[candidate] ?? 0) >= 4 { continue }
                    if store.hasChunk(candidate) { continue }
                    inFlightChunks.insert(candidate)
                    activeBulkWorkers += 1
                    chunkStartTime[candidate] = now
                    spawnChunkFetch(index: candidate, isUrgent: false, isRescue: false)
                    launched += 1
                }
            }
        }
        condition.unlock()
        return false
    }

    private func spawnChunkFetch(index: Int, isUrgent: Bool, isRescue: Bool) {
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let startByte = Int64(index) * Int64(chunkSize)
        if meta.totalSize > 0 && startByte >= meta.totalSize {
            finishChunkFetch(index: index, isUrgent: isUrgent, isRescue: isRescue, data: nil, totalSize: nil, statusCode: 200)
            return
        }
        let endByte: Int64 = {
            if meta.totalSize > 0 {
                return min(meta.totalSize - 1, startByte + Int64(chunkSize) - 1)
            }
            return startByte + Int64(chunkSize) - 1
        }()

        var req = URLRequest(url: streamURL, timeoutInterval: isUrgent ? 10.0 : 16.0)
        req.httpMethod = "GET"
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        let session = self.urlSession
        Task.detached(priority: isUrgent ? .userInitiated : .utility) { [weak self] in
            guard let self else { return }
            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                let parsedTotal = Self.parseTotalSize(from: http, startByte: startByte, dataCount: data.count)

                if status == 206 || (status == 200 && index == 0) {
                    let slice: Data
                    if status == 200 && data.count > chunkSize {
                        slice = data.prefix(chunkSize)
                    } else {
                        slice = data
                    }
                    self.finishChunkFetch(
                        index: index,
                        isUrgent: isUrgent,
                        isRescue: isRescue,
                        data: slice,
                        totalSize: parsedTotal,
                        statusCode: status
                    )
                } else {
                    self.finishChunkFetch(
                        index: index,
                        isUrgent: isUrgent,
                        isRescue: isRescue,
                        data: nil,
                        totalSize: parsedTotal,
                        statusCode: status
                    )
                }
            } catch {
                self.finishChunkFetch(
                    index: index,
                    isUrgent: isUrgent,
                    isRescue: isRescue,
                    data: nil,
                    totalSize: nil,
                    statusCode: -1
                )
            }
        }
    }

    private func finishChunkFetch(
        index: Int,
        isUrgent: Bool,
        isRescue: Bool,
        data: Data?,
        totalSize: Int64?,
        statusCode: Int
    ) {
        if let totalSize, totalSize > 0 {
            store.setTotalSize(totalSize, sourceURL: streamURL.absoluteString)
        }
        if let data, !data.isEmpty {
            store.storeChunk(index: index, data: data)
        }

        condition.lock()
        if !isUrgent && !isRescue {
            activeBulkWorkers = max(0, activeBulkWorkers - 1)
        }
        if let data, !data.isEmpty {
            inFlightChunks.remove(index)
            rescueChunks.remove(index)
            chunkStartTime.removeValue(forKey: index)
            failedCount.removeValue(forKey: index)

            // Update wire throughput measurement
            let now = ProcessInfo.processInfo.systemUptime
            recentWireBytes += Int64(data.count)
            let dt = now - recentWireTimestamp
            if dt >= 0.30 {
                let instMBs = (Double(recentWireBytes) / (1024.0 * 1024.0)) / dt
                measuredWireSpeedMBs = measuredWireSpeedMBs > 0.05
                    ? (measuredWireSpeedMBs * 0.35 + instMBs * 0.65)
                    : instMBs
                recentWireBytes = 0
                recentWireTimestamp = now
            }
        } else {
            if !isRescue {
                inFlightChunks.remove(index)
            } else {
                rescueChunks.remove(index)
            }
            if statusCode == 429 {
                // Automatic 429 rate-limit backoff and concurrency reduction
                dynamicConcurrencyCap = max(1, dynamicConcurrencyCap - 1)
                last429BackoffUntil = ProcessInfo.processInfo.systemUptime + 1.8
                DonbyLogger.shared.log("Turbo 分片引擎检测到 HTTP 429 限流，自动降并发至 \(dynamicConcurrencyCap) 并退避", level: .warning, subsystem: "TurboCache")
            } else if statusCode != 416 {
                failedCount[index, default: 0] += 1
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    public static func parseTotalSize(from response: HTTPURLResponse?, startByte: Int64, dataCount: Int) -> Int64? {
        guard let response else { return nil }
        if let cr = response.value(forHTTPHeaderField: "Content-Range") ?? response.value(forHTTPHeaderField: "content-range") {
            // Format: bytes start-end/total
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
}

// MARK: - Task C & D: Global Turbo Cache Engine & Disk LRU Manager

public final class DonbyTurboCacheEngine: @unchecked Sendable {
    public static let shared = DonbyTurboCacheEngine()

    public let cacheRootDirectory: URL
    private let lock = NSLock()
    private var activeStores: [String: TieredAssetChunkStore] = [:]

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheRootDirectory = cachesDir.appendingPathComponent("DonbyMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRootDirectory, withIntermediateDirectories: true)
    }

    public static func makeAssetKey(serverId: UUID, itemId: String, mediaSourceId: String) -> String {
        let raw = "\(serverId.uuidString)_\(itemId)_\(mediaSourceId)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    public func store(
        for assetKey: String,
        maxMemoryBytes: Int = 524_288_000,
        persistDisk: Bool = true
    ) -> TieredAssetChunkStore {
        lock.lock()
        defer { lock.unlock() }
        if let existing = activeStores[assetKey] {
            existing.updateConfiguration(maxMemoryBytes: maxMemoryBytes, persistDisk: persistDisk)
            return existing
        }
        let created = TieredAssetChunkStore(
            assetKey: assetKey,
            rootDirectory: cacheRootDirectory,
            chunkSize: 1_048_576,
            maxMemoryBytes: maxMemoryBytes,
            persistDisk: persistDisk
        )
        activeStores[assetKey] = created
        return created
    }

    public func removeAsset(assetKey: String, forceIncludePinned: Bool = false) {
        lock.lock()
        if let st = activeStores[assetKey] {
            if st.currentMeta().pinned && !forceIncludePinned {
                lock.unlock()
                return
            }
            activeStores.removeValue(forKey: assetKey)
        }
        lock.unlock()
        let dir = cacheRootDirectory.appendingPathComponent(assetKey, isDirectory: true)
        if !forceIncludePinned {
            let metaURL = dir.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? JSONDecoder().decode(ChunkStoreMeta.self, from: data),
               meta.pinned {
                return
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Computes total disk bytes used by unpinned cache vs pinned offline downloads (including ~/Movies/Donby).
    public func calculateDiskUsage() -> (unpinnedCacheBytes: Int64, pinnedDownloadBytes: Int64) {
        var unpinned: Int64 = 0
        var pinned: Int64 = 0

        if let dirs = try? FileManager.default.contentsOfDirectory(
            at: cacheRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in dirs {
                let metaURL = dir.appendingPathComponent("meta.json")
                let dataURL = dir.appendingPathComponent("media.bin")
                let isPinned: Bool = {
                    if let d = try? Data(contentsOf: metaURL),
                       let m = try? JSONDecoder().decode(ChunkStoreMeta.self, from: d) {
                        return m.pinned
                    }
                    return false
                }()
                let fileSize: Int64 = {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: dataURL.path),
                       let sz = attrs[.size] as? NSNumber {
                        return sz.int64Value
                    }
                    return 0
                }()
                if isPinned {
                    pinned += fileSize
                } else {
                    unpinned += fileSize
                }
            }
        }

        let moviesRoot = DonbyOfflineLibraryStorage.moviesDonbyRootURL
        if let enumerator = FileManager.default.enumerator(
            at: moviesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   vals.isRegularFile == true,
                   let sz = vals.fileSize {
                    pinned += Int64(sz)
                }
            }
        }

        return (unpinned, pinned)
    }

    /// LRU sweeps unpinned cache directories to keep unpinned disk usage within `maxDiskBytes`.
    public func enforceDiskBudget(maxDiskBytes: Int64) {
        let clampedBudget = max(128 * 1024 * 1024, maxDiskBytes)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: cacheRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let key: String
            let dir: URL
            let lastAccess: Date
            let size: Int64
        }

        var unpinnedEntries: [Entry] = []
        var totalUnpinned: Int64 = 0

        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            let dataURL = dir.appendingPathComponent("media.bin")
            guard let d = try? Data(contentsOf: metaURL),
                  let m = try? JSONDecoder().decode(ChunkStoreMeta.self, from: d) else {
                continue
            }
            if m.pinned { continue }
            let sz = ((try? FileManager.default.attributesOfItem(atPath: dataURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
            totalUnpinned += sz
            unpinnedEntries.append(Entry(key: m.assetKey, dir: dir, lastAccess: m.lastAccess, size: sz))
        }

        guard totalUnpinned > clampedBudget else { return }
        unpinnedEntries.sort { $0.lastAccess < $1.lastAccess }
        for entry in unpinnedEntries {
            if totalUnpinned <= clampedBudget { break }
            removeAsset(assetKey: entry.key, forceIncludePinned: false)
            totalUnpinned -= entry.size
        }
    }

    public func clearAllUnpinnedCache() {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: cacheRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for dir in dirs {
            removeAsset(assetKey: dir.lastPathComponent, forceIncludePinned: false)
        }
    }
}

// MARK: - Task D: Offline Download Models & Download Manager (Shared Pinned ChunkStore)

public enum DownloadTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued = "queued"
    case downloading = "downloading"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"

    public var displayTitle: String {
        switch self {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
}

public struct OfflineSubtitleAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: String { localFileName }
    public let name: String
    public let localFileName: String
    public let streamIndex: Int?
    public let codec: String?

    public init(name: String, localFileName: String, streamIndex: Int?, codec: String?) {
        self.name = name
        self.localFileName = localFileName
        self.streamIndex = streamIndex
        self.codec = codec
    }
}

public struct DownloadEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { assetKey }
    public let assetKey: String
    public let serverId: UUID
    public let serverName: String
    public let itemId: String
    public let mediaSourceId: String
    public let title: String
    public let subtitle: String?
    public let posterURLString: String?
    public let resolutionBadge: String?
    public var streamURLString: String
    public var downloadURLString: String
    public var headers: [String: String]
    public var itemSnapshot: EmbyItem
    public var mediaSourceSnapshot: MediaSourceInfo
    public var offlineSubtitles: [OfflineSubtitleAsset]
    public var localVideoFilePath: String?
    public var localFolderPath: String?
    public var localSeriesFolderPath: String?
    public var localPosterPath: String?
    public var localBackdropPath: String?
    public var localThumbPath: String?
    public var localLogoPath: String?
    public var status: DownloadTaskStatus
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var speedMBs: Double
    public var errorMessage: String?
    public let createdAt: Date

    public init(
        assetKey: String,
        serverId: UUID,
        serverName: String,
        itemId: String,
        mediaSourceId: String,
        title: String,
        subtitle: String?,
        posterURLString: String?,
        resolutionBadge: String?,
        streamURLString: String,
        downloadURLString: String,
        headers: [String: String],
        itemSnapshot: EmbyItem,
        mediaSourceSnapshot: MediaSourceInfo,
        offlineSubtitles: [OfflineSubtitleAsset] = [],
        localVideoFilePath: String? = nil,
        localFolderPath: String? = nil,
        localSeriesFolderPath: String? = nil,
        localPosterPath: String? = nil,
        localBackdropPath: String? = nil,
        localThumbPath: String? = nil,
        localLogoPath: String? = nil,
        status: DownloadTaskStatus = .queued,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        speedMBs: Double = 0.0,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.assetKey = assetKey
        self.serverId = serverId
        self.serverName = serverName
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.title = title
        self.subtitle = subtitle
        self.posterURLString = posterURLString
        self.resolutionBadge = resolutionBadge
        self.streamURLString = streamURLString
        self.downloadURLString = downloadURLString
        self.headers = headers
        self.itemSnapshot = itemSnapshot
        self.mediaSourceSnapshot = mediaSourceSnapshot
        self.offlineSubtitles = offlineSubtitles
        self.localVideoFilePath = localVideoFilePath
        self.localFolderPath = localFolderPath
        self.localSeriesFolderPath = localSeriesFolderPath
        self.localPosterPath = localPosterPath
        self.localBackdropPath = localBackdropPath
        self.localThumbPath = localThumbPath
        self.localLogoPath = localLogoPath
        self.status = status
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.speedMBs = speedMBs
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    public var progressFraction: Double {
        guard totalBytes > 0 else { return status == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public var hydratedItemSnapshot: EmbyItem {
        DonbyOfflineLibraryStorage.hydrateArtworkURLs(
            for: itemSnapshot,
            posterURL: localPosterPath.map { URL(fileURLWithPath: $0) },
            backdropURL: localBackdropPath.map { URL(fileURLWithPath: $0) },
            thumbURL: localThumbPath.map { URL(fileURLWithPath: $0) },
            logoURL: localLogoPath.map { URL(fileURLWithPath: $0) }
        )
    }

    /// Converts UHD `/play/video/{assetId}` -> `/download/video/{assetId}` and `/play/subtitle/{assetId}` -> `/download/subtitle/{assetId}`.
    public static func derivePreferredDownloadURL(from playURL: URL) -> URL {
        let raw = playURL.absoluteString
        if raw.contains("/play/video/") {
            let converted = raw.replacingOccurrences(of: "/play/video/", with: "/download/video/")
            if let u = URL(string: converted) { return u }
        }
        if raw.contains("/play/subtitle/") {
            let converted = raw.replacingOccurrences(of: "/play/subtitle/", with: "/download/subtitle/")
            if let u = URL(string: converted) { return u }
        }
        return playURL
    }
}

// MARK: - Task D: Offline Download Coordinator (Shares Pinned ChunkStore & ~/Movies/Donby Library)

@MainActor
public final class DonbyDownloadManager: ObservableObject {
    public static let shared = DonbyDownloadManager()

    @Published public private(set) var entries: [DownloadEntry] = []
    @Published public private(set) var statusIndex: DonbyDownloadStatusIndex = .empty
    @Published public var maxConcurrentDownloads: Int = 2

    private var workerTasks: [String: Task<Void, Never>] = [:]
    private let storageFileURL: URL
    private var statusRevision: Int = 0
    private var lastProgressStatusSync: TimeInterval = 0

    private init() {
        DonbyOfflineLibraryStorage.ensureRootDirectories()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Donby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageFileURL = dir.appendingPathComponent("downloads_v1.json")
        loadFromDisk()
    }

    public func entry(for assetKey: String) -> DownloadEntry? {
        entries.first { $0.assetKey == assetKey }
    }

    public func completedEntry(for itemId: String, serverId: UUID? = nil, mediaSourceId: String? = nil) -> DownloadEntry? {
        entries.first { entry in
            entry.itemId == itemId &&
            entry.status == .completed &&
            (serverId == nil || entry.serverId == serverId) &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || entry.mediaSourceId == mediaSourceId) &&
            hasPlayableBackingFile(for: entry)
        }
    }

    public func activeOrCompletedEntry(for itemId: String, serverId: UUID? = nil, mediaSourceId: String? = nil) -> DownloadEntry? {
        if let done = completedEntry(for: itemId, serverId: serverId, mediaSourceId: mediaSourceId) {
            return done
        }
        return entries.first { entry in
            entry.itemId == itemId &&
            (serverId == nil || entry.serverId == serverId) &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || entry.mediaSourceId == mediaSourceId)
        }
    }

    public func isDownloadedAndReady(assetKey: String) -> Bool {
        guard let item = entry(for: assetKey), item.status == .completed else { return false }
        return hasPlayableBackingFile(for: item)
    }

    private func hasPlayableBackingFile(for entry: DownloadEntry) -> Bool {
        if let localPath = entry.localVideoFilePath,
           FileManager.default.fileExists(atPath: localPath) {
            return true
        }
        let store = DonbyTurboCacheEngine.shared.store(for: entry.assetKey, persistDisk: true)
        return store.currentMeta().isFullyCached && FileManager.default.fileExists(atPath: store.dataFileURL.path)
    }

    public func offlinePlayableResource(for entry: DownloadEntry) -> ResolvedPlaybackResource? {
        let store = DonbyTurboCacheEngine.shared.store(for: entry.assetKey, persistDisk: true)
        let videoURL: URL
        if let localPath = entry.localVideoFilePath, FileManager.default.fileExists(atPath: localPath) {
            videoURL = URL(fileURLWithPath: localPath)
        } else {
            let meta = store.currentMeta()
            guard meta.isFullyCached && FileManager.default.fileExists(atPath: store.dataFileURL.path) else {
                return nil
            }
            videoURL = store.dataFileURL
        }

        let legacySubDir = store.assetDirectory.appendingPathComponent("subtitles", isDirectory: true)
        let localDir = entry.localFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var resolvedSubs: [SubtitleResourceItem] = []
        for sub in entry.offlineSubtitles {
            if let localDir {
                let candidate = localDir.appendingPathComponent(sub.localFileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    resolvedSubs.append(SubtitleResourceItem(
                        name: sub.name,
                        url: candidate,
                        streamIndex: sub.streamIndex,
                        codec: sub.codec,
                        isExternal: true
                    ))
                    continue
                }
            }
            let legacyCandidate = legacySubDir.appendingPathComponent(sub.localFileName)
            if FileManager.default.fileExists(atPath: legacyCandidate.path) {
                resolvedSubs.append(SubtitleResourceItem(
                    name: sub.name,
                    url: legacyCandidate,
                    streamIndex: sub.streamIndex,
                    codec: sub.codec,
                    isExternal: true
                ))
            }
        }
        return ResolvedPlaybackResource(
            streamURL: videoURL,
            headers: [:],
            playSessionId: "offline-\(entry.assetKey)",
            mediaSource: entry.mediaSourceSnapshot,
            subtitleURLs: resolvedSubs,
            isDirectStream: true,
            routeNote: entry.localVideoFilePath != nil ? "离线媒体库 (~/Movies/Donby)" : "本地离线缓存 (Pinned ChunkStore)"
        )
    }

    public func enqueueDownload(
        server: EmbyServerConfig,
        item: EmbyItem,
        seriesItem: EmbyItem? = nil,
        resource: ResolvedPlaybackResource,
        title: String,
        subtitle: String?,
        posterURLString: String?,
        itemArtworkURLs: (poster: URL?, backdrop: URL?, thumb: URL?, logo: URL?, seasonPoster: URL?) = (nil, nil, nil, nil, nil),
        seriesArtworkURLs: (poster: URL?, backdrop: URL?, logo: URL?) = (nil, nil, nil),
        connectionBudgetPerTask: Int = 3
    ) {
        let assetKey = DonbyTurboCacheEngine.makeAssetKey(
            serverId: server.id,
            itemId: item.id,
            mediaSourceId: resource.mediaSource.id
        )
        let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
        store.setPinned(true)
        if let knownSize = resource.mediaSource.size, knownSize > 0 {
            store.setTotalSize(knownSize, sourceURL: resource.streamURL.absoluteString)
        }

        let layout = DonbyOfflineLibraryStorage.makeLayoutPaths(
            item: item,
            seriesItem: seriesItem,
            mediaSource: resource.mediaSource,
            streamURL: resource.streamURL
        )
        try? FileManager.default.createDirectory(at: layout.itemFolderURL, withIntermediateDirectories: true)
        if let seriesDir = layout.seriesFolderURL {
            try? FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)
        }

        let preferredDownloadURL = resource.downloadURL ?? DownloadEntry.derivePreferredDownloadURL(from: resource.streamURL)
        let existingMeta = store.currentMeta()
        let alreadyOnDisk = FileManager.default.fileExists(atPath: layout.videoFileURL.path)

        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].streamURLString = resource.streamURL.absoluteString
            entries[idx].downloadURLString = preferredDownloadURL.absoluteString
            entries[idx].headers = resource.headers
            entries[idx].localVideoFilePath = layout.videoFileURL.path
            entries[idx].localFolderPath = layout.itemFolderURL.path
            entries[idx].localSeriesFolderPath = layout.seriesFolderURL?.path
            entries[idx].localPosterPath = layout.primaryPosterFileURL.path
            entries[idx].localBackdropPath = layout.backdropFileURL.path
            entries[idx].localThumbPath = layout.thumbFileURL.path
            entries[idx].localLogoPath = layout.clearLogoFileURL.path
            if entries[idx].status == .paused || entries[idx].status == .failed {
                entries[idx].status = alreadyOnDisk ? .completed : .queued
                entries[idx].errorMessage = nil
            }
        } else {
            let newEntry = DownloadEntry(
                assetKey: assetKey,
                serverId: server.id,
                serverName: server.name,
                itemId: item.id,
                mediaSourceId: resource.mediaSource.id,
                title: title,
                subtitle: subtitle,
                posterURLString: posterURLString,
                resolutionBadge: item.resolutionBadge,
                streamURLString: resource.streamURL.absoluteString,
                downloadURLString: preferredDownloadURL.absoluteString,
                headers: resource.headers,
                itemSnapshot: item,
                mediaSourceSnapshot: resource.mediaSource,
                offlineSubtitles: [],
                localVideoFilePath: layout.videoFileURL.path,
                localFolderPath: layout.itemFolderURL.path,
                localSeriesFolderPath: layout.seriesFolderURL?.path,
                localPosterPath: layout.primaryPosterFileURL.path,
                localBackdropPath: layout.backdropFileURL.path,
                localThumbPath: layout.thumbFileURL.path,
                localLogoPath: layout.clearLogoFileURL.path,
                status: (alreadyOnDisk || existingMeta.isFullyCached) ? .completed : .queued,
                totalBytes: max(existingMeta.totalSize, resource.mediaSource.size ?? 0),
                downloadedBytes: existingMeta.cachedBytes,
                speedMBs: 0.0
            )
            entries.insert(newEntry, at: 0)
        }
        saveToDisk()

        // Download artwork + write metadata sidecars + download external subtitles into ~/Movies/Donby
        Task {
            await downloadMetadataAndArtwork(
                assetKey: assetKey,
                server: server,
                item: item,
                seriesItem: seriesItem,
                mediaSource: resource.mediaSource,
                layout: layout,
                headers: resource.headers,
                itemArtworkURLs: itemArtworkURLs,
                seriesArtworkURLs: seriesArtworkURLs
            )
            await downloadExternalSubtitles(
                assetKey: assetKey,
                subtitles: resource.subtitleURLs,
                headers: resource.headers,
                layout: layout,
                server: server,
                item: item,
                mediaSource: resource.mediaSource
            )
        }

        if existingMeta.isFullyCached && !alreadyOnDisk {
            Task.detached(priority: .utility) {
                let total = max(existingMeta.totalSize, 0)
                if Self.materializeCompletedVideoFile(store: store, destinationURL: layout.videoFileURL, expectedSize: total) {
                    DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
                    await MainActor.run {
                        DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: total)
                    }
                }
            }
        } else {
            scheduleQueue(connectionBudgetPerTask: connectionBudgetPerTask)
        }
    }

    public func pauseDownload(assetKey: String) {
        workerTasks[assetKey]?.cancel()
        workerTasks.removeValue(forKey: assetKey)
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            if entries[idx].status == .downloading || entries[idx].status == .queued {
                entries[idx].status = .paused
                entries[idx].speedMBs = 0.0
                saveToDisk()
            }
        }
        scheduleQueue()
    }

    public func resumeDownload(assetKey: String, connectionBudgetPerTask: Int = 3) {
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            if entries[idx].status != .completed {
                entries[idx].status = .queued
                entries[idx].errorMessage = nil
                saveToDisk()
            }
        }
        scheduleQueue(connectionBudgetPerTask: connectionBudgetPerTask)
    }

    public func removeDownload(assetKey: String, deleteCachedData: Bool = true) {
        workerTasks[assetKey]?.cancel()
        workerTasks.removeValue(forKey: assetKey)
        let removedEntry = entries.first { $0.assetKey == assetKey }
        entries.removeAll { $0.assetKey == assetKey }
        saveToDisk()
        let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
        store.setPinned(false)
        if deleteCachedData {
            store.closeFileHandles()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
            if let removedEntry {
                cleanupOfflineMediaFiles(for: removedEntry)
            }
        }
        scheduleQueue()
    }

    private func cleanupOfflineMediaFiles(for entry: DownloadEntry) {
        let fm = FileManager.default
        if let videoPath = entry.localVideoFilePath {
            let videoURL = URL(fileURLWithPath: videoPath)
            let stem = videoURL.deletingPathExtension().lastPathComponent
            let folder = videoURL.deletingLastPathComponent()
            try? fm.removeItem(at: videoURL)
            try? fm.removeItem(at: folder.appendingPathComponent("\(stem).meta.json"))
            try? fm.removeItem(at: folder.appendingPathComponent("\(stem)-thumb.jpg"))
            for sub in entry.offlineSubtitles {
                try? fm.removeItem(at: folder.appendingPathComponent(sub.localFileName))
            }
            pruneEmptyFolderArtworkAndDirs(startingAt: folder, seriesFolder: entry.localSeriesFolderPath.map { URL(fileURLWithPath: $0) })
        }
    }

    private func pruneEmptyFolderArtworkAndDirs(startingAt folder: URL, seriesFolder: URL?) {
        let fm = FileManager.default
        let videoExts: Set<String> = ["mkv", "mp4", "mov", "m4v", "webm", "avi", "ts", "m2ts", "flv"]

        func directoryHasVideos(_ dir: URL) -> Bool {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return false
            }
            for case let file as URL in enumerator {
                if videoExts.contains(file.pathExtension.lowercased()) {
                    return true
                }
            }
            return false
        }

        if !directoryHasVideos(folder) {
            try? fm.removeItem(at: folder)
        }
        if let seriesFolder, seriesFolder != folder, !directoryHasVideos(seriesFolder) {
            try? fm.removeItem(at: seriesFolder)
        }
    }

    private func scheduleQueue(connectionBudgetPerTask: Int = 3) {
        let activeCount = entries.filter { $0.status == .downloading }.count
        guard activeCount < maxConcurrentDownloads else { return }

        for idx in entries.indices where entries[idx].status == .queued {
            let currentlyActive = entries.filter { $0.status == .downloading }.count
            if currentlyActive >= maxConcurrentDownloads { break }
            entries[idx].status = .downloading
            entries[idx].errorMessage = nil
            saveToDisk()
            startDownloadWorker(for: entries[idx], connectionBudget: connectionBudgetPerTask)
        }
    }

    nonisolated private static func materializeCompletedVideoFile(
        store: TieredAssetChunkStore,
        destinationURL: URL,
        expectedSize: Int64
    ) -> Bool {
        let fm = FileManager.default
        let dir = destinationURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        store.closeFileHandles()

        let src = store.dataFileURL
        guard fm.fileExists(atPath: src.path) else {
            return fm.fileExists(atPath: destinationURL.path)
        }

        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: src, to: destinationURL)
            if expectedSize > 0 {
                let handle = try FileHandle(forUpdating: destinationURL)
                try handle.truncate(atOffset: UInt64(expectedSize))
                try handle.close()
            }
            return true
        } catch {
            return false
        }
    }

    private func startDownloadWorker(for entrySnapshot: DownloadEntry, connectionBudget: Int) {
        let assetKey = entrySnapshot.assetKey
        workerTasks[assetKey]?.cancel()

        let task = Task.detached(priority: .utility) {
            let store = DonbyTurboCacheEngine.shared.store(for: assetKey, persistDisk: true)
            store.setPinned(true)

            let primaryURL = URL(string: entrySnapshot.downloadURLString) ?? URL(string: entrySnapshot.streamURLString)
            let fallbackURL = URL(string: entrySnapshot.streamURLString)
            guard let targetURL = primaryURL ?? fallbackURL else {
                await MainActor.run {
                    DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: "无效的下载 URL")
                }
                return
            }

            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpMaximumConnectionsPerHost = 6
            cfg.timeoutIntervalForRequest = 18
            cfg.timeoutIntervalForResource = 60
            let session = URLSession(configuration: cfg)
            defer { session.invalidateAndCancel() }

            var activeURL = targetURL
            // 1. Ensure chunk 0 & totalSize are resolved
            if store.currentMeta().totalSize <= 0 || !store.hasChunk(0) {
                let chunkSize = store.currentMeta().chunkSize
                var req = URLRequest(url: activeURL, timeoutInterval: 15)
                for (k, v) in entrySnapshot.headers { req.setValue(v, forHTTPHeaderField: k) }
                req.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")

                var probeData: Data?
                var probeResp: HTTPURLResponse?
                if let (d, r) = try? await session.data(for: req),
                   let http = r as? HTTPURLResponse,
                   (http.statusCode == 206 || http.statusCode == 200) {
                    probeData = d
                    probeResp = http
                } else if let fb = fallbackURL, fb != activeURL {
                    activeURL = fb
                    var fbReq = URLRequest(url: fb, timeoutInterval: 15)
                    for (k, v) in entrySnapshot.headers { fbReq.setValue(v, forHTTPHeaderField: k) }
                    fbReq.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
                    if let (d, r) = try? await session.data(for: fbReq),
                       let http = r as? HTTPURLResponse,
                       (http.statusCode == 206 || http.statusCode == 200) {
                        probeData = d
                        probeResp = http
                    }
                }

                guard let firstData = probeData, let firstHttp = probeResp else {
                    await MainActor.run {
                        DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: "连接下载源失败或无下载权限")
                    }
                    return
                }
                if let total = TurboStreamByteHandle.parseTotalSize(from: firstHttp, startByte: 0, dataCount: firstData.count), total > 0 {
                    store.setTotalSize(total, sourceURL: activeURL.absoluteString)
                }
                let slice = firstData.count > chunkSize ? firstData.prefix(chunkSize) : firstData
                store.storeChunk(index: 0, data: slice)
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
                    if Self.materializeCompletedVideoFile(store: store, destinationURL: destURL, expectedSize: meta.totalSize) {
                        DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
                    }
                }
                await MainActor.run {
                    DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: meta.totalSize)
                }
                return
            }

            let workers = max(1, min(4, connectionBudget))
            let chunkSize = meta.chunkSize
            let totalSize = meta.totalSize
            let headers = entrySnapshot.headers
            let finalURL = activeURL

            actor ChunkWorkQueue {
                var queue: [Int]
                var failedError: String?
                var bytesSinceLastReport: Int64 = 0
                var lastReportTime: TimeInterval = ProcessInfo.processInfo.systemUptime

                init(chunks: [Int]) {
                    self.queue = chunks
                }
                func next() -> Int? {
                    guard failedError == nil, !queue.isEmpty else { return nil }
                    return queue.removeFirst()
                }
                func recordSuccess(bytes: Int) -> (shouldReport: Bool, speedMBs: Double) {
                    bytesSinceLastReport += Int64(bytes)
                    let now = ProcessInfo.processInfo.systemUptime
                    let dt = now - lastReportTime
                    if dt >= 0.35 {
                        let spd = (Double(bytesSinceLastReport) / (1024.0 * 1024.0)) / dt
                        bytesSinceLastReport = 0
                        lastReportTime = now
                        return (true, spd)
                    }
                    return (false, 0)
                }
                func recordFailure(_ msg: String) {
                    if failedError == nil { failedError = msg }
                }
            }

            let workQueue = ChunkWorkQueue(chunks: missingChunks)

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask {
                        while !Task.isCancelled {
                            guard let idx = await workQueue.next() else { break }
                            let startByte = Int64(idx) * Int64(chunkSize)
                            let endByte = min(totalSize - 1, startByte + Int64(chunkSize) - 1)
                            var success = false

                            for attempt in 0..<4 {
                                if Task.isCancelled { return }
                                var req = URLRequest(url: finalURL, timeoutInterval: 20)
                                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                                req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

                                if let (data, resp) = try? await session.data(for: req),
                                   let http = resp as? HTTPURLResponse {
                                    if http.statusCode == 206 || (http.statusCode == 200 && idx == 0) {
                                        store.storeChunk(index: idx, data: data)
                                        let rep = await workQueue.recordSuccess(bytes: data.count)
                                        if rep.shouldReport {
                                            let curMeta = store.currentMeta()
                                            await MainActor.run {
                                                DonbyDownloadManager.shared.updateProgress(
                                                    assetKey: assetKey,
                                                    downloadedBytes: curMeta.cachedBytes,
                                                    totalBytes: curMeta.totalSize,
                                                    speedMBs: rep.speedMBs
                                                )
                                            }
                                        }
                                        success = true
                                        break
                                    } else if http.statusCode == 429 {
                                        try? await Task.sleep(nanoseconds: UInt64(1_200_000_000 * (attempt + 1)))
                                        continue
                                    }
                                }
                                try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                            }

                            if !success && !Task.isCancelled {
                                await workQueue.recordFailure("分片 #\(idx) 多次拉取失败")
                                break
                            }
                        }
                    }
                }
            }

            if Task.isCancelled { return }
            store.flushMeta()
            if let err = await workQueue.failedError {
                await MainActor.run {
                    DonbyDownloadManager.shared.markFailed(assetKey: assetKey, message: err)
                }
            } else if store.currentMeta().isFullyCached {
                let finalTotal = store.currentMeta().totalSize
                if let destPath = entrySnapshot.localVideoFilePath {
                    let destURL = URL(fileURLWithPath: destPath)
                    if Self.materializeCompletedVideoFile(store: store, destinationURL: destURL, expectedSize: finalTotal) {
                        DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
                    }
                }
                await MainActor.run {
                    DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: finalTotal)
                }
            }
        }
        workerTasks[assetKey] = task
    }

    private func downloadMetadataAndArtwork(
        assetKey: String,
        server: EmbyServerConfig,
        item: EmbyItem,
        seriesItem: EmbyItem?,
        mediaSource: MediaSourceInfo,
        layout: OfflineLibraryPaths,
        headers: [String: String],
        itemArtworkURLs: (poster: URL?, backdrop: URL?, thumb: URL?, logo: URL?, seasonPoster: URL?),
        seriesArtworkURLs: (poster: URL?, backdrop: URL?, logo: URL?)
    ) async {
        func fetchAndWriteArtwork(_ url: URL?, to fileURL: URL) async {
            guard let url else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) { return }
            if url.isFileURL {
                if let data = try? Data(contentsOf: url), data.count > 128 {
                    try? data.write(to: fileURL, options: .atomic)
                }
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               data.count > 128 {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        // 1. Write Series sidecar & series artwork if applicable
        if let seriesMetaURL = layout.seriesMetadataFileURL {
            let resolvedSeries = seriesItem ?? EmbyItem(
                id: item.seriesId ?? item.id,
                name: item.seriesName ?? "未命名剧集",
                serverId: server.id.uuidString,
                type: "Series",
                overview: item.overview,
                genres: item.genres,
                communityRating: item.communityRating,
                productionYear: item.productionYear,
                people: item.people
            )
            let seriesSidecar = OfflineSeriesSidecar(
                serverId: server.id,
                serverName: server.name,
                seriesItem: resolvedSeries
            )
            if let encoded = try? JSONEncoder().encode(seriesSidecar) {
                try? encoded.write(to: seriesMetaURL, options: .atomic)
            }
            await fetchAndWriteArtwork(seriesArtworkURLs.poster ?? itemArtworkURLs.poster, to: layout.primaryPosterFileURL)
            await fetchAndWriteArtwork(seriesArtworkURLs.backdrop ?? itemArtworkURLs.backdrop, to: layout.backdropFileURL)
            await fetchAndWriteArtwork(seriesArtworkURLs.logo ?? itemArtworkURLs.logo, to: layout.clearLogoFileURL)
            if let seasonPosterURL = layout.seasonPosterFileURL {
                await fetchAndWriteArtwork(itemArtworkURLs.seasonPoster ?? seriesArtworkURLs.poster, to: seasonPosterURL)
            }
        } else {
            await fetchAndWriteArtwork(itemArtworkURLs.poster, to: layout.primaryPosterFileURL)
            await fetchAndWriteArtwork(itemArtworkURLs.backdrop, to: layout.backdropFileURL)
            await fetchAndWriteArtwork(itemArtworkURLs.logo, to: layout.clearLogoFileURL)
        }

        await fetchAndWriteArtwork(itemArtworkURLs.thumb ?? itemArtworkURLs.backdrop ?? itemArtworkURLs.poster, to: layout.thumbFileURL)

        // 2. Write Episode / Movie sidecar JSON
        let sidecar = OfflineEpisodeOrMovieSidecar(
            assetKey: assetKey,
            serverId: server.id,
            serverName: server.name,
            item: item,
            mediaSource: mediaSource,
            videoFileName: layout.videoFileURL.lastPathComponent,
            thumbFileName: layout.thumbFileURL.lastPathComponent,
            posterFileName: layout.primaryPosterFileURL.lastPathComponent,
            backdropFileName: layout.backdropFileURL.lastPathComponent,
            clearLogoFileName: layout.clearLogoFileURL.lastPathComponent,
            subtitles: entry(for: assetKey)?.offlineSubtitles ?? []
        )
        if let encoded = try? JSONEncoder().encode(sidecar) {
            try? encoded.write(to: layout.metadataFileURL, options: .atomic)
        }
    }

    private func downloadExternalSubtitles(
        assetKey: String,
        subtitles: [SubtitleResourceItem],
        headers: [String: String],
        layout: OfflineLibraryPaths,
        server: EmbyServerConfig,
        item: EmbyItem,
        mediaSource: MediaSourceInfo
    ) async {
        guard !subtitles.isEmpty else { return }
        let subDir = layout.itemFolderURL
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let videoStem = layout.videoFileURL.deletingPathExtension().lastPathComponent

        var savedSubs: [OfflineSubtitleAsset] = []
        for (ord, sub) in subtitles.enumerated() {
            let dlURL = DownloadEntry.derivePreferredDownloadURL(from: sub.url)
            var req = URLRequest(url: dlURL, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            var fetchedData: Data?
            if let (d, r) = try? await URLSession.shared.data(for: req),
               let http = r as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               !d.isEmpty {
                fetchedData = d
            } else if dlURL != sub.url {
                var fbReq = URLRequest(url: sub.url, timeoutInterval: 15)
                for (k, v) in headers { fbReq.setValue(v, forHTTPHeaderField: k) }
                if let (d, _) = try? await URLSession.shared.data(for: fbReq), !d.isEmpty {
                    fetchedData = d
                }
            }
            guard let data = fetchedData else { continue }
            let ext = sub.url.pathExtension.isEmpty ? (sub.codec?.lowercased() == "ass" ? "ass" : "srt") : sub.url.pathExtension
            let cleanLabel = DonbyOfflineLibraryStorage.sanitizeFileName(sub.name, fallback: "sub\(ord)")
            let fileName = "\(videoStem).\(ord + 1).\(cleanLabel).\(ext)"
            let fileURL = subDir.appendingPathComponent(fileName)
            try? data.write(to: fileURL, options: .atomic)
            savedSubs.append(OfflineSubtitleAsset(
                name: sub.name,
                localFileName: fileName,
                streamIndex: sub.streamIndex,
                codec: sub.codec
            ))
        }

        if !savedSubs.isEmpty, let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].offlineSubtitles = savedSubs
            saveToDisk()

            // Refresh episode sidecar with offline subtitle filenames
            let sidecar = OfflineEpisodeOrMovieSidecar(
                assetKey: assetKey,
                serverId: server.id,
                serverName: server.name,
                item: item,
                mediaSource: mediaSource,
                videoFileName: layout.videoFileURL.lastPathComponent,
                thumbFileName: layout.thumbFileURL.lastPathComponent,
                posterFileName: layout.primaryPosterFileURL.lastPathComponent,
                backdropFileName: layout.backdropFileURL.lastPathComponent,
                clearLogoFileName: layout.clearLogoFileURL.lastPathComponent,
                subtitles: savedSubs
            )
            if let encoded = try? JSONEncoder().encode(sidecar) {
                try? encoded.write(to: layout.metadataFileURL, options: .atomic)
            }
        }
    }

    private func updateProgress(assetKey: String, downloadedBytes: Int64, totalBytes: Int64, speedMBs: Double) {
        guard let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) else { return }
        entries[idx].downloadedBytes = downloadedBytes
        if totalBytes > 0 { entries[idx].totalBytes = totalBytes }
        entries[idx].speedMBs = speedMBs
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressStatusSync >= 1.0 {
            lastProgressStatusSync = now
            rebuildStatusIndex()
        }
    }

    private func markCompleted(assetKey: String, totalBytes: Int64) {
        workerTasks.removeValue(forKey: assetKey)
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].status = .completed
            if totalBytes > 0 {
                entries[idx].totalBytes = totalBytes
                entries[idx].downloadedBytes = totalBytes
            }
            entries[idx].speedMBs = 0.0
            entries[idx].errorMessage = nil
            DonbyLogger.shared.log("离线下载完成: \(entries[idx].title)", level: .info, subsystem: "Download")
        }
        saveToDisk()
        scheduleQueue()
    }

    private func markFailed(assetKey: String, message: String) {
        workerTasks.removeValue(forKey: assetKey)
        if let idx = entries.firstIndex(where: { $0.assetKey == assetKey }) {
            entries[idx].status = .failed
            entries[idx].speedMBs = 0.0
            entries[idx].errorMessage = message
            DonbyLogger.shared.log("离线下载失败 (\(entries[idx].title)): \(message)", level: .error, subsystem: "Download")
        }
        saveToDisk()
        scheduleQueue()
    }

    private func rebuildStatusIndex() {
        var completedIds = Set<String>()
        var inProgress: [String: Double] = [:]
        var seriesIdCounts: [String: Int] = [:]
        var seriesNameCounts: [String: Int] = [:]
        var seenSeriesEpisodes = Set<String>()

        for entry in entries {
            if entry.status == .completed && hasPlayableBackingFile(for: entry) {
                completedIds.insert(entry.itemId)
                if entry.itemSnapshot.isEpisode {
                    let uniqueEpKey = entry.itemId
                    if seenSeriesEpisodes.insert(uniqueEpKey).inserted {
                        if let sId = entry.itemSnapshot.seriesId, !sId.isEmpty {
                            seriesIdCounts[sId, default: 0] += 1
                        }
                        if let sName = entry.itemSnapshot.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                           !sName.isEmpty {
                            seriesNameCounts[sName, default: 0] += 1
                        }
                    }
                }
            } else if entry.status == .downloading || entry.status == .queued {
                inProgress[entry.itemId] = max(inProgress[entry.itemId] ?? 0, entry.progressFraction)
            }
        }

        statusRevision &+= 1
        statusIndex = DonbyDownloadStatusIndex(
            revision: statusRevision,
            completedItemIds: completedIds,
            inProgressByItemId: inProgress,
            completedCountBySeriesId: seriesIdCounts,
            completedCountBySeriesName: seriesNameCounts
        )
    }

    /// Migrates previously completed downloads from cache bins (`ChunkStore`) or legacy `剧集`/`电影` split folders
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
                    if server.type == .uhdNative {
                        resolvedSeries = try? await UHDStreamClient.shared.fetchItemDetail(
                            server: server,
                            item: EmbyItem(
                                id: sid,
                                name: entry.itemSnapshot.seriesName ?? "",
                                type: "Series",
                                uhdMediaType: "tv"
                            )
                        )
                    } else {
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

            // 1. Move any file sitting in legacy split folders (`~/Movies/Donby/剧集` or `电影`) into unified `~/Movies/Donby/`
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

            // 2. Materialize legacy completed downloads still stored only in `~/Library/Caches/DonbyMedia/<assetKey>/media.bin`
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
                    if Self.materializeCompletedVideoFile(store: store, destinationURL: layout.videoFileURL, expectedSize: expectedSize) {
                        DonbyTurboCacheEngine.shared.removeAsset(assetKey: entry.assetKey, forceIncludePinned: true)
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
                entries[idx].localVideoFilePath = layout.videoFileURL.path
                entries[idx].localFolderPath = layout.itemFolderURL.path
                entries[idx].localSeriesFolderPath = layout.seriesFolderURL?.path
                entries[idx].localPosterPath = layout.primaryPosterFileURL.path
                entries[idx].localBackdropPath = layout.backdropFileURL.path
                entries[idx].localThumbPath = layout.thumbFileURL.path
                entries[idx].localLogoPath = layout.clearLogoFileURL.path
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
                    let isUHD = server.type == .uhdNative
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

    private func loadFromDisk() {
        defer { rebuildStatusIndex() }
        guard let data = try? Data(contentsOf: storageFileURL),
              let decoded = try? JSONDecoder().decode([DownloadEntry].self, from: data) else {
            return
        }
        self.entries = decoded.map { item in
            var copy = item
            if copy.status == .downloading {
                copy.status = .paused
                copy.speedMBs = 0.0
            }
            return copy
        }
    }

    private func saveToDisk() {
        rebuildStatusIndex()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storageFileURL, options: .atomic)
        }
    }
}

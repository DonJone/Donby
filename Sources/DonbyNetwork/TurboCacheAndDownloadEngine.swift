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
    public var serverId: UUID?
    public var itemId: String?
    public var mediaSourceId: String?
    public var displayTitle: String?
    public var subtitle: String?
    public var posterURLString: String?
    public var itemSnapshot: EmbyItem?
    public var mediaSourceSnapshot: MediaSourceInfo?

    public init(
        assetKey: String,
        totalSize: Int64 = 0,
        chunkSize: Int = 524_288,
        completedChunks: Set<Int> = [],
        lastAccess: Date = Date(),
        pinned: Bool = false,
        sourceURLString: String = "",
        estimatedBitrateBps: Int64 = 25_000_000,
        serverId: UUID? = nil,
        itemId: String? = nil,
        mediaSourceId: String? = nil,
        displayTitle: String? = nil,
        subtitle: String? = nil,
        posterURLString: String? = nil,
        itemSnapshot: EmbyItem? = nil,
        mediaSourceSnapshot: MediaSourceInfo? = nil
    ) {
        self.assetKey = assetKey
        self.totalSize = totalSize
        self.chunkSize = max(65_536, chunkSize)
        self.completedChunks = completedChunks
        self.lastAccess = lastAccess
        self.pinned = pinned
        self.sourceURLString = sourceURLString
        self.estimatedBitrateBps = estimatedBitrateBps
        self.serverId = serverId
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.posterURLString = posterURLString
        self.itemSnapshot = itemSnapshot
        self.mediaSourceSnapshot = mediaSourceSnapshot
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
    public let chunksDirectoryURL: URL

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
    private var activeReaders: Int = 0
    private var didNotifyFullyCached: Bool = false
    private var contiguousPrefixCount: Int = 0

    public init(
        assetKey: String,
        rootDirectory: URL,
        chunkSize: Int = 524_288,
        maxMemoryBytes: Int = 524_288_000,
        persistDisk: Bool = true
    ) {
        self.assetKey = assetKey
        self.assetDirectory = rootDirectory.appendingPathComponent(assetKey, isDirectory: true)
        self.dataFileURL = assetDirectory.appendingPathComponent("media.bin")
        self.metaFileURL = assetDirectory.appendingPathComponent("meta.json")
        self.chunksDirectoryURL = assetDirectory.appendingPathComponent("chunks", isDirectory: true)
        self.maxMemoryBytes = max(32 * 1024 * 1024, min(2_147_483_648, maxMemoryBytes))
        self.persistDisk = persistDisk

        try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metaFileURL),
           let loaded = try? JSONDecoder().decode(ChunkStoreMeta.self, from: data) {
            self.meta = loaded
            self.didNotifyFullyCached = loaded.isFullyCached
        } else {
            self.meta = ChunkStoreMeta(assetKey: assetKey, chunkSize: chunkSize)
        }
        self.meta.lastAccess = Date()
        self.reconcileAndCompactDiskStorageLocked()
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

    public var activeReaderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeReaders
    }

    public func retainReader() {
        lock.lock()
        activeReaders += 1
        lock.unlock()
    }

    public func releaseReader() -> Int {
        lock.lock()
        activeReaders = max(0, activeReaders - 1)
        let remaining = activeReaders
        lock.unlock()
        return remaining
    }

    public func updateCachedMetadata(
        serverId: UUID?,
        itemId: String?,
        mediaSourceId: String?,
        displayTitle: String?,
        subtitle: String?,
        posterURLString: String?,
        itemSnapshot: EmbyItem?,
        mediaSourceSnapshot: MediaSourceInfo?
    ) {
        lock.lock()
        meta.serverId = serverId ?? meta.serverId
        meta.itemId = itemId ?? meta.itemId
        meta.mediaSourceId = mediaSourceId ?? meta.mediaSourceId
        meta.displayTitle = displayTitle ?? meta.displayTitle
        meta.subtitle = subtitle ?? meta.subtitle
        meta.posterURLString = posterURLString ?? meta.posterURLString
        if let itemSnapshot { meta.itemSnapshot = itemSnapshot }
        if let mediaSourceSnapshot { meta.mediaSourceSnapshot = mediaSourceSnapshot }
        meta.lastAccess = Date()
        saveMetaLocked()
        lock.unlock()
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
        var completedMetaForNotify: ChunkStoreMeta? = nil
        lock.lock()

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

        // 2. Store in L2 Disk cache if enabled or pinned.
        // Write contiguous prefix chunks [0..contiguousPrefixCount] directly to `media.bin`,
        // while spilling out-of-order / high-offset seek chunks into `chunks/<index>.chk`
        // so `media.bin` never creates a multi-tens-of-GB sparse or zero-filled file before download completion.
        if persistDisk || meta.pinned {
            if index <= contiguousPrefixCount {
                ensureFileHandlesLocked()
                if let wh = writeHandle {
                    let offset = UInt64(index) * UInt64(meta.chunkSize)
                    do {
                        try wh.seek(toOffset: offset)
                        try wh.write(contentsOf: data)
                        meta.completedChunks.insert(index)
                        if index == contiguousPrefixCount {
                            contiguousPrefixCount += 1
                            foldConsecutiveSpillChunksIntoMediaBinLocked(wh: wh)
                        }
                        dirtyMetaOps += 1
                        if dirtyMetaOps >= 32 || meta.isFullyCached {
                            dirtyMetaOps = 0
                            saveMetaLocked()
                        }
                        if meta.isFullyCached && !meta.pinned && !didNotifyFullyCached {
                            didNotifyFullyCached = true
                            completedMetaForNotify = meta
                        }
                    } catch {
                        // Ignore transient disk write error and keep L1 memory copy
                    }
                }
            } else {
                try? FileManager.default.createDirectory(at: chunksDirectoryURL, withIntermediateDirectories: true)
                let spillURL = chunkSpillFileURL(for: index)
                if (try? data.write(to: spillURL, options: .atomic)) != nil {
                    meta.completedChunks.insert(index)
                    dirtyMetaOps += 1
                    if dirtyMetaOps >= 32 || meta.isFullyCached {
                        dirtyMetaOps = 0
                        saveMetaLocked()
                    }
                    if meta.isFullyCached && !meta.pinned && !didNotifyFullyCached {
                        ensureFileHandlesLocked()
                        if let wh = writeHandle {
                            foldConsecutiveSpillChunksIntoMediaBinLocked(wh: wh)
                        }
                        didNotifyFullyCached = true
                        completedMetaForNotify = meta
                    }
                }
            }
        }
        lock.unlock()

        if let completedMetaForNotify {
            DonbyTurboCacheEngine.shared.notifyAssetFullyCached(completedMetaForNotify)
        }
    }

    public func readChunk(index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if let mem = memoryChunks[index] {
            return mem
        }
        guard meta.completedChunks.contains(index) else { return nil }
        let len = expectedChunkLenLocked(index: index)
        guard len > 0 else { return nil }

        // Check out-of-order spill file first if beyond contiguous prefix
        if index >= contiguousPrefixCount {
            let spillURL = chunkSpillFileURL(for: index)
            if let data = try? Data(contentsOf: spillURL), !data.isEmpty {
                let slice = data.count > len ? data.prefix(len) : data
                evictMemoryLockedIfNeeded(incomingBytes: slice.count)
                if slice.count <= maxMemoryBytes {
                    memoryChunks[index] = slice
                    memoryOrder.append(index)
                    memoryBytes += slice.count
                }
                return slice
            }
        }

        ensureFileHandlesLocked()
        guard let rh = readHandle else { return nil }
        let offset = UInt64(index) * UInt64(meta.chunkSize)
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
        if let wh = writeHandle {
            foldConsecutiveSpillChunksIntoMediaBinLocked(wh: wh)
        }
        saveMetaLocked()
        try? readHandle?.close()
        readHandle = nil
        try? writeHandle?.close()
        writeHandle = nil
        lock.unlock()
    }

    public func prepareContiguousMediaBinForMaterialization() {
        lock.lock()
        ensureFileHandlesLocked()
        if let wh = writeHandle {
            foldConsecutiveSpillChunksIntoMediaBinLocked(wh: wh)
            // Also fold any remaining completed spill chunks in case contiguousPrefixCount lagged
            let sorted = meta.completedChunks.sorted()
            for idx in sorted {
                let spillURL = chunkSpillFileURL(for: idx)
                if FileManager.default.fileExists(atPath: spillURL.path),
                   let data = try? Data(contentsOf: spillURL), !data.isEmpty {
                    let offset = UInt64(idx) * UInt64(meta.chunkSize)
                    try? wh.seek(toOffset: offset)
                    try? wh.write(contentsOf: data)
                    try? FileManager.default.removeItem(at: spillURL)
                }
            }
        }
        try? FileManager.default.removeItem(at: chunksDirectoryURL)
        saveMetaLocked()
        lock.unlock()
    }

    private func chunkSpillFileURL(for index: Int) -> URL {
        chunksDirectoryURL.appendingPathComponent("\(index).chk")
    }

    private func foldConsecutiveSpillChunksIntoMediaBinLocked(wh: FileHandle) {
        var didFoldAny = false
        while meta.completedChunks.contains(contiguousPrefixCount) {
            let spillURL = chunkSpillFileURL(for: contiguousPrefixCount)
            if FileManager.default.fileExists(atPath: spillURL.path) {
                guard let spillData = try? Data(contentsOf: spillURL), !spillData.isEmpty else {
                    break
                }
                let offset = UInt64(contiguousPrefixCount) * UInt64(meta.chunkSize)
                do {
                    try wh.seek(toOffset: offset)
                    try wh.write(contentsOf: spillData)
                    try? FileManager.default.removeItem(at: spillURL)
                    didFoldAny = true
                } catch {
                    break
                }
            }
            contiguousPrefixCount += 1
        }
        if didFoldAny {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: chunksDirectoryURL.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: chunksDirectoryURL)
            }
        }
    }

    /// Computes contiguous prefix [0..<prefix] and compacts any legacy bloated `media.bin` whose logical EOF
    /// was stretched to multi-GB by out-of-order tail/seek chunks.
    private func reconcileAndCompactDiskStorageLocked() {
        var prefix = 0
        while meta.completedChunks.contains(prefix) {
            prefix += 1
        }
        contiguousPrefixCount = prefix

        let fm = FileManager.default
        guard fm.fileExists(atPath: dataFileURL.path) else { return }

        // First fold any spill chunks < prefix that might already exist in `chunks/`
        if fm.fileExists(atPath: chunksDirectoryURL.path) {
            ensureFileHandlesLocked()
            if let wh = writeHandle {
                for idx in 0..<prefix {
                    let spillURL = chunkSpillFileURL(for: idx)
                    if fm.fileExists(atPath: spillURL.path),
                       let d = try? Data(contentsOf: spillURL), !d.isEmpty {
                        let off = UInt64(idx) * UInt64(meta.chunkSize)
                        try? wh.seek(toOffset: off)
                        try? wh.write(contentsOf: d)
                        try? fm.removeItem(at: spillURL)
                    }
                }
            }
        }

        let prefixBytes = Int64(prefix) * Int64(meta.chunkSize)
        let logicalSize = ((try? fm.attributesOfItem(atPath: dataFileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        // If `media.bin` is stretched > 4 chunks beyond the contiguous prefix (e.g. a 35 GB file with only 140 MB downloaded),
        // extract out-of-order chunks >= prefix into `chunks/<idx>.chk` and truncate `media.bin` down to `prefixBytes`!
        guard logicalSize > prefixBytes + Int64(meta.chunkSize * 4), !meta.isFullyCached else {
            return
        }

        ensureFileHandlesLocked()
        if let rh = readHandle {
            let highChunks = meta.completedChunks.filter { $0 >= prefix }.sorted()
            if !highChunks.isEmpty {
                try? fm.createDirectory(at: chunksDirectoryURL, withIntermediateDirectories: true)
            }
            for idx in highChunks {
                let spillURL = chunkSpillFileURL(for: idx)
                if fm.fileExists(atPath: spillURL.path) { continue }
                let off = UInt64(idx) * UInt64(meta.chunkSize)
                let len = expectedChunkLenLocked(index: idx)
                guard len > 0, Int64(off) < logicalSize else { continue }
                if (try? rh.seek(toOffset: off)) != nil,
                   let data = try? rh.read(upToCount: len), !data.isEmpty {
                    try? data.write(to: spillURL, options: .atomic)
                }
            }
        }

        if let wh = writeHandle {
            try? wh.truncate(atOffset: UInt64(max(0, prefixBytes)))
        }
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

// MARK: - Task C: Multi-Connection Streaming Turbo Session & Custom AVIO Byte Handle

private final class StreamingChunkContext {
    let attemptId: UInt64
    let chunkIndex: Int
    let chunkSize: Int
    let startByte: Int64
    let isUrgent: Bool
    let isRescue: Bool
    let isDirectRange: Bool
    let requestOriginURL: URL
    let usedRedirectedURL: Bool
    let redirectEpoch: UInt64
    weak var owner: TurboStreamByteHandle?
    weak var dataTask: URLSessionDataTask?
    var statusCode: Int = 200
    var acceptBody: Bool = false
    var bytesReceived: Int = 0
    var parsedTotalSize: Int64?
    var cancelledIntentionally: Bool = false
    var rejectedByStatus: Bool = false
    var reached200Cap: Bool = false

    init(
        attemptId: UInt64,
        chunkIndex: Int,
        chunkSize: Int,
        startByte: Int64,
        isUrgent: Bool,
        isRescue: Bool,
        isDirectRange: Bool = false,
        requestOriginURL: URL,
        usedRedirectedURL: Bool,
        redirectEpoch: UInt64 = 0,
        owner: TurboStreamByteHandle
    ) {
        self.attemptId = attemptId
        self.chunkIndex = chunkIndex
        self.chunkSize = chunkSize
        self.startByte = startByte
        self.isUrgent = isUrgent
        self.isRescue = isRescue
        self.isDirectRange = isDirectRange
        self.requestOriginURL = requestOriginURL
        self.usedRedirectedURL = usedRedirectedURL
        self.redirectEpoch = redirectEpoch
        self.owner = owner
    }
}

internal final class TurboStreamingSessionHub: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = TurboStreamingSessionHub()

    private let lock = NSLock()
    private var contexts: [Int: StreamingChunkContext] = [:]
    private let delegateQueue: OperationQueue
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 45
        return URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }()

    var sharedURLSession: URLSession { session }

    override private init() {
        let q = OperationQueue()
        q.name = "com.donby.turbo.streaming"
        q.maxConcurrentOperationCount = 8
        q.qualityOfService = .userInitiated
        self.delegateQueue = q
        super.init()
    }

    @discardableResult
    fileprivate func startTask(request: URLRequest, context: StreamingChunkContext) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.priority = context.isUrgent ? URLSessionTask.highPriority : URLSessionTask.defaultPriority
        context.dataTask = task
        lock.lock()
        contexts[task.taskIdentifier] = context
        lock.unlock()
        task.resume()
        return task
    }

    func cancelTask(_ task: URLSessionDataTask, intentional: Bool) {
        lock.lock()
        if let ctx = contexts[task.taskIdentifier], intentional {
            ctx.cancelledIntentionally = true
        }
        lock.unlock()
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200

        lock.lock()
        guard let ctx = contexts[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.allow)
            return
        }
        if ctx.cancelledIntentionally {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let valid = (status == 206) || (status == 200 && (ctx.chunkIndex == 0 || ctx.isDirectRange))
        ctx.statusCode = status
        ctx.acceptBody = valid
        let parsedTotal = TurboStreamByteHandle.parseTotalSize(from: http, startByte: ctx.startByte, dataCount: 0)
        ctx.parsedTotalSize = parsedTotal
        if !valid {
            ctx.rejectedByStatus = true
        }
        let owner = ctx.owner
        let chunkIdx = ctx.chunkIndex
        let originURL = ctx.requestOriginURL
        lock.unlock()

        if !valid {
            completionHandler(.cancel)
            return
        }

        owner?.handleChunkResponseHeaders(
            index: chunkIdx,
            statusCode: status,
            parsedTotalSize: parsedTotal,
            finalURL: http?.url,
            originURL: originURL
        )
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard let ctx = contexts[dataTask.taskIdentifier],
              ctx.acceptBody,
              !ctx.cancelledIntentionally,
              !ctx.reached200Cap else {
            lock.unlock()
            return
        }

        let appendData: Data
        var shouldCancelAfter200Cap = false
        if ctx.statusCode == 200 {
            let remaining = max(0, ctx.chunkSize - ctx.bytesReceived)
            if remaining <= 0 {
                ctx.reached200Cap = true
                lock.unlock()
                dataTask.cancel()
                return
            }
            appendData = data.count > remaining ? Data(data.prefix(remaining)) : data
            ctx.bytesReceived += appendData.count
            if ctx.bytesReceived >= ctx.chunkSize {
                ctx.reached200Cap = true
                shouldCancelAfter200Cap = true
            }
        } else {
            appendData = data
            ctx.bytesReceived += appendData.count
        }
        let attemptId = ctx.attemptId
        let chunkIndex = ctx.chunkIndex
        let isDirect = ctx.isDirectRange
        let startByte = ctx.startByte
        let owner = ctx.owner
        lock.unlock()

        if isDirect {
            owner?.appendDirectRangePartial(attemptId: attemptId, startOffset: startByte, delta: appendData)
        } else {
            owner?.appendChunkPartialData(attemptId: attemptId, index: chunkIndex, delta: appendData)
        }

        if shouldCancelAfter200Cap {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let ctx = contexts.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        let attemptId = ctx.attemptId
        let chunkIndex = ctx.chunkIndex
        let startByte = ctx.startByte
        let isUrgent = ctx.isUrgent
        let isRescue = ctx.isRescue
        let isDirect = ctx.isDirectRange
        let usedRedirected = ctx.usedRedirectedURL
        let redirectEpoch = ctx.redirectEpoch
        let totalSize = ctx.parsedTotalSize
        let status = ctx.rejectedByStatus ? ctx.statusCode : (error == nil ? ctx.statusCode : -1)
        let succeeded = ctx.reached200Cap || (error == nil && ctx.acceptBody && !ctx.rejectedByStatus && !ctx.cancelledIntentionally)
        let wasCancelled = ctx.cancelledIntentionally && !ctx.reached200Cap
        let owner = ctx.owner
        lock.unlock()

        if isDirect {
            owner?.finishDirectRangeAttempt(
                attemptId: attemptId,
                startOffset: startByte,
                usedRedirectedURL: usedRedirected,
                redirectEpoch: redirectEpoch,
                totalSize: totalSize,
                statusCode: status,
                succeeded: succeeded,
                wasCancelled: wasCancelled
            )
        } else {
            owner?.finishStreamingAttempt(
                attemptId: attemptId,
                index: chunkIndex,
                isUrgent: isUrgent,
                isRescue: isRescue,
                usedRedirectedURL: usedRedirected,
                redirectEpoch: redirectEpoch,
                totalSize: totalSize,
                statusCode: status,
                succeeded: succeeded,
                wasCancelled: wasCancelled
            )
        }
    }
}

public final class TurboStreamByteHandle: @unchecked Sendable {
    public let assetKey: String
    public let streamURL: URL
    public let headers: [String: String]
    public let store: TieredAssetChunkStore
    private let onResolvedRedirectURL: (@Sendable (URL) -> Void)?

    private let condition = NSCondition()
    private var cursorOffset: Int64 = 0
    private var isAborted: Bool = false
    private var isClosed: Bool = false
    private var effectiveStreamURL: URL? = nil
    private var effectiveRedirectEpoch: UInt64 = 0
    private var didNotifyRedirectCallback: Bool = false

    private var inOpenProbePhase: Bool = true
    private var chunk0HeadersReceived: Bool = false
    private let openedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    private var nextAttemptId: UInt64 = 1
    private var shouldYieldReadHandler: (@Sendable () -> Bool)? = nil
    private var inFlightChunks: Set<Int> = []
    private var rescueChunks: Set<Int> = []
    private var chunkStartTime: [Int: TimeInterval] = [:]
    private var chunkNextRetryTime: [Int: TimeInterval] = [:]
    private var chunk429Retries: [Int: Int] = [:]
    private var failedCount: [Int: Int] = [:]
    private var activeBulkWorkers: Int = 0
    private var configuredConcurrencyBudget: Int
    private var dynamicConcurrencyCap: Int
    private var prefetchAheadChunks: Int
    private var last429BackoffUntil: TimeInterval = 0
    private var last429StepDownUptime: TimeInterval = 0
    private var cleanSuccessesSinceLast429: Int = 0
    private var measuredWireSpeedMBs: Double = 0.0
    private var recentWireBytes: Int64 = 0
    private var recentWireTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime

    private struct ActiveAttemptRecord {
        let attemptId: UInt64
        let chunkIndex: Int
        let isUrgent: Bool
        let isRescue: Bool
        weak var task: URLSessionDataTask?
        var lastByteTimestamp: TimeInterval
    }

    private var activeAttempts: [UInt64: ActiveAttemptRecord] = [:]
    private var attemptBuffers: [UInt64: Data] = [:]
    private var activeDisplayAttempt: [Int: UInt64] = [:]
    private var directSlices: [(startOffset: Int64, data: Data)] = []
    private var directInFlightStarts: [Int64: UInt64] = [:]
    private var directFailedStarts: [Int64: Int] = [:]
    private var direct429Retries: [Int64: Int] = [:]
    private var directNextRetryTime: [Int64: TimeInterval] = [:]

    private var coordinatorTask: Task<Void, Never>?

    public init(
        assetKey: String,
        streamURL: URL,
        headers: [String: String],
        store: TieredAssetChunkStore,
        knownTotalSize: Int64? = nil,
        connectionBudget: Int = 4,
        prefetchAheadChunks: Int = 72,
        onResolvedRedirectURL: (@Sendable (URL) -> Void)? = nil
    ) {
        self.assetKey = assetKey
        self.streamURL = streamURL
        self.headers = headers
        self.store = store
        let clampedBudget = max(1, min(8, connectionBudget))
        self.configuredConcurrencyBudget = clampedBudget
        self.dynamicConcurrencyCap = clampedBudget
        self.prefetchAheadChunks = max(12, min(360, prefetchAheadChunks))
        self.onResolvedRedirectURL = onResolvedRedirectURL

        if let knownTotalSize, knownTotalSize > 0 {
            store.setTotalSize(knownTotalSize, sourceURL: streamURL.absoluteString)
        }
        if store.hasChunk(0) {
            self.chunk0HeadersReceived = true
        }
        store.retainReader()

        // Immediately start Chunk 0 uncontended so header bytes & redirect settle with zero queue competition.
        if !store.hasChunk(0) {
            requestUrgentChunk(0)
        }
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
        let clampedBudget = max(1, min(8, connectionBudget))
        self.configuredConcurrencyBudget = clampedBudget
        self.dynamicConcurrencyCap = clampedBudget
        self.prefetchAheadChunks = max(12, min(360, prefetchAheadChunks))
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

    public func interruptPendingReadForSeek() {
        wakeWaitingReads()
    }

    private func shouldYieldCurrentReadLocked() -> Bool {
        if isAborted || isClosed { return true }
        return shouldYieldReadHandler?() ?? false
    }

    private func shouldYieldReadAtOffsetLocked(_ offset: Int64, totalSize: Int64, chunkSize: Int) -> Bool {
        if isAborted || isClosed { return true }
        // Never abort a near-tail container index read (e.g. 64+ KB Matroska Cues at the end of a 3h 30GB MKV)
        // on an intermediate seek, because FFmpeg sets `cues_parsing_deferred = 0` before reading Cues.
        if totalSize > Int64(chunkSize * 4) && offset >= totalSize - Int64(chunkSize * 2) {
            return false
        }
        return shouldYieldReadHandler?() ?? false
    }

    private func isChunkInFlight(_ chunkIndex: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return inFlightChunks.contains(chunkIndex)
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

        // Fast path 2: progressive bytes already streamed into active partial buffer
        if let partialCopied = tryCopyPartialLockedOut(targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
            return partialCopied
        }

        // Fast path 3: exact-offset unaligned EOF tail read (check inFlightChunks under lock to avoid Swift Set race)
        if meta.totalSize > 0,
           currentOffset >= meta.totalSize - Int64(chunkSize),
           offsetInChunk >= 16_384,
           !isChunkInFlight(targetChunk) {
            return readDirectTailRange(at: currentOffset, totalSize: meta.totalSize, into: buffer, count: count)
        }

        condition.lock()
        if shouldYieldReadAtOffsetLocked(currentOffset, totalSize: meta.totalSize, chunkSize: chunkSize) {
            condition.unlock()
            return -1
        }
        condition.unlock()

        // Urgent path: trigger urgent streaming fetch & wake coordinator
        requestUrgentChunk(targetChunk)

        let hardDeadline = Date().addingTimeInterval(26.0)
        var stallDeadline = Date().addingTimeInterval(15.0)
        condition.lock()
        while !shouldYieldReadAtOffsetLocked(currentOffset, totalSize: meta.totalSize, chunkSize: chunkSize) {
            if let partialCopied = tryCopyPartialLocked(targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count) {
                condition.unlock()
                return partialCopied
            }
            if (failedCount[targetChunk] ?? 0) >= 6 || (chunk429Retries[targetChunk] ?? 0) >= 12 {
                condition.unlock()
                return -1
            }
            let nowDate = Date()
            if nowDate >= stallDeadline || nowDate >= hardDeadline {
                condition.unlock()
                return -1
            }
            let now = ProcessInfo.processInfo.systemUptime
            let activeAttempt = activeDisplayAttempt[targetChunk].flatMap { activeAttempts[$0] }
            let receivedAnyBytes = activeAttempt.flatMap { attemptBuffers[$0.attemptId]?.isEmpty == false } ?? false
            let stalledTime: TimeInterval = activeAttempt.map { now - $0.lastByteTimestamp } ?? (chunkStartTime[targetChunk].map { now - $0 } ?? 0)
            if receivedAnyBytes && stalledTime < 2.0 {
                stallDeadline = min(hardDeadline, nowDate.addingTimeInterval(12.0))
            }
            // If previous attempt failed or hit 429 cooldown and finished, re-trigger urgent fetch cleanly once retry delay elapses.
            if !inFlightChunks.contains(targetChunk), now >= (chunkNextRetryTime[targetChunk] ?? 0) {
                inFlightChunks.insert(targetChunk)
                chunkStartTime[targetChunk] = now
                spawnChunkFetchLocked(index: targetChunk, isUrgent: true, isRescue: false)
                condition.unlock()
                if let chunkData = store.readChunk(index: targetChunk) {
                    return copyOut(from: chunkData, offsetInChunk: offsetInChunk, into: buffer, count: count, targetChunk: targetChunk)
                }
                condition.lock()
                continue
            }
            // Wait up to 2.8s on cold Chunk 0 before spawning duplicate rescue; avoid duplicate rescue during 429 cooldown.
            let rescueThreshold: TimeInterval = receivedAnyBytes ? 2.2 : ((targetChunk == 0 && !chunk0HeadersReceived) ? 2.8 : 1.4)
            if now >= last429BackoffUntil &&
                (chunkStartTime[targetChunk] != nil) &&
                stalledTime > rescueThreshold &&
                !rescueChunks.contains(targetChunk) {
                rescueChunks.insert(targetChunk)
                spawnChunkFetchLocked(index: targetChunk, isUrgent: true, isRescue: true)
            }
            condition.wait(until: Date().addingTimeInterval(0.03))
            condition.unlock()
            if let chunkData = store.readChunk(index: targetChunk) {
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

    private func tryCopyPartialLockedOut(
        targetChunk: Int,
        offsetInChunk: Int,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        return tryCopyPartialLocked(targetChunk: targetChunk, offsetInChunk: offsetInChunk, into: buffer, count: count)
    }

    private func tryCopyPartialLocked(
        targetChunk: Int,
        offsetInChunk: Int,
        into buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int? {
        guard let dispAttempt = activeDisplayAttempt[targetChunk],
              let partial = attemptBuffers[dispAttempt],
              offsetInChunk < partial.count else {
            return nil
        }
        let available = partial.count - offsetInChunk
        let toCopy = min(count, available)
        partial.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                buffer.update(from: base.advanced(by: offsetInChunk), count: toCopy)
            }
        }
        cursorOffset += Int64(toCopy)
        condition.broadcast()
        return toCopy
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
            if now >= (directNextRetryTime[offset] ?? 0),
               directInFlightStarts[offset] == nil,
               !directInFlightStarts.keys.contains(where: { $0 <= offset && offset < $0 + 262_144 }) {
                spawnDirectRangeFetchLocked(startOffset: offset, totalSize: totalSize)
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
        for slice in directSlices {
            if offset >= slice.startOffset {
                let rel = Int(offset - slice.startOffset)
                if rel < slice.data.count {
                    let avail = slice.data.count - rel
                    let toCopy = min(count, avail)
                    slice.data.withUnsafeBytes { raw in
                        if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                            buffer.update(from: base.advanced(by: rel), count: toCopy)
                        }
                    }
                    cursorOffset += Int64(toCopy)
                    condition.broadcast()
                    return toCopy
                }
            }
        }
        for (startOff, attemptId) in directInFlightStarts where offset >= startOff {
            if let buf = attemptBuffers[attemptId] {
                let rel = Int(offset - startOff)
                if rel < buf.count {
                    let avail = buf.count - rel
                    let toCopy = min(count, avail)
                    buf.withUnsafeBytes { raw in
                        if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                            buffer.update(from: base.advanced(by: rel), count: toCopy)
                        }
                    }
                    cursorOffset += Int64(toCopy)
                    condition.broadcast()
                    return toCopy
                }
            }
        }
        return nil
    }

    private func spawnDirectRangeFetchLocked(startOffset: Int64, totalSize: Int64) {
        let endByte = min(totalSize - 1, startOffset + 262_143)
        guard endByte >= startOffset else { return }

        let usedRedirected = (effectiveStreamURL != nil)
        let targetURL = effectiveStreamURL ?? streamURL
        var req = URLRequest(url: targetURL, timeoutInterval: 10.0)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sameOrigin = (targetURL.host?.lowercased() == streamURL.host?.lowercased())
        for (k, v) in headers {
            if !sameOrigin && k.lowercased() == "authorization" { continue }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Donby/1.0 (macOS; UHDNow Client)", forHTTPHeaderField: "User-Agent")
        }
        req.setValue("bytes=\(startOffset)-\(endByte)", forHTTPHeaderField: "Range")

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
        let task = TurboStreamingSessionHub.shared.startTask(request: req, context: ctx)
        activeAttempts[attemptId] = ActiveAttemptRecord(
            attemptId: attemptId,
            chunkIndex: -1,
            isUrgent: true,
            isRescue: false,
            task: task,
            lastByteTimestamp: now
        )
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
        if total > 0 && newPos > total {
            cursorOffset = total
        } else {
            cursorOffset = newPos
        }

        let newChunk = Int(max(0, cursorOffset) / Int64(meta.chunkSize))
        var tasksToCancel: [URLSessionDataTask] = []
        let totalChunks = total > 0 ? Int((total + Int64(meta.chunkSize) - 1) / Int64(meta.chunkSize)) : 0
        let isNearTailProbe = totalChunks > 2 && newChunk >= totalChunks - 2
        if abs(newChunk - oldChunk) > 4 {
            let keepEnd = newChunk + prefetchAheadChunks
            for (_, rec) in activeAttempts {
                if rec.chunkIndex == 0 && inOpenProbePhase { continue }
                // On a real playback jump (not an EOF cue probe), also cancel stale out-of-window urgent/rescue tasks
                // so HTTP/2 sockets & CDN slots immediately serve the newly seeked position.
                let cancelUrgent = !isNearTailProbe && rec.chunkIndex >= 0
                if !rec.isUrgent || cancelUrgent {
                    if rec.chunkIndex < max(0, newChunk - 1) || rec.chunkIndex > keepEnd {
                        if let task = rec.task {
                            tasksToCancel.append(task)
                        }
                    }
                }
            }
            // Give the newly seeked target chunk a clean retry budget immediately
            failedCount.removeValue(forKey: newChunk)
            chunk429Retries.removeValue(forKey: newChunk)
            chunkNextRetryTime.removeValue(forKey: newChunk)
        }
        let resultPos = cursorOffset
        condition.broadcast()
        condition.unlock()

        for task in tasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(task, intentional: true)
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
            let key = assetKey
            Task { @MainActor in
                DonbyDownloadManager.shared.cleanupRedundantCacheIfMaterialized(assetKey: key)
            }
        }
    }

    private func requestUrgentChunk(_ chunkIndex: Int) {
        condition.lock()
        let alreadyInFlight = inFlightChunks.contains(chunkIndex)
        if !alreadyInFlight && !isAborted && !isClosed {
            inFlightChunks.insert(chunkIndex)
            chunkStartTime[chunkIndex] = ProcessInfo.processInfo.systemUptime
            spawnChunkFetchLocked(index: chunkIndex, isUrgent: true, isRescue: false)
        } else if alreadyInFlight, let dispId = activeDisplayAttempt[chunkIndex], let task = activeAttempts[dispId]?.task {
            task.priority = URLSessionTask.highPriority
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
                try? await Task.sleep(nanoseconds: 25_000_000)
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
        if inOpenProbePhase && (now - openedUptime > 2.2) {
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

        // During open probe phase, keep initial Chunk 0 & tail seek uncontended until Chunk 0 headers arrive,
        // and allow at most 1 lookahead chunk right behind cursor until `markInitialOpenCompleted()` fires.
        let effectiveCap: Int
        if inOpenProbePhase {
            effectiveCap = chunk0HeadersReceived ? min(1, dynamicConcurrencyCap) : 0
        } else {
            effectiveCap = dynamicConcurrencyCap
        }

        let totalChunks = meta.totalChunks
        let ahead = prefetchAheadChunks

        // Check stalled bulk chunks near cursor needing rescue
        for idx in inFlightChunks where idx >= currentChunk && idx <= currentChunk + 2 {
            if let started = chunkStartTime[idx], now - started > 2.4, !rescueChunks.contains(idx) {
                rescueChunks.insert(idx)
                spawnChunkFetchLocked(index: idx, isUrgent: true, isRescue: true)
            }
        }

        if activeBulkWorkers < effectiveCap {
            let maxChunk = totalChunks > 0 ? min(totalChunks - 1, currentChunk + ahead) : (currentChunk + min(ahead, 12))
            if maxChunk >= currentChunk {
                for candidate in currentChunk...maxChunk {
                    if activeBulkWorkers >= effectiveCap { break }
                    if inFlightChunks.contains(candidate) { continue }
                    if (failedCount[candidate] ?? 0) >= 6 || (chunk429Retries[candidate] ?? 0) >= 12 { continue }
                    if now < (chunkNextRetryTime[candidate] ?? 0) { continue }
                    if store.hasChunk(candidate) { continue }
                    inFlightChunks.insert(candidate)
                    activeBulkWorkers += 1
                    chunkStartTime[candidate] = now
                    spawnChunkFetchLocked(index: candidate, isUrgent: false, isRescue: false)
                }
            }
        }
        condition.unlock()
        return false
    }

    private func spawnChunkFetchLocked(index: Int, isUrgent: Bool, isRescue: Bool) {
        let meta = store.currentMeta()
        let chunkSize = meta.chunkSize
        let startByte = Int64(index) * Int64(chunkSize)
        if meta.totalSize > 0 && startByte >= meta.totalSize {
            if !isUrgent && !isRescue {
                activeBulkWorkers = max(0, activeBulkWorkers - 1)
            }
            if !isRescue { inFlightChunks.remove(index) } else { rescueChunks.remove(index) }
            condition.broadcast()
            return
        }
        let endByte: Int64 = {
            if meta.totalSize > 0 {
                return min(meta.totalSize - 1, startByte + Int64(chunkSize) - 1)
            }
            return startByte + Int64(chunkSize) - 1
        }()

        let usedRedirected = (effectiveStreamURL != nil)
        let targetURL = effectiveStreamURL ?? streamURL
        var req = URLRequest(url: targetURL, timeoutInterval: isUrgent ? 10.0 : 16.0)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sameOrigin = (targetURL.host?.lowercased() == streamURL.host?.lowercased())
        for (k, v) in headers {
            if !sameOrigin && k.lowercased() == "authorization" { continue }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Donby/1.0 (macOS; UHDNow Client)", forHTTPHeaderField: "User-Agent")
        }
        req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        let attemptId = nextAttemptId
        nextAttemptId &+= 1
        let now = ProcessInfo.processInfo.systemUptime

        let ctx = StreamingChunkContext(
            attemptId: attemptId,
            chunkIndex: index,
            chunkSize: chunkSize,
            startByte: startByte,
            isUrgent: isUrgent,
            isRescue: isRescue,
            requestOriginURL: targetURL,
            usedRedirectedURL: usedRedirected,
            redirectEpoch: usedRedirected ? effectiveRedirectEpoch : 0,
            owner: self
        )

        var buf = Data()
        buf.reserveCapacity(Int(endByte - startByte + 1))
        attemptBuffers[attemptId] = buf
        if activeDisplayAttempt[index] == nil {
            activeDisplayAttempt[index] = attemptId
        }
        let task = TurboStreamingSessionHub.shared.startTask(request: req, context: ctx)
        activeAttempts[attemptId] = ActiveAttemptRecord(
            attemptId: attemptId,
            chunkIndex: index,
            isUrgent: isUrgent,
            isRescue: isRescue,
            task: task,
            lastByteTimestamp: now
        )
    }

    fileprivate func handleChunkResponseHeaders(
        index: Int,
        statusCode: Int,
        parsedTotalSize: Int64?,
        finalURL: URL?,
        originURL: URL
    ) {
        if let parsedTotalSize, parsedTotalSize > 0 {
            store.setTotalSize(parsedTotalSize, sourceURL: streamURL.absoluteString)
        }

        var notifyRedirectURL: URL? = nil
        condition.lock()
        if index == 0 {
            chunk0HeadersReceived = true
        }
        if let finalURL,
           finalURL.absoluteString != originURL.absoluteString,
           finalURL.absoluteString != streamURL.absoluteString {
            if effectiveStreamURL?.absoluteString != finalURL.absoluteString {
                effectiveStreamURL = finalURL
                effectiveRedirectEpoch &+= 1
            }
            if !didNotifyRedirectCallback {
                didNotifyRedirectCallback = true
                notifyRedirectURL = finalURL
            }
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

    fileprivate func appendChunkPartialData(attemptId: UInt64, index: Int, delta: Data) {
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

        if let curDisp = activeDisplayAttempt[index] {
            if curDisp != attemptId && (attemptBuffers[curDisp]?.count ?? 0) < buf.count {
                activeDisplayAttempt[index] = attemptId
            }
        } else {
            activeDisplayAttempt[index] = attemptId
        }

        // Update wire throughput progressively as bytes stream in
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
    }

    fileprivate func appendDirectRangePartial(attemptId: UInt64, startOffset: Int64, delta: Data) {
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

    private func handleRateLimit429Locked(now: TimeInterval) {
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

    private func recordCleanCompletionAndRecoverConcurrencyLocked(now: TimeInterval) {
        guard dynamicConcurrencyCap < configuredConcurrencyBudget else { return }
        guard now >= last429BackoffUntil + 2.5 else { return }
        cleanSuccessesSinceLast429 += 1
        if cleanSuccessesSinceLast429 >= 8 {
            cleanSuccessesSinceLast429 = 0
            dynamicConcurrencyCap = min(configuredConcurrencyBudget, dynamicConcurrencyCap + 1)
            DonbyLogger.shared.log("Turbo 分片引擎限流缓解，并发恢复至 \(dynamicConcurrencyCap)", level: .info, subsystem: "TurboCache")
        }
    }

    fileprivate func finishDirectRangeAttempt(
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
        condition.lock()
        activeAttempts.removeValue(forKey: attemptId)
        if directInFlightStarts[startOffset] == attemptId {
            directInFlightStarts.removeValue(forKey: startOffset)
        }
        let data = attemptBuffers.removeValue(forKey: attemptId)
        if succeeded, let data, !data.isEmpty {
            directFailedStarts.removeValue(forKey: startOffset)
            direct429Retries.removeValue(forKey: startOffset)
            directNextRetryTime.removeValue(forKey: startOffset)
            directSlices.removeAll { $0.startOffset == startOffset }
            directSlices.append((startOffset: startOffset, data: data))
            if directSlices.count > 12 {
                directSlices.removeFirst()
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
    }

    fileprivate func finishStreamingAttempt(
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
        var completedData: Data? = nil
        var competingTasksToCancel: [URLSessionDataTask] = []
        var scheduleNext = false

        condition.lock()
        activeAttempts.removeValue(forKey: attemptId)
        let data = attemptBuffers.removeValue(forKey: attemptId)

        if !isUrgent && !isRescue {
            activeBulkWorkers = max(0, activeBulkWorkers - 1)
        }

        if succeeded, let data, !data.isEmpty {
            completedData = data
            inFlightChunks.remove(index)
            rescueChunks.remove(index)
            chunkStartTime.removeValue(forKey: index)
            chunkNextRetryTime.removeValue(forKey: index)
            chunk429Retries.removeValue(forKey: index)
            failedCount.removeValue(forKey: index)
            activeDisplayAttempt.removeValue(forKey: index)
            recordCleanCompletionAndRecoverConcurrencyLocked(now: now)

            // Cancel any competing attempt still running for the same chunk index
            let competingIds = activeAttempts.values.filter { $0.chunkIndex == index }.map(\.attemptId)
            for cid in competingIds {
                if let rec = activeAttempts.removeValue(forKey: cid) {
                    if !rec.isUrgent && !rec.isRescue {
                        activeBulkWorkers = max(0, activeBulkWorkers - 1)
                    }
                    if let t = rec.task { competingTasksToCancel.append(t) }
                }
                attemptBuffers.removeValue(forKey: cid)
            }
            if index == 0 {
                chunk0HeadersReceived = true
            }
            scheduleNext = !isAborted && !isClosed
        } else {
            if activeDisplayAttempt[index] == attemptId {
                let fallbackAttempt = activeAttempts.values
                    .filter { $0.chunkIndex == index }
                    .max { (attemptBuffers[$0.attemptId]?.count ?? 0) < (attemptBuffers[$1.attemptId]?.count ?? 0) }
                if let fallbackAttempt {
                    activeDisplayAttempt[index] = fallbackAttempt.attemptId
                } else {
                    activeDisplayAttempt.removeValue(forKey: index)
                }
            }
            let hasOtherAttempt = activeAttempts.values.contains { $0.chunkIndex == index }
            if !hasOtherAttempt {
                if !isRescue { inFlightChunks.remove(index) }
                rescueChunks.remove(index)
            } else if isRescue {
                rescueChunks.remove(index)
            }

            if !wasCancelled {
                if statusCode == 429 {
                    handleRateLimit429Locked(now: now)
                    let r = (chunk429Retries[index] ?? 0) + 1
                    chunk429Retries[index] = r
                    chunkNextRetryTime[index] = now + min(2.4, 0.45 * Double(r))
                } else if usedRedirectedURL && (statusCode == 200 || statusCode >= 400) && statusCode != 416 {
                    // Cached 302 CDN URL expired or rejected; clear redirect once per epoch & retry origin URL cleanly
                    if redirectEpoch == effectiveRedirectEpoch {
                        effectiveStreamURL = nil
                    }
                    chunkNextRetryTime[index] = now + 0.05
                } else if statusCode != 416 {
                    let f = (failedCount[index] ?? 0) + 1
                    failedCount[index] = f
                    chunkNextRetryTime[index] = now + min(1.5, 0.15 * Double(f))
                }
            }
            scheduleNext = !isAborted && !isClosed && !wasCancelled
        }
        condition.broadcast()
        condition.unlock()

        if let completedData {
            store.storeChunk(index: index, data: completedData)
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        for t in competingTasksToCancel {
            TurboStreamingSessionHub.shared.cancelTask(t, intentional: true)
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
}

// MARK: - Task C & D: Global Turbo Cache Engine & Disk LRU Manager

public struct CachedMediaSummary: Identifiable, Equatable, Sendable {
    public var id: String { assetKey }
    public let assetKey: String
    public let serverId: UUID?
    public let itemId: String?
    public let mediaSourceId: String?
    public let displayTitle: String
    public let subtitle: String?
    public let posterURLString: String?
    public let sourceURLString: String
    public let cachedBytes: Int64
    public let totalBytes: Int64
    public let lastAccess: Date
    public let isFullyCached: Bool
    public let itemSnapshot: EmbyItem?
    public let mediaSourceSnapshot: MediaSourceInfo?

    public init(
        assetKey: String,
        serverId: UUID?,
        itemId: String?,
        mediaSourceId: String?,
        displayTitle: String,
        subtitle: String?,
        posterURLString: String?,
        sourceURLString: String,
        cachedBytes: Int64,
        totalBytes: Int64,
        lastAccess: Date,
        isFullyCached: Bool,
        itemSnapshot: EmbyItem?,
        mediaSourceSnapshot: MediaSourceInfo?
    ) {
        self.assetKey = assetKey
        self.serverId = serverId
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.posterURLString = posterURLString
        self.sourceURLString = sourceURLString
        self.cachedBytes = cachedBytes
        self.totalBytes = totalBytes
        self.lastAccess = lastAccess
        self.isFullyCached = isFullyCached
        self.itemSnapshot = itemSnapshot
        self.mediaSourceSnapshot = mediaSourceSnapshot
    }

    public var progressFraction: Double {
        guard totalBytes > 0 else { return isFullyCached ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(cachedBytes) / Double(totalBytes)))
    }
}

public final class DonbyTurboCacheEngine: @unchecked Sendable {
    public static let shared = DonbyTurboCacheEngine()

    public let cacheRootDirectory: URL
    private let lock = NSLock()
    private var activeStores: [String: TieredAssetChunkStore] = [:]
    private var fullCacheHandler: (@Sendable (ChunkStoreMeta) -> Void)?

    public func setOnAssetFullyCached(_ handler: (@Sendable (ChunkStoreMeta) -> Void)?) {
        lock.lock()
        fullCacheHandler = handler
        lock.unlock()
    }

    internal func notifyAssetFullyCached(_ meta: ChunkStoreMeta) {
        lock.lock()
        let handler = fullCacheHandler
        lock.unlock()
        handler?(meta)
    }

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
            chunkSize: 524_288,
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

    private static func physicalOrCachedBytes(for dataURL: URL, meta: ChunkStoreMeta?) -> Int64 {
        let fm = FileManager.default
        let hasMediaBin = fm.fileExists(atPath: dataURL.path)
        let chunksDir = dataURL.deletingLastPathComponent().appendingPathComponent("chunks", isDirectory: true)
        let hasSpillChunks = fm.fileExists(atPath: chunksDir.path)
        guard hasMediaBin || hasSpillChunks else {
            return 0
        }
        if let meta, !meta.completedChunks.isEmpty {
            return meta.cachedBytes
        }
        if let vals = try? dataURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
           let alloc = vals.totalFileAllocatedSize ?? vals.fileAllocatedSize, alloc > 0 {
            return Int64(alloc)
        }
        if let attrs = try? fm.attributesOfItem(atPath: dataURL.path),
           let sz = attrs[.size] as? NSNumber {
            return sz.int64Value
        }
        return 0
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
                let parsedMeta: ChunkStoreMeta? = {
                    guard let d = try? Data(contentsOf: metaURL) else { return nil }
                    return try? JSONDecoder().decode(ChunkStoreMeta.self, from: d)
                }()
                let isPinned = parsedMeta?.pinned ?? false
                let fileSize = Self.physicalOrCachedBytes(for: dataURL, meta: parsedMeta)
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
            let sz = Self.physicalOrCachedBytes(for: dataURL, meta: m)
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

    public func cachedProgress(
        forItemId itemId: String,
        serverId: UUID? = nil,
        mediaSourceId: String? = nil
    ) -> CachedMediaSummary? {
        if let serverId, let mediaSourceId, !mediaSourceId.isEmpty {
            let exactKey = Self.makeAssetKey(serverId: serverId, itemId: itemId, mediaSourceId: mediaSourceId)
            if let hit = listUnpinnedCachedAssets().first(where: { $0.assetKey == exactKey }) {
                return hit
            }
        }
        return listUnpinnedCachedAssets().first { summary in
            summary.itemId == itemId &&
            (serverId == nil || summary.serverId == serverId) &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || summary.mediaSourceId == mediaSourceId)
        }
    }

    public func listUnpinnedCachedAssets(excludingAssetKeys: Set<String> = []) -> [CachedMediaSummary] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: cacheRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        var results: [CachedMediaSummary] = []

        for dir in dirs {
            let key = dir.lastPathComponent
            if excludingAssetKeys.contains(key) { continue }
            let metaURL = dir.appendingPathComponent("meta.json")
            let dataURL = dir.appendingPathComponent("media.bin")
            guard let d = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(ChunkStoreMeta.self, from: d) else {
                continue
            }
            if meta.pinned { continue }
            let cachedBytes = Self.physicalOrCachedBytes(for: dataURL, meta: meta)
            guard cachedBytes > 0 else { continue }

            let fallbackTitle = meta.itemSnapshot?.name
                ?? URL(string: meta.sourceURLString)?.lastPathComponent
                ?? "未命名流媒体缓存"
            let title = (meta.displayTitle?.isEmpty == false ? meta.displayTitle : nil) ?? fallbackTitle

            results.append(CachedMediaSummary(
                assetKey: meta.assetKey,
                serverId: meta.serverId,
                itemId: meta.itemId ?? meta.itemSnapshot?.id,
                mediaSourceId: meta.mediaSourceId ?? meta.mediaSourceSnapshot?.id,
                displayTitle: title,
                subtitle: meta.subtitle,
                posterURLString: meta.posterURLString,
                sourceURLString: meta.sourceURLString,
                cachedBytes: cachedBytes,
                totalBytes: meta.totalSize,
                lastAccess: meta.lastAccess,
                isFullyCached: meta.isFullyCached,
                itemSnapshot: meta.itemSnapshot,
                mediaSourceSnapshot: meta.mediaSourceSnapshot
            ))
        }

        return results.sorted { $0.lastAccess > $1.lastAccess }
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

public enum DownloadOrigin: String, Codable, Sendable {
    case manualDownload = "manual"
    case autoArchivedFromCache = "autoArchived"
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
    public var origin: DownloadOrigin
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case assetKey, serverId, serverName, itemId, mediaSourceId, title, subtitle, posterURLString
        case resolutionBadge, streamURLString, downloadURLString, headers, itemSnapshot, mediaSourceSnapshot
        case offlineSubtitles, localVideoFilePath, localFolderPath, localSeriesFolderPath
        case localPosterPath, localBackdropPath, localThumbPath, localLogoPath
        case status, totalBytes, downloadedBytes, speedMBs, errorMessage, origin, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetKey = try c.decode(String.self, forKey: .assetKey)
        serverId = try c.decode(UUID.self, forKey: .serverId)
        serverName = try c.decode(String.self, forKey: .serverName)
        itemId = try c.decode(String.self, forKey: .itemId)
        mediaSourceId = try c.decode(String.self, forKey: .mediaSourceId)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        posterURLString = try c.decodeIfPresent(String.self, forKey: .posterURLString)
        resolutionBadge = try c.decodeIfPresent(String.self, forKey: .resolutionBadge)
        streamURLString = try c.decode(String.self, forKey: .streamURLString)
        downloadURLString = try c.decode(String.self, forKey: .downloadURLString)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        itemSnapshot = try c.decode(EmbyItem.self, forKey: .itemSnapshot)
        mediaSourceSnapshot = try c.decode(MediaSourceInfo.self, forKey: .mediaSourceSnapshot)
        offlineSubtitles = try c.decodeIfPresent([OfflineSubtitleAsset].self, forKey: .offlineSubtitles) ?? []
        localVideoFilePath = try c.decodeIfPresent(String.self, forKey: .localVideoFilePath)
        localFolderPath = try c.decodeIfPresent(String.self, forKey: .localFolderPath)
        localSeriesFolderPath = try c.decodeIfPresent(String.self, forKey: .localSeriesFolderPath)
        localPosterPath = try c.decodeIfPresent(String.self, forKey: .localPosterPath)
        localBackdropPath = try c.decodeIfPresent(String.self, forKey: .localBackdropPath)
        localThumbPath = try c.decodeIfPresent(String.self, forKey: .localThumbPath)
        localLogoPath = try c.decodeIfPresent(String.self, forKey: .localLogoPath)
        status = try c.decode(DownloadTaskStatus.self, forKey: .status)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        downloadedBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        speedMBs = try c.decodeIfPresent(Double.self, forKey: .speedMBs) ?? 0
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        origin = try c.decodeIfPresent(DownloadOrigin.self, forKey: .origin) ?? .manualDownload
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

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
        origin: DownloadOrigin = .manualDownload,
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
        self.origin = origin
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

    public func entry(forItemId itemId: String, serverId: UUID? = nil) -> DownloadEntry? {
        entries.first { entry in
            entry.itemId == itemId && (serverId == nil || entry.serverId == serverId)
        }
    }

    public func cleanupRedundantCacheIfMaterialized(assetKey: String) {
        guard let existing = entry(for: assetKey),
              existing.status == .completed,
              let localPath = existing.localVideoFilePath,
              FileManager.default.fileExists(atPath: localPath) else {
            return
        }
        DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
    }

    public func updateOfflinePlaybackProgress(
        itemId: String,
        played: Bool? = nil,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        persistDiskNow: Bool = true
    ) {
        var didChange = false
        for idx in entries.indices where entries[idx].itemId == itemId {
            var snapshot = entries[idx].itemSnapshot
            var ud = snapshot.userData ?? EmbyUserData()
            if let played {
                ud.played = played
                if played {
                    ud.playedPercentage = 100.0
                    ud.playbackPositionTicks = 0
                }
            }
            if let pos = positionSeconds, pos >= 0 {
                ud.playbackPositionTicks = Int64(pos * 10_000_000.0)
                if let dur = durationSeconds, dur > 0 {
                    let pct = min(100.0, max(0.0, (pos / dur) * 100.0))
                    ud.playedPercentage = pct
                    if pct >= 92.0 {
                        ud.played = true
                    }
                }
            }
            snapshot.userData = ud
            entries[idx].itemSnapshot = snapshot
            didChange = true

            if persistDiskNow, let localPath = entries[idx].localVideoFilePath {
                let videoURL = URL(fileURLWithPath: localPath)
                let stem = videoURL.deletingPathExtension().lastPathComponent
                let sidecarURL = videoURL.deletingLastPathComponent().appendingPathComponent("\(stem).meta.json")
                if let d = try? Data(contentsOf: sidecarURL),
                   var sidecar = try? JSONDecoder().decode(OfflineEpisodeOrMovieSidecar.self, from: d) {
                    sidecar.item = snapshot
                    if let encoded = try? JSONEncoder().encode(sidecar) {
                        try? encoded.write(to: sidecarURL, options: .atomic)
                    }
                }
            }
        }
        if didChange && persistDiskNow {
            saveToDisk()
        }
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
        connectionBudgetPerTask: Int = 3,
        origin: DownloadOrigin = .manualDownload
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
            if origin == .manualDownload {
                entries[idx].origin = .manualDownload
            }
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
                speedMBs: 0.0,
                errorMessage: nil,
                origin: origin
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
                Self.materializeAndCleanupIfIdle(store: store, assetKey: assetKey, destinationURL: layout.videoFileURL, expectedSize: total)
                await MainActor.run {
                    DonbyDownloadManager.shared.markCompleted(assetKey: assetKey, totalBytes: total)
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

    public func promoteToManualDownload(assetKey: String) {
        guard let idx = entries.firstIndex(where: { $0.assetKey == assetKey }),
              entries[idx].origin != .manualDownload else { return }
        entries[idx].origin = .manualDownload
        saveToDisk()
    }

    @discardableResult
    public func removeAutoArchivedAfterPlayback(itemId: String, mediaSourceId: String? = nil) -> DownloadEntry? {
        guard let target = entries.first(where: { entry in
            entry.origin == .autoArchivedFromCache &&
            entry.itemId == itemId &&
            (mediaSourceId == nil || mediaSourceId?.isEmpty == true || entry.mediaSourceId == mediaSourceId)
        }) else {
            return nil
        }
        removeDownload(assetKey: target.assetKey, deleteCachedData: true)
        return target
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

    @discardableResult
    nonisolated private static func materializeAndCleanupIfIdle(
        store: TieredAssetChunkStore,
        assetKey: String,
        destinationURL: URL,
        expectedSize: Int64
    ) -> Bool {
        let res = materializeCompletedVideoFile(store: store, destinationURL: destinationURL, expectedSize: expectedSize)
        if res.success && !res.keptCacheForActiveReader {
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: assetKey, forceIncludePinned: true)
        }
        return res.success
    }

    nonisolated private static func materializeCompletedVideoFile(
        store: TieredAssetChunkStore,
        destinationURL: URL,
        expectedSize: Int64
    ) -> (success: Bool, keptCacheForActiveReader: Bool) {
        let fm = FileManager.default
        let dir = destinationURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        store.prepareContiguousMediaBinForMaterialization()
        let src = store.dataFileURL
        guard fm.fileExists(atPath: src.path) else {
            return (fm.fileExists(atPath: destinationURL.path), false)
        }

        // If PlayerView is currently streaming from this ChunkStore, use APFS CoW copy instead of moving media.bin out from under the reader.
        let hasActiveReaders = store.activeReaderCount > 0
        if !hasActiveReaders {
            store.closeFileHandles()
        } else {
            store.flushMeta()
        }

        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            if hasActiveReaders {
                try fm.copyItem(at: src, to: destinationURL)
            } else {
                try fm.moveItem(at: src, to: destinationURL)
            }
            if expectedSize > 0 {
                let handle = try FileHandle(forUpdating: destinationURL)
                try handle.truncate(atOffset: UInt64(expectedSize))
                try handle.close()
            }
            return (true, hasActiveReaders)
        } catch {
            return (false, hasActiveReaders)
        }
    }

private final class DownloadRangeStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class StreamTaskState {
        let allowStatus200: Bool
        var responseContinuation: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>?
        var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var yieldedResponse = false

        init(allowStatus200: Bool) {
            self.allowStatus200 = allowStatus200
        }
    }

    private let lock = NSLock()
    private var states: [Int: StreamTaskState] = [:]

    func openStream(
        session: URLSession,
        request: URLRequest,
        allowStatus200: Bool
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let dataTask = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (respCont: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>) in
                let state = StreamTaskState(allowStatus200: allowStatus200)
                state.responseContinuation = respCont
                lock.lock()
                states[dataTask.taskIdentifier] = state
                lock.unlock()
                dataTask.resume()
            }
        } onCancel: {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier], !state.yieldedResponse else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        state.yieldedResponse = true
        let respCont = state.responseContinuation
        state.responseContinuation = nil

        guard let http = response as? HTTPURLResponse else {
            states.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            respCont?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }

        var capturedCont: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { cont in
            capturedCont = cont
        }
        capturedCont.onTermination = { _ in
            dataTask.cancel()
        }

        let accept = (http.statusCode == 206) || (http.statusCode == 200 && state.allowStatus200)
        if accept {
            state.dataContinuation = capturedCont
            lock.unlock()
            respCont?.resume(returning: (http, stream))
            completionHandler(.allow)
        } else {
            states.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            capturedCont.finish()
            respCont?.resume(returning: (http, stream))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let cont = states[dataTask.taskIdentifier]?.dataContinuation
        lock.unlock()
        cont?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let state = states.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        let respCont = state.responseContinuation
        state.responseContinuation = nil
        let dataCont = state.dataContinuation
        state.dataContinuation = nil
        let alreadyYielded = state.yieldedResponse
        state.yieldedResponse = true
        lock.unlock()

        if !alreadyYielded {
            respCont?.resume(throwing: error ?? URLError(.unknown))
        } else if let error {
            dataCont?.finish(throwing: error)
        } else {
            dataCont?.finish()
        }
    }
}

    nonisolated private static func buildRangeURLRequest(
        url: URL,
        originHost: String?,
        headers: [String: String],
        startByte: Int64,
        endByte: Int64,
        timeout: TimeInterval
    ) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sameOrigin = (url.host?.lowercased() == originHost?.lowercased())
        for (k, v) in headers {
            if !sameOrigin && k.lowercased() == "authorization" { continue }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Donby/1.0 (macOS; UHDNow Client)", forHTTPHeaderField: "User-Agent")
        }
        req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")
        return req
    }

private actor DownloadBatchCoordinator {
    enum BatchLease {
        case batch(startChunk: Int, endChunk: Int, requestURL: URL, usedCDN: Bool, redirectEpoch: UInt64)
        case wait(TimeInterval)
        case done
    }

    private var missingQueue: [Int]
    private var activeBatchEnd: Int = -1
    private var inFlightChunkCount: Int = 0
    private var activeWorkerCount: Int = 0
    private var workerCap: Int
    private let maxWorkerCap: Int
    private var batchSizeChunks: Int = 16 // 16 * 512 KiB = 8 MiB contiguous range per HTTP GET

    private let originURL: URL
    private var cachedCDNURL: URL?
    private var redirectEpoch: UInt64 = 0

    private var backoffUntil: TimeInterval = 0
    private var last429StepDownTime: TimeInterval = 0
    private var cleanBatchesSince429: Int = 0
    private var batchHardRetries: [Int: Int] = [:]
    private var batch429Retries: [Int: Int] = [:]

    private(set) var failedError: String?
    private var bytesSinceLastReport: Int64 = 0
    private var lastReportTime: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(missingChunks: [Int], initialOriginURL: URL, initialCDNURL: URL?, maxWorkerCap: Int) {
        self.missingQueue = missingChunks
        self.originURL = initialOriginURL
        self.cachedCDNURL = initialCDNURL
        self.redirectEpoch = initialCDNURL != nil ? 1 : 0
        self.maxWorkerCap = maxWorkerCap
        self.workerCap = maxWorkerCap
        _ = activeBatchEnd
        _ = inFlightChunkCount
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

        let start = missingQueue.removeFirst()
        var end = start
        let limit = min(batchSizeChunks, missingQueue.count + 1)
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
            usedCDN: useCDN,
            redirectEpoch: useCDN ? redirectEpoch : 0
        )
    }

    func recordProgressBytes(_ byteCount: Int) -> (shouldReport: Bool, speedMBs: Double) {
        bytesSinceLastReport += Int64(byteCount)
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
        let now = ProcessInfo.processInfo.systemUptime
        if now >= backoffUntil + 2.0 {
            cleanBatchesSince429 += 1
            if cleanBatchesSince429 >= 4 {
                cleanBatchesSince429 = 0
                if batchSizeChunks < 16 {
                    batchSizeChunks = min(16, batchSizeChunks * 2)
                } else if workerCap < maxWorkerCap {
                    workerCap = min(maxWorkerCap, workerCap + 1)
                }
            }
        }
    }

    func requeueBatchFailure(
        resumeFromChunk: Int,
        endChunk: Int,
        statusCode: Int,
        usedCDN: Bool,
        epoch: UInt64,
        retryAfterHeader: String?
    ) {
        activeWorkerCount = max(0, activeWorkerCount - 1)
        if resumeFromChunk <= endChunk {
            let unstored = Array(resumeFromChunk...endChunk)
            missingQueue.insert(contentsOf: unstored, at: 0)
        }

        let now = ProcessInfo.processInfo.systemUptime
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
                } else if batchSizeChunks > 4 {
                    batchSizeChunks = max(4, batchSizeChunks / 2)
                }
            }
            if r >= 12, failedError == nil {
                failedError = "分片 #\(resumeFromChunk) 触发服务器持续限流 (429)"
            }
            return
        }

        if usedCDN && (statusCode == 200 || statusCode >= 400) && statusCode != 416 {
            if epoch == redirectEpoch {
                cachedCDNURL = nil
            }
            return
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

    private func startDownloadWorker(for entrySnapshot: DownloadEntry, connectionBudget: Int) {
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

            let workers = max(2, min(6, connectionBudget))
            let cfg = URLSessionConfiguration.ephemeral
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.httpMaximumConnectionsPerHost = max(8, workers + 2)
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 300

            let streamDelegate = DownloadRangeStreamDelegate()
            let opQueue = OperationQueue()
            opQueue.name = "com.donby.download.worker"
            opQueue.maxConcurrentOperationCount = max(4, workers * 2)
            opQueue.qualityOfService = .utility
            let session = URLSession(configuration: cfg, delegate: streamDelegate, delegateQueue: opQueue)
            defer { session.invalidateAndCancel() }

            var originURL = targetURL
            var resolvedCDNURL: URL? = nil
            let headers = entrySnapshot.headers
            let primaryOriginHost = originURL.host

            // 1. Ensure chunk 0 & totalSize + 302 CDN redirect URL are resolved cleanly
            let probeChunkSize = store.currentMeta().chunkSize
            if store.currentMeta().totalSize <= 0 || !store.hasChunk(0) {
                var probeData: Data?
                var probeResp: HTTPURLResponse?
                let probeCandidates = [targetURL, fallbackURL].compactMap { $0 }
                for candidate in probeCandidates {
                    if Task.isCancelled { return }
                    let req = Self.buildRangeURLRequest(
                        url: candidate,
                        originHost: candidate.host,
                        headers: headers,
                        startByte: 0,
                        endByte: Int64(probeChunkSize - 1),
                        timeout: 18
                    )
                    if let (d, r) = try? await session.data(for: req),
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
                store.storeChunk(index: 0, data: slice)
            } else {
                // Warm existing CDN redirect link cleanly with a tiny HEAD/1-byte probe if resuming so batches bypass origin 429s
                let req = Self.buildRangeURLRequest(
                    url: originURL,
                    originHost: primaryOriginHost,
                    headers: headers,
                    startByte: 0,
                    endByte: 0,
                    timeout: 10
                )
                if let (_, r) = try? await session.data(for: req),
                   let http = r as? HTTPURLResponse,
                   (http.statusCode == 206 || http.statusCode == 200),
                   let finalRespURL = http.url,
                   finalRespURL.absoluteString != originURL.absoluteString {
                    resolvedCDNURL = finalRespURL
                }
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
            let coordinator = DownloadBatchCoordinator(
                missingChunks: missingChunks,
                initialOriginURL: originURL,
                initialCDNURL: resolvedCDNURL,
                maxWorkerCap: workers
            )

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask {
                        while !Task.isCancelled {
                            switch await coordinator.leaseNextBatch() {
                            case .done:
                                return
                            case .wait(let delaySec):
                                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                            case .batch(let startChunk, let endChunk, let requestURL, let usedCDN, let redirectEpoch):
                                let batchStartByte = Int64(startChunk) * Int64(chunkSize)
                                let batchEndByte = min(totalSize - 1, Int64(endChunk + 1) * Int64(chunkSize) - 1)
                                let req = Self.buildRangeURLRequest(
                                    url: requestURL,
                                    originHost: originURL.host,
                                    headers: headers,
                                    startByte: batchStartByte,
                                    endByte: batchEndByte,
                                    timeout: 25
                                )

                                var currentChunkIdx = startChunk
                                var statusCode = -1
                                var retryAfterHeader: String? = nil

                                do {
                                    let (http, byteStream) = try await streamDelegate.openStream(
                                        session: session,
                                        request: req,
                                        allowStatus200: (startChunk == 0 && batchStartByte == 0)
                                    )
                                    statusCode = http.statusCode
                                    retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")

                                    if statusCode == 206 || (statusCode == 200 && startChunk == 0) {
                                        await coordinator.updateResolvedRedirectURL(http.url, usedCDN: usedCDN, epoch: redirectEpoch)

                                        var acc = Data()
                                        acc.reserveCapacity(chunkSize * 2)
                                        var readCursor = 0

                                        for try await netSlice in byteStream {
                                            if Task.isCancelled { break }
                                            acc.append(netSlice)

                                            let rep = await coordinator.recordProgressBytes(netSlice.count)
                                            while currentChunkIdx <= endChunk {
                                                let expectedLen = min(
                                                    chunkSize,
                                                    Int(max(0, totalSize - Int64(currentChunkIdx) * Int64(chunkSize)))
                                                )
                                                if acc.count - readCursor < expectedLen {
                                                    break
                                                }
                                                let endPos = readCursor + expectedLen
                                                let chunkData = Data(acc[readCursor..<endPos])
                                                readCursor = endPos
                                                store.storeChunk(index: currentChunkIdx, data: chunkData)
                                                currentChunkIdx += 1
                                            }
                                            if readCursor >= chunkSize {
                                                acc.removeSubrange(0..<readCursor)
                                                readCursor = 0
                                            }
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
                                        }

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

                                        // Flush trailing partial slice if EOF matches exact chunk length
                                        while currentChunkIdx <= endChunk {
                                            let expectedLen = min(
                                                chunkSize,
                                                Int(max(0, totalSize - Int64(currentChunkIdx) * Int64(chunkSize)))
                                            )
                                            guard acc.count - readCursor >= expectedLen else { break }
                                            let endPos = readCursor + expectedLen
                                            let chunkData = Data(acc[readCursor..<endPos])
                                            readCursor = endPos
                                            store.storeChunk(index: currentChunkIdx, data: chunkData)
                                            currentChunkIdx += 1
                                        }

                                        if currentChunkIdx > endChunk {
                                            await coordinator.finishBatchSuccess()
                                        } else {
                                            await coordinator.requeueBatchFailure(
                                                resumeFromChunk: currentChunkIdx,
                                                endChunk: endChunk,
                                                statusCode: statusCode,
                                                usedCDN: usedCDN,
                                                epoch: redirectEpoch,
                                                retryAfterHeader: retryAfterHeader
                                            )
                                        }
                                    } else {
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
                                    if Task.isCancelled { return }
                                    await coordinator.requeueBatchFailure(
                                        resumeFromChunk: currentChunkIdx,
                                        endChunk: endChunk,
                                        statusCode: statusCode,
                                        usedCDN: usedCDN,
                                        epoch: redirectEpoch,
                                        retryAfterHeader: retryAfterHeader
                                    )
                                }
                            }
                        }
                    }
                }
            }

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

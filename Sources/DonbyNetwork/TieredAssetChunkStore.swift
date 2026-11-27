import Foundation
import Darwin
import DonbyCore
import DonbyKernelC

// MARK: - Task C: ChunkStore Metadata & KernelRust Slab/Sparse Storage Bridge

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
        let count = completedChunks.count
        guard count > 0 else { return 0 }
        guard totalSize > 0 else {
            return Int64(count) * Int64(chunkSize)
        }
        let lastIdx = totalChunks - 1
        if completedChunks.contains(lastIdx) {
            let lastLen = max(0, totalSize - Int64(lastIdx) * Int64(chunkSize))
            return min(totalSize, Int64(count - 1) * Int64(chunkSize) + lastLen)
        }
        return min(totalSize, Int64(count) * Int64(chunkSize))
    }
}

public final class TieredAssetChunkStore: @unchecked Sendable {
    public let assetKey: String
    public let assetDirectory: URL
    public let dataFileURL: URL
    public let metaFileURL: URL
    public let chunksDirectoryURL: URL

    internal let lock = NSLock()
    internal let metaWriteLock = NSLock()
    internal let metaWriteQueue = DispatchQueue(label: "com.donby.chunkstore.meta", qos: .utility)
    internal var meta: ChunkStoreMeta
    internal var isClosedForDisk: Bool = false
    internal var isRemovedFromDisk: Bool = false
    internal var maxMemoryBytes: Int
    internal var persistDisk: Bool
    internal var didNotifyFullyCached: Bool = false
    internal let rawStore: OpaquePointer

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
        let loadedMeta: ChunkStoreMeta
        if let data = try? Data(contentsOf: metaFileURL),
           let loaded = try? JSONDecoder().decode(ChunkStoreMeta.self, from: data) {
            loadedMeta = loaded
        } else {
            loadedMeta = ChunkStoreMeta(assetKey: assetKey, chunkSize: chunkSize)
        }

        let assetDirPath = self.assetDirectory.path
        let seedIndices = loadedMeta.completedChunks.map { Int32($0) }
        let openedStore: OpaquePointer? = seedIndices.withUnsafeBufferPointer { buf in
            assetDirPath.withCString { cPath in
                dk_net_store_open(
                    cPath,
                    loadedMeta.totalSize,
                    Int32(loadedMeta.chunkSize),
                    persistDisk || loadedMeta.pinned,
                    loadedMeta.pinned,
                    buf.baseAddress,
                    Int32(buf.count)
                )
            }
        }
        guard let openedStore else {
            fatalError("Failed to initialize KernelRust DKChunkStore")
        }
        self.rawStore = openedStore
        dk_net_store_update_config(openedStore, Int64(self.maxMemoryBytes), persistDisk || loadedMeta.pinned)

        var syncedMeta = loadedMeta
        syncedMeta.lastAccess = Date()
        let reconciled = Self.fetchCompletedIndices(from: openedStore)
        let prunedCount = max(0, syncedMeta.completedChunks.count - reconciled.count)
        syncedMeta.completedChunks = reconciled
        self.meta = syncedMeta
        self.didNotifyFullyCached = syncedMeta.isFullyCached

        if prunedCount > 0 {
            DonbyLogger.shared.log(
                "检测到缓存索引与磁盘文件不一致，已自动清理 \(prunedCount) 个缺失/空洞分片 (\(assetKey))",
                level: .warning,
                subsystem: "TurboCache"
            )
            if persistDisk || syncedMeta.pinned {
                writeMetaSnapshotToDisk(syncedMeta)
            }
        }
    }

    deinit {
        lock.lock()
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        let snapshot = shouldPersist ? meta : nil
        lock.unlock()
        if let snapshot {
            writeMetaSnapshotToDisk(snapshot)
        }
        dk_net_store_release(rawStore)
    }

    public func currentMeta() -> ChunkStoreMeta {
        lock.lock()
        defer { lock.unlock() }
        return meta
    }

    public func cachedBytesFast() -> Int64 {
        var cached: Int64 = 0
        var total: Int64 = 0
        var full = false
        dk_net_store_get_progress(rawStore, &cached, &total, &full)
        return cached
    }

    public func totalSizeFast() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return meta.totalSize
    }

    public var activeReaderCount: Int {
        Int(dk_net_store_active_readers(rawStore))
    }

    public func retainReader() {
        dk_net_store_retain_reader(rawStore)
    }

    public func releaseReader() -> Int {
        Int(dk_net_store_release_reader(rawStore))
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
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        meta.serverId = serverId ?? meta.serverId
        meta.itemId = itemId ?? meta.itemId
        meta.mediaSourceId = mediaSourceId ?? meta.mediaSourceId
        meta.displayTitle = displayTitle ?? meta.displayTitle
        meta.subtitle = subtitle ?? meta.subtitle
        meta.posterURLString = posterURLString ?? meta.posterURLString
        if let itemSnapshot { meta.itemSnapshot = itemSnapshot }
        if let mediaSourceSnapshot { meta.mediaSourceSnapshot = mediaSourceSnapshot }
        meta.lastAccess = Date()
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        let snapshot = meta
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func updateConfiguration(maxMemoryBytes: Int, persistDisk: Bool) {
        let clampedMem = max(32 * 1024 * 1024, min(2_147_483_648, maxMemoryBytes))
        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        self.maxMemoryBytes = clampedMem
        let effectivePersist = persistDisk || meta.pinned
        self.persistDisk = effectivePersist
        self.isClosedForDisk = false
        lock.unlock()
        dk_net_store_update_config(rawStore, Int64(clampedMem), effectivePersist)
    }

    public func setPinned(_ pinned: Bool) {
        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        meta.pinned = pinned
        if pinned {
            persistDisk = true
        }
        let shouldPersist = !isClosedForDisk && !isRemovedFromDisk
        let snapshot = meta
        lock.unlock()
        dk_net_store_set_pinned(rawStore, pinned)
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func setTotalSize(_ totalSize: Int64, sourceURL: String? = nil) {
        var snapshot: ChunkStoreMeta? = nil
        var changedTotal = false
        lock.lock()
        if !isRemovedFromDisk && totalSize > 0 && meta.totalSize != totalSize {
            meta.totalSize = totalSize
            changedTotal = true
            if let sourceURL, !sourceURL.isEmpty {
                meta.sourceURLString = sourceURL
            }
            if (persistDisk || meta.pinned) && !isClosedForDisk {
                snapshot = meta
            }
        }
        lock.unlock()
        if changedTotal {
            dk_net_store_set_total_size(rawStore, totalSize)
        }
        if let snapshot {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func hasChunk(_ index: Int) -> Bool {
        dk_net_store_has_chunk(rawStore, Int32(index))
    }

    public func expectedChunkLength(for index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return expectedChunkLenLocked(index: index)
    }

    public func storeChunk(index: Int, data: Data, cacheInMemory: Bool = true) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            dk_net_store_write_slice(rawStore, Int32(index), ptr, Int32(raw.count), cacheInMemory)
        }
        recordChunkCompletedFromNative(index: index)
    }

    internal func recordChunkCompletedFromNative(index: Int) {
        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        meta.completedChunks.insert(index)
        meta.lastAccess = Date()
        let shouldNotifyFull = meta.isFullyCached && !didNotifyFullyCached
        if shouldNotifyFull {
            didNotifyFullyCached = true
        }
        let snapshot = shouldNotifyFull ? meta : nil
        lock.unlock()

        if let snapshot {
            if persistDisk || snapshot.pinned {
                metaWriteQueue.async { [weak self] in
                    self?.writeMetaSnapshotToDisk(snapshot)
                }
            }
            DonbyTurboCacheEngine.shared.notifyAssetFullyCached(snapshot)
        }
    }

    public func readChunkBytes(index: Int, offsetInChunk: Int, into dst: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0, offsetInChunk >= 0 else { return -1 }
        let n = Int(dk_net_store_read_bytes(rawStore, Int32(index), Int32(offsetInChunk), dst, Int32(count)))
        if n < 0 {
            evictStaleCompletedChunk(index: index)
        }
        return n
    }

    public func readChunk(index: Int) -> Data? {
        let len = expectedChunkLength(for: index)
        guard len > 0 else { return nil }
        var data = Data(count: len)
        let n = data.withUnsafeMutableBytes { raw -> Int in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return Int(dk_net_store_read_bytes(rawStore, Int32(index), 0, ptr, Int32(len)))
        }
        if n < 0 {
            evictStaleCompletedChunk(index: index)
            return nil
        }
        if n < len {
            data.removeSubrange(n..<len)
        }
        return data
    }

    private func evictStaleCompletedChunk(index: Int) {
        var evictedSnapshot: ChunkStoreMeta? = nil
        lock.lock()
        if meta.completedChunks.remove(index) != nil {
            didNotifyFullyCached = false
            if (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk {
                evictedSnapshot = meta
            }
        }
        lock.unlock()
        if let evictedSnapshot {
            metaWriteQueue.async { [weak self] in
                self?.writeMetaSnapshotToDisk(evictedSnapshot)
            }
        }
    }

    public func evictBehindCursor(cursorChunk: Int, keepBackChunks: Int = 8) {
        dk_net_store_evict_behind_cursor(rawStore, Int32(cursorChunk), Int32(keepBackChunks))
    }

    public func evictDistantChunks(aroundChunk centerChunk: Int, keepBackChunks: Int = 16, keepAheadChunks: Int = 48) {
        dk_net_store_evict_distant_chunks(rawStore, Int32(centerChunk), Int32(keepBackChunks), Int32(keepAheadChunks))
    }

    public func flushMeta() {
        dk_net_store_flush(rawStore)
        metaWriteQueue.sync {}
        lock.lock()
        let snapshot = meta
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func trimIdleMemoryKeepingPinned() {
        dk_net_store_trim_idle_keeping_pinned(rawStore)
        malloc_zone_pressure_relief(nil, 0)
    }

    public func closeFileHandles() {
        dk_net_store_close_handles(rawStore)
        metaWriteQueue.sync {}
        lock.lock()
        let wasRemoved = isRemovedFromDisk
        isClosedForDisk = true
        let snapshot = meta
        let shouldPersist = (persistDisk || meta.pinned) && !wasRemoved
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func invalidateForRemoval() {
        lock.lock()
        isRemovedFromDisk = true
        isClosedForDisk = true
        lock.unlock()
        dk_net_store_invalidate_for_removal(rawStore)
        metaWriteQueue.sync {}
    }

    internal func expectedChunkLenLocked(index: Int) -> Int {
        guard meta.totalSize > 0 else { return meta.chunkSize }
        let start = Int64(index) * Int64(meta.chunkSize)
        if start >= meta.totalSize { return 0 }
        return Int(min(Int64(meta.chunkSize), meta.totalSize - start))
    }

    internal func writeMetaSnapshotToDisk(_ snapshot: ChunkStoreMeta) {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        metaWriteLock.lock()
        defer { metaWriteLock.unlock() }
        lock.lock()
        let removed = isRemovedFromDisk
        lock.unlock()
        guard !removed else { return }
        try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try? encoded.write(to: metaFileURL, options: .atomic)
    }

    private static func fetchCompletedIndices(from store: OpaquePointer) -> Set<Int> {
        let count = Int(dk_net_store_copy_completed_indices(store, nil, 0))
        guard count > 0 else { return [] }
        var buf = [Int32](repeating: 0, count: count)
        let copied = buf.withUnsafeMutableBufferPointer { ptr in
            Int(dk_net_store_copy_completed_indices(store, ptr.baseAddress, Int32(count)))
        }
        return Set(buf.prefix(min(count, copied)).map { Int($0) })
    }
}

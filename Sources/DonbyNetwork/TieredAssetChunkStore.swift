import Foundation
import Darwin
import DonbyCore

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
    internal let memoryLock = NSLock()
    internal let metaWriteLock = NSLock()
    internal let diskQueue = DispatchQueue(label: "com.donby.chunkstore.disk", qos: .userInitiated)
    internal let metaWriteQueue = DispatchQueue(label: "com.donby.chunkstore.meta", qos: .utility)
    internal var meta: ChunkStoreMeta
    internal var memoryChunks: [Int: Data] = [:]
    internal var memoryOrder: [Int] = []
    internal var memoryBytes: Int = 0
    internal var pendingDiskChunks: [Int: Data] = [:]
    internal var didEnsureChunksDir: Bool = false
    internal var isClosedForDisk: Bool = false
    internal var isRemovedFromDisk: Bool = false
    internal var maxMemoryBytes: Int
    internal var persistDisk: Bool
    internal var readHandle: FileHandle?
    internal var writeHandle: FileHandle?
    internal var dirtyMetaOps: Int = 0
    internal var activeReaders: Int = 0
    internal var didNotifyFullyCached: Bool = false
    internal var contiguousPrefixCount: Int = 0

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
        // Never call `diskQueue.sync` / `metaWriteQueue.sync` inside `deinit`: if the last strong
        // reference drops at the end of a `[weak self]` closure on `diskQueue` or `metaWriteQueue`,
        // synchronous re-entry onto the same serial queue triggers a GCD SIGTRAP deadlock.
        lock.lock()
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        let snapshot = shouldPersist ? meta : nil
        try? readHandle?.close()
        readHandle = nil
        try? writeHandle?.close()
        writeHandle = nil
        lock.unlock()
        if let snapshot {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func currentMeta() -> ChunkStoreMeta {
        lock.lock()
        defer { lock.unlock() }
        return meta
    }

    public func cachedBytesFast() -> Int64 {
        lock.lock(); defer { lock.unlock() }; return meta.cachedBytes
    }

    public func totalSizeFast() -> Int64 {
        lock.lock(); defer { lock.unlock() }; return meta.totalSize
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
        memoryLock.lock()
        self.maxMemoryBytes = clampedMem
        evictMemoryLockedIfNeeded(incomingBytes: 0)
        memoryLock.unlock()

        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        self.persistDisk = persistDisk || meta.pinned
        self.isClosedForDisk = false
        lock.unlock()
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
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func setTotalSize(_ totalSize: Int64, sourceURL: String? = nil) {
        var snapshot: ChunkStoreMeta? = nil
        lock.lock()
        if !isRemovedFromDisk && totalSize > 0 && meta.totalSize != totalSize {
            meta.totalSize = totalSize
            if let sourceURL, !sourceURL.isEmpty {
                meta.sourceURLString = sourceURL
            }
            if (persistDisk || meta.pinned) && !isClosedForDisk {
                snapshot = meta
            }
        }
        lock.unlock()
        if let snapshot {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func hasChunk(_ index: Int) -> Bool {
        memoryLock.lock()
        let inMem = (memoryChunks[index] != nil)
        memoryLock.unlock()
        if inMem { return true }

        lock.lock()
        let inDisk = !isRemovedFromDisk && ((pendingDiskChunks[index] != nil) || meta.completedChunks.contains(index))
        lock.unlock()
        return inDisk
    }

    public func expectedChunkLength(for index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return expectedChunkLenLocked(index: index)
    }

    public func storeChunk(index: Int, data: Data, cacheInMemory: Bool = true) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        if meta.totalSize > 0 {
            let expectedLen = expectedChunkLenLocked(index: index)
            guard expectedLen > 0, data.count >= expectedLen else {
                lock.unlock()
                return
            }
        }
        meta.lastAccess = Date()
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        if shouldPersist {
            pendingDiskChunks[index] = data
        }
        let backpressureLimit = cacheInMemory ? 128 : 96
        let needsBackpressure = shouldPersist && (pendingDiskChunks.count >= backpressureLimit)
        lock.unlock()

        // 1. Store in L1 Memory cache under fast memoryLock (skipped for background offline downloads
        //    with zero active readers so downloading multi-GB files never bloats RAM to 500 MiB).
        if cacheInMemory {
            memoryLock.lock()
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
            memoryLock.unlock()
        }

        guard shouldPersist else { return }

        // 2. Persist L2 Disk cache asynchronously on dedicated serial diskQueue so URLSession delegate
        //    callbacks and AVIO demux reads are NEVER stalled by filesystem writes or JSON serialization.
        diskQueue.async { [weak self] in
            self?.persistChunkOnDiskQueue(index: index, data: data)
        }
        if needsBackpressure {
            diskQueue.sync {}
        }
    }

    private func persistChunkOnDiskQueue(index: Int, data: Data) {
        lock.lock()
        guard (persistDisk || meta.pinned), !isClosedForDisk, !isRemovedFromDisk else {
            pendingDiskChunks.removeValue(forKey: index)
            lock.unlock()
            return
        }
        let chunkSize = meta.chunkSize
        // Pinned offline downloads write directly to sparse APFS offsets in `media.bin` (zero spill-file
        // double-copy amplification and zero 3,000-file unlink storms); unpinned stream caches keep
        // anti-sparse spill files so seek-streaming a 35 GB movie never bloats logical media.bin size.
        let directWriteToMediaBin = meta.pinned || (index <= contiguousPrefixCount)
        let shouldCreateDir = !directWriteToMediaBin && !didEnsureChunksDir
        var whForDirect: FileHandle? = nil
        if directWriteToMediaBin {
            ensureFileHandlesLocked()
            whForDirect = writeHandle
        }
        lock.unlock()

        var wroteOK = false
        var completedMetaForNotify: ChunkStoreMeta? = nil
        var metaSnapshotToWrite: ChunkStoreMeta? = nil

        if directWriteToMediaBin {
            if let wh = whForDirect {
                do {
                    try wh.seek(toOffset: UInt64(index) * UInt64(chunkSize))
                    try wh.write(contentsOf: data)
                    wroteOK = true
                } catch {
                    wroteOK = false
                }
            }
            var shouldFoldSpills = false
            lock.lock()
            if wroteOK && !isRemovedFromDisk {
                meta.completedChunks.insert(index)
                if index == contiguousPrefixCount {
                    contiguousPrefixCount += 1
                    shouldFoldSpills = (whForDirect != nil)
                }
                dirtyMetaOps += 1
                let flushThreshold = meta.pinned ? 128 : 64
                if dirtyMetaOps >= flushThreshold || meta.isFullyCached {
                    dirtyMetaOps = 0
                    metaSnapshotToWrite = meta
                }
                if meta.isFullyCached && !meta.pinned && !didNotifyFullyCached {
                    didNotifyFullyCached = true
                    completedMetaForNotify = meta
                }
            }
            pendingDiskChunks.removeValue(forKey: index)
            lock.unlock()

            if shouldFoldSpills, let wh = whForDirect {
                foldConsecutiveSpillChunksOnDiskQueue(wh: wh, chunkSize: chunkSize, maxChunksPerPass: 16)
            }
        } else {
            if shouldCreateDir {
                try? FileManager.default.createDirectory(at: chunksDirectoryURL, withIntermediateDirectories: true)
            }
            let spillURL = chunkSpillFileURL(for: index)
            // Direct write without `.atomic` temp-file+rename overhead: spill chunks are only indexed
            // in `meta.completedChunks` AFTER `data.write` returns cleanly, so partial writes on crash are ignored.
            if (try? data.write(to: spillURL)) != nil {
                wroteOK = true
            } else {
                try? FileManager.default.createDirectory(at: chunksDirectoryURL, withIntermediateDirectories: true)
                wroteOK = (try? data.write(to: spillURL)) != nil
            }

            lock.lock()
            if wroteOK && !isRemovedFromDisk {
                didEnsureChunksDir = true
                meta.completedChunks.insert(index)
                dirtyMetaOps += 1
                if dirtyMetaOps >= 64 || meta.isFullyCached {
                    dirtyMetaOps = 0
                    metaSnapshotToWrite = meta
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
            pendingDiskChunks.removeValue(forKey: index)
            lock.unlock()
        }

        if let metaSnapshotToWrite {
            metaWriteQueue.async { [weak self] in
                self?.writeMetaSnapshotToDisk(metaSnapshotToWrite)
            }
        }
        if let completedMetaForNotify {
            DonbyTurboCacheEngine.shared.notifyAssetFullyCached(completedMetaForNotify)
        }
    }

    public func readChunk(index: Int) -> Data? {
        memoryLock.lock()
        if let mem = memoryChunks[index] {
            memoryLock.unlock()
            return mem
        }
        memoryLock.unlock()

        lock.lock()
        if let pending = pendingDiskChunks[index] {
            lock.unlock()
            return pending
        }
        guard !isRemovedFromDisk, meta.completedChunks.contains(index) else {
            lock.unlock()
            return nil
        }
        let len = expectedChunkLenLocked(index: index)
        guard len > 0 else {
            lock.unlock()
            return nil
        }
        let isSpillCandidate = (index >= contiguousPrefixCount)
        let chunkSize = meta.chunkSize
        let hasKnownTotalSize = meta.totalSize > 0
        lock.unlock()

        var loadedSlice: Data? = nil
        // Read out-of-order spill file outside `lock` so concurrent checks never block on disk I/O
        if isSpillCandidate {
            let spillURL = chunkSpillFileURL(for: index)
            if let data = try? Data(contentsOf: spillURL),
               (hasKnownTotalSize ? data.count >= len : !data.isEmpty) {
                loadedSlice = data.count > len ? Data(data.prefix(len)) : data
            }
        }

        if loadedSlice == nil {
            var evictedSnapshot: ChunkStoreMeta? = nil
            lock.lock()
            // Re-check pendingDiskChunks in case a concurrent write arrived between unlocks.
            if let pending = pendingDiskChunks[index] {
                lock.unlock()
                return pending
            }
            // NEVER create an empty `media.bin` during a read; only open if it already exists.
            ensureReadHandleLocked()
            if let rh = readHandle {
                let offset = Int64(index) * Int64(chunkSize)
                let requiredBytes = Int64(len)
                let rangeValid: Bool
                if hasKnownTotalSize {
                    rangeValid = Self.isByteRangeAllocatedInFile(fd: rh.fileDescriptor, offset: offset, length: requiredBytes)
                } else {
                    var st = stat()
                    let fileSize = (fstat(rh.fileDescriptor, &st) == 0) ? Int64(st.st_size) : 0
                    let avail = min(requiredBytes, max(0, fileSize - offset))
                    rangeValid = avail > 0 && Self.isByteRangeAllocatedInFile(fd: rh.fileDescriptor, offset: offset, length: avail)
                }
                if rangeValid {
                    do {
                        try rh.seek(toOffset: UInt64(offset))
                        if let data = try rh.read(upToCount: len),
                           (hasKnownTotalSize ? data.count == len : !data.isEmpty) {
                            loadedSlice = data
                        }
                    } catch {
                        loadedSlice = nil
                    }
                }
            }
            if loadedSlice == nil {
                // Disk backing is missing, truncated, or an APFS sparse hole: immediately evict
                // stale index so `hasChunk(index)` becomes false and Turbo/Download refetches cleanly.
                if meta.completedChunks.remove(index) != nil {
                    if index < contiguousPrefixCount {
                        contiguousPrefixCount = index
                    }
                    didNotifyFullyCached = false
                    if (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk {
                        evictedSnapshot = meta
                    }
                }
            }
            lock.unlock()

            if let evictedSnapshot {
                metaWriteQueue.async { [weak self] in
                    self?.writeMetaSnapshotToDisk(evictedSnapshot)
                }
            }
        }

        guard let slice = loadedSlice else { return nil }
        memoryLock.lock()
        if memoryChunks[index] == nil {
            evictMemoryLockedIfNeeded(incomingBytes: slice.count)
            if slice.count <= maxMemoryBytes {
                memoryChunks[index] = slice
                memoryOrder.append(index)
                memoryBytes += slice.count
            }
        }
        memoryLock.unlock()
        return slice
    }

    /// Sliding window eviction behind playhead cursor (keeps Chunk 0..3 + EOF Cues pinned and retains recent rewind window while under RAM cap).
    public func evictBehindCursor(cursorChunk: Int, keepBackChunks: Int = 8) {
        let threshold = cursorChunk - max(2, keepBackChunks)
        guard threshold > 0 else { return }

        lock.lock()
        let totalChunks = meta.totalChunks
        let backedByDisk = persistDisk || meta.pinned
        lock.unlock()
        let protectedTailStart = totalChunks > 4 ? (totalChunks - 2) : Int.max

        memoryLock.lock()
        // When backed by L2 disk, trim stale chunks behind the rewind window once L1 exceeds 96 MiB
        // (or 75% of maxMemoryBytes when lower) to keep active footprint compact across multi-seek sessions.
        let softCap = backedByDisk ? min((maxMemoryBytes * 3) / 4, 96 * 1024 * 1024) : (maxMemoryBytes * 3) / 4
        guard memoryBytes > softCap else {
            memoryLock.unlock()
            return
        }
        let keysToRemove = memoryOrder.filter { $0 >= 4 && $0 < threshold && $0 < protectedTailStart }
        for k in keysToRemove {
            if let removed = memoryChunks.removeValue(forKey: k) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
        if !keysToRemove.isEmpty {
            let removedSet = Set(keysToRemove)
            memoryOrder.removeAll { removedSet.contains($0) }
        }
        memoryLock.unlock()
    }

    /// Evicts distant L1 chunks outside `[center - keepBack, center + keepAhead]` on large jumps when backed by L2 disk.
    public func evictDistantChunks(aroundChunk centerChunk: Int, keepBackChunks: Int = 16, keepAheadChunks: Int = 48) {
        lock.lock()
        let totalChunks = meta.totalChunks
        let backedByDisk = persistDisk || meta.pinned
        lock.unlock()
        guard backedByDisk else { return }

        let protectedTailStart = totalChunks > 4 ? (totalChunks - 2) : Int.max
        let keepLo = max(4, centerChunk - keepBackChunks)
        let keepHi = centerChunk + keepAheadChunks

        memoryLock.lock()
        let softCap = min((maxMemoryBytes * 3) / 4, 96 * 1024 * 1024)
        guard memoryBytes > softCap else {
            memoryLock.unlock()
            return
        }
        let keysToRemove = memoryOrder.filter { $0 >= 4 && $0 < protectedTailStart && ($0 < keepLo || $0 > keepHi) }
        for k in keysToRemove {
            if let removed = memoryChunks.removeValue(forKey: k) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
        if !keysToRemove.isEmpty {
            let removedSet = Set(keysToRemove)
            memoryOrder.removeAll { removedSet.contains($0) }
        }
        memoryLock.unlock()
    }

    public func flushMeta() {
        diskQueue.sync {}
        metaWriteQueue.sync {}
        lock.lock()
        let snapshot = meta
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    /// Trims idle L1 RAM chunks once no active readers remain (preserving only Chunks 0..3 + final 2 EOF
    /// chunks for <20ms warm reopens while all remaining chunks stay persisted in L2 disk cache).
    public func trimIdleMemoryKeepingPinned() {
        lock.lock()
        let hasReaders = activeReaders > 0
        let backedByDisk = (persistDisk || meta.pinned) && !isRemovedFromDisk
        let totalChunks = meta.totalChunks
        lock.unlock()
        guard !hasReaders && backedByDisk else { return }

        let protectedTailStart = totalChunks > 4 ? (totalChunks - 2) : Int.max
        memoryLock.lock()
        let keysToDrop = memoryOrder.filter { $0 >= 4 && $0 < protectedTailStart }
        for k in keysToDrop {
            if let removed = memoryChunks.removeValue(forKey: k) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
        if !keysToDrop.isEmpty {
            let dropSet = Set(keysToDrop)
            memoryOrder.removeAll { dropSet.contains($0) }
        }
        memoryLock.unlock()
        if !keysToDrop.isEmpty {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    public func closeFileHandles() {
        diskQueue.sync {}
        metaWriteQueue.sync {}
        lock.lock()
        let wasRemoved = isRemovedFromDisk
        isClosedForDisk = true
        if !wasRemoved, let wh = writeHandle {
            foldConsecutiveSpillChunksIntoMediaBinLocked(wh: wh)
        }
        let snapshot = meta
        let shouldPersist = (persistDisk || meta.pinned) && !wasRemoved
        try? readHandle?.close()
        readHandle = nil
        try? writeHandle?.close()
        writeHandle = nil
        pendingDiskChunks.removeAll()
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    /// Permanently invalidates this store prior to deleting its on-disk asset directory.
    /// Drains both `diskQueue` and `metaWriteQueue` and blocks all subsequent writes (including
    /// `deinit -> flushMeta()` or cancelled worker `defer` blocks) from resurrecting a zombie `meta.json`.
    public func invalidateForRemoval() {
        lock.lock()
        isRemovedFromDisk = true
        isClosedForDisk = true
        pendingDiskChunks.removeAll()
        lock.unlock()

        diskQueue.sync {}
        metaWriteQueue.sync {}

        memoryLock.lock()
        memoryChunks.removeAll()
        memoryOrder.removeAll()
        memoryBytes = 0
        memoryLock.unlock()

        lock.lock()
        try? readHandle?.close()
        readHandle = nil
        try? writeHandle?.close()
        writeHandle = nil
        pendingDiskChunks.removeAll()
        lock.unlock()
    }

    internal func expectedChunkLenLocked(index: Int) -> Int {
        guard meta.totalSize > 0 else { return meta.chunkSize }
        let start = Int64(index) * Int64(meta.chunkSize)
        if start >= meta.totalSize { return 0 }
        return Int(min(Int64(meta.chunkSize), meta.totalSize - start))
    }

    internal func evictMemoryLockedIfNeeded(incomingBytes: Int) {
        while memoryBytes + incomingBytes > maxMemoryBytes && !memoryOrder.isEmpty {
            let oldest = memoryOrder.removeFirst()
            if let removed = memoryChunks.removeValue(forKey: oldest) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
    }

    internal func ensureReadHandleLocked() {
        guard readHandle == nil, FileManager.default.fileExists(atPath: dataFileURL.path) else { return }
        readHandle = try? FileHandle(forReadingFrom: dataFileURL)
    }

    internal func ensureFileHandlesLocked() {
        guard !isRemovedFromDisk else { return }
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
}

import Foundation
import Darwin
import DonbyCore

// MARK: - Disk Reconciliation, APFS Sparse Extent Validation & Spill Folding

extension TieredAssetChunkStore {
    internal struct AllocatedByteExtent {
        let start: Int64
        let end: Int64
    }

    /// Checks whether `[offset, offset + length)` is backed by allocated data (not past EOF
    /// and not inside an unallocated APFS sparse hole) via `fstat` + `SEEK_DATA`/`SEEK_HOLE`.
    internal static func isByteRangeAllocatedInFile(fd: Int32, offset: Int64, length: Int64) -> Bool {
        guard offset >= 0, length > 0 else { return false }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        let fileSize = Int64(st.st_size)
        guard offset + length <= fileSize else { return false }

        let dataStart = Darwin.lseek(fd, off_t(offset), SEEK_DATA)
        if dataStart < 0 {
            // ENXIO means no allocated data exists at or after `offset` (pure sparse hole).
            // Any other error (e.g. ENOTSUP/EINVAL on non-sparse volumes) falls back to `fstat` size.
            return errno != ENXIO
        }
        guard Int64(dataStart) == offset else { return false }

        let holeStart = Darwin.lseek(fd, off_t(offset), SEEK_HOLE)
        if holeStart < 0 {
            return true
        }
        return Int64(holeStart) >= offset + length
    }

    /// Enumerates all allocated (non-hole) byte extents in `fd` in O(number of extents).
    /// Returns `nil` when the underlying filesystem does not support `SEEK_DATA`/`SEEK_HOLE`.
    internal static func enumerateAllocatedExtents(fd: Int32, logicalSize: Int64) -> [AllocatedByteExtent]? {
        guard logicalSize > 0 else { return [] }
        var extents: [AllocatedByteExtent] = []
        var pos: Int64 = 0
        while pos < logicalSize {
            let ds = Darwin.lseek(fd, off_t(pos), SEEK_DATA)
            if ds < 0 {
                if errno == ENXIO {
                    break
                }
                return nil
            }
            let dataStart = Int64(ds)
            if dataStart >= logicalSize { break }
            let hs = Darwin.lseek(fd, off_t(dataStart), SEEK_HOLE)
            if hs < 0 {
                return nil
            }
            let holeStart = min(logicalSize, Int64(hs))
            if holeStart > dataStart {
                extents.append(AllocatedByteExtent(start: dataStart, end: holeStart))
            }
            if holeStart <= pos { break }
            pos = holeStart
        }
        return extents
    }

    internal static func isRangeCoveredByExtents(
        offset: Int64,
        length: Int64,
        extents: [AllocatedByteExtent]
    ) -> Bool {
        guard length > 0, !extents.isEmpty else { return false }
        let endOffset = offset + length
        var lo = 0
        var hi = extents.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if extents[mid].start <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let idx = lo - 1
        guard idx >= 0 else { return false }
        return extents[idx].start <= offset && extents[idx].end >= endOffset
    }

    /// Evicts header (`0...3`) and EOF tail probe chunks (final 2 chunks) from L1 RAM,
    /// pending writes, spill files, and `meta.completedChunks` so a failed open/probe retries cleanly.
    public func invalidateProbeChunks() {
        diskQueue.sync {}
        metaWriteQueue.sync {}

        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        let totalChunks = meta.totalChunks
        var targets = Set<Int>()
        let headEnd = totalChunks > 0 ? min(4, totalChunks) : 4
        for i in 0..<headEnd { targets.insert(i) }
        if totalChunks > 4 {
            targets.insert(totalChunks - 2)
            targets.insert(totalChunks - 1)
        }
        for idx in targets {
            meta.completedChunks.remove(idx)
            pendingDiskChunks.removeValue(forKey: idx)
        }
        if targets.contains(0) {
            contiguousPrefixCount = 0
        }
        didNotifyFullyCached = meta.isFullyCached
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        let snapshot = meta
        lock.unlock()

        memoryLock.lock()
        for idx in targets {
            if let removed = memoryChunks.removeValue(forKey: idx) {
                memoryBytes = max(0, memoryBytes - removed.count)
            }
        }
        memoryOrder.removeAll { targets.contains($0) }
        memoryLock.unlock()

        let fm = FileManager.default
        for idx in targets {
            let spillURL = chunkSpillFileURL(for: idx)
            if fm.fileExists(atPath: spillURL.path) {
                try? fm.removeItem(at: spillURL)
            }
        }

        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func prepareContiguousMediaBinForMaterialization() {
        diskQueue.sync {}
        metaWriteQueue.sync {}
        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        isClosedForDisk = false
        ensureFileHandlesLocked()
        if let wh = writeHandle {
            foldConsecutiveSpillChunksIntoMediaBinLocked(wh: wh)
            // Also fold any remaining completed spill chunks in case contiguousPrefixCount lagged
            for idx in meta.completedChunks.sorted() {
                writeSpillFileIntoMediaBinLocked(index: idx, wh: wh)
            }
        }
        try? FileManager.default.removeItem(at: chunksDirectoryURL)
        didEnsureChunksDir = false
        let shouldPersist = (persistDisk || meta.pinned) && !isRemovedFromDisk
        let snapshot = meta
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    internal func chunkSpillFileURL(for index: Int) -> URL {
        chunksDirectoryURL.appendingPathComponent("\(index).chk")
    }

    internal func writeSpillFileIntoMediaBinLocked(index: Int, wh: FileHandle) {
        let spillURL = chunkSpillFileURL(for: index)
        if FileManager.default.fileExists(atPath: spillURL.path),
           let data = try? Data(contentsOf: spillURL), !data.isEmpty {
            let offset = UInt64(index) * UInt64(meta.chunkSize)
            try? wh.seek(toOffset: offset)
            try? wh.write(contentsOf: data)
            try? FileManager.default.removeItem(at: spillURL)
        }
    }

    internal func foldConsecutiveSpillChunksOnDiskQueue(wh: FileHandle, chunkSize: Int, maxChunksPerPass: Int = 16) {
        var didFoldAny = false
        var foldedSpills = 0
        while foldedSpills < maxChunksPerPass {
            lock.lock()
            let canFold = !isClosedForDisk && !isRemovedFromDisk && meta.completedChunks.contains(contiguousPrefixCount)
            let nextIdx = contiguousPrefixCount
            lock.unlock()
            guard canFold else { break }

            let spillURL = chunkSpillFileURL(for: nextIdx)
            let hasSpillFile = FileManager.default.fileExists(atPath: spillURL.path)
            if hasSpillFile {
                guard let spillData = try? Data(contentsOf: spillURL), !spillData.isEmpty else { break }
                do {
                    try wh.seek(toOffset: UInt64(nextIdx) * UInt64(chunkSize))
                    try wh.write(contentsOf: spillData)
                } catch { break }
            }
            lock.lock()
            if contiguousPrefixCount == nextIdx { contiguousPrefixCount += 1 }
            lock.unlock()
            if hasSpillFile {
                try? FileManager.default.removeItem(at: spillURL)
                didFoldAny = true
                foldedSpills += 1
            }
        }
        if didFoldAny, let contents = try? FileManager.default.contentsOfDirectory(atPath: chunksDirectoryURL.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: chunksDirectoryURL)
            lock.lock(); didEnsureChunksDir = false; lock.unlock()
        }
    }

    internal func foldConsecutiveSpillChunksIntoMediaBinLocked(wh: FileHandle) {
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
                didEnsureChunksDir = false
            }
        }
    }

    /// Validates that every chunk recorded in `meta.completedChunks` actually has valid disk backing
    /// (a complete `.chk` spill file or an allocated non-hole byte range inside `media.bin`), prunes
    /// phantom/truncated/sparse-hole entries, recomputes `contiguousPrefixCount`, and compacts legacy
    /// bloated unpinned `media.bin` files.
    internal func reconcileAndCompactDiskStorageLocked() {
        let fm = FileManager.default
        let hasMediaBin = fm.fileExists(atPath: dataFileURL.path)
        let hasChunksDir = fm.fileExists(atPath: chunksDirectoryURL.path)

        var validSpillChunks = Set<Int>()
        if hasChunksDir, let names = try? fm.contentsOfDirectory(atPath: chunksDirectoryURL.path) {
            for name in names where name.hasSuffix(".chk") {
                let stem = String(name.dropLast(4))
                guard let idx = Int(stem), idx >= 0 else { continue }
                let spillURL = chunksDirectoryURL.appendingPathComponent(name)
                let size = ((try? fm.attributesOfItem(atPath: spillURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let requiredLen: Int64 = meta.totalSize > 0 ? Int64(expectedChunkLenLocked(index: idx)) : 1
                if requiredLen > 0 && size >= requiredLen {
                    validSpillChunks.insert(idx)
                }
            }
        }

        let logicalSize: Int64 = hasMediaBin
            ? (((try? fm.attributesOfItem(atPath: dataFileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0)
            : 0

        var prunedCount = 0
        if !meta.completedChunks.isEmpty {
            if !hasMediaBin {
                let beforeCount = meta.completedChunks.count
                meta.completedChunks = meta.completedChunks.intersection(validSpillChunks)
                prunedCount = beforeCount - meta.completedChunks.count
            } else {
                var allocatedExtents: [AllocatedByteExtent]? = nil
                let fd = Darwin.open(dataFileURL.path, O_RDONLY)
                if fd >= 0 {
                    allocatedExtents = Self.enumerateAllocatedExtents(fd: fd, logicalSize: logicalSize)
                    Darwin.close(fd)
                }
                let chunkSize = Int64(meta.chunkSize)
                var validSet = Set<Int>()
                validSet.reserveCapacity(meta.completedChunks.count)
                for idx in meta.completedChunks {
                    if validSpillChunks.contains(idx) {
                        validSet.insert(idx)
                        continue
                    }
                    let offset = Int64(idx) * chunkSize
                    let requiredLen: Int64
                    if meta.totalSize > 0 {
                        requiredLen = Int64(expectedChunkLenLocked(index: idx))
                    } else {
                        requiredLen = min(chunkSize, max(0, logicalSize - offset))
                    }
                    guard requiredLen > 0, offset >= 0, offset + requiredLen <= logicalSize else {
                        prunedCount += 1
                        continue
                    }
                    if let extents = allocatedExtents,
                       !Self.isRangeCoveredByExtents(offset: offset, length: requiredLen, extents: extents) {
                        prunedCount += 1
                        continue
                    }
                    validSet.insert(idx)
                }
                if prunedCount > 0 {
                    meta.completedChunks = validSet
                }
            }
        }

        var prefix = 0
        if hasMediaBin {
            while meta.completedChunks.contains(prefix) {
                prefix += 1
            }
        }
        contiguousPrefixCount = prefix
        didNotifyFullyCached = meta.isFullyCached

        if prunedCount > 0 {
            DonbyLogger.shared.log(
                "检测到缓存索引与磁盘文件不一致，已自动清理 \(prunedCount) 个缺失/空洞分片 (\(assetKey))",
                level: .warning,
                subsystem: "TurboCache"
            )
            if persistDisk || meta.pinned {
                writeMetaSnapshotToDisk(meta)
            }
        }

        guard hasMediaBin else { return }

        // First fold any spill chunks < prefix that might already exist in `chunks/`
        if hasChunksDir && prefix > 0 {
            ensureFileHandlesLocked()
            if let wh = writeHandle {
                for idx in 0..<prefix {
                    writeSpillFileIntoMediaBinLocked(index: idx, wh: wh)
                }
            }
        }

        let prefixBytes = Int64(prefix) * Int64(meta.chunkSize)
        // Keep pinned offline downloads in direct sparse APFS `media.bin`; only compact unpinned streaming caches.
        guard !meta.pinned, !meta.isFullyCached, logicalSize > prefixBytes + Int64(meta.chunkSize * 4) else {
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
                guard len > 0, Int64(off) + Int64(len) <= logicalSize else { continue }
                if (try? rh.seek(toOffset: off)) != nil,
                   let data = try? rh.read(upToCount: len), data.count == len {
                    try? data.write(to: spillURL, options: .atomic)
                }
            }
        }

        if let wh = writeHandle {
            try? wh.truncate(atOffset: UInt64(max(0, prefixBytes)))
        }
    }
}

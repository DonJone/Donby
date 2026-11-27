import Foundation
import Darwin
import DonbyCore
import DonbyKernelC

// MARK: - Probe Invalidation & Materialization Bridge

extension TieredAssetChunkStore {
    /// Evicts header (`0...3`) and EOF tail probe chunks (final 2 chunks) from L1 RAM,
    /// `DKChunkStore`, and `meta.completedChunks` so a failed open/probe retries cleanly.
    public func invalidateProbeChunks() {
        dk_net_store_invalidate_probe_chunks(rawStore)
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
        }
        didNotifyFullyCached = meta.isFullyCached
        let shouldPersist = (persistDisk || meta.pinned) && !isClosedForDisk && !isRemovedFromDisk
        let snapshot = meta
        lock.unlock()

        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }

    public func prepareContiguousMediaBinForMaterialization() {
        dk_net_store_flush(rawStore)
        metaWriteQueue.sync {}
        lock.lock()
        guard !isRemovedFromDisk else {
            lock.unlock()
            return
        }
        isClosedForDisk = false
        let shouldPersist = (persistDisk || meta.pinned) && !isRemovedFromDisk
        let snapshot = meta
        lock.unlock()
        if shouldPersist {
            writeMetaSnapshotToDisk(snapshot)
        }
    }
}

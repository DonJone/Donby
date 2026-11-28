import Foundation
import DonbyCore
import DonbyNetwork

public struct ImageMetadataCacheUsage: Sendable {
    public let imageBytes: Int64
    public let metadataBytes: Int64
    public var totalBytes: Int64 { imageBytes + metadataBytes }

    public init(imageBytes: Int64, metadataBytes: Int64) {
        self.imageBytes = imageBytes
        self.metadataBytes = metadataBytes
    }
}

/// Coordinates unified disk budget and cleanup across artwork images and metadata caches
/// (ServerHomeCache snapshots, multi-platform ratings, IMDb official dataset, and optional extension bridge).
public final class ImageMetadataCacheCoordinator: @unchecked Sendable {
    public static let shared = ImageMetadataCacheCoordinator()

    private var budgetTask: Task<Void, Never>?
    private let lock = NSLock()

    private init() {}

    public func measureUsageAsync() async -> ImageMetadataCacheUsage {
        async let imageBytes = ArtworkImageCache.shared.diskCacheSizeBytesAsync()
        async let homeBytes = ServerHomeCacheStore.shared.diskCacheSizeBytesAsync()
        async let ratingBytes = MultiPlatformRatingService.shared.diskCacheSizeBytes()
        async let imdbBytes = IMDbOfficialRatingsStore.shared.diskCacheSizeBytes()
        async let extBytes = DonbyAppExtensionCenter.shared.plugin?.metadataCacheSizeBytes() ?? 0

        let metadataTotal = await (homeBytes + ratingBytes + imdbBytes + extBytes)
        return ImageMetadataCacheUsage(imageBytes: await imageBytes, metadataBytes: metadataTotal)
    }

    public func updateDiskLimitMB(_ limitMB: Int) {
        lock.lock()
        budgetTask?.cancel()
        if limitMB <= 0 {
            budgetTask = nil
            lock.unlock()
            ArtworkImageCache.shared.setMaxDiskCacheBytes(0)
            return
        }

        let totalLimit = Int64(limitMB) * 1024 * 1024
        let metadataCap = min(Int64(256) * 1024 * 1024, totalLimit / 4)

        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }

            let imdbBytes = await IMDbOfficialRatingsStore.shared.diskCacheSizeBytes()
            let extBytes = await DonbyAppExtensionCenter.shared.plugin?.metadataCacheSizeBytes() ?? 0
            var homeBytes = await ServerHomeCacheStore.shared.diskCacheSizeBytesAsync()
            var ratingBytes = await MultiPlatformRatingService.shared.diskCacheSizeBytes()

            let currentMeta = homeBytes + ratingBytes + imdbBytes + extBytes
            if currentMeta > metadataCap {
                let targetHomeBudget = max(0, metadataCap - ratingBytes - imdbBytes - extBytes)
                await ServerHomeCacheStore.shared.pruneIfNeededAsync(maxBytes: targetHomeBudget)
                homeBytes = await ServerHomeCacheStore.shared.diskCacheSizeBytesAsync()

                let remainingMeta = homeBytes + ratingBytes + imdbBytes + extBytes
                if remainingMeta > metadataCap {
                    let ratingBudget = max(Int64(4) * 1024 * 1024, metadataCap - homeBytes - imdbBytes - extBytes)
                    await MultiPlatformRatingService.shared.pruneIfNeeded(maxBytes: ratingBudget)
                    ratingBytes = await MultiPlatformRatingService.shared.diskCacheSizeBytes()
                }
            }

            guard !Task.isCancelled else { return }
            let finalMetadataBytes = homeBytes + ratingBytes + imdbBytes + extBytes
            let imageBudget = min(totalLimit, max(Int64(64) * 1024 * 1024, totalLimit - finalMetadataBytes))
            ArtworkImageCache.shared.setMaxDiskCacheBytes(imageBudget)
        }
        budgetTask = task
        lock.unlock()
    }

    private func cancelBudgetTask() {
        lock.lock()
        budgetTask?.cancel()
        budgetTask = nil
        lock.unlock()
    }

    private func currentBudgetTask() -> Task<Void, Never>? {
        lock.lock()
        let task = budgetTask
        lock.unlock()
        return task
    }

    public func enforceDiskLimitMBAsync(_ limitMB: Int) async {
        updateDiskLimitMB(limitMB)
        await currentBudgetTask()?.value
    }

    public func clearAllAsync() async {
        cancelBudgetTask()

        await ArtworkImageCache.shared.clearAllCacheAsync()
        await MultiPlatformRatingService.shared.clearCache()
        await IMDbOfficialRatingsStore.shared.clearCache()
        if let plugin = await DonbyAppExtensionCenter.shared.plugin {
            await plugin.clearMetadataCacheAsync()
        }
        await ServerHomeCacheStore.shared.clearAllAsync()
    }
}

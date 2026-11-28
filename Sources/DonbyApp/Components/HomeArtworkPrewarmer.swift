import Foundation
import DonbyCore
import DonbyNetwork

/// Priority-ordered, generation-guarded prewarmer for homepage hero, library, continue-watching,
/// and first-screen poster artwork. Warms both TCP/TLS/H2 origins and memory/disk decode caches
/// ahead of `NativeEmbyHomeView` cell layout.
public final class HomeArtworkPrewarmer: @unchecked Sendable {
    public static let shared = HomeArtworkPrewarmer()

    private struct Target: Sendable {
        let item: EmbyItem
        let kind: EmbyImageKind
        let maxWidth: Int
        let priority: Operation.QueuePriority
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeSnapshotTask: Task<Void, Never>?
    private var activeSignature: String?
    private var lastCompletedSignature: String?
    private var lastCompletedAt: Date = .distantPast

    private init() {}

    public func cancelAll() {
        lock.lock()
        generation &+= 1
        let prev = activeSnapshotTask
        activeSnapshotTask = nil
        activeSignature = nil
        lastCompletedSignature = nil
        lock.unlock()
        prev?.cancel()
    }

    /// Prewarms image host connections and decodes/fetches first-screen homepage artwork in strict visual order.
    public func prewarmHome(
        server: EmbyServerConfig,
        carouselItems: [EmbyItem],
        libraryViews: [EmbyItem],
        resumeItems: [EmbyItem],
        nextUpItems: [EmbyItem],
        latestByLibrary: [String: [EmbyItem]],
        extraPosterShelves: [[EmbyItem]] = []
    ) {
        let targets = buildTargets(
            carouselItems: carouselItems,
            libraryViews: libraryViews,
            resumeItems: resumeItems,
            nextUpItems: nextUpItems,
            latestByLibrary: latestByLibrary,
            extraPosterShelves: extraPosterShelves
        )

        prewarmOrigins(for: server, sampleItems: targets.prefix(16).map(\.item))
        guard !targets.isEmpty else { return }

        let signature = "\(server.activeBaseURL)|" + targets.map { "\($0.item.id):\($0.kind.rawValue):\($0.maxWidth)" }.joined(separator: ",")
        let now = Date()

        lock.lock()
        if activeSnapshotTask != nil, activeSignature == signature {
            lock.unlock()
            return
        }
        if activeSnapshotTask == nil,
           lastCompletedSignature == signature,
           now.timeIntervalSince(lastCompletedAt) < 15.0 {
            lock.unlock()
            return
        }
        generation &+= 1
        let gen = generation
        let prev = activeSnapshotTask
        activeSignature = signature
        let heroTargets = targets.filter { $0.maxWidth >= 1200 }
        let cardTargets = targets.filter { $0.maxWidth < 1200 }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // Keep prewarm concurrency bounded (<= 4 total: 1 hero slot + 3 card slots) so
            // 2200px hero decodes never starve visible 360px poster cells on decodeOperationQueue.
            await withTaskGroup(of: Void.self) { group in
                if !cardTargets.isEmpty {
                    group.addTask {
                        await Self.runTargets(cardTargets, server: server, maxConcurrent: 3)
                    }
                }
                if !heroTargets.isEmpty {
                    group.addTask {
                        await Self.runTargets(heroTargets, server: server, maxConcurrent: 1)
                    }
                }
            }
            guard let self else { return }
            self.clearTaskIfMatching(gen: gen, signature: signature)
        }
        activeSnapshotTask = task
        lock.unlock()
        prev?.cancel()
    }

    /// Incrementally prewarms a newly arrived cold-load shelf before UI layout finishes.
    public func prewarmShelfItems(
        server: EmbyServerConfig,
        items: [EmbyItem],
        kind: EmbyImageKind,
        maxWidth: Int,
        priority: Operation.QueuePriority = .normal,
        maxCount: Int = 8
    ) {
        let slice = Array(items.prefix(maxCount))
        guard !slice.isEmpty else { return }
        prewarmOrigins(for: server, sampleItems: slice)
        let targets = slice.map { Target(item: $0, kind: kind, maxWidth: maxWidth, priority: priority) }
        Task.detached(priority: priority == .low ? .utility : .userInitiated) {
            await Self.runTargets(targets, server: server, maxConcurrent: 4)
        }
    }

    private func clearTaskIfMatching(gen: UInt64, signature: String) {
        lock.lock()
        if generation == gen {
            activeSnapshotTask = nil
            activeSignature = nil
            lastCompletedSignature = signature
            lastCompletedAt = Date()
        }
        lock.unlock()
    }

    private func prewarmOrigins(for server: EmbyServerConfig, sampleItems: [EmbyItem]) {
        if let baseURL = URL(string: server.activeBaseURL) {
            ArtworkDownloadManager.shared.prewarmOrigin(for: baseURL, server: server)
        }
        var warmedHosts = Set<String>()
        if let baseHost = URL(string: server.activeBaseURL)?.host?.lowercased() {
            warmedHosts.insert(baseHost)
        }
        for item in sampleItems {
            for raw in [item.uhdBackdropURL, item.uhdPosterURL, item.uhdThumbURL] {
                guard let raw, !raw.isEmpty, let url = URL(string: raw),
                      let host = url.host?.lowercased(), !host.isEmpty else { continue }
                if warmedHosts.insert(host).inserted {
                    ArtworkDownloadManager.shared.prewarmOrigin(for: url, server: server)
                    if warmedHosts.count >= 3 { return }
                }
            }
        }
    }

    private func buildTargets(
        carouselItems: [EmbyItem],
        libraryViews: [EmbyItem],
        resumeItems: [EmbyItem],
        nextUpItems: [EmbyItem],
        latestByLibrary: [String: [EmbyItem]],
        extraPosterShelves: [[EmbyItem]]
    ) -> [Target] {
        var targets: [Target] = []
        var seen = Set<String>()

        func appendTarget(item: EmbyItem, kind: EmbyImageKind, maxWidth: Int, priority: Operation.QueuePriority) {
            let dedupKey = "\(item.id)|\(kind.rawValue)|\(maxWidth > 900 ? "f" : "t")"
            guard seen.insert(dedupKey).inserted else { return }
            if MediaArtworkView.cachedCGImageInMemory(item: item, kind: kind, maxWidth: maxWidth) != nil {
                return
            }
            targets.append(Target(item: item, kind: kind, maxWidth: maxWidth, priority: priority))
        }

        // Wave 1: Active hero + immediate next hero slide
        if let firstHero = carouselItems.first {
            appendTarget(item: firstHero, kind: .backdrop, maxWidth: 2200, priority: .veryHigh)
        }
        if carouselItems.count > 1 {
            appendTarget(item: carouselItems[1], kind: .backdrop, maxWidth: 2200, priority: .normal)
        }

        // Wave 2: Library strip ("我的媒体")
        for view in libraryViews.prefix(6) {
            let kind: EmbyImageKind = (view.backdropImageTags?.isEmpty == false) ? .backdrop : .primary
            appendTarget(item: view, kind: kind, maxWidth: 440, priority: .high)
        }

        // Wave 3: Continue watching / Next up landscape cards
        var seenContinue = Set<String>()
        var continueAdded = 0
        for item in resumeItems + nextUpItems {
            guard seenContinue.insert(item.id).inserted else { continue }
            appendTarget(item: item, kind: .thumb, maxWidth: 500, priority: .high)
            continueAdded += 1
            if continueAdded >= 6 { break }
        }

        // Wave 4: Extension poster shelves (e.g. UHD hot) + first 2 visible library shelves
        var shelfOrder: [[EmbyItem]] = extraPosterShelves.filter { !$0.isEmpty }
        for view in libraryViews {
            if let items = latestByLibrary[view.id], !items.isEmpty {
                shelfOrder.append(items)
            }
        }

        for (shelfIndex, items) in shelfOrder.prefix(5).enumerated() {
            let count = shelfIndex < 2 ? 8 : 6
            let pri: Operation.QueuePriority
            switch shelfIndex {
            case 0: pri = .high
            case 1: pri = .normal
            default: pri = .low
            }
            for item in items.prefix(count) {
                appendTarget(item: item, kind: .primary, maxWidth: 360, priority: pri)
            }
        }

        return targets
    }

    private static func runTargets(
        _ targets: [Target],
        server: EmbyServerConfig,
        maxConcurrent: Int
    ) async {
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            let initialCount = min(maxConcurrent, targets.count)
            for _ in 0..<initialCount {
                let target = targets[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return }
                    _ = await MediaArtworkView.loadOrFetchCGImage(
                        server: server,
                        item: target.item,
                        kind: target.kind,
                        maxWidth: target.maxWidth,
                        priority: target.priority
                    )
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, nextIndex < targets.count else { continue }
                let target = targets[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return }
                    _ = await MediaArtworkView.loadOrFetchCGImage(
                        server: server,
                        item: target.item,
                        kind: target.kind,
                        maxWidth: target.maxWidth,
                        priority: target.priority
                    )
                }
            }
        }
    }
}

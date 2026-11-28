import Foundation
import CoreGraphics
import DonbyCore
import DonbyNetwork

/// Propagates priority boosts from coalesced `CGImageLoadCoordinator` callers down into
/// queued `Operation` decodes and `ArtworkDownloadCoordinator` / `URLSessionDataTask` slots.
public final class ArtworkPriorityEscalator: @unchecked Sendable {
    private let lock = NSLock()
    private var _priority: Operation.QueuePriority
    private var hooks: [@Sendable (Operation.QueuePriority) -> Void] = []

    public init(initialPriority: Operation.QueuePriority) {
        self._priority = initialPriority
    }

    public var currentPriority: Operation.QueuePriority {
        lock.lock()
        defer { lock.unlock() }
        return _priority
    }

    public func registerBoostHook(_ hook: @escaping @Sendable (Operation.QueuePriority) -> Void) {
        lock.lock()
        let current = _priority
        hooks.append(hook)
        lock.unlock()
        hook(current)
    }

    public func boost(to priority: Operation.QueuePriority) {
        lock.lock()
        guard priority.rawValue > _priority.rawValue else {
            lock.unlock()
            return
        }
        _priority = priority
        let currentHooks = hooks
        lock.unlock()
        for hook in currentHooks {
            hook(priority)
        }
    }
}

private final class ActiveDataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var desiredPriority: Float

    init(priority: Operation.QueuePriority) {
        self.desiredPriority = Self.taskPriority(for: priority)
    }

    static func taskPriority(for priority: Operation.QueuePriority) -> Float {
        switch priority {
        case .veryHigh: return 0.95
        case .high: return 0.80
        case .normal: return 0.55
        case .low: return 0.25
        case .veryLow: return 0.15
        @unknown default: return 0.50
        }
    }

    func attach(_ dataTask: URLSessionDataTask) {
        lock.lock()
        task = dataTask
        dataTask.priority = desiredPriority
        lock.unlock()
    }

    func boost(to priority: Operation.QueuePriority) {
        let mapped = Self.taskPriority(for: priority)
        lock.lock()
        if mapped > desiredPriority {
            desiredPriority = mapped
            task?.priority = mapped
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }
}

// MARK: - Priority-Reserved Concurrency-Controlled Artwork Downloader
private actor DownloadConcurrencyGate {
    private let limit: Int
    private let lowPriorityLimit: Int
    private var active: Int = 0
    private var waiters: [(id: UUID, priority: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var pendingBoosts: [UUID: Int] = [:]

    init(limit: Int, lowPriorityLimit: Int) {
        self.limit = max(1, limit)
        self.lowPriorityLimit = max(1, min(lowPriorityLimit, self.limit))
    }

    private func canRun(priorityRaw: Int, currentActive: Int) -> Bool {
        if priorityRaw <= Operation.QueuePriority.low.rawValue {
            return currentActive < lowPriorityLimit
        }
        return currentActive < limit
    }

    func acquire(priority: Operation.QueuePriority = .normal, waiterId: UUID = UUID()) async throws {
        try Task.checkCancellation()
        let boostedPriority = max(priority.rawValue, pendingBoosts.removeValue(forKey: waiterId) ?? priority.rawValue)
        if canRun(priorityRaw: boostedPriority, currentActive: active) {
            active += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    pendingBoosts.removeValue(forKey: waiterId)
                    cont.resume(throwing: CancellationError())
                    return
                }
                let finalPriority = max(boostedPriority, pendingBoosts.removeValue(forKey: waiterId) ?? boostedPriority)
                if canRun(priorityRaw: finalPriority, currentActive: active) {
                    active += 1
                    cont.resume(returning: ())
                    return
                }
                waiters.append((waiterId, finalPriority, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterId) }
        }
    }

    func boostPriority(id: UUID, to priority: Operation.QueuePriority) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            if priority.rawValue > waiters[idx].priority {
                waiters[idx].priority = priority.rawValue
                if canRun(priorityRaw: waiters[idx].priority, currentActive: active) {
                    let promoted = waiters.remove(at: idx)
                    active += 1
                    promoted.continuation.resume(returning: ())
                }
            }
        } else {
            let existing = pendingBoosts[id] ?? Int.min
            if priority.rawValue > existing {
                pendingBoosts[id] = priority.rawValue
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        pendingBoosts.removeValue(forKey: id)
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let entry = waiters.remove(at: idx)
            entry.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        let nextActive = max(0, active - 1)
        var bestIdx: Int?
        var bestPri = Int.min
        for idx in waiters.indices {
            let pri = waiters[idx].priority
            guard canRun(priorityRaw: pri, currentActive: nextActive) else { continue }
            if pri > bestPri {
                bestPri = pri
                bestIdx = idx
            }
        }
        if let bestIdx {
            let next = waiters.remove(at: bestIdx)
            active = nextActive + 1
            next.continuation.resume(returning: ())
            return
        }
        active = nextActive
    }
}

private actor ArtworkDownloadCoordinator {
    private struct InFlightEntry {
        let id: UUID
        let gateWaiterId: UUID
        let dataTaskBox: ActiveDataTaskBox
        var priority: Operation.QueuePriority
        let task: Task<Void, Never>
        var waiters: [(id: UUID, continuation: CheckedContinuation<(Data, URLResponse), Error>)] = []
    }

    // 16 total slots for HTTP/2-3 multiplexing; cap background prefetch at 6 so 10 fast-lane slots stay open for visible cards.
    private let gate = DownloadConcurrencyGate(limit: 16, lowPriorityLimit: 6)
    private let session: URLSession
    private var inFlight: [String: InFlightEntry] = [:]

    init(session: URLSession) {
        self.session = session
    }

    private nonisolated static func fetchData(
        session: URLSession,
        request: URLRequest,
        dataTaskBox: ActiveDataTaskBox
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, let response {
                        cont.resume(returning: (data, response))
                    } else {
                        cont.resume(throwing: URLError(.badServerResponse))
                    }
                }
                dataTaskBox.attach(task)
                task.resume()
            }
        } onCancel: {
            dataTaskBox.cancel()
        }
    }

    func boostPriority(for key: String, to priority: Operation.QueuePriority) async {
        guard var existing = inFlight[key], priority.rawValue > existing.priority.rawValue else { return }
        existing.priority = priority
        inFlight[key] = existing
        existing.dataTaskBox.boost(to: priority)
        await gate.boostPriority(id: existing.gateWaiterId, to: priority)
    }

    func download(
        for request: URLRequest,
        priority: Operation.QueuePriority = .normal,
        escalator: ArtworkPriorityEscalator? = nil
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let effectivePriority = maxPriority(priority, escalator?.currentPriority ?? priority)
        let key = request.url?.absoluteString ?? UUID().uuidString
        let entryId: UUID
        if var existing = inFlight[key] {
            entryId = existing.id
            if effectivePriority.rawValue > existing.priority.rawValue {
                existing.priority = effectivePriority
                inFlight[key] = existing
                existing.dataTaskBox.boost(to: effectivePriority)
                await gate.boostPriority(id: existing.gateWaiterId, to: effectivePriority)
            }
        } else {
            let newId = UUID()
            let gateWaiterId = UUID()
            let dataTaskBox = ActiveDataTaskBox(priority: effectivePriority)
            let session = self.session
            let gate = self.gate
            let task = Task {
                let result: Result<(Data, URLResponse), Error>
                do {
                    try await gate.acquire(priority: effectivePriority, waiterId: gateWaiterId)
                    do {
                        try Task.checkCancellation()
                        let response = try await Self.fetchData(session: session, request: request, dataTaskBox: dataTaskBox)
                        await gate.release()
                        result = .success(response)
                    } catch {
                        await gate.release()
                        result = .failure(error)
                    }
                } catch {
                    result = .failure(error)
                }
                self.complete(key: key, entryId: newId, result: result)
            }
            inFlight[key] = InFlightEntry(
                id: newId,
                gateWaiterId: gateWaiterId,
                dataTaskBox: dataTaskBox,
                priority: effectivePriority,
                task: task
            )
            entryId = newId
        }

        if let escalator {
            escalator.registerBoostHook { [weak self] boosted in
                guard let self else { return }
                Task { await self.boostPriority(for: key, to: boosted) }
            }
        }

        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    if let entry = inFlight[key], entry.id == entryId, entry.waiters.isEmpty {
                        entry.task.cancel()
                        inFlight.removeValue(forKey: key)
                    }
                    return
                }
                guard var entry = inFlight[key], entry.id == entryId else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                entry.waiters.append((waiterId, cont))
                inFlight[key] = entry
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, entryId: entryId, waiterId: waiterId) }
        }
    }

    private func maxPriority(_ lhs: Operation.QueuePriority, _ rhs: Operation.QueuePriority) -> Operation.QueuePriority {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }

    private func cancelWaiter(key: String, entryId: UUID, waiterId: UUID) {
        guard var entry = inFlight[key], entry.id == entryId else { return }
        if let idx = entry.waiters.firstIndex(where: { $0.id == waiterId }) {
            let removed = entry.waiters.remove(at: idx)
            removed.continuation.resume(throwing: CancellationError())
        }
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }

    private func complete(key: String, entryId: UUID, result: Result<(Data, URLResponse), Error>) {
        guard let entry = inFlight[key], entry.id == entryId else { return }
        inFlight.removeValue(forKey: key)
        for waiter in entry.waiters {
            waiter.continuation.resume(with: result)
        }
    }
}

public final class ArtworkDownloadManager: @unchecked Sendable {
    public static let shared = ArtworkDownloadManager()
    private let session: URLSession
    private let coordinator: ArtworkDownloadCoordinator
    let cgLoadCoordinator = CGImageLoadCoordinator()

    private let prewarmLock = NSLock()
    private var prewarmedOrigins: [String: Date] = [:]
    private static let prewarmTTL: TimeInterval = 60

    private let negativeLock = NSLock()
    private var negativeMisses: [String: Date] = [:]
    private static let negativeMissTTL: TimeInterval = 60
    private static let maxNegativeMissEntries = 1024

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        self.session = session
        self.coordinator = ArtworkDownloadCoordinator(session: session)
    }

    public func download(
        for request: URLRequest,
        priority: Operation.QueuePriority = .normal,
        escalator: ArtworkPriorityEscalator? = nil
    ) async throws -> (Data, URLResponse) {
        try await coordinator.download(for: request, priority: priority, escalator: escalator)
    }

    /// Pre-negotiates TCP/TLS/H2 on the dedicated artwork `URLSession` so first-screen posters avoid cold handshake latency.
    public func prewarmOrigin(for url: URL, server: EmbyServerConfig? = nil) {
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else { return }
        let portPart = url.port.map { ":\($0)" } ?? ""
        let originKey = "\(scheme)://\(host)\(portPart)"
        let now = Date()

        prewarmLock.lock()
        if let last = prewarmedOrigins[originKey], now.timeIntervalSince(last) < Self.prewarmTTL {
            prewarmLock.unlock()
            return
        }
        prewarmedOrigins[originKey] = now
        prewarmLock.unlock()

        guard let originURL = URL(string: "\(originKey)/") else { return }
        var req = EmbyClient.shared.makeImageRequest(url: originURL, server: server)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 4
        let task = session.dataTask(with: req) { _, _, _ in }
        task.priority = 0.2
        task.resume()
    }

    public func isNegativelyCached(_ url: URL) -> Bool {
        let key = url.absoluteString
        let now = Date()
        negativeLock.lock()
        defer { negativeLock.unlock() }
        guard let ts = negativeMisses[key] else { return false }
        if now.timeIntervalSince(ts) < Self.negativeMissTTL {
            return true
        }
        negativeMisses.removeValue(forKey: key)
        return false
    }

    public func recordNegativeMiss(_ url: URL) {
        let key = url.absoluteString
        let now = Date()
        negativeLock.lock()
        if negativeMisses.count >= Self.maxNegativeMissEntries {
            negativeMisses = negativeMisses.filter { now.timeIntervalSince($0.value) < Self.negativeMissTTL }
            if negativeMisses.count >= Self.maxNegativeMissEntries {
                negativeMisses.removeAll(keepingCapacity: true)
            }
        }
        negativeMisses[key] = now
        negativeLock.unlock()
    }

    public func clearNegativeCache() {
        negativeLock.lock()
        negativeMisses.removeAll(keepingCapacity: false)
        negativeLock.unlock()
    }
}

actor CGImageLoadCoordinator {
    private struct InFlightEntry {
        let id: UUID
        let escalator: ArtworkPriorityEscalator
        let task: Task<Void, Never>
        var waiters: [(id: UUID, continuation: CheckedContinuation<CGImage?, Never>)] = []
    }

    private var inFlight: [String: InFlightEntry] = [:]

    func load(
        key: String,
        priority: Operation.QueuePriority = .normal,
        work: @escaping @Sendable (ArtworkPriorityEscalator) async -> CGImage?
    ) async -> CGImage? {
        if Task.isCancelled { return nil }
        let entryId: UUID
        if let existing = inFlight[key] {
            entryId = existing.id
            existing.escalator.boost(to: priority)
        } else {
            let newId = UUID()
            let escalator = ArtworkPriorityEscalator(initialPriority: priority)
            let task = Task {
                let img = await work(escalator)
                self.complete(key: key, entryId: newId, result: img)
            }
            inFlight[key] = InFlightEntry(id: newId, escalator: escalator, task: task)
            entryId = newId
        }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: nil)
                    cancelWaiterIfNeeded(key: key, entryId: entryId, waiterId: waiterId)
                    return
                }
                guard var entry = inFlight[key], entry.id == entryId else {
                    cont.resume(returning: nil)
                    return
                }
                entry.waiters.append((waiterId, cont))
                inFlight[key] = entry
            }
        } onCancel: {
            Task { await self.cancelWaiterIfNeeded(key: key, entryId: entryId, waiterId: waiterId) }
        }
    }

    private func complete(key: String, entryId: UUID, result: CGImage?) {
        guard let entry = inFlight[key], entry.id == entryId else { return }
        inFlight.removeValue(forKey: key)
        for waiter in entry.waiters {
            waiter.continuation.resume(returning: result)
        }
    }

    private func cancelWaiterIfNeeded(key: String, entryId: UUID, waiterId: UUID) {
        guard var entry = inFlight[key], entry.id == entryId else { return }
        if let idx = entry.waiters.firstIndex(where: { $0.id == waiterId }) {
            let waiter = entry.waiters.remove(at: idx)
            waiter.continuation.resume(returning: nil)
        }
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }
}

import Foundation
import CoreGraphics

// MARK: - Concurrency-Controlled Artwork Downloader
private actor DownloadConcurrencyGate {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [(id: UUID, priority: Int, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire(priority: Operation.QueuePriority = .normal) async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiters.append((waiterId, priority.rawValue, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterId) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let entry = waiters.remove(at: idx)
            entry.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        if !waiters.isEmpty {
            var bestIdx = 0
            var bestPri = waiters[0].priority
            for idx in 1..<waiters.count where waiters[idx].priority > bestPri {
                bestPri = waiters[idx].priority
                bestIdx = idx
            }
            let next = waiters.remove(at: bestIdx)
            next.continuation.resume(returning: ())
            return
        }
        active = max(0, active - 1)
    }
}

private actor ArtworkDownloadCoordinator {
    private struct InFlightEntry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [(id: UUID, continuation: CheckedContinuation<(Data, URLResponse), Error>)] = []
    }

    private let gate = DownloadConcurrencyGate(limit: 6)
    private let session: URLSession
    private var inFlight: [String: InFlightEntry] = [:]

    init(session: URLSession) {
        self.session = session
    }

    func download(for request: URLRequest, priority: Operation.QueuePriority = .normal) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let key = request.url?.absoluteString ?? UUID().uuidString
        let entryId: UUID
        if let existing = inFlight[key] {
            entryId = existing.id
        } else {
            let newId = UUID()
            let session = self.session
            let gate = self.gate
            let task = Task {
                let result: Result<(Data, URLResponse), Error>
                do {
                    try await gate.acquire(priority: priority)
                    do {
                        try Task.checkCancellation()
                        let response = try await session.data(for: request)
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
            inFlight[key] = InFlightEntry(id: newId, task: task)
            entryId = newId
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
    private let coordinator: ArtworkDownloadCoordinator
    let cgLoadCoordinator = CGImageLoadCoordinator()

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.coordinator = ArtworkDownloadCoordinator(session: URLSession(configuration: config))
    }

    public func download(for request: URLRequest, priority: Operation.QueuePriority = .normal) async throws -> (Data, URLResponse) {
        try await coordinator.download(for: request, priority: priority)
    }
}

actor CGImageLoadCoordinator {
    private struct InFlightEntry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [(id: UUID, continuation: CheckedContinuation<CGImage?, Never>)] = []
    }

    private var inFlight: [String: InFlightEntry] = [:]

    func load(key: String, work: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        if Task.isCancelled { return nil }
        let entryId: UUID
        if let existing = inFlight[key] {
            entryId = existing.id
        } else {
            let newId = UUID()
            let task = Task {
                let img = await work()
                self.complete(key: key, entryId: newId, result: img)
            }
            inFlight[key] = InFlightEntry(id: newId, task: task)
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

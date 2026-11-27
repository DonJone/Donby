import Foundation
import DonbyCore

// MARK: - Sliding-Window Bandwidth Meter (Smooth, Zero-Freeze, Auto-Decaying)

/// Lock-light sliding-window throughput meter shared by offline downloads and Turbo streaming.
/// Uses fixed time buckets across a rolling window so bursty TCP arrivals smooth naturally
/// and reported speed decays cleanly to 0.0 MB/s during stalls, backoff, or idle periods.
public final class SlidingWindowSpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let bucketDuration: TimeInterval
    private let bucketCount: Int
    private let windowDuration: TimeInterval
    private var buckets: [Int64]
    private var headBucketIndex: Int64 = -1
    private var firstByteUptime: TimeInterval = 0
    private var lastByteUptime: TimeInterval = 0
    private var totalWindowBytes: Int64 = 0
    private var peakObservedMBs: Double = 0.0

    public init(windowDuration: TimeInterval = 2.5, bucketDuration: TimeInterval = 0.10) {
        let safeBucket = max(0.05, bucketDuration)
        let count = max(5, Int((max(0.5, windowDuration) / safeBucket).rounded()))
        self.bucketDuration = safeBucket
        self.bucketCount = count
        self.windowDuration = Double(count) * safeBucket
        self.buckets = Array(repeating: 0, count: count)
    }

    public func reset() {
        lock.lock()
        for i in 0..<bucketCount { buckets[i] = 0 }
        headBucketIndex = -1
        firstByteUptime = 0
        lastByteUptime = 0
        totalWindowBytes = 0
        lock.unlock()
    }

    public func recordBytes(_ byteCount: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard byteCount > 0 else { return }
        lock.lock()
        advanceBucketsLocked(to: now)
        if lastByteUptime <= 0 || (now - lastByteUptime) >= windowDuration {
            firstByteUptime = now
        }
        lastByteUptime = now
        let slot = Int(headBucketIndex % Int64(bucketCount))
        let safeSlot = slot >= 0 ? slot : (slot + bucketCount)
        buckets[safeSlot] += Int64(byteCount)
        totalWindowBytes += Int64(byteCount)
        lock.unlock()
    }

    /// Returns current throughput in MiB/s (`MB/s` = 1,048,576 B/s), decaying smoothly to 0.0 when idle.
    public func speedMBs(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastByteUptime > 0 else { return 0.0 }
        let idleSec = now - lastByteUptime
        if idleSec >= windowDuration {
            advanceBucketsLocked(to: now)
            return 0.0
        }
        advanceBucketsLocked(to: now)
        guard totalWindowBytes > 0 else { return 0.0 }
        let span = min(windowDuration, max(0.45, now - firstByteUptime))
        let spd = (Double(totalWindowBytes) / (1024.0 * 1024.0)) / span
        if spd > peakObservedMBs { peakObservedMBs = spd }
        return spd
    }

    public func peakSpeedMBs() -> Double {
        lock.lock(); defer { lock.unlock() }; return peakObservedMBs
    }

    /// Returns time in seconds since the last recorded byte (or `.infinity` if none).
    public func idleSeconds(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        lock.lock()
        let last = lastByteUptime
        lock.unlock()
        return last > 0 ? max(0.0, now - last) : .infinity
    }

    private func advanceBucketsLocked(to now: TimeInterval) {
        let targetIdx = Int64(floor(now / bucketDuration))
        if headBucketIndex < 0 {
            headBucketIndex = targetIdx
            return
        }
        let delta = targetIdx - headBucketIndex
        guard delta > 0 else { return }
        if delta >= Int64(bucketCount) {
            for i in 0..<bucketCount { buckets[i] = 0 }
            totalWindowBytes = 0
        } else {
            for step in 1...Int(delta) {
                let idx = headBucketIndex + Int64(step)
                let slot = Int(idx % Int64(bucketCount))
                let safeSlot = slot >= 0 ? slot : (slot + bucketCount)
                totalWindowBytes = max(0, totalWindowBytes - buckets[safeSlot])
                buckets[safeSlot] = 0
            }
        }
        headBucketIndex = targetIdx
    }
}

internal final class WorkerTransferMonitor: @unchecked Sendable {
    private let lock = NSLock()
    let startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var headersUptime: TimeInterval = 0
    private var lastByteUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var receivedBytes: Int64 = 0
    private var didTriggerStallCancel = false
    // 3.5s sliding window aligns closely with the 2.5s aggregate meter for fair peer-relative comparison.
    private let recentMeter = SlidingWindowSpeedMeter(windowDuration: 3.5, bucketDuration: 0.15)

    func markHeadersReceived(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); headersUptime = now; lastByteUptime = now; lock.unlock()
    }

    func recordBytes(_ count: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard count > 0 else { return }
        lock.lock(); receivedBytes += Int64(count); lastByteUptime = now; lock.unlock()
        recentMeter.recordBytes(count, at: now)
    }

    func markStallCancelled() {
        lock.lock(); didTriggerStallCancel = true; lock.unlock()
    }

    var wasStallCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return didTriggerStallCancel
    }

    func recentBytesPerSecond(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        recentMeter.speedMBs(at: now) * 1_048_576.0
    }

    func snapshot() -> (headersUptime: TimeInterval, lastByteUptime: TimeInterval, receivedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }; return (headersUptime, lastByteUptime, receivedBytes)
    }
}

/// Atomic dynamic upper chunk bound for work-stealing: allows an idle peer worker to steal
/// the back half of a large active segment so the original worker stops cleanly at the new boundary.
internal final class ActiveSegmentBound: @unchecked Sendable {
    private let lock = NSLock()
    private var currentChunk: Int
    private var endChunk: Int

    init(startChunk: Int, endChunk: Int) {
        self.currentChunk = startChunk
        self.endChunk = endChunk
    }

    func advanceCurrent(to nextChunk: Int) {
        lock.lock(); currentChunk = nextChunk; lock.unlock()
    }

    func currentEnd() -> Int {
        lock.lock(); defer { lock.unlock() }; return endChunk
    }

    func remainingChunks() -> Int {
        lock.lock(); defer { lock.unlock() }; return max(0, endChunk - currentChunk + 1)
    }

    /// Splits the un-downloaded tail in half if at least `minRemaining` chunks remain; returns stolen range.
    func tryStealTail(minRemaining: Int = 12) -> ClosedRange<Int>? {
        lock.lock()
        defer { lock.unlock() }
        let rem = endChunk - currentChunk + 1
        guard rem >= minRemaining else { return nil }
        let keep = max(4, rem / 2)
        let newEnd = currentChunk + keep - 1
        let stolenStart = newEnd + 1
        guard stolenStart <= endChunk else { return nil }
        let stolenEnd = endChunk
        endChunk = newEnd
        return stolenStart...stolenEnd
    }
}

internal final class LiveDownloadByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var committedBytes: Int64
    private var inFlightByWorker: [Int: Int64] = [:]

    init(initialCommittedBytes: Int64) {
        self.committedBytes = max(0, initialCommittedBytes)
    }

    func addInFlight(workerId: Int, delta: Int) {
        guard delta > 0 else { return }
        lock.lock(); inFlightByWorker[workerId, default: 0] += Int64(delta); lock.unlock()
    }

    func commitChunk(workerId: Int, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        inFlightByWorker[workerId] = max(0, (inFlightByWorker[workerId] ?? 0) - Int64(bytes))
        committedBytes += Int64(bytes)
        lock.unlock()
    }

    func clearWorkerInFlight(workerId: Int) {
        lock.lock(); inFlightByWorker[workerId] = 0; lock.unlock()
    }

    func liveBytes(cappedAt totalSize: Int64) -> Int64 {
        lock.lock()
        let total = committedBytes + inFlightByWorker.values.reduce(Int64(0), +)
        lock.unlock()
        return totalSize > 0 ? min(totalSize, total) : total
    }
}

internal final class DownloadRangeStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class StreamTaskState {
        let allowStatus200: Bool
        let originHost: String?
        let onRedirectResolved: (@Sendable (URL) -> Void)?
        var responseContinuation: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void), Error>?
        var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var directHeaderContinuation: CheckedContinuation<(HTTPURLResponse, @Sendable () -> Void), Error>?
        var directBodyContinuation: CheckedContinuation<Void, Error>?
        var directBytesHandler: (@Sendable (UnsafeRawBufferPointer) -> Bool)?
        var yieldedResponse = false

        init(allowStatus200: Bool, originHost: String?, onRedirectResolved: (@Sendable (URL) -> Void)?) {
            self.allowStatus200 = allowStatus200
            self.originHost = originHost?.lowercased()
            self.onRedirectResolved = onRedirectResolved
        }
    }

    private let lock = NSLock()
    private var states: [Int: StreamTaskState] = [:]

    func openStream(
        session: URLSession,
        request: URLRequest,
        allowStatus200: Bool,
        onRedirectResolved: (@Sendable (URL) -> Void)? = nil
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void) {
        let dataTask = session.dataTask(with: request)
        let originHost = request.url?.host
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (respCont: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void), Error>) in
                let state = StreamTaskState(
                    allowStatus200: allowStatus200,
                    originHost: originHost,
                    onRedirectResolved: onRedirectResolved
                )
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

    func openDirectStream(
        session: URLSession,
        request: URLRequest,
        allowStatus200: Bool,
        onRedirectResolved: (@Sendable (URL) -> Void)? = nil,
        onBytes: @escaping @Sendable (UnsafeRawBufferPointer) -> Bool
    ) async throws -> (HTTPURLResponse, @Sendable () -> Void, Task<Void, Error>) {
        let dataTask = session.dataTask(with: request)
        let originHost = request.url?.host
        let (http, cancelTask) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (hdrCont: CheckedContinuation<(HTTPURLResponse, @Sendable () -> Void), Error>) in
                let state = StreamTaskState(
                    allowStatus200: allowStatus200,
                    originHost: originHost,
                    onRedirectResolved: onRedirectResolved
                )
                state.directHeaderContinuation = hdrCont
                state.directBytesHandler = onBytes
                lock.lock()
                states[dataTask.taskIdentifier] = state
                lock.unlock()
                dataTask.resume()
            }
        } onCancel: {
            dataTask.cancel()
        }

        let bodyTask = Task<Void, Error> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (bodyCont: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if let state = states[dataTask.taskIdentifier] {
                        state.directBodyContinuation = bodyCont
                        lock.unlock()
                    } else {
                        lock.unlock()
                        bodyCont.resume(returning: ())
                    }
                }
            } onCancel: {
                dataTask.cancel()
            }
        }
        return (http, cancelTask, bodyTask)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let state = states[task.taskIdentifier]
        let originHost = state?.originHost
        let onRedirect = state?.onRedirectResolved
        lock.unlock()

        var sanitized = request
        if let targetURL = sanitized.url {
            let targetHost = targetURL.host?.lowercased()
            if let originHost, let targetHost, targetHost != originHost {
                sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            onRedirect?(targetURL)
        }
        completionHandler(sanitized)
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
        let hdrCont = state.directHeaderContinuation
        state.directHeaderContinuation = nil

        guard let http = response as? HTTPURLResponse else {
            states.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            respCont?.resume(throwing: URLError(.badServerResponse))
            hdrCont?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }

        let cancelTask: @Sendable () -> Void = {
            dataTask.cancel()
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isErrorDocument = TurboStreamingSessionHub.isLikelyNonMediaErrorContentType(contentType)
        let accept = !isErrorDocument && ((http.statusCode == 206) || (http.statusCode == 200 && state.allowStatus200))

        if hdrCont != nil {
            if !accept {
                states.removeValue(forKey: dataTask.taskIdentifier)
            }
            lock.unlock()
            hdrCont?.resume(returning: (http, cancelTask))
            completionHandler(accept ? .allow : .cancel)
            return
        }

        var capturedCont: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { cont in
            capturedCont = cont
        }
        capturedCont.onTermination = { _ in
            dataTask.cancel()
        }

        if accept {
            state.dataContinuation = capturedCont
            lock.unlock()
            respCont?.resume(returning: (http, stream, cancelTask))
            completionHandler(.allow)
        } else {
            states.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            capturedCont.finish()
            respCont?.resume(returning: (http, stream, cancelTask))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let state = states[dataTask.taskIdentifier]
        let cont = state?.dataContinuation
        let directHandler = state?.directBytesHandler
        lock.unlock()
        if let directHandler {
            let keepGoing = data.withUnsafeBytes { directHandler($0) }
            if !keepGoing { dataTask.cancel() }
        } else {
            cont?.yield(data)
        }
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
        let hdrCont = state.directHeaderContinuation
        state.directHeaderContinuation = nil
        let bodyCont = state.directBodyContinuation
        state.directBodyContinuation = nil
        state.directBytesHandler = nil
        let alreadyYielded = state.yieldedResponse
        state.yieldedResponse = true
        lock.unlock()

        if !alreadyYielded {
            let err = error ?? URLError(.unknown)
            respCont?.resume(throwing: err)
            hdrCont?.resume(throwing: err)
        } else if let error {
            dataCont?.finish(throwing: error)
            bodyCont?.resume(throwing: error)
        } else {
            dataCont?.finish()
            bodyCont?.resume(returning: ())
        }
    }
}

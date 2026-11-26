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
        self.activeVideoDeliveryLimit = max(0, activeVideoDeliveryLimit)
        self.planName = planName
        self.displayUnlimitedTraffic = displayUnlimitedTraffic
        self.trafficLimitBytes = trafficLimitBytes
        self.checkedAt = checkedAt
    }
}

// MARK: - Multi-Connection Streaming Turbo Session Hub

internal final class StreamingChunkContext {
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

/// Shared HTTP/2 connection pool accessor for optional service extension modules.
public enum DonbyNetworkSession {
    public static var sharedURLSession: URLSession {
        TurboStreamingSessionHub.shared.sharedURLSession
    }
}

internal final class TurboStreamingSessionHub: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = TurboStreamingSessionHub()

    private let lock = NSLock()
    private var contexts: [ObjectIdentifier: StreamingChunkContext] = [:]
    private var hostProtocolMultiplexed: [String: Bool] = [:]
    private let delegateQueue: OperationQueue
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 90
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
    func startTask(request: URLRequest, context: StreamingChunkContext, priority: Float = 0.35) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.priority = context.isUrgent ? 1.0 : priority
        context.dataTask = task
        lock.lock()
        contexts[ObjectIdentifier(task)] = context
        lock.unlock()
        task.resume()
        return task
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let ctx = contexts[ObjectIdentifier(task)]
        let isCanceled = ctx?.cancelledIntentionally ?? false
        let owner = ctx?.owner
        let originURL = ctx?.requestOriginURL
        let chunkIdx = ctx?.chunkIndex ?? -1
        lock.unlock()

        if isCanceled {
            completionHandler(nil)
            return
        }
        if let finalURL = request.url, let owner, let originURL {
            owner.handleEarlyRedirectResolved(chunkIndex: chunkIdx, finalURL: finalURL, originURL: originURL)
        }
        completionHandler(request)
    }

    func cancelTask(_ task: URLSessionDataTask, intentional: Bool) {
        lock.lock()
        if let ctx = contexts[ObjectIdentifier(task)], intentional {
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
        guard let ctx = contexts[ObjectIdentifier(dataTask)] else {
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
        let attemptId = ctx.attemptId
        let chunkIdx = ctx.chunkIndex
        let originURL = ctx.requestOriginURL
        lock.unlock()

        if !valid {
            completionHandler(.cancel)
            return
        }

        owner?.handleChunkResponseHeaders(
            attemptId: attemptId,
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
        guard let ctx = contexts[ObjectIdentifier(dataTask)],
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
        guard let ctx = contexts.removeValue(forKey: ObjectIdentifier(task)) else {
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

    func isHostKnownMultiplexed(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return false }
        lock.lock()
        let known = hostProtocolMultiplexed[host] ?? false
        lock.unlock()
        return known
    }

    static func makeRangeRequest(
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let tx = metrics.transactionMetrics.last,
              let proto = tx.networkProtocolName?.lowercased(), !proto.isEmpty else { return }
        let isMultiplexed = proto.hasPrefix("h2") || proto.hasPrefix("h3")
        let finalHost = tx.request.url?.host?.lowercased()
        let origHost = task.originalRequest?.url?.host?.lowercased()
        lock.lock()
        if let finalHost, !finalHost.isEmpty {
            hostProtocolMultiplexed[finalHost] = isMultiplexed
        }
        if let origHost, !origHost.isEmpty {
            hostProtocolMultiplexed[origHost] = isMultiplexed
        }
        let owner = contexts[ObjectIdentifier(task)]?.owner
        lock.unlock()
        owner?.markProtocolMultiplexed(isMultiplexed)
    }
}

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
        return (Double(totalWindowBytes) / (1024.0 * 1024.0)) / span
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

    func markHeadersReceived(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); headersUptime = now; lastByteUptime = now; lock.unlock()
    }

    func recordBytes(_ count: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard count > 0 else { return }
        lock.lock(); receivedBytes += Int64(count); lastByteUptime = now; lock.unlock()
    }

    func markStallCancelled() {
        lock.lock(); didTriggerStallCancel = true; lock.unlock()
    }

    var wasStallCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return didTriggerStallCancel
    }

    func snapshot() -> (headersUptime: TimeInterval, lastByteUptime: TimeInterval, receivedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }; return (headersUptime, lastByteUptime, receivedBytes)
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
        var responseContinuation: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void), Error>?
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
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void) {
        let dataTask = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (respCont: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void), Error>) in
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
        let cancelTask: @Sendable () -> Void = {
            dataTask.cancel()
        }
        capturedCont.onTermination = { _ in
            dataTask.cancel()
        }

        let accept = (http.statusCode == 206) || (http.statusCode == 200 && state.allowStatus200)
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

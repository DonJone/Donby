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
    var laneIndex: Int = 0
    var laneGeneration: UInt64 = 0
    var statusCode: Int = 200
    var acceptBody: Bool = false
    var bytesReceived: Int = 0
    var parsedTotalSize: Int64?
    var cancelledIntentionally: Bool = false
    var rejectedByStatus: Bool = false
    var reached200Cap: Bool = false
    var dispatchUptime: TimeInterval = 0
    var responseHeaderUptime: TimeInterval = 0

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

/// Shared HTTP/2 API connection pool accessor for Emby/UHD metadata & control requests,
/// physically isolated from bulk video streaming lanes so media transfers never HoL-block API calls.
public enum DonbyNetworkSession {
    public static var sharedURLSession: URLSession {
        TurboStreamingSessionHub.shared.apiURLSession
    }

    public static func prewarmEdgeOrigin(_ url: URL, headers: [String: String] = [:], laneCount: Int = 4) {
        TurboStreamingSessionHub.shared.prewarmEdgeOrigin(url, headers: headers, laneCount: laneCount)
    }
}

internal final class TurboStreamingSessionHub: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = TurboStreamingSessionHub()
    static let streamLaneCount = 4
    static let maxStreamLaneCount = 8

    struct StreamLaneTelemetry {
        var ewmaTTFB: TimeInterval = 0.65
        var ewmaThroughputBps: Double = 0
        var consecutiveSlowTransfers: Int = 0
        var lastHealthyUptime: TimeInterval = 0
        var warmHosts: Set<String> = []
    }

    struct StreamLane {
        var session: URLSession
        var activeTasks: Int = 0
        var consecutiveStalls: Int = 0
        var lastStallUptime: TimeInterval = 0
        var generation: UInt64 = 1
        var telemetry = StreamLaneTelemetry()
        var pendingRecycleWhenIdle: Bool = false
    }

    let lock = NSLock()
    var contexts: [ObjectIdentifier: StreamingChunkContext] = [:]
    var hostProtocolMultiplexed: [String: Bool] = [:]
    var lanes: [StreamLane] = []
    var roundRobinCursor: Int = 0
    var lastOriginPrewarmUptime: [String: TimeInterval] = [:]

    /// Dedicated API session isolated from bulk streaming lanes.
    let apiURLSession: URLSession

    var sharedURLSession: URLSession { apiURLSession }

    override private init() {
        let apiCfg = URLSessionConfiguration.default
        apiCfg.urlCache = nil
        apiCfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        apiCfg.httpMaximumConnectionsPerHost = 8
        apiCfg.timeoutIntervalForRequest = 15
        apiCfg.timeoutIntervalForResource = 60
        self.apiURLSession = URLSession(configuration: apiCfg)
        super.init()
        var initialLanes: [StreamLane] = []
        initialLanes.reserveCapacity(Self.maxStreamLaneCount)
        for idx in 0..<Self.maxStreamLaneCount {
            initialLanes.append(StreamLane(session: makeStreamLaneSession(index: idx), generation: 1))
        }
        self.lanes = initialLanes
    }

    func makeStreamLaneSession(index: Int) -> URLSession {
        // Ephemeral configuration per lane grants each lane an independent TCP/TLS connection pool
        // even over HTTP/2 edges, eliminating single-TCP CWND collapse & HoL starvation.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 90
        let q = OperationQueue()
        q.name = "com.donby.turbo.streaming.lane.\(index)"
        // Strictly serial delegateQueue preserves per-task didReceive byte ordering.
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    /// Returns a warm streaming lane session for detail preloading so TCP/TLS sockets warmed
    /// on the detail screen are reused immediately when playback starts.
    func warmStreamSession(forLane index: Int) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        let safeIdx = ((index % lanes.count) + lanes.count) % lanes.count
        return lanes[safeIdx].session
    }

    func laneGeneration(for index: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard lanes.indices.contains(index) else { return 0 }
        return lanes[index].generation
    }

    func laneSessionIdentifier(for index: Int) -> ObjectIdentifier? {
        lock.lock()
        defer { lock.unlock() }
        guard lanes.indices.contains(index) else { return nil }
        return ObjectIdentifier(lanes[index].session)
    }

    func selectLaneLocked(
        forHost host: String?,
        isUrgent: Bool,
        excludeLane: Int?,
        activeLaneCap: Int = TurboStreamingSessionHub.streamLaneCount,
        now: TimeInterval
    ) -> Int {
        var bestIdx = 0
        var bestScore = Double.greatestFiniteMagnitude
        let count = min(lanes.count, max(1, activeLaneCap))
        let normHost = host?.lowercased()
        for offset in 0..<count {
            let idx = (roundRobinCursor + offset) % count
            if let excludeLane, count > 1, idx == excludeLane {
                continue
            }
            let lane = lanes[idx]
            let stallPenalty: Double = (lane.consecutiveStalls > 0 && (now - lane.lastStallUptime) < 12.0)
                ? Double(lane.consecutiveStalls) * 250.0
                : 0.0
            let recyclePenalty: Double = lane.pendingRecycleWhenIdle ? 180.0 : 0.0
            var score = Double(lane.activeTasks) * 100.0 + stallPenalty + recyclePenalty
            if isUrgent {
                if let normHost, lane.telemetry.warmHosts.contains(normHost) {
                    score -= 18.0
                }
                score += min(25.0, lane.telemetry.ewmaTTFB * 12.0)
                if lane.telemetry.ewmaThroughputBps > 0 {
                    score -= min(15.0, (lane.telemetry.ewmaThroughputBps / 1_048_576.0) * 1.8)
                }
            }
            if score < bestScore {
                bestScore = score
                bestIdx = idx
            }
        }
        roundRobinCursor = (bestIdx + 1) % count
        return bestIdx
    }

    /// Reports a stall/rescue on a streaming lane; recycles only that lane after repeated stalls
    /// so degraded TCP connections are replaced without disturbing healthy warm lanes.
    func reportLaneStall(laneIndex: Int) {
        var staleSessionToFinish: URLSession? = nil
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if lanes.indices.contains(laneIndex) {
            lanes[laneIndex].consecutiveStalls += 1
            lanes[laneIndex].lastStallUptime = now
            if lanes[laneIndex].consecutiveStalls >= 2 {
                staleSessionToFinish = recycleLaneLocked(index: laneIndex)
            }
        }
        lock.unlock()
        staleSessionToFinish?.finishTasksAndInvalidate()
    }

    func reportLaneHealthy(laneIndex: Int) {
        lock.lock()
        if lanes.indices.contains(laneIndex) {
            lanes[laneIndex].consecutiveStalls = 0
            lanes[laneIndex].telemetry.lastHealthyUptime = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
    }

    @discardableResult
    func startTask(
        request: URLRequest,
        context: StreamingChunkContext,
        priority: Float = 0.35,
        excludeLane: Int? = nil,
        activeLaneCap: Int = TurboStreamingSessionHub.streamLaneCount
    ) -> (task: URLSessionDataTask, laneIndex: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let targetHost = request.url?.host?.lowercased()
        let urgentSelect = context.isUrgent || context.isRescue || context.isDirectRange || context.chunkIndex == 0
        lock.lock()
        let chosenIdx = selectLaneLocked(
            forHost: targetHost,
            isUrgent: urgentSelect,
            excludeLane: excludeLane,
            activeLaneCap: activeLaneCap,
            now: now
        )
        let session = lanes[chosenIdx].session
        let generation = lanes[chosenIdx].generation
        lanes[chosenIdx].activeTasks += 1
        let task = session.dataTask(with: request)
        task.priority = context.isUrgent ? 1.0 : priority
        context.dataTask = task
        context.laneIndex = chosenIdx
        context.laneGeneration = generation
        context.dispatchUptime = now
        contexts[ObjectIdentifier(task)] = context
        lock.unlock()
        task.resume()
        return (task, chosenIdx)
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
        let originURL = ctx?.requestOriginURL ?? task.originalRequest?.url
        let chunkIdx = ctx?.chunkIndex ?? -1
        lock.unlock()

        if isCanceled {
            completionHandler(nil)
            return
        }
        var sanitizedRequest = request
        if let finalURL = sanitizedRequest.url {
            if let origHost = originURL?.host?.lowercased(),
               let nextHost = finalURL.host?.lowercased(),
               origHost != nextHost {
                sanitizedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            if let owner, let originURL {
                owner.handleEarlyRedirectResolved(chunkIndex: chunkIdx, finalURL: finalURL, originURL: originURL)
            }
        }
        completionHandler(sanitizedRequest)
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
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isErrorDocument = Self.isLikelyNonMediaErrorContentType(contentType)
        let valid = !isErrorDocument && ((status == 206) || (status == 200 && (ctx.chunkIndex == 0 || ctx.isDirectRange)))
        ctx.statusCode = status
        ctx.acceptBody = valid
        let parsedTotal = TurboStreamByteHandle.parseTotalSize(from: http, startByte: ctx.startByte, dataCount: 0)
        ctx.parsedTotalSize = parsedTotal
        let headerNow = ProcessInfo.processInfo.systemUptime
        ctx.responseHeaderUptime = headerNow
        if valid {
            recordLaneHeaderArrivalLocked(
                laneIndex: ctx.laneIndex,
                laneGeneration: ctx.laneGeneration,
                host: http?.url?.host ?? ctx.requestOriginURL.host,
                dispatchUptime: ctx.dispatchUptime,
                headerUptime: headerNow
            )
        } else {
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
            appendData.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), !raw.isEmpty else { return }
                owner?.appendChunkPartialBytes(attemptId: attemptId, index: chunkIndex, ptr: ptr, count: raw.count)
            }
        }

        if shouldCancelAfter200Cap {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let now = ProcessInfo.processInfo.systemUptime
        var staleSessionToFinish: URLSession? = nil
        lock.lock()
        guard let ctx = contexts.removeValue(forKey: ObjectIdentifier(task)) else {
            lock.unlock()
            return
        }
        let succeeded = ctx.reached200Cap || (error == nil && ctx.acceptBody && !ctx.rejectedByStatus && !ctx.cancelledIntentionally)
        let wasCancelled = ctx.cancelledIntentionally && !ctx.reached200Cap
        if lanes.indices.contains(ctx.laneIndex), lanes[ctx.laneIndex].generation == ctx.laneGeneration {
            lanes[ctx.laneIndex].activeTasks = max(0, lanes[ctx.laneIndex].activeTasks - 1)
            staleSessionToFinish = recordLaneTransferFinishedLocked(
                laneIndex: ctx.laneIndex,
                bytesReceived: ctx.bytesReceived,
                headerUptime: ctx.responseHeaderUptime,
                now: now,
                succeeded: succeeded,
                wasCancelled: wasCancelled
            )
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
        let laneIndex = ctx.laneIndex
        let status = ctx.rejectedByStatus ? ctx.statusCode : (error == nil ? ctx.statusCode : -1)
        let owner = ctx.owner
        lock.unlock()
        staleSessionToFinish?.finishTasksAndInvalidate()

        if succeeded {
            reportLaneHealthy(laneIndex: laneIndex)
        } else if !wasCancelled && status < 0 {
            reportLaneStall(laneIndex: laneIndex)
        }

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

    internal static func isLikelyNonMediaErrorContentType(_ contentType: String) -> Bool {
        let lower = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return lower.hasPrefix("text/html") || lower.hasPrefix("application/json") || lower.hasPrefix("application/problem+json")
    }

    func isHostKnownMultiplexed(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return false }
        lock.lock()
        if let known = hostProtocolMultiplexed[host] {
            lock.unlock()
            return known
        }
        lock.unlock()
        if let persisted = NetworkRouteWarmStore.shared.isHostKnownMultiplexed(host) {
            lock.lock()
            hostProtocolMultiplexed[host] = persisted
            lock.unlock()
            return persisted
        }
        return false
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
        if let finalHost, !finalHost.isEmpty {
            NetworkRouteWarmStore.shared.recordHostProtocol(host: finalHost, isMultiplexed: isMultiplexed)
        }
        if let origHost, !origHost.isEmpty, origHost != finalHost {
            NetworkRouteWarmStore.shared.recordHostProtocol(host: origHost, isMultiplexed: isMultiplexed)
        }
        owner?.markProtocolMultiplexed(isMultiplexed)
    }
}

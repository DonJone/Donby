import Foundation
import DonbyCore
import DonbyNetwork

private struct UHDPlaybackDomainDTO: Decodable {
    let id: String
    let name: String
    let domain: String?
    let description: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, domain, description
        case sortOrder = "sort_order"
    }
}

private struct UHDResolveDomainDTO: Decodable {
    let domain: String
}

private struct UHDSpeedTestNetworkInfoDTO: Decodable {
    let ip: String?
    let country: String?
    let countryName: String?
    let region: String?
    let regionName: String?
    let province: String?
    let provinceName: String?
    let isp: String?
    let displayLocation: String?

    enum CodingKeys: String, CodingKey {
        case ip, country, region, province, isp
        case countryName = "country_name"
        case regionName = "region_name"
        case provinceName = "province_name"
        case displayLocation = "display_location"
    }
}

private struct UHDSpeedTestSessionDTO: Decodable {
    let sessionId: String
    let reportToken: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case reportToken = "report_token"
    }
}

private actor UHDHostWarmCache {
    static let shared = UHDHostWarmCache()
    private var lastWarmedAt: [String: Date] = [:]

    func shouldWarm(hostKey: String) -> Bool {
        let now = Date()
        if let prev = lastWarmedAt[hostKey], now.timeIntervalSince(prev) < 120 {
            return false
        }
        lastWarmedAt[hostKey] = now
        return true
    }
}

// MARK: - High-Throughput Chunk-Level Speed Test Receiver (Zero Byte-by-Byte Bottleneck)

private final class UHDSpeedTestStreamRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onProgress: @Sendable (UHDSpeedTestProgress) -> Void
    private let lock = NSLock()
    private var engine: UHDSpeedTestMetricsEngine?
    private var contentLength: Int64
    private var continuation: CheckedContinuation<UHDSpeedTestMetricsEngine.Snapshot, Error>?
    private var finished = false
    private var lastProgressEmitTime: Double = 0
    private weak var activeTask: URLSessionDataTask?
    private var ownSession: URLSession?

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (UHDSpeedTestProgress) -> Void) {
        self.expectedBytes = expectedBytes
        self.contentLength = expectedBytes
        self.onProgress = onProgress
        super.init()
    }

    func run(request: URLRequest) async throws -> UHDSpeedTestMetricsEngine.Snapshot {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        let queue = OperationQueue()
        queue.name = "com.donby.uhd.speedtest"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        self.ownSession = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if finished {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                let task = session.dataTask(with: request)
                self.activeTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        let cont = continuation
        let wasFinished = finished
        finished = true
        continuation = nil
        lock.unlock()
        task?.cancel()
        ownSession?.invalidateAndCancel()
        ownSession = nil
        if !wasFinished {
            cont?.resume(throwing: CancellationError())
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let err: Error = (http.statusCode == 401)
                ? EmbyClientError.unauthorized
                : EmbyClientError.httpStatus(http.statusCode, "测速下载被拒绝 (HTTP \(http.statusCode))")
            complete(with: .failure(err))
            completionHandler(.cancel)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if response.expectedContentLength > 0 {
            contentLength = response.expectedContentLength
        }
        engine = UHDSpeedTestMetricsEngine(startTimeSec: now)
        lastProgressEmitTime = now
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        var emitPayload: UHDSpeedTestProgress?

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if engine == nil {
            engine = UHDSpeedTestMetricsEngine(startTimeSec: now)
        }
        let sampled = engine!.ingest(chunkBytes: Int64(data.count), at: now)
        if sampled || (now - lastProgressEmitTime) >= 0.12 {
            lastProgressEmitTime = now
            let snap = engine!.currentSnapshot(at: now)
            let denom = Double(max(1, contentLength))
            emitPayload = UHDSpeedTestProgress(
                fraction: min(1.0, Double(snap.totalBytes) / denom),
                currentMbps: snap.currentMbps,
                averageMbps: snap.averageMbps,
                peakMbps: snap.peakMbps,
                downloadedBytes: snap.totalBytes,
                totalBytes: contentLength,
                recentSamplesMbps: Array(snap.samplesMbps.suffix(48))
            )
        }
        lock.unlock()

        if let emitPayload {
            onProgress(emitPayload)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                complete(with: .failure(CancellationError()))
            } else {
                complete(with: .failure(error))
            }
            return
        }

        lock.lock()
        var eng = engine ?? UHDSpeedTestMetricsEngine(startTimeSec: now)
        let finalSnap = eng.finalize(at: now)
        let total = max(contentLength, finalSnap.totalBytes)
        lock.unlock()

        onProgress(UHDSpeedTestProgress(
            fraction: 1.0,
            currentMbps: finalSnap.currentMbps,
            averageMbps: finalSnap.averageMbps,
            peakMbps: finalSnap.peakMbps,
            downloadedBytes: finalSnap.totalBytes,
            totalBytes: total,
            recentSamplesMbps: Array(finalSnap.samplesMbps.suffix(48))
        ))
        complete(with: .success(finalSnap))
    }

    private func complete(with result: Result<UHDSpeedTestMetricsEngine.Snapshot, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let sessionToClose = ownSession
        ownSession = nil
        lock.unlock()

        sessionToClose?.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }
}

extension UHDStreamClient {
    // MARK: - Playback Domains & Speed Test (Official Spec Compliant)

    public func fetchPlaybackDomains(server: EmbyServerConfig) async throws -> [ServerLineInfo] {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/playback/domains",
            token: server.accessToken
        )
        let domains = try await performRequest([UHDPlaybackDomainDTO].self, request: req, priority: .normal)
        let sorted = domains.sorted { $0.sortOrder < $1.sortOrder }
        let existingByDomainId = Dictionary(
            server.backupLines.compactMap { line -> (String, ServerLineInfo)? in
                guard let did = line.domainId, !did.isEmpty else { return nil }
                return (did, line)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return sorted.map { dom in
            let prev = existingByDomainId[dom.id]
            let baseURL = (dom.domain?.isEmpty == false) ? dom.domain! : (prev?.url ?? server.mainLineURL)
            let displayName = UHDDisplayNormalizer.formatCDNLineName(
                rawName: dom.name,
                description: dom.description,
                url: baseURL
            )
            return ServerLineInfo(
                id: prev?.id ?? UUID(),
                name: displayName,
                url: baseURL,
                domainId: dom.id,
                isAutoSynced: true,
                latencyMs: nil,
                lastCheckedAt: prev?.lastCheckedAt,
                lastSpeedMbps: prev?.lastSpeedMbps,
                lastPeakMbps: prev?.lastPeakMbps,
                lastExitLocation: nil,
                lastExitISP: nil
            )
        }
    }

    public func resolvePlaybackDomain(server: EmbyServerConfig, domainId: String, cacheTTL: TimeInterval = 300) async throws -> URL {
        let req = try makeRequest(
            baseURL: server.mainLineURL,
            path: "/api/v1/stream/playback/domains/\(domainId)/resolve",
            token: server.accessToken,
            timeout: 10
        )
        let dto = try await performRequest(UHDResolveDomainDTO.self, request: req, priority: .playback)
        let clean = ServerLineInfo.normalizeBaseURL(dto.domain)
        guard let url = URL(string: clean) else {
            throw EmbyClientError.invalidServerURL(dto.domain)
        }
        if cacheTTL > 0 {
            await UHDResolvedDomainCache.shared.set(url, serverId: server.id, domainId: domainId, ttlSeconds: cacheTTL)
        }
        return url
    }

    public func resolveActivePlaybackOrigin(server: EmbyServerConfig, forceFresh: Bool = false) async throws -> URL {
        let domainId: String? = {
            if let selectedId = server.selectedLineId,
               let line = server.backupLines.first(where: { $0.id == selectedId }),
               let id = line.domainId, !id.isEmpty {
                return id
            }
            return server.backupLines.first(where: { $0.domainId?.isEmpty == false })?.domainId
        }()
        if let domainId {
            if !forceFresh, let cached = await UHDResolvedDomainCache.shared.get(serverId: server.id, domainId: domainId) {
                return cached
            }
            return try await resolvePlaybackDomain(server: server, domainId: domainId)
        }
        let fetched = try await fetchPlaybackDomains(server: server)
        guard let firstId = fetched.first?.domainId, !firstId.isEmpty else {
            guard let fallback = URL(string: server.mainLineURL) else {
                throw EmbyClientError.invalidServerURL(server.mainLineURL)
            }
            return fallback
        }
        return try await resolvePlaybackDomain(server: server, domainId: firstId)
    }

    public func invalidateResolvedDomainCache(serverId: UUID) async {
        await UHDResolvedDomainCache.shared.invalidate(serverId: serverId)
        await UHDAssetResponseCache.shared.invalidate(serverId: serverId)
    }

    public func prewarmPlaybackDomain(server: EmbyServerConfig) async {
        guard server.type == .uhdNative, !server.mainLineURL.isEmpty, !server.accessToken.isEmpty else { return }
        if let resolvedURL = try? await resolveActivePlaybackOrigin(server: server, forceFresh: false),
           let host = resolvedURL.host,
           await UHDHostWarmCache.shared.shouldWarm(hostKey: host) {
            var headReq = URLRequest(url: resolvedURL, timeoutInterval: 3.0)
            headReq.httpMethod = "HEAD"
            headReq.cachePolicy = .reloadIgnoringLocalCacheData
            headReq.setValue("Donby/\(appVersion) (macOS; UHDNow Client)", forHTTPHeaderField: "User-Agent")
            _ = try? await apiSession.data(for: headReq)
        }
    }

    public func pingLine(server: EmbyServerConfig, line: ServerLineInfo?) async -> Int? {
        let domainId = line?.domainId ?? server.backupLines.first?.domainId
        let start = CFAbsoluteTimeGetCurrent()
        do {
            if let domainId, !domainId.isEmpty {
                let resolved = try await resolvePlaybackDomain(server: server, domainId: domainId)
                let probeStart = CFAbsoluteTimeGetCurrent()
                let netReq = try makeRequest(
                    baseURL: resolved.absoluteString,
                    path: "/api/v1/stream/speed-test/network-info",
                    token: server.accessToken,
                    timeout: 6
                )
                let (_, resp) = try await apiSession.data(for: netReq)
                if let http = resp as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                    return max(1, Int((CFAbsoluteTimeGetCurrent() - probeStart) * 1000))
                }
                return max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            } else {
                let req = try makeRequest(
                    baseURL: server.mainLineURL,
                    path: "/api/v1/stream/playback/domains",
                    token: server.accessToken,
                    timeout: 6
                )
                _ = try await apiSession.data(for: req)
                return max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            }
        } catch {
            return nil
        }
    }

    /// Resolves a fresh `TEST_BASE` for `domainId` and probes `TEST_BASE/api/v1/stream/speed-test/network-info`
    /// without consuming download traffic quota. Useful for verifying DIRECT vs PROXY exit routing.
    public func probeLineExitNetworkInfo(
        server: EmbyServerConfig,
        domainId: String
    ) async throws -> (resolvedBase: URL, networkInfo: UHDSpeedTestNetworkInfo, latencyMs: Int) {
        let resolvedBase = try await resolvePlaybackDomain(server: server, domainId: domainId, cacheTTL: 0)
        let probeStart = CFAbsoluteTimeGetCurrent()
        let netReq = try makeRequest(
            baseURL: resolvedBase.absoluteString,
            path: "/api/v1/stream/speed-test/network-info",
            token: server.accessToken,
            timeout: 10
        )
        let dto = try await performRequest(UHDSpeedTestNetworkInfoDTO.self, request: netReq, priority: .normal)
        let ms = max(1, Int((CFAbsoluteTimeGetCurrent() - probeStart) * 1000))
        let info = UHDSpeedTestNetworkInfo(
            ip: dto.ip ?? "",
            country: dto.country ?? "",
            countryName: dto.countryName ?? "",
            region: dto.region ?? "",
            regionName: dto.regionName ?? "",
            province: dto.province ?? "",
            provinceName: dto.provinceName ?? "",
            isp: dto.isp ?? "",
            displayLocation: dto.displayLocation ?? "未知"
        )
        return (resolvedBase, info, ms)
    }

    /// Spec-compliant UHD Speed Test:
    /// 1. Resolve fresh `TEST_BASE` via `API_BASE/api/v1/stream/playback/domains/{domain_id}/resolve`.
    /// 2. `GET TEST_BASE/api/v1/stream/speed-test/network-info`
    /// 3. `POST TEST_BASE/api/v1/stream/speed-test/session`
    /// 4. `GET TEST_BASE/api/v1/stream/speed-test/download?session_id=...&size_mb=...` (chunk-level delegate stream, warmup exclusion, 300ms rolling peak)
    /// 5. `POST API_BASE/api/v1/stream/speed-test/report` (submitted ONCE only on clean completion, never retried, never sent on cancel/error).
    public func runSpeedTest(
        server: EmbyServerConfig,
        domainId: String,
        sizeMiB: Int = 32,
        onNetworkInfo: (@Sendable (URL, UHDSpeedTestNetworkInfo) -> Void)? = nil,
        onProgress: @escaping @Sendable (UHDSpeedTestProgress) -> Void
    ) async throws -> UHDSpeedTestResult {
        let clampedMiB = [32, 64, 100].contains(sizeMiB) ? sizeMiB : 32
        let apiBase = server.mainLineURL

        // Step 1: Freshly resolve TEST_BASE for this round
        let testBaseURL = try await resolvePlaybackDomain(server: server, domainId: domainId, cacheTTL: 0)
        let testBase = testBaseURL.absoluteString
        try Task.checkCancellation()

        // Step 2: Query exit network info on TEST_BASE
        let netInfoReq = try makeRequest(
            baseURL: testBase,
            path: "/api/v1/stream/speed-test/network-info",
            token: server.accessToken,
            timeout: 12
        )
        let netInfoDTO = try await performRequest(UHDSpeedTestNetworkInfoDTO.self, request: netInfoReq, priority: .normal)
        let netInfo = UHDSpeedTestNetworkInfo(
            ip: netInfoDTO.ip ?? "",
            country: netInfoDTO.country ?? "",
            countryName: netInfoDTO.countryName ?? "",
            region: netInfoDTO.region ?? "",
            regionName: netInfoDTO.regionName ?? "",
            province: netInfoDTO.province ?? "",
            provinceName: netInfoDTO.provinceName ?? "",
            isp: netInfoDTO.isp ?? "",
            displayLocation: netInfoDTO.displayLocation ?? "未知"
        )
        onNetworkInfo?(testBaseURL, netInfo)
        try Task.checkCancellation()

        // Step 3: Create speed-test session on TEST_BASE
        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "parent_domain_id": domainId,
            "size_mib": clampedMiB
        ])
        let sessionReq = try makeRequest(
            baseURL: testBase,
            path: "/api/v1/stream/speed-test/session",
            method: "POST",
            token: server.accessToken,
            bodyData: sessionBody,
            timeout: 15
        )
        let session = try await performRequest(UHDSpeedTestSessionDTO.self, request: sessionReq, priority: .normal)
        try Task.checkCancellation()

        // Step 4: Stream binary payload from TEST_BASE with chunk-level delegate (no compression, no cache)
        var dlReq = try makeRequest(
            baseURL: testBase,
            path: "/api/v1/stream/speed-test/download",
            queryItems: [
                URLQueryItem(name: "session_id", value: session.sessionId),
                URLQueryItem(name: "size_mb", value: "\(clampedMiB)")
            ],
            token: server.accessToken,
            timeout: 180,
            extraHeaders: [
                "Accept": "application/octet-stream",
                "Accept-Encoding": "identity",
                "Cache-Control": "no-cache"
            ]
        )
        dlReq.cachePolicy = .reloadIgnoringLocalCacheData

        let expectedBytes = Int64(clampedMiB) * 1_048_576
        let runner = UHDSpeedTestStreamRunner(expectedBytes: expectedBytes, onProgress: onProgress)
        let snapshot = try await runner.run(request: dlReq)

        // Step 5: Submit single report to API_BASE (never retry; keep local metrics if report fails)
        var reportSubmitted = false
        let reportPayload: [String: Any] = [
            "session_id": session.sessionId,
            "report_token": session.reportToken,
            "average_mbps": snapshot.averageMbps,
            "peak_mbps": snapshot.peakMbps,
            "elapsed_ms": snapshot.elapsedMs,
            "sample_count": snapshot.sampleCount,
            "server_downloaded_bytes": snapshot.totalBytes
        ]
        if let reportData = try? JSONSerialization.data(withJSONObject: reportPayload),
           let reportReq = try? makeRequest(
                baseURL: apiBase,
                path: "/api/v1/stream/speed-test/report",
                method: "POST",
                token: server.accessToken,
                bodyData: reportData,
                timeout: 12
           ) {
            do {
                try await performAction(request: reportReq, priority: .normal)
                reportSubmitted = true
            } catch {
                reportSubmitted = false
            }
        }

        return UHDSpeedTestResult(
            domainId: domainId,
            resolvedHost: testBaseURL.host ?? testBase,
            networkInfo: netInfo,
            averageMbps: snapshot.averageMbps,
            peakMbps: snapshot.peakMbps,
            elapsedMs: snapshot.elapsedMs,
            sampleCount: snapshot.sampleCount,
            downloadedBytes: snapshot.totalBytes,
            sizeMiB: clampedMiB,
            samplesMbps: snapshot.samplesMbps,
            reportSubmitted: reportSubmitted,
            testedAt: Date()
        )
    }
}

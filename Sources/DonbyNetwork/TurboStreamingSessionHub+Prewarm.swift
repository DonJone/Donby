import Foundation
import DonbyCore

// MARK: - Multi-Lane Telemetry, Zombie-Flow Recycling & Parallel TLS/H2 Edge Prewarming

extension TurboStreamingSessionHub {
    func recycleLaneLocked(index: Int) -> URLSession? {
        guard lanes.indices.contains(index) else { return nil }
        let oldSession = lanes[index].session
        let nextGen = lanes[index].generation &+ 1
        lanes[index] = StreamLane(
            session: makeStreamLaneSession(index: index),
            activeTasks: 0,
            consecutiveStalls: 0,
            lastStallUptime: 0,
            generation: nextGen
        )
        return oldSession
    }

    func recordLaneHeaderArrivalLocked(
        laneIndex: Int,
        laneGeneration: UInt64,
        host: String?,
        dispatchUptime: TimeInterval,
        headerUptime: TimeInterval
    ) {
        guard lanes.indices.contains(laneIndex),
              lanes[laneIndex].generation == laneGeneration else { return }
        if let normHost = host?.lowercased(), !normHost.isEmpty {
            lanes[laneIndex].telemetry.warmHosts.insert(normHost)
        }
        if dispatchUptime > 0 {
            let ttfb = headerUptime - dispatchUptime
            if ttfb >= 0.005 && ttfb < 8.0 {
                let prev = lanes[laneIndex].telemetry.ewmaTTFB
                lanes[laneIndex].telemetry.ewmaTTFB = prev * 0.65 + ttfb * 0.35
            }
        }
        lanes[laneIndex].telemetry.lastHealthyUptime = headerUptime
    }

    func recordLaneTransferFinishedLocked(
        laneIndex: Int,
        bytesReceived: Int,
        headerUptime: TimeInterval,
        now: TimeInterval,
        succeeded: Bool,
        wasCancelled: Bool
    ) -> URLSession? {
        guard lanes.indices.contains(laneIndex) else { return nil }
        if succeeded && headerUptime > 0 && bytesReceived >= 65_536 {
            let elapsed = max(0.015, now - headerUptime)
            let sampleBps = Double(bytesReceived) / elapsed
            let prev = lanes[laneIndex].telemetry.ewmaThroughputBps
            lanes[laneIndex].telemetry.ewmaThroughputBps = prev > 0
                ? (prev * 0.60 + sampleBps * 0.40)
                : sampleBps
            lanes[laneIndex].telemetry.lastHealthyUptime = now

            if bytesReceived >= 262_144 {
                let peerSpeeds = lanes.enumerated()
                    .compactMap { (i, lane) -> Double? in
                        guard i != laneIndex, lane.telemetry.ewmaThroughputBps > 0 else { return nil }
                        return lane.telemetry.ewmaThroughputBps
                    }
                    .sorted()
                if !peerSpeeds.isEmpty {
                    let medianPeer = peerSpeeds[peerSpeeds.count / 2]
                    if sampleBps < 450_000.0 && sampleBps < medianPeer * 0.25 {
                        lanes[laneIndex].telemetry.consecutiveSlowTransfers += 1
                        if lanes[laneIndex].telemetry.consecutiveSlowTransfers >= 2 {
                            lanes[laneIndex].pendingRecycleWhenIdle = true
                        }
                    } else {
                        lanes[laneIndex].telemetry.consecutiveSlowTransfers = 0
                    }
                }
            }
        } else if !wasCancelled && !succeeded {
            lanes[laneIndex].telemetry.consecutiveSlowTransfers = 0
        }

        if lanes[laneIndex].pendingRecycleWhenIdle && lanes[laneIndex].activeTasks == 0 {
            return recycleLaneLocked(index: laneIndex)
        }
        return nil
    }

    /// Returns the highest EWMA throughput (in bytes/sec) observed across healthy lanes.
    func fastestHealthyLaneSpeedBps() -> Double {
        lock.lock()
        defer { lock.unlock() }
        var best: Double = 0
        for lane in lanes where lane.consecutiveStalls == 0 && !lane.pendingRecycleWhenIdle {
            if lane.telemetry.ewmaThroughputBps > best {
                best = lane.telemetry.ewmaThroughputBps
            }
        }
        return best
    }

    /// Returns true when at least one non-excluded lane is verified warm/fast and lightly loaded,
    /// enabling sub-second blocked-reader micro-hedges without causing duplicate storms on cold slow edges.
    func hasVerifiedFastAlternateLane(forHost rawHost: String?, excludingLane: Int?) -> Bool {
        let normHost = rawHost?.lowercased()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        for (idx, lane) in lanes.enumerated() {
            if let excludingLane, lanes.count > 1, idx == excludingLane { continue }
            guard lane.consecutiveStalls == 0, !lane.pendingRecycleWhenIdle, lane.activeTasks <= 1 else { continue }
            let recentlyHealthy = lane.telemetry.lastHealthyUptime > 0 && (now - lane.telemetry.lastHealthyUptime) < 120.0
            let hostWarm = normHost.map { lane.telemetry.warmHosts.contains($0) } ?? false
            let provenFast = lane.telemetry.ewmaThroughputBps >= 1_500_000.0 || (recentlyHealthy && lane.telemetry.ewmaTTFB < 0.45)
            if (hostWarm && recentlyHealthy) || provenFast {
                return true
            }
        }
        return false
    }

    /// Proactively establishes warm TCP + TLS 1.3 + HTTP/2 sockets across `0..<laneCount` streaming lanes
    /// for `url`'s origin (`scheme://host:port`), deduplicated on a 45s window with zero media payload transfer.
    func prewarmEdgeOrigin(
        _ url: URL,
        headers: [String: String] = [:],
        laneCount: Int = TurboStreamingSessionHub.streamLaneCount
    ) {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(),
              !host.isEmpty else { return }
        // Skip synthetic unroutable test port 1
        let resolvedPort = url.port ?? (scheme == "http" ? 80 : 443)
        guard resolvedPort != 1 else { return }

        let originKey = "\(scheme)://\(host):\(resolvedPort)"
        guard let rootURL = URL(string: "\(originKey)/") else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let clampedLanes = max(1, min(Self.streamLaneCount, laneCount))
        var targetSessions: [(index: Int, generation: UInt64, session: URLSession)] = []

        lock.lock()
        if let prev = lastOriginPrewarmUptime[originKey], (now - prev) < 45.0 {
            lock.unlock()
            return
        }
        lastOriginPrewarmUptime[originKey] = now
        for idx in 0..<min(clampedLanes, lanes.count) {
            if lanes[idx].activeTasks == 0 {
                targetSessions.append((idx, lanes[idx].generation, lanes[idx].session))
            }
        }
        lock.unlock()

        guard !targetSessions.isEmpty else { return }

        for entry in targetSessions {
            Task.detached(priority: .utility) { [weak self] in
                var req = URLRequest(url: rootURL, timeoutInterval: 3.5)
                req.httpMethod = "HEAD"
                req.cachePolicy = .reloadIgnoringLocalCacheData
                for (k, v) in headers where k.lowercased() != "range" {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if req.value(forHTTPHeaderField: "User-Agent") == nil {
                    req.setValue("Donby/\(DonbyAppInfo.version) (macOS; UHDNow Client)", forHTTPHeaderField: "User-Agent")
                }
                let t0 = ProcessInfo.processInfo.systemUptime
                guard let (_, resp) = try? await entry.session.data(for: req),
                      let http = resp as? HTTPURLResponse,
                      http.statusCode > 0 else { return }
                let t1 = ProcessInfo.processInfo.systemUptime
                self?.recordPrewarmHeaderArrival(
                    laneIndex: entry.index,
                    laneGeneration: entry.generation,
                    host: http.url?.host ?? host,
                    dispatchUptime: t0,
                    headerUptime: t1
                )
            }
        }
    }

    private func recordPrewarmHeaderArrival(
        laneIndex: Int,
        laneGeneration: UInt64,
        host: String?,
        dispatchUptime: TimeInterval,
        headerUptime: TimeInterval
    ) {
        lock.lock()
        recordLaneHeaderArrivalLocked(
            laneIndex: laneIndex,
            laneGeneration: laneGeneration,
            host: host,
            dispatchUptime: dispatchUptime,
            headerUptime: headerUptime
        )
        lock.unlock()
    }
}

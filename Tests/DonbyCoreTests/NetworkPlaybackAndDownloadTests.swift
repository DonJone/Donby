import Foundation
import Darwin
import Testing
@testable import DonbyCore
@testable import DonbyNetwork

struct NetworkPlaybackAndDownloadTests {
    @Test func turboSessionHubIsolatesAPIFromMultiLanePoolAndSupportsCrossLaneRescue() {
        let hub = TurboStreamingSessionHub.shared
        let apiId = ObjectIdentifier(DonbyNetworkSession.sharedURLSession)
        var laneIds: Set<ObjectIdentifier> = []
        for idx in 0..<TurboStreamingSessionHub.streamLaneCount {
            let sid = hub.laneSessionIdentifier(for: idx)
            #expect(sid != nil)
            if let sid {
                #expect(sid != apiId)
                laneIds.insert(sid)
            }
        }
        #expect(laneIds.count == TurboStreamingSessionHub.streamLaneCount)

        // Verify cross-lane rescue excludes the stalled lane cleanly
        let key = "test_multilane_\(UUID().uuidString)"
        let store = DonbyTurboCacheEngine.shared.store(for: key, persistDisk: false)
        let dummyURL = URL(string: "http://127.0.0.1:1/media.mkv")!
        let handle = TurboStreamByteHandle(
            assetKey: key,
            streamURL: dummyURL,
            headers: [:],
            store: store,
            knownTotalSize: 64 * 1024 * 1024,
            connectionBudget: 4
        )
        defer {
            handle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: key, forceIncludePinned: true)
        }

        let req = TurboStreamingSessionHub.makeRangeRequest(
            url: dummyURL,
            originHost: dummyURL.host,
            headers: [:],
            startByte: 0,
            endByte: 1023,
            timeout: 2
        )
        let ctx1 = StreamingChunkContext(
            attemptId: 9001,
            chunkIndex: 10,
            chunkSize: 1024,
            startByte: 0,
            isUrgent: true,
            isRescue: false,
            requestOriginURL: dummyURL,
            usedRedirectedURL: false,
            owner: handle
        )
        let (task1, lane1) = hub.startTask(request: req, context: ctx1, priority: 1.0)
        let ctx2 = StreamingChunkContext(
            attemptId: 9002,
            chunkIndex: 10,
            chunkSize: 1024,
            startByte: 0,
            isUrgent: true,
            isRescue: true,
            requestOriginURL: dummyURL,
            usedRedirectedURL: false,
            owner: handle
        )
        let (task2, lane2) = hub.startTask(request: req, context: ctx2, priority: 1.0, excludeLane: lane1)
        hub.cancelTask(task1, intentional: true)
        hub.cancelTask(task2, intentional: true)
        #expect(lane2 != lane1)

        // Verify repeated stall on one lane recycles ONLY that lane
        let otherLane = (lane1 + 1) % TurboStreamingSessionHub.streamLaneCount
        let genBefore = hub.laneGeneration(for: lane1)
        let otherGenBefore = hub.laneGeneration(for: otherLane)
        hub.reportLaneHealthy(laneIndex: lane1)
        hub.reportLaneStall(laneIndex: lane1)
        #expect(hub.laneGeneration(for: lane1) == genBefore)
        hub.reportLaneStall(laneIndex: lane1)
        #expect(hub.laneGeneration(for: lane1) == genBefore + 1)
        #expect(hub.laneGeneration(for: otherLane) == otherGenBefore)
    }

    @Test func turboHandleLargeFileTailWindowAndParallelResumeAnchorPrefetch() {
        #expect(TurboStreamByteHandle.tailProbeChunkCount(for: 2 * 1024 * 1024 * 1024) == 2)
        #expect(TurboStreamByteHandle.tailProbeChunkCount(for: 8 * 1024 * 1024 * 1024) == 4)

        let eightGiB: Int64 = 8 * 1024 * 1024 * 1024
        let directURL = URL(string: "http://127.0.0.1:1/cdn/movie_4k_remux.mkv")!

        // Budget 4 with resume at 50%: should trigger Chunk 0 + 2 MiB EOF tail + speculative resume anchor
        let keyFast = "test_resume_anchor_fast_\(UUID().uuidString)"
        let storeFast = DonbyTurboCacheEngine.shared.store(for: keyFast, persistDisk: false)
        let handleFast = TurboStreamByteHandle(
            assetKey: keyFast,
            streamURL: directURL,
            headers: [:],
            store: storeFast,
            knownTotalSize: eightGiB,
            connectionBudget: 4,
            initialStartSeconds: 1800,
            knownDurationSeconds: 3600
        )
        defer {
            handleFast.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: keyFast, forceIncludePinned: true)
        }

        handleFast.condition.lock()
        let triggeredHeadRunway = handleFast.didTriggerOpenHeadRunwayPrefetch
        let triggeredTail = handleFast.didTriggerProbeTailPrefetch
        let triggeredResume = handleFast.didTriggerResumeAnchorPrefetch
        let tailStartExpected = eightGiB - 524_288
        let hasTailInFlight = handleFast.directInFlightStarts[tailStartExpected] != nil
        let hasHeadRunwayInFlight = handleFast.inFlightChunks.contains(2)
        let estChunk = Int((eightGiB / 2) / Int64(storeFast.currentMeta().chunkSize))
        let hasResumeAnchorInFlight = handleFast.inFlightChunks.contains(estChunk - 2)
        handleFast.condition.unlock()

        #expect(triggeredHeadRunway)
        #expect(hasHeadRunwayInFlight)
        #expect(triggeredTail)
        #expect(hasTailInFlight)
        #expect(triggeredResume)
        #expect(hasResumeAnchorInFlight)

        // Budget 1 (single-stream server limit): MUST NOT fire parallel tail or resume anchor during open
        let keySingle = "test_resume_anchor_single_\(UUID().uuidString)"
        let storeSingle = DonbyTurboCacheEngine.shared.store(for: keySingle, persistDisk: false)
        let handleSingle = TurboStreamByteHandle(
            assetKey: keySingle,
            streamURL: directURL,
            headers: [:],
            store: storeSingle,
            knownTotalSize: eightGiB,
            connectionBudget: 1,
            initialStartSeconds: 1800,
            knownDurationSeconds: 3600
        )
        defer {
            handleSingle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: keySingle, forceIncludePinned: true)
        }

        handleSingle.condition.lock()
        let singleTail = handleSingle.didTriggerProbeTailPrefetch
        let singleResume = handleSingle.didTriggerResumeAnchorPrefetch
        handleSingle.condition.unlock()

        #expect(!singleTail)
        #expect(!singleResume)
    }

    @Test func turboHandleRescueWinnerCancelsCrawlingOriginalAttemptAndReleasesTrailingChunks() {
        let key = "test_rescue_cancel_\(UUID().uuidString)"
        let store = DonbyTurboCacheEngine.shared.store(for: key, persistDisk: false)
        let chunkSize = store.currentMeta().chunkSize
        let totalSize = Int64(chunkSize * 20)
        store.setTotalSize(totalSize, sourceURL: "http://127.0.0.1:1/video.mkv")
        let handle = TurboStreamByteHandle(
            assetKey: key,
            streamURL: URL(string: "http://127.0.0.1:1/video.mkv")!,
            headers: [:],
            store: store,
            knownTotalSize: totalSize,
            connectionBudget: 4
        )
        defer {
            handle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: key, forceIncludePinned: true)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let slowPrimaryId: UInt64 = 5001
        let fastRescueId: UInt64 = 5002

        handle.condition.lock()
        handle.activeAttempts[slowPrimaryId] = TurboStreamByteHandle.ActiveAttemptRecord(
            attemptId: slowPrimaryId,
            startChunkIndex: 5,
            currentChunkIndex: 5,
            endChunkExclusive: 9,
            initialByteSkip: 0,
            isUrgent: true,
            isRescue: false,
            laneIndex: 0,
            task: nil,
            lastByteTimestamp: now, // Even if still trickling bytes (not completely idle!)
            chunkStartTimestamp: now - 3.0
        )
        handle.attemptBuffers[slowPrimaryId] = Data(repeating: 0x11, count: 4096)
        for idx in 5..<9 { handle.inFlightChunks.insert(idx) }

        handle.activeAttempts[fastRescueId] = TurboStreamByteHandle.ActiveAttemptRecord(
            attemptId: fastRescueId,
            startChunkIndex: 5,
            currentChunkIndex: 5,
            endChunkExclusive: 7,
            initialByteSkip: 0,
            isUrgent: true,
            isRescue: true,
            laneIndex: 1,
            task: nil,
            lastByteTimestamp: now,
            chunkStartTimestamp: now
        )
        handle.attemptBuffers[fastRescueId] = Data()
        handle.rescueChunks.insert(5)
        handle.condition.unlock()

        // Rescue delivers full chunk 5 first -> must immediately cancel slowPrimaryId and release chunks 7..8!
        handle.appendChunkPartialData(attemptId: fastRescueId, index: 5, delta: Data(repeating: 0xAA, count: chunkSize))

        handle.condition.lock()
        let slowStillActive = handle.activeAttempts[slowPrimaryId] != nil
        let chunk7StillLocked = handle.inFlightChunks.contains(7)
        let chunk8StillLocked = handle.inFlightChunks.contains(8)
        let chunk6StillOwnedByRescue = handle.inFlightChunks.contains(6)
        handle.condition.unlock()

        #expect(store.hasChunk(5))
        #expect(!slowStillActive)
        #expect(!chunk7StillLocked)
        #expect(!chunk8StillLocked)
        #expect(chunk6StillOwnedByRescue)
    }

    @Test @MainActor func downloadManagerDefaultsToSingleTaskAndSupportsNestedPlaybackYield() {
        let mgr = DonbyDownloadManager.shared
        #expect(mgr.maxConcurrentDownloads == 1)
        #expect(!mgr.isYieldingForPlayback)

        let t1 = mgr.beginPlaybackNetworkPriority(activeAssetKey: "asset_a")
        #expect(mgr.isYieldingForPlayback)
        let t2 = mgr.beginPlaybackNetworkPriority(activeAssetKey: "asset_b")
        #expect(mgr.isYieldingForPlayback)

        mgr.endPlaybackNetworkPriority(token: t1)
        #expect(mgr.isYieldingForPlayback)
        mgr.endPlaybackNetworkPriority(token: t2)
        #expect(!mgr.isYieldingForPlayback)
    }

    @Test func downloadRangeDelegateStripsAuthOnCrossHostRedirectAndSignalsEarly() async throws {
        // Minimal single-process loopback server:
        //   GET /origin (on 127.0.0.1) -> 302 Location: http://localhost:<port>/cdn
        //   GET /cdn (on localhost)    -> verifies Authorization was stripped & returns 206 payload
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(listenFD >= 0)
        defer { Darwin.close(listenFD) }

        var opt: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindRes == 0)
        #expect(Darwin.listen(listenFD, 8) == 0)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listenFD, $0, &addrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })

        final class AuthCapture: @unchecked Sendable {
            private let lock = NSLock()
            var cdnSawAuth = false
            var earlyRedirectURL: URL? = nil
            func setCDNSawAuth(_ v: Bool) { lock.lock(); cdnSawAuth = v; lock.unlock() }
            func setEarlyRedirect(_ u: URL) { lock.lock(); earlyRedirectURL = u; lock.unlock() }
            func snapshot() -> (Bool, URL?) { lock.lock(); defer { lock.unlock() }; return (cdnSawAuth, earlyRedirectURL) }
        }
        let capture = AuthCapture()

        let serverTask = Task.detached {
            for _ in 0..<2 {
                let clientFD = Darwin.accept(listenFD, nil, nil)
                if clientFD < 0 { break }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.recv(clientFD, &buf, buf.count, 0)
                let reqStr = n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : ""
                let responseData: Data
                if reqStr.contains("GET /origin ") {
                    let hdr = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(port)/cdn\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    responseData = Data(hdr.utf8)
                } else {
                    if reqStr.lowercased().contains("authorization:") {
                        capture.setCDNSawAuth(true)
                    }
                    let hdr = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nContent-Range: bytes 0-\(payload.count - 1)/\(payload.count)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    var combined = Data(hdr.utf8)
                    combined.append(payload)
                    responseData = combined
                }
                responseData.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        var sent = 0
                        while sent < responseData.count {
                            let w = Darwin.send(clientFD, base.advanced(by: sent), responseData.count - sent, 0)
                            if w <= 0 { break }
                            sent += w
                        }
                    }
                }
                Darwin.close(clientFD)
            }
        }
        defer { serverTask.cancel() }

        let delegate = DownloadRangeStreamDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        let opQ = OperationQueue()
        opQ.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: opQ)
        defer { session.invalidateAndCancel() }

        let req = TurboStreamingSessionHub.makeRangeRequest(
            url: URL(string: "http://127.0.0.1:\(port)/origin")!,
            originHost: "127.0.0.1",
            headers: ["Authorization": "Bearer secret-token"],
            startByte: 0,
            endByte: Int64(payload.count - 1),
            timeout: 5
        )
        let (http, stream, _) = try await delegate.openStream(
            session: session,
            request: req,
            allowStatus200: false,
            onRedirectResolved: { url in
                capture.setEarlyRedirect(url)
            }
        )
        var received = Data()
        for try await chunk in stream {
            received.append(chunk)
        }

        let snap = capture.snapshot()
        #expect(http.statusCode == 206)
        #expect(received == payload)
        #expect(snap.1?.path == "/cdn")
        #expect(!snap.0)
    }
}

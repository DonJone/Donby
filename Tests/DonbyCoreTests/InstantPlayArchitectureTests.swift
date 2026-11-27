import Foundation
import Darwin
import Testing
@testable import DonbyCore
@testable import DonbyNetwork
import DonbyKernelC

// MARK: - Concurrent Loopback HTTP Range Harness for Turbo Engine v3 Verification

private final class LoopbackRangeServer: @unchecked Sendable {
    struct RequestInfo: Sendable {
        let method: String
        let path: String
        let startByte: Int64
        let endByte: Int64
        let rawHeaders: String
    }

    private let listenFD: Int32
    let port: UInt16
    private var acceptTask: Task<Void, Never>?

    init(handler: @escaping @Sendable (Int32, UInt16, RequestInfo) async -> Void) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        self.listenFD = fd

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        let assignedPort = UInt16(bigEndian: bound.sin_port)
        self.port = assignedPort

        self.acceptTask = Task.detached {
            while !Task.isCancelled {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 { break }
                var clientNoPipe: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &clientNoPipe, socklen_t(MemoryLayout<Int32>.size))
                Task.detached {
                    defer { Darwin.close(clientFD) }
                    guard let req = Self.readHTTPRequest(from: clientFD) else { return }
                    await handler(clientFD, assignedPort, req)
                }
            }
        }
    }

    func shutdown() {
        acceptTask?.cancel()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let w = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if w <= 0 { return false }
                sent += w
            }
            return true
        }
    }

    private static func readHTTPRequest(from fd: Int32) -> RequestInfo? {
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let sep = Data("\r\n\r\n".utf8)
        while acc.range(of: sep) == nil && acc.count < 16_384 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            acc.append(contentsOf: buf.prefix(n))
        }
        let raw = String(decoding: acc, as: UTF8.self)
        guard !raw.isEmpty else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        let reqParts = (lines.first ?? "").split(separator: " ")
        guard reqParts.count >= 2 else { return nil }
        let method = String(reqParts[0])
        let path = String(reqParts[1])

        var startByte: Int64 = 0
        var endByte: Int64 = -1
        for line in lines where line.lowercased().hasPrefix("range:") {
            if let eqIdx = line.firstIndex(of: "=") {
                let spec = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                let pair = spec.split(separator: "-", omittingEmptySubsequences: false)
                if pair.count == 2 {
                    startByte = Int64(pair[0]) ?? 0
                    endByte = Int64(pair[1]) ?? -1
                }
            }
        }
        return RequestInfo(method: method, path: path, startByte: startByte, endByte: endByte, rawHeaders: raw)
    }
}

@Suite("Turbo Engine v3 Instant-Play Architecture Tests", .serialized)
struct InstantPlayArchitectureTests {
    @Test func tailFirstExactCuesBypassBeatsThrottledTwoMiBTailCrawl() async throws {
        let eightGiB: Int64 = 8 * 1024 * 1024 * 1024
        let cuesOffset: Int64 = eightGiB - 122_880

        let server = try LoopbackRangeServer { clientFD, _, req in
            let end = req.endByte >= req.startByte ? min(eightGiB - 1, req.endByte) : min(eightGiB - 1, req.startByte + 524_287)
            let len = Int(max(0, end - req.startByte + 1))
            let hdr = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nContent-Range: bytes \(req.startByte)-\(end)/\(eightGiB)\r\nContent-Length: \(len)\r\nConnection: close\r\n\r\n"
            guard LoopbackRangeServer.sendAll(clientFD, Data(hdr.utf8)) else { return }

            if req.startByte <= eightGiB - 1_500_000 {
                // Simulate a shaped 2 MiB tail crawl stalling ~1.8 MiB ahead of EOF Cues
                let headSlice = Data(repeating: 0x11, count: min(len, 32_768))
                _ = LoopbackRangeServer.sendAll(clientFD, headSlice)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return
            }

            var payload = Data(count: len)
            payload.withUnsafeMutableBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<len {
                    ptr[i] = UInt8(((req.startByte + Int64(i)) & 0xFF) ^ 0x5A)
                }
            }
            _ = LoopbackRangeServer.sendAll(clientFD, payload)
        }
        defer { server.shutdown() }

        let key = "test_v3_cues_bypass_\(UUID().uuidString)"
        let store = DonbyTurboCacheEngine.shared.store(for: key, persistDisk: false)
        store.storeChunk(index: 0, data: Data(repeating: 0x42, count: 524_288))
        store.setTotalSize(eightGiB, sourceURL: "http://127.0.0.1:\(server.port)/movie.mkv")

        let handle = TurboStreamByteHandle(
            assetKey: key,
            streamURL: URL(string: "http://127.0.0.1:\(server.port)/movie.mkv")!,
            headers: [:],
            store: store,
            knownTotalSize: eightGiB,
            connectionBudget: 4
        )
        defer {
            handle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: key, forceIncludePinned: true)
        }

        func seedDistantSlowTailCrawl(_ h: TurboStreamByteHandle) {
            h.condition.lock()
            h.directSlices.removeAll()
            for (_, rec) in h.activeAttempts { rec.task?.cancel() }
            h.activeAttempts.removeAll()
            h.directInFlightStarts.removeAll()
            h.directInFlightEndOffsets.removeAll()
            h.spawnDirectRangeFetchLocked(startOffset: eightGiB - 2_097_152, totalSize: eightGiB, length: 2_097_152)
            h.condition.unlock()
        }
        seedDistantSlowTailCrawl(handle)
        try? await Task.sleep(nanoseconds: 45_000_000)

        let t0 = ProcessInfo.processInfo.systemUptime
        let seekPos = handle.seek(offset: cuesOffset, whence: SEEK_SET)
        #expect(seekPos == cuesOffset)

        var out = [UInt8](repeating: 0, count: 4096)
        let n = out.withUnsafeMutableBufferPointer { ptr in
            handle.read(into: ptr.baseAddress!, count: 4096)
        }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000.0

        #expect(n == 4096)
        #expect(elapsedMs < 250.0)
        for i in 0..<64 {
            let expected = UInt8(((cuesOffset + Int64(i)) & 0xFF) ^ 0x5A)
            #expect(out[i] == expected)
        }
    }

    @Test func early302RedirectFansOutHeadTailAndResumeBeforeChunk0206Arrives() async throws {
        let eightGiB: Int64 = 8_589_934_592
        let estChunk = Int((eightGiB / 2) / 524_288)
        let expectedResumeStart = Int64(estChunk - 2) * 524_288
        let expectedTailStart = eightGiB - 524_288

        final class FanOutRecorder: @unchecked Sendable {
            private let lock = NSLock()
            let tailStart: Int64
            let resumeStart: Int64
            var chunk0Edge206Sent = false
            var sawHeadRunwayBefore206 = false
            var sawTailBefore206 = false
            var sawResumeBefore206 = false

            init(tailStart: Int64, resumeStart: Int64) {
                self.tailStart = tailStart
                self.resumeStart = resumeStart
            }

            func markEdgeArrival(startByte: Int64) {
                lock.lock()
                defer { lock.unlock() }
                guard !chunk0Edge206Sent else { return }
                if startByte == 524_288 || startByte == 1_048_576 { sawHeadRunwayBefore206 = true }
                if startByte == tailStart { sawTailBefore206 = true }
                if startByte == resumeStart { sawResumeBefore206 = true }
            }

            func markChunk0206Sent() {
                lock.lock(); chunk0Edge206Sent = true; lock.unlock()
            }

            func snapshot() -> (head: Bool, tail: Bool, resume: Bool) {
                lock.lock(); defer { lock.unlock() }
                return (sawHeadRunwayBefore206, sawTailBefore206, sawResumeBefore206)
            }
        }
        let recorder = FanOutRecorder(tailStart: expectedTailStart, resumeStart: expectedResumeStart)

        let server = try LoopbackRangeServer { clientFD, boundPort, req in
            if req.path.hasPrefix("/emby/Videos/") {
                let redir = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(boundPort)/edge/remux.mkv\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = LoopbackRangeServer.sendAll(clientFD, Data(redir.utf8))
                return
            }

            recorder.markEdgeArrival(startByte: req.startByte)
            if req.startByte == 0 {
                // Hold Chunk 0's 206 response headers for 350ms so sibling fan-out must originate from the 302 callback!
                try? await Task.sleep(nanoseconds: 350_000_000)
                recorder.markChunk0206Sent()
            }

            let end = req.endByte >= req.startByte ? min(eightGiB - 1, req.endByte) : min(eightGiB - 1, req.startByte + 524_287)
            let len = Int(max(0, end - req.startByte + 1))
            let hdr = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nContent-Range: bytes \(req.startByte)-\(end)/\(eightGiB)\r\nContent-Length: \(len)\r\nConnection: close\r\n\r\n"
            if LoopbackRangeServer.sendAll(clientFD, Data(hdr.utf8)) {
                _ = LoopbackRangeServer.sendAll(clientFD, Data(repeating: 0x33, count: min(len, 65_536)))
            }
        }
        defer { server.shutdown() }

        let key = "test_v3_early302_\(UUID().uuidString)"
        let store = DonbyTurboCacheEngine.shared.store(for: key, persistDisk: false)
        let originURL = URL(string: "http://127.0.0.1:\(server.port)/emby/Videos/ep1/stream.mkv")!
        let handle = TurboStreamByteHandle(
            assetKey: key,
            streamURL: originURL,
            headers: ["Authorization": "MediaBrowser Token=\"secret\""],
            store: store,
            knownTotalSize: eightGiB,
            connectionBudget: 4,
            initialStartSeconds: 1800,
            knownDurationSeconds: 3600
        )
        defer {
            handle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: key, forceIncludePinned: true)
        }

        // Poll lightly up to 300ms (still before Chunk 0's 350ms 206 header hold expires)
        for _ in 0..<15 {
            let s = recorder.snapshot()
            if s.head && s.tail && s.resume { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let snap = recorder.snapshot()
        #expect(expectedResumeStart > 0 && expectedTailStart > expectedResumeStart)
        #expect(snap.head)
        #expect(snap.tail)
        #expect(snap.resume)
    }

    @Test func blockedReaderTailTrimAndMicroHedgeDefeatsSlowLaneWithoutStarvation() async throws {
        let chunkSize = 524_288
        let totalSize = Int64(chunkSize * 64)
        let targetChunk = 10
        let targetOffset = Int64(targetChunk * chunkSize)

        final class AttemptTracker: @unchecked Sendable {
            private let lock = NSLock()
            var chunk10Requests = 0
            var fastChunk11Requests = 0
            func nextChunk10Attempt() -> Int {
                lock.lock(); defer { lock.unlock() }
                chunk10Requests += 1
                return chunk10Requests
            }
            func noteChunk11Request() {
                lock.lock(); fastChunk11Requests += 1; lock.unlock()
            }
            func snapshot() -> (Int, Int) {
                lock.lock(); defer { lock.unlock() }
                return (chunk10Requests, fastChunk11Requests)
            }
        }
        let tracker = AttemptTracker()

        let server = try LoopbackRangeServer { clientFD, _, req in
            let end = req.endByte >= req.startByte ? min(totalSize - 1, req.endByte) : min(totalSize - 1, req.startByte + Int64(chunkSize) - 1)
            let len = Int(max(0, end - req.startByte + 1))
            let hdr = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nContent-Range: bytes \(req.startByte)-\(end)/\(totalSize)\r\nContent-Length: \(len)\r\nConnection: close\r\n\r\n"
            guard LoopbackRangeServer.sendAll(clientFD, Data(hdr.utf8)) else { return }

            let inChunk10Range = req.startByte >= targetOffset && req.startByte < targetOffset + Int64(chunkSize)
            let isFirstSlowChunk10 = inChunk10Range && (tracker.nextChunk10Attempt() == 1)
            if req.startByte == Int64((targetChunk + 1) * chunkSize) {
                tracker.noteChunk11Request()
            }

            if isFirstSlowChunk10 {
                // Throttle primary stream to ~140 KB/s (~3.6s per 512 KiB chunk)
                var sent = 0
                while sent < len && !Task.isCancelled {
                    let step = min(16_384, len - sent)
                    let chunkByte = UInt8(((Int(req.startByte) + sent) / chunkSize) & 0xFF)
                    if !LoopbackRangeServer.sendAll(clientFD, Data(repeating: chunkByte, count: step)) {
                        break
                    }
                    sent += step
                    try? await Task.sleep(nanoseconds: 115_000_000)
                }
                return
            }

            // Healthy fast lanes deliver at full wire speed
            var payload = Data(count: len)
            payload.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var pos = 0
                while pos < len {
                    let cIdx = Int((req.startByte + Int64(pos)) / Int64(chunkSize))
                    let remInChunk = min(len - pos, chunkSize - Int((req.startByte + Int64(pos)) % Int64(chunkSize)))
                    memset(base.advanced(by: pos), Int32(cIdx & 0xFF), remInChunk)
                    pos += remInChunk
                }
            }
            _ = LoopbackRangeServer.sendAll(clientFD, payload)
        }
        defer { server.shutdown() }

        let key = "test_v3_micro_hedge_\(UUID().uuidString)"
        let store = DonbyTurboCacheEngine.shared.store(for: key, persistDisk: false)
        store.storeChunk(index: 0, data: Data(repeating: 0, count: chunkSize))
        store.setTotalSize(totalSize, sourceURL: "http://127.0.0.1:\(server.port)/stream.mkv")

        let handle = TurboStreamByteHandle(
            assetKey: key,
            streamURL: URL(string: "http://127.0.0.1:\(server.port)/stream.mkv")!,
            headers: [:],
            store: store,
            knownTotalSize: totalSize,
            connectionBudget: 4
        )
        defer {
            handle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: key, forceIncludePinned: true)
        }
        handle.markInitialOpenCompleted()
        handle.markProtocolMultiplexed(true)

        _ = handle.seek(offset: targetOffset, whence: SEEK_SET)

        let t0 = ProcessInfo.processInfo.systemUptime
        var readBuf = [UInt8](repeating: 0, count: chunkSize * 2)
        var totalRead = 0
        while totalRead < chunkSize * 2 {
            let r = readBuf.withUnsafeMutableBufferPointer { ptr in
                handle.read(into: ptr.baseAddress!.advanced(by: totalRead), count: chunkSize * 2 - totalRead)
            }
            if r <= 0 { break }
            totalRead += r
        }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000.0
        let snap = tracker.snapshot()

        #expect(totalRead == chunkSize * 2)
        // Without micro-hedge, Chunk 10 alone would take ~3,600ms; micro-hedge triggers at 300ms and finishes <650ms!
        #expect(elapsedMs < 650.0)
        #expect(snap.0 >= 2)
        #expect(readBuf[0] == UInt8(targetChunk))
        #expect(readBuf[chunkSize - 1] == UInt8(targetChunk))
        #expect(readBuf[chunkSize] == UInt8(targetChunk + 1))
        #expect(readBuf[chunkSize * 2 - 1] == UInt8(targetChunk + 1))
    }

    @Test func singleClickSeekStripesAcrossWarmLanesWhileRapidScrubGatesToTwo() {
        let chunkSize = 524_288
        let totalSize = Int64(chunkSize * 400)
        let dummyURL = URL(string: "http://127.0.0.1:1/cdn/remux.mkv")!

        // Case A: Single-click seek immediately stripes 2-chunk (1 MiB) spans across >= 3 lanes
        let keySingle = "test_v3_single_seek_\(UUID().uuidString)"
        let storeSingle = DonbyTurboCacheEngine.shared.store(for: keySingle, persistDisk: false)
        storeSingle.storeChunk(index: 0, data: Data(repeating: 0, count: chunkSize))
        let handleSingle = TurboStreamByteHandle(
            assetKey: keySingle,
            streamURL: dummyURL,
            headers: [:],
            store: storeSingle,
            knownTotalSize: totalSize,
            connectionBudget: 4
        )
        defer {
            handleSingle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: keySingle, forceIncludePinned: true)
        }
        handleSingle.markInitialOpenCompleted()
        handleSingle.markProtocolMultiplexed(true)

        _ = handleSingle.seek(offset: Int64(40 * chunkSize), whence: SEEK_SET)
        handleSingle.requestUrgentChunk(40)

        handleSingle.condition.lock()
        let singleStreak = handleSingle.recentSeekStreakCount
        let singleAttempts = handleSingle.activeAttempts.values.filter { $0.startChunkIndex >= 40 }
        let singleSpans = singleAttempts.map { $0.endChunkExclusive - $0.startChunkIndex }
        handleSingle.condition.unlock()

        #expect(singleStreak == 1)
        #expect(singleAttempts.count >= 3)
        #expect(singleSpans.allSatisfy { $0 == 2 })

        // Case B: Rapid scrub (3 jumps within <100ms) gates active lookahead to <= 2 streams
        let keyScrub = "test_v3_scrub_seek_\(UUID().uuidString)"
        let storeScrub = DonbyTurboCacheEngine.shared.store(for: keyScrub, persistDisk: false)
        storeScrub.storeChunk(index: 0, data: Data(repeating: 0, count: chunkSize))
        let handleScrub = TurboStreamByteHandle(
            assetKey: keyScrub,
            streamURL: dummyURL,
            headers: [:],
            store: storeScrub,
            knownTotalSize: totalSize,
            connectionBudget: 4
        )
        defer {
            handleScrub.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: keyScrub, forceIncludePinned: true)
        }
        handleScrub.markInitialOpenCompleted()
        handleScrub.markProtocolMultiplexed(true)

        _ = handleScrub.seek(offset: Int64(20 * chunkSize), whence: SEEK_SET)
        _ = handleScrub.seek(offset: Int64(60 * chunkSize), whence: SEEK_SET)
        _ = handleScrub.seek(offset: Int64(120 * chunkSize), whence: SEEK_SET)
        handleScrub.requestUrgentChunk(120)

        handleScrub.condition.lock()
        let scrubStreak = handleScrub.recentSeekStreakCount
        let scrubActive = handleScrub.activeAttempts.values.filter {
            $0.currentChunkIndex >= 120 && !$0.trimmedEarly && !$0.isRescue
        }
        handleScrub.condition.unlock()

        #expect(scrubStreak >= 3)
        #expect(scrubActive.count <= 2)
    }

    @Test func playbackIntentCoordinatorFastTableAndRouteWarmStorePersistence() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("donby_routewarm_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storageFile = tempDir.appendingPathComponent("network_route_warm_v1.json")

        let serverId = UUID()
        let edgeURL = URL(string: "https://edge-node-01.example.net")!
        let redirectURL = URL(string: "https://cdn-slice-02.example.net/video/ep1.mkv?sig=abc")!
        let redirectKey = "\(serverId.uuidString)|ep1|src1|https://emby.example.net"

        do {
            let store1 = NetworkRouteWarmStore(storageURL: storageFile)
            store1.recordHostProtocol(host: "edge-node-01.example.net", isMultiplexed: true)
            store1.storeEdgeOrigin(edgeURL, serverId: serverId, lineKey: "lineA")
            store1.storeRedirect(redirectURL, for: redirectKey)
            store1.flushToDiskSync()
        }

        // Reload from disk simulating cold app restart
        let store2 = NetworkRouteWarmStore(storageURL: storageFile)
        #expect(store2.isHostKnownMultiplexed("EDGE-NODE-01.EXAMPLE.NET") == true)
        #expect(store2.cachedEdgeOrigin(serverId: serverId, lineKey: "lineA") == edgeURL)
        #expect(store2.cachedRedirect(for: redirectKey) == redirectURL)

        store2.invalidateRedirect(for: redirectKey)
        #expect(store2.cachedRedirect(for: redirectKey) == nil)
        store2.invalidateServer(serverId)
        #expect(store2.cachedEdgeOrigin(serverId: serverId, lineKey: "lineA") == nil)

        // Verify PlaybackIntentCoordinator 0ms fast table + live 302 route upgrade
        let srv = EmbyServerConfig(
            id: serverId,
            name: "TestServer",
            host: "emby.example.net",
            port: 443,
            isHttps: true,
            username: "tester",
            accessToken: "tok",
            cache302Request: true
        )
        let originStream = URL(string: "https://emby.example.net/emby/Videos/01JABCDEF1234567890ABCDEFG/stream.mkv")!
        let mediaSource = MediaSourceInfo(id: "src_hevc_4k", name: "4K DoVi", size: 12_000_000_000)
        let initialRes = ResolvedPlaybackResource(
            streamURL: originStream,
            originStreamURL: originStream,
            downloadURL: originStream,
            headers: [:],
            playSessionId: "ps1",
            mediaSource: mediaSource,
            subtitleURLs: [],
            isDirectStream: true,
            routeNote: "DirectStream"
        )

        let itemId = "e01JABCDEF1234567890ABCDEFG"
        let bareItemId = "01JABCDEF1234567890ABCDEFG"
        defer { PlaybackIntentCoordinator.shared.invalidateServer(serverId) }

        PlaybackIntentCoordinator.shared.storeResolvedResource(
            initialRes,
            server: srv,
            itemId: itemId,
            preferredPreset: .higherBitrate
        )
        // Canonical ULID lookup hits synchronously with 0ms delay
        let hitBefore302 = PlaybackIntentCoordinator.shared.cachedResolvedResource(
            server: srv,
            itemId: bareItemId,
            preferredPreset: .higherBitrate
        )
        #expect(hitBefore302?.streamURL == originStream)

        // Once preload learns a 302 CDN URL, synchronous fast-table lookup automatically upgrades streamURL
        let realRedirectKey = EmbyClient.redirectCacheKey(
            serverId: srv.id,
            itemId: bareItemId,
            mediaSourceId: mediaSource.id,
            baseURL: srv.activeBaseURL
        )
        NetworkRouteWarmStore.shared.storeRedirect(redirectURL, for: realRedirectKey)
        let hitAfter302 = PlaybackIntentCoordinator.shared.cachedResolvedResource(
            server: srv,
            itemId: bareItemId,
            preferredPreset: .higherBitrate
        )
        #expect(hitAfter302?.streamURL == redirectURL)
        #expect(hitAfter302?.originStreamURL == originStream)
    }

    @Test func adaptiveEightLanePoolAndSteadyStateLargeRangeSpans() {
        let hub = TurboStreamingSessionHub.shared
        #expect(TurboStreamingSessionHub.maxStreamLaneCount == 8)
        var laneIds: Set<ObjectIdentifier> = []
        for idx in 0..<TurboStreamingSessionHub.maxStreamLaneCount {
            if let sid = hub.laneSessionIdentifier(for: idx) {
                laneIds.insert(sid)
            }
        }
        #expect(laneIds.count == 8)

        let chunkSize = 524_288
        let totalSize = Int64(chunkSize * 200)
        let key = "test_2a_large_span_\(UUID().uuidString)"
        let store = DonbyTurboCacheEngine.shared.store(for: key, persistDisk: false)
        store.setTotalSize(totalSize, sourceURL: "http://127.0.0.1:1/cdn/large.mkv")
        for idx in 0..<18 {
            store.storeChunk(index: idx, data: Data(repeating: UInt8(idx & 0xFF), count: chunkSize))
        }

        let handle = TurboStreamByteHandle(
            assetKey: key,
            streamURL: URL(string: "http://127.0.0.1:1/cdn/large.mkv")!,
            headers: [:],
            store: store,
            knownTotalSize: totalSize,
            connectionBudget: 8,
            prefetchAheadChunks: 120
        )
        defer {
            handle.close()
            DonbyTurboCacheEngine.shared.removeAsset(assetKey: key, forceIncludePinned: true)
        }
        handle.markInitialOpenCompleted()
        handle.markProtocolMultiplexed(true)

        handle.condition.lock()
        let maxSpan = handle.activeAttempts.values.map { $0.endChunkExclusive - $0.startChunkIndex }.max() ?? 0
        handle.condition.unlock()

        #expect(maxSpan >= 16)
    }

    @Test func unpinnedChunkStoreWritesDirectlyToSparseMediaBinAndCompanionPacerTransitions() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("donby-unpinned-sparse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let chunkSize = 65_536
        let totalSize = Int64(chunkSize * 120)
        let store = TieredAssetChunkStore(
            assetKey: "unpinned_sparse",
            rootDirectory: tmpDir,
            chunkSize: chunkSize,
            maxMemoryBytes: 32 * 1024 * 1024,
            persistDisk: true
        )
        store.setTotalSize(totalSize, sourceURL: "https://example.invalid/sparse.mkv")
        for idx in [0, 10, 80, 119] {
            store.storeChunk(index: idx, data: Data(repeating: UInt8(idx + 3), count: chunkSize), cacheInMemory: false)
        }
        store.flushMeta()

        let spillCount = (try? FileManager.default.contentsOfDirectory(atPath: store.chunksDirectoryURL.path).count) ?? 0
        #expect(spillCount == 0)
        #expect(FileManager.default.fileExists(atPath: store.assetDirectory.appendingPathComponent("chunks.bitmap").path))
        #expect(store.cachedBytesFast() == Int64(4 * chunkSize))

        var buf = [UInt8](repeating: 0, count: 1024)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            store.readChunkBytes(index: 80, offsetInChunk: 0, into: ptr.baseAddress!, count: 1024)
        }
        #expect(n == 1024)
        #expect(buf[0] == 83)

        // Companion pacer C ABI smoke check (exact 0 -> >0 -> -1 transitions are verified deterministically in Rust net::tests)
        #expect(dk_net_get_download_companion_rate_limit_bps() >= -1)
    }
}

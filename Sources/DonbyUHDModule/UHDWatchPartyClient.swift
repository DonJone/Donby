import Foundation
import DonbyCore
import DonbyNetwork

private struct WPCreateEnvelope: Decodable {
    let ok: Bool
    let data: WPCreateData?
    let msg: String?
}

private struct WPCreateData: Decodable {
    let id: String
    let invite: String
}

private struct WPJoinEnvelope: Decodable {
    let ok: Bool
    let data: WPJoinData?
    let msg: String?
}

private struct WPJoinData: Decodable {
    let id: String
}

private struct WPOkEnvelope: Decodable {
    let ok: Bool
    let msg: String?
}

private struct WPServerFrame: Decodable {
    let type: String
    let room: UHDWatchPartyRoomSnapshot?
    let clientMs: Int64?
    let serverMs: Int64?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type, room, code, message
        case clientMs = "client_ms"
        case serverMs = "server_ms"
    }
}

public final class UHDWatchPartyClient: Sendable {
    public static let shared = UHDWatchPartyClient()
    private static let sharedDecoder = JSONDecoder()
    private let session: URLSession

    private init() {
        self.session = DonbyNetworkSession.sharedURLSession
    }

    private func normalizedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func makeRequest(
        server: EmbyServerConfig,
        path: String,
        method: String,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        let base = normalizedBase(server.mainLineURL)
        guard let url = URL(string: base + path) else {
            throw EmbyClientError.invalidServerURL(base + path)
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Donby/\(DonbyAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        if !server.accessToken.isEmpty {
            req.setValue(server.accessToken, forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    public func createRoom(server: EmbyServerConfig, assetId: String, maxMembers: Int = 4) async throws -> UHDWatchPartyCreatedRoom {
        let clampedMax = max(1, min(10, maxMembers))
        let req = try makeRequest(
            server: server,
            path: "/api/v1/stream/watch-parties",
            method: "POST",
            body: ["asset_id": assetId, "max_members": clampedMax]
        )
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? Self.sharedDecoder.decode(WPOkEnvelope.self, from: data))?.msg ?? "创建同看房间失败 (HTTP \(http.statusCode))"
            throw EmbyClientError.httpStatus(http.statusCode, msg)
        }
        let env = try Self.sharedDecoder.decode(WPCreateEnvelope.self, from: data)
        guard env.ok, let d = env.data else {
            throw EmbyClientError.httpStatus(500, env.msg ?? "创建同看房间失败")
        }
        return UHDWatchPartyCreatedRoom(id: d.id, invite: d.invite)
    }

    public func joinRoom(server: EmbyServerConfig, inviteCode: String) async throws -> String {
        guard let normalized = UHDWatchPartyInviteParser.extractInviteCode(from: inviteCode) else {
            throw EmbyClientError.httpStatus(400, "请输入 8 位数字邀请码或同看邀请链接")
        }
        let req = try makeRequest(
            server: server,
            path: "/api/v1/stream/watch-parties/join",
            method: "POST",
            body: ["invite": normalized]
        )
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? Self.sharedDecoder.decode(WPOkEnvelope.self, from: data))?.msg ?? {
                switch http.statusCode {
                case 404: return "房间已结束或邀请码无效"
                case 409: return "房间已满、已锁定或当前账号已在其他同看房间"
                default: return "加入同看失败 (HTTP \(http.statusCode))"
                }
            }()
            throw EmbyClientError.httpStatus(http.statusCode, msg)
        }
        let env = try Self.sharedDecoder.decode(WPJoinEnvelope.self, from: data)
        guard env.ok, let d = env.data else {
            throw EmbyClientError.httpStatus(500, env.msg ?? "加入同看失败")
        }
        return d.id
    }

    public func leaveRoom(server: EmbyServerConfig, roomId: String) async throws {
        let req = try makeRequest(server: server, path: "/api/v1/stream/watch-parties/\(roomId)/membership", method: "DELETE")
        try await performVoid(req)
    }

    public func endRoom(server: EmbyServerConfig, roomId: String) async throws {
        let req = try makeRequest(server: server, path: "/api/v1/stream/watch-parties/\(roomId)", method: "DELETE")
        try await performVoid(req)
    }

    public func setLocked(server: EmbyServerConfig, roomId: String, locked: Bool) async throws {
        let req = try makeRequest(server: server, path: "/api/v1/stream/watch-parties/\(roomId)", method: "PATCH", body: ["locked": locked])
        try await performVoid(req)
    }

    public func kickMember(server: EmbyServerConfig, roomId: String, userId: String) async throws {
        let req = try makeRequest(server: server, path: "/api/v1/stream/watch-parties/\(roomId)/members/\(userId)", method: "DELETE")
        try await performVoid(req)
    }

    public func transferHost(server: EmbyServerConfig, roomId: String, userId: String) async throws {
        let req = try makeRequest(server: server, path: "/api/v1/stream/watch-parties/\(roomId)/host", method: "PUT", body: ["user_id": userId])
        try await performVoid(req)
    }

    private func performVoid(_ req: URLRequest) async throws {
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? Self.sharedDecoder.decode(WPOkEnvelope.self, from: data))?.msg ?? "同看操作失败 (HTTP \(http.statusCode))"
            throw EmbyClientError.httpStatus(http.statusCode, msg)
        }
    }
}

public enum UHDWatchPartyConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case terminated(reason: String)
}

@MainActor
public final class UHDWatchPartySession: ObservableObject {
    @Published public private(set) var server: EmbyServerConfig
    @Published public private(set) var roomId: String
    @Published public private(set) var inviteCode: String?
    @Published public private(set) var currentUserId: String
    @Published public private(set) var snapshot: UHDWatchPartyRoomSnapshot?
    @Published public private(set) var connectionState: UHDWatchPartyConnectionState = .idle
    @Published public private(set) var lastErrorMessage: String?

    private static let sharedDecoder = JSONDecoder()

    /// Estimated `(serverTimeMs - localUnixTimeMs)` updated via heartbeat/pong RTT estimation.
    public private(set) var serverClockOffsetMs: Double = 0

    public var onRoomSnapshot: ((UHDWatchPartyRoomSnapshot) -> Void)?
    public var onStaleRevision: ((UHDWatchPartyRoomSnapshot?) -> Void)?
    public var onTerminated: ((String) -> Void)?

    public var isHost: Bool {
        guard let snap = snapshot, !currentUserId.isEmpty else { return false }
        return snap.hostId == currentUserId
    }

    public var estimatedServerNowMs: Int64 {
        let localNow = Date().timeIntervalSince1970 * 1000.0
        return Int64((localNow + serverClockOffsetMs).rounded())
    }

    private var wsSession: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var intentionallyStopped: Bool = false
    private var reconnectAttempt: Int = 0

    public init(server: EmbyServerConfig, roomId: String, inviteCode: String? = nil, currentUserId: String = "") {
        self.server = server
        self.roomId = roomId
        self.inviteCode = inviteCode
        self.currentUserId = currentUserId
    }

    public func updateCurrentUserId(_ uid: String) {
        if !uid.isEmpty, currentUserId != uid {
            currentUserId = uid
        }
    }

    public func connect() {
        intentionallyStopped = false
        reconnectAttempt = 0
        openSocket()
    }

    public func disconnect(permanently: Bool = true) {
        if permanently {
            intentionallyStopped = true
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        if permanently && connectionState != .idle {
            connectionState = .idle
        }
    }

    private func openSocket() {
        disconnect(permanently: false)
        guard !intentionallyStopped else { return }

        var base = server.mainLineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasPrefix("https://") {
            base = "wss://" + base.dropFirst(8)
        } else if base.lowercased().hasPrefix("http://") {
            base = "ws://" + base.dropFirst(7)
        }
        guard var comps = URLComponents(string: base + "/api/v1/stream/watch-party-socket") else {
            connectionState = .terminated(reason: "同看地址无效")
            return
        }
        comps.queryItems = [URLQueryItem(name: "room_id", value: roomId)]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Donby/\(DonbyAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        if !server.accessToken.isEmpty {
            req.setValue(server.accessToken, forHTTPHeaderField: "Authorization")
        }

        let cfg = URLSessionConfiguration.ephemeral
        let urlSession = URLSession(configuration: cfg)
        let task = urlSession.webSocketTask(with: req)
        self.wsSession = urlSession
        self.wsTask = task
        let nextConnState: UHDWatchPartyConnectionState = (reconnectAttempt == 0) ? .connecting : .reconnecting
        if self.connectionState != nextConnState {
            self.connectionState = nextConnState
        }
        task.resume()

        startHeartbeatLoop()
        startReceiveLoop(for: task)
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { break }
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
                self.sendJSON(["type": "heartbeat", "client_ms": nowMs])
            }
        }
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { break }
                    switch message {
                    case .string(let text):
                        self.handleServerText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleServerText(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, !self.intentionallyStopped else { break }
                    self.scheduleReconnect()
                    break
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !intentionallyStopped else { return }
        reconnectAttempt += 1
        if reconnectAttempt > 12 {
            let reason = "同看连接断开，已停止自动重连"
            let nextState: UHDWatchPartyConnectionState = .terminated(reason: reason)
            if connectionState != nextState {
                connectionState = nextState
            }
            onTerminated?(reason)
            return
        }
        if connectionState != .reconnecting {
            connectionState = .reconnecting
        }
        let delaySec = min(6.0, Double(reconnectAttempt) * 0.8)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.intentionallyStopped else { return }
            self.openSocket()
        }
    }

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? Self.sharedDecoder.decode(WPServerFrame.self, from: data) else {
            return
        }
        switch frame.type {
        case "snapshot", "ack":
            if let room = frame.room {
                if connectionState != .connected {
                    connectionState = .connected
                }
                reconnectAttempt = 0
                if let inv = room.invite, !inv.isEmpty, inviteCode != inv {
                    inviteCode = inv
                }
                if snapshot != room {
                    snapshot = room
                }
                onRoomSnapshot?(room)
            }
        case "pong":
            if let clientMs = frame.clientMs, let serverMs = frame.serverMs {
                let nowMs = Date().timeIntervalSince1970 * 1000.0
                let rtt = max(0.0, nowMs - Double(clientMs))
                let estimatedOffset = Double(serverMs) - (Double(clientMs) + rtt * 0.5)
                if serverClockOffsetMs == 0 {
                    serverClockOffsetMs = estimatedOffset
                } else {
                    serverClockOffsetMs = serverClockOffsetMs * 0.7 + estimatedOffset * 0.3
                }
            }
        case "error":
            let nextErr = frame.message ?? frame.code ?? "同看同步错误"
            if lastErrorMessage != nextErr {
                lastErrorMessage = nextErr
            }
            if frame.code == "PARTY_STALE" {
                onStaleRevision?(snapshot)
            }
        case "closed":
            let reason = "房主已结束本次同看房间"
            disconnect(permanently: true)
            let nextState: UHDWatchPartyConnectionState = .terminated(reason: reason)
            if connectionState != nextState {
                connectionState = nextState
            }
            onTerminated?(reason)
        case "removed":
            let reason = "你已离开或被移出同看房间"
            disconnect(permanently: true)
            let nextState: UHDWatchPartyConnectionState = .terminated(reason: reason)
            if connectionState != nextState {
                connectionState = nextState
            }
            onTerminated?(reason)
        case "replaced":
            let reason = "当前账号已在其他设备加入同看，本端已断开"
            disconnect(permanently: true)
            let nextState: UHDWatchPartyConnectionState = .terminated(reason: reason)
            if connectionState != nextState {
                connectionState = nextState
            }
            onTerminated?(reason)
        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let wsTask,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else {
            return
        }
        wsTask.send(.string(str)) { _ in }
    }

    public func sendPlayback(state: String, positionSeconds: Double, rate: Double = 1.0, playing: Bool? = nil) {
        guard let rev = snapshot?.revision else { return }
        let clampedPos = max(0, min(604_800_000, Int64((positionSeconds * 1000.0).rounded())))
        let clampedRate = max(0.25, min(3.0, rate))
        var msg: [String: Any] = [
            "type": "playback",
            "revision": rev,
            "state": state,
            "position_ms": clampedPos,
            "rate": clampedRate
        ]
        if let playing {
            msg["playing"] = playing
        }
        sendJSON(msg)
    }

    public func sendSwitch(assetId: String, positionSeconds: Double = 0, rate: Double = 1.0, playing: Bool = true) {
        guard let rev = snapshot?.revision, !assetId.isEmpty else { return }
        let clampedPos = max(0, min(604_800_000, Int64((positionSeconds * 1000.0).rounded())))
        sendJSON([
            "type": "switch",
            "revision": rev,
            "asset_id": assetId,
            "position_ms": clampedPos,
            "rate": max(0.25, min(3.0, rate)),
            "playing": playing
        ])
    }

    public func sendMemberStatus(_ status: String) {
        guard let rev = snapshot?.revision else { return }
        sendJSON([
            "type": "status",
            "revision": rev,
            "status": status
        ])
    }

    /// Wait up to `timeoutSeconds` for the first room snapshot after connecting (used by Join flow).
    public func waitForFirstSnapshot(timeoutSeconds: Double = 8.0) async -> UHDWatchPartyRoomSnapshot? {
        if let snap = snapshot { return snap }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let snap = snapshot { return snap }
            if case .terminated = connectionState { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return snapshot
    }
}

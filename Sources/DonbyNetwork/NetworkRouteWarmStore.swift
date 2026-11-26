import Foundation
import DonbyCore

/// Lightweight `DONBY_HOME`-isolated route & protocol warm store.
/// Persists HTTP/2-HTTP/3 host multiplexing capabilities (7d TTL), resolved CDN edge origins (300s TTL),
/// and recent 302 direct stream targets (1800s TTL) with synchronous in-memory lookup and debounced disk flush.
public final class NetworkRouteWarmStore: @unchecked Sendable {
    public static let shared = NetworkRouteWarmStore()

    struct ProtocolRecord: Codable, Equatable {
        var isMultiplexed: Bool
        var expiresAt: Date
    }

    struct URLRecord: Codable, Equatable {
        var urlString: String
        var expiresAt: Date
    }

    struct PersistedPayload: Codable {
        var schemaVersion: Int = 1
        var protocols: [String: ProtocolRecord] = [:]
        var edgeOrigins: [String: URLRecord] = [:]
        var redirects: [String: URLRecord] = [:]
    }

    private static let maxProtocolEntries = 256
    private static let maxEdgeOriginEntries = 64
    private static let maxRedirectEntries = 256

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.donby.network.routewarm", qos: .utility)
    private let explicitStorageURL: URL?
    private var loadedDirectoryPath: String = ""
    private var payload = PersistedPayload()
    private var flushScheduled = false

    internal init(storageURL: URL? = nil) {
        self.explicitStorageURL = storageURL
        let targetURL = Self.resolveStorageURL(explicit: storageURL)
        self.loadedDirectoryPath = targetURL.path
        if let data = try? Data(contentsOf: targetURL),
           let decoded = try? JSONDecoder().decode(PersistedPayload.self, from: data) {
            var pruned = decoded
            Self.pruneExpired(&pruned, now: Date())
            self.payload = pruned
        }
    }

    private static func resolveStorageURL(explicit: URL?) -> URL {
        if let explicit { return explicit }
        return DonbyStoragePaths.cachesDirectoryURL
            .appendingPathComponent("DonbyNetwork", isDirectory: true)
            .appendingPathComponent("network_route_warm_v1.json", isDirectory: false)
    }

    private func ensureCurrentHomeLoadedLocked() {
        guard explicitStorageURL == nil else { return }
        let currentURL = Self.resolveStorageURL(explicit: nil)
        guard currentURL.path != loadedDirectoryPath else { return }
        loadedDirectoryPath = currentURL.path
        if let data = try? Data(contentsOf: currentURL),
           let decoded = try? JSONDecoder().decode(PersistedPayload.self, from: data) {
            var pruned = decoded
            Self.pruneExpired(&pruned, now: Date())
            payload = pruned
        } else {
            payload = PersistedPayload()
        }
    }

    private static func pruneExpired(_ state: inout PersistedPayload, now: Date) {
        state.protocols = state.protocols.filter { $0.value.expiresAt > now }
        state.edgeOrigins = state.edgeOrigins.filter { $0.value.expiresAt > now }
        state.redirects = state.redirects.filter { $0.value.expiresAt > now }
    }

    // MARK: - HTTP/2 & HTTP/3 Multiplexing Capability Cache (TTL 7d)

    public func isHostKnownMultiplexed(_ rawHost: String?) -> Bool? {
        guard let host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        let now = Date()
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        guard let rec = payload.protocols[host] else {
            lock.unlock()
            return nil
        }
        if rec.expiresAt <= now {
            payload.protocols.removeValue(forKey: host)
            lock.unlock()
            return nil
        }
        let val = rec.isMultiplexed
        lock.unlock()
        return val
    }

    public func recordHostProtocol(host rawHost: String?, isMultiplexed: Bool, ttlSeconds: TimeInterval = 7 * 86_400) {
        guard let host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return }
        let now = Date()
        var needsFlush = false
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        let prev = payload.protocols[host]
        let newExpiry = now.addingTimeInterval(max(60, ttlSeconds))
        if prev?.isMultiplexed != isMultiplexed || (prev.map { $0.expiresAt.timeIntervalSince(now) < ttlSeconds * 0.5 } ?? true) {
            if payload.protocols.count >= Self.maxProtocolEntries {
                payload.protocols = payload.protocols.filter { $0.value.expiresAt > now }
                if payload.protocols.count >= Self.maxProtocolEntries,
                   let oldest = payload.protocols.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                    payload.protocols.removeValue(forKey: oldest)
                }
            }
            payload.protocols[host] = ProtocolRecord(isMultiplexed: isMultiplexed, expiresAt: newExpiry)
            needsFlush = scheduleFlushLocked()
        }
        lock.unlock()
        if needsFlush { dispatchDebouncedFlush() }
    }

    // MARK: - Edge Origin Base URL Cache (TTL 300s)

    public func cachedEdgeOrigin(serverId: UUID, lineKey: String = "default") -> URL? {
        let key = "\(serverId.uuidString)|\(lineKey)"
        let now = Date()
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        guard let rec = payload.edgeOrigins[key] else {
            lock.unlock()
            return nil
        }
        if rec.expiresAt <= now {
            payload.edgeOrigins.removeValue(forKey: key)
            lock.unlock()
            return nil
        }
        let urlStr = rec.urlString
        lock.unlock()
        return URL(string: urlStr)
    }

    public func storeEdgeOrigin(_ url: URL, serverId: UUID, lineKey: String = "default", ttlSeconds: TimeInterval = 300) {
        let key = "\(serverId.uuidString)|\(lineKey)"
        let now = Date()
        var needsFlush = false
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        if payload.edgeOrigins.count >= Self.maxEdgeOriginEntries {
            payload.edgeOrigins = payload.edgeOrigins.filter { $0.value.expiresAt > now }
            if payload.edgeOrigins.count >= Self.maxEdgeOriginEntries,
               let oldest = payload.edgeOrigins.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                payload.edgeOrigins.removeValue(forKey: oldest)
            }
        }
        payload.edgeOrigins[key] = URLRecord(urlString: url.absoluteString, expiresAt: now.addingTimeInterval(max(10, ttlSeconds)))
        needsFlush = scheduleFlushLocked()
        lock.unlock()
        if needsFlush { dispatchDebouncedFlush() }
    }

    // MARK: - Synchronous 302 Direct Stream Cache (TTL 1800s)

    public func cachedRedirect(for key: String) -> URL? {
        guard !key.isEmpty else { return nil }
        let now = Date()
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        guard let rec = payload.redirects[key] else {
            lock.unlock()
            return nil
        }
        if rec.expiresAt <= now {
            payload.redirects.removeValue(forKey: key)
            lock.unlock()
            return nil
        }
        let urlStr = rec.urlString
        lock.unlock()
        return URL(string: urlStr)
    }

    public func storeRedirect(_ url: URL, for key: String, ttlSeconds: TimeInterval = 1800) {
        guard !key.isEmpty else { return }
        let now = Date()
        var needsFlush = false
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        if payload.redirects.count >= Self.maxRedirectEntries {
            payload.redirects = payload.redirects.filter { $0.value.expiresAt > now }
            if payload.redirects.count >= Self.maxRedirectEntries,
               let oldest = payload.redirects.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                payload.redirects.removeValue(forKey: oldest)
            }
        }
        payload.redirects[key] = URLRecord(urlString: url.absoluteString, expiresAt: now.addingTimeInterval(max(15, ttlSeconds)))
        needsFlush = scheduleFlushLocked()
        lock.unlock()
        if needsFlush { dispatchDebouncedFlush() }
    }

    public func invalidateRedirect(for key: String) {
        guard !key.isEmpty else { return }
        var needsFlush = false
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        if payload.redirects.removeValue(forKey: key) != nil {
            needsFlush = scheduleFlushLocked()
        }
        lock.unlock()
        if needsFlush { dispatchDebouncedFlush() }
    }

    public func invalidateServer(_ serverId: UUID) {
        let prefix = "\(serverId.uuidString)|"
        var needsFlush = false
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        let beforeOrigins = payload.edgeOrigins.count
        let beforeRedirects = payload.redirects.count
        payload.edgeOrigins = payload.edgeOrigins.filter { !$0.key.hasPrefix(prefix) }
        payload.redirects = payload.redirects.filter { !$0.key.hasPrefix(prefix) }
        if payload.edgeOrigins.count != beforeOrigins || payload.redirects.count != beforeRedirects {
            needsFlush = scheduleFlushLocked()
        }
        lock.unlock()
        if needsFlush { dispatchDebouncedFlush() }
    }

    // MARK: - Debounced Disk Persistence

    private func scheduleFlushLocked() -> Bool {
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    private func dispatchDebouncedFlush() {
        ioQueue.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.writeSnapshotNow()
        }
    }

    internal func flushToDiskSync() {
        ioQueue.sync {
            writeSnapshotNow()
        }
    }

    private func writeSnapshotNow() {
        let now = Date()
        let snapshot: PersistedPayload
        let targetURL: URL
        lock.lock()
        ensureCurrentHomeLoadedLocked()
        flushScheduled = false
        Self.pruneExpired(&payload, now: now)
        snapshot = payload
        targetURL = Self.resolveStorageURL(explicit: explicitStorageURL)
        lock.unlock()

        let parent = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        try? encoded.write(to: targetURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
    }
}
